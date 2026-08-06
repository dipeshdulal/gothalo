// Package imagedrop lands an uploaded image inside an agent's working directory
// and hands back the absolute path it wrote.
//
// The whole feature rests on one property of coding agents: give Claude Code (or
// Codex, or opencode) a *path* to an image file and it reads the image. So the
// bridge never has to speak any agent's attachment protocol, and no agent needs
// a new capability — the bridge only has to put the bytes somewhere the agent
// can reach and say where that is. The app then types the path into the composer
// like any other prompt text.
//
// "Somewhere the agent can reach" is why this writes under the agent's own cwd
// rather than a temp dir: agents are scoped to their working directory and
// refuse to read outside it, so /tmp would produce a path the agent declines.
// Same reason the caller resolves the pane to its cwd exactly the way GET /diff
// does — the tree the agent is working in is the tree the image has to land in.
//
// Everything about the written name is derived here, never from the client: the
// upload carries raw bytes and nothing else (see CONTRACT-image.md), the type is
// sniffed from the bytes, and the extension comes from the sniffed type. A
// client that cannot name the file cannot escape the directory.
package imagedrop

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// MaxBytes caps one upload. Phones shoot 4-12 MP stills and a tailnet upload is
// slow enough that anything larger is a mistake rather than a screenshot; the
// handler buffers the whole body, so this doubles as the memory bound per
// in-flight request.
const MaxBytes = 10 << 20 // 10 MiB

// dropDir is the per-repo directory images land in, relative to the agent's cwd.
// Nested under .gothalo/ so everything this bridge ever writes into someone's
// project shares one hideable, disposable root.
const dropDir = ".gothalo/images"

// Retention. Images are a scratch artefact of a single prompt — the agent reads
// the file during that turn and never again — so a repo must not accumulate them
// indefinitely. Pruning happens on every write (there is no daemon loop to hang
// it off, and a write is exactly when the directory grows), bounded both ways:
// by age, and by count so a busy afternoon can't leave hundreds behind.
const (
	retainAge   = 7 * 24 * time.Hour
	retainCount = 40
)

// nameTimeLayout is the timestamp prefix of every file this package writes.
// Fixed-width and zero-padded, so lexicographic order IS chronological order —
// which is what lets pruning sort by name instead of stat-ing every file.
//
// The name is also the clock: prune reads each file's age back out of its name
// rather than from its mtime. That keeps retention a pure function of the
// injected time (deterministic in tests, and immune to a checkout or a copy
// rewriting mtimes), and means a file this package did not write — an unparseable
// name — is never deleted.
const nameTimeLayout = "20060102-150405"

// Errors the handler maps to status codes: 413, 415, 400 respectively.
var (
	ErrTooLarge    = fmt.Errorf("image exceeds the %d MiB limit", MaxBytes>>20)
	ErrUnsupported = errors.New("unsupported image type: want png, jpeg, gif, or webp")
	ErrEmpty       = errors.New("empty image body")
)

// imageExts is the allowlist, sniffed content type -> extension. Only formats a
// coding agent actually reads are here; the sniffed type is the single source of
// the extension, so an uploaded .png that is really a shell script becomes
// neither (it is rejected).
var imageExts = map[string]string{
	"image/png":  ".png",
	"image/jpeg": ".jpg",
	"image/gif":  ".gif",
	"image/webp": ".webp",
}

// Result is the POST /image response: where the image landed, and what the
// bridge decided it was.
type Result struct {
	// Path is absolute — what the app inserts into the composer, and what the
	// agent opens. Absolute rather than relative because the agent's cwd is not
	// necessarily the shell's cwd by the time it reads the file.
	Path string `json:"path"`
	// RelativePath is the same file relative to the agent's cwd, for display.
	RelativePath string `json:"relative_path"`
	// ContentType is what the bytes were sniffed as, not what the client claimed.
	ContentType string `json:"content_type"`
	Bytes       int    `json:"bytes"`
}

// Detect validates an upload and reports the sniffed type and the extension that
// follows from it. Split out from Save so a handler can reject junk before it
// pays for a Herdr round-trip to resolve the pane's cwd.
func Detect(data []byte) (contentType, ext string, err error) {
	if len(data) == 0 {
		return "", "", ErrEmpty
	}
	if len(data) > MaxBytes {
		return "", "", ErrTooLarge
	}
	ct := http.DetectContentType(data)
	ext, ok := imageExts[ct]
	if !ok {
		return ct, "", ErrUnsupported
	}
	return ct, ext, nil
}

// Save writes data into <cwd>/.gothalo/images and returns where it landed. now
// is injected rather than read from the clock so the produced name — and the
// retention sweep that follows the write — are deterministic.
//
// The name is <timestamp>-<content hash>.<ext>. The timestamp alone has
// one-second resolution, so the hash is what keeps two uploads inside the same
// second from landing on one name — collision-free without a counter or a lock.
// It also makes a retried upload idempotent within that second: the same bytes
// re-write the same path rather than leaving a duplicate behind. Across seconds
// the same image does get a second name, which is the deliberate trade — a name
// that ignored time would make retention (which reads the age back out of the
// name) impossible.
func Save(cwd string, data []byte, now time.Time) (Result, error) {
	ct, ext, err := Detect(data)
	if err != nil {
		return Result{}, err
	}
	if !filepath.IsAbs(cwd) {
		// An agent with no resolvable cwd (or a relative one) would send us
		// writing into the bridge's own process directory. Refuse instead.
		return Result{}, fmt.Errorf("agent has no absolute working directory (%q)", cwd)
	}

	dir := filepath.Join(cwd, filepath.FromSlash(dropDir))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Result{}, fmt.Errorf("create %s: %w", dropDir, err)
	}
	if err := ensureIgnored(filepath.Dir(dir)); err != nil {
		return Result{}, err
	}

	sum := sha256.Sum256(data)
	name := now.UTC().Format(nameTimeLayout) + "-" + hex.EncodeToString(sum[:4]) + ext
	full := filepath.Join(dir, name)

	// Write via a temp file in the same directory and rename: the agent may be
	// told the path the instant this returns, and a rename is the only way to
	// guarantee it never opens a half-written image.
	tmp, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		return Result{}, fmt.Errorf("create temp image: %w", err)
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return Result{}, fmt.Errorf("write image: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return Result{}, fmt.Errorf("write image: %w", err)
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		os.Remove(tmpName)
		return Result{}, fmt.Errorf("write image: %w", err)
	}
	if err := os.Rename(tmpName, full); err != nil {
		os.Remove(tmpName)
		return Result{}, fmt.Errorf("write image: %w", err)
	}

	Prune(dir, now)

	return Result{
		Path:         full,
		RelativePath: filepath.ToSlash(filepath.Join(filepath.FromSlash(dropDir), name)),
		ContentType:  ct,
		Bytes:        len(data),
	}, nil
}

// ensureIgnored drops a catch-all .gitignore into .gothalo/ the first time the
// bridge writes there.
//
// Without it every screenshot shows up as an untracked file — in `git status`
// on the desktop, and in gothalo's own GET /diff, which asks for
// --untracked-files=all and would list the review screen full of the images the
// user just attached. A single "*" also ignores the .gitignore itself, so the
// directory stays completely invisible to the repo it lives in.
func ensureIgnored(gothaloDir string) error {
	path := filepath.Join(gothaloDir, ".gitignore")
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	if err := os.WriteFile(path, []byte("*\n"), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// Prune enforces the retention bounds on a drop directory: anything older than
// retainAge goes, and past that only the retainCount newest are kept.
//
// Ages come from the filenames (see nameTimeLayout), so a file whose name this
// package did not produce is counted by neither bound and never removed —
// deleting from inside someone's repository is a place to be conservative.
// Failures are silent by design: retention must never fail the upload that
// triggered it.
func Prune(dir string, now time.Time) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type dropped struct {
		name string
		at   time.Time
	}
	var ours []dropped
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		at, ok := parseDropName(e.Name())
		if !ok {
			continue
		}
		ours = append(ours, dropped{name: e.Name(), at: at})
	}
	sort.Slice(ours, func(i, j int) bool { return ours[i].name < ours[j].name })

	cutoff := now.UTC().Add(-retainAge)
	var keep []dropped
	for _, d := range ours {
		if d.at.Before(cutoff) {
			os.Remove(filepath.Join(dir, d.name))
			continue
		}
		keep = append(keep, d)
	}
	for i := 0; i < len(keep)-retainCount; i++ {
		os.Remove(filepath.Join(dir, keep[i].name))
	}
}

// parseDropName reads the timestamp back out of a name this package wrote,
// reporting !ok for anything that doesn't match the scheme.
func parseDropName(name string) (time.Time, bool) {
	if len(name) < len(nameTimeLayout) {
		return time.Time{}, false
	}
	ext := filepath.Ext(name)
	if _, ok := imageExts[extType(ext)]; !ok {
		return time.Time{}, false
	}
	if !strings.HasPrefix(name[len(nameTimeLayout):], "-") {
		return time.Time{}, false
	}
	at, err := time.ParseInLocation(nameTimeLayout, name[:len(nameTimeLayout)], time.UTC)
	if err != nil {
		return time.Time{}, false
	}
	return at, true
}

// extType is the reverse of imageExts — an extension back to its content type,
// used only to recognise our own files during a prune.
func extType(ext string) string {
	for ct, e := range imageExts {
		if e == ext {
			return ct
		}
	}
	return ""
}
