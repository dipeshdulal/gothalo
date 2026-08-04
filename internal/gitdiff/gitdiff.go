// Package gitdiff collects a working tree's pending changes — the branch, the
// changed-file list, and a per-file unified diff — for GET /diff. It shells
// out to the git binary directly against a pane's cwd; there is no Herdr API
// for this, and the bridge already reads other local state directly (see
// internal/transcript), so a direct git invocation fits the same model.
package gitdiff

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// FileChange is one file in the working tree's pending changes.
type FileChange struct {
	// Path is the file's current location (its new path for a rename).
	Path string `json:"path"`
	// OldPath is set only for a rename/copy — the path it moved from.
	OldPath string `json:"old_path,omitempty"`
	// Status is a coarse classification: "modified" | "added" | "deleted" |
	// "renamed" | "untracked".
	Status    string `json:"status"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
	// Diff is a unified diff for this file alone (untracked files get a
	// synthetic "every line added" diff so the UI has one shape to render).
	Diff string `json:"diff"`
}

// Result is the full GET /diff payload for one pane's working tree.
type Result struct {
	// Branch is best-effort ("" if HEAD is detached or git fails) — never
	// fails the whole request.
	Branch string       `json:"branch"`
	Files  []FileChange `json:"files"`
}

// Branch returns the current git branch for cwd, best-effort: "" when cwd
// isn't a git work tree, git is missing/errors, or HEAD is detached. It's a
// single `git rev-parse` — light enough to call per-agent while assembling a
// snapshot, unlike [Collect] which also diffs the working tree.
func Branch(cwd string) string {
	if cwd == "" {
		return ""
	}
	out, err := gitString(cwd, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return ""
	}
	branch := strings.TrimSpace(out)
	if branch == "HEAD" {
		// Detached HEAD — no branch to show.
		return ""
	}
	return branch
}

// Collect runs git against cwd and returns its pending changes. A cwd that
// isn't a git repository (or has no changes) returns a zero-value Result, not
// an error — only a git invocation that fails outright (e.g. git missing)
// errors, so a quiet non-repo pane just shows "no changes" instead of an
// error screen.
func Collect(cwd string) (Result, error) {
	branch, _ := gitString(cwd, "rev-parse", "--abbrev-ref", "HEAD")

	// --untracked-files=all expands an untracked directory into its individual
	// files (git's default collapses it to one opaque directory entry) — a new
	// package like internal/gitdiff/ should list its actual files, not itself.
	statusRaw, err := gitRaw(cwd, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		// Most likely "not a git repository" — not a bridge error, just
		// nothing to show.
		return Result{}, nil
	}
	entries := parsePorcelain(statusRaw)
	if len(entries) == 0 {
		return Result{Branch: strings.TrimSpace(branch)}, nil
	}

	// One combined diff (working tree vs HEAD) covers every tracked file
	// (staged, unstaged, or both) in a single git invocation; split it back
	// out per file below rather than shelling out once per changed file.
	diffRaw, _ := gitRaw(cwd, "diff", "HEAD", "--no-color")
	diffs := splitUnifiedDiff(diffRaw)

	files := make([]FileChange, 0, len(entries))
	for _, e := range entries {
		fc := FileChange{Path: e.Path, OldPath: e.OldPath, Status: e.Status}
		if d, ok := diffs[e.Path]; ok {
			fc.Diff = d
			fc.Additions, fc.Deletions = countChanges(d)
		} else if e.Status == "untracked" {
			fc.Diff, fc.Additions = untrackedDiff(cwd, e.Path)
		}
		files = append(files, fc)
	}
	return Result{Branch: strings.TrimSpace(branch), Files: files}, nil
}

// entry is one changed file from `git status --porcelain=v1 -z`, before its
// diff text is attached.
type entry struct {
	Path    string
	OldPath string
	Status  string
}

// parsePorcelain parses `git status --porcelain=v1 -z` output: NUL-separated
// records, each "XY path" — with a rename/copy (code contains R or C)
// contributing a second NUL-separated field, the origin path, consumed here
// as the next token rather than split on whitespace (paths can contain
// spaces).
func parsePorcelain(raw []byte) []entry {
	parts := strings.Split(string(raw), "\x00")
	var out []entry
	for i := 0; i < len(parts); i++ {
		p := parts[i]
		if len(p) < 3 {
			continue
		}
		code := p[:2]
		path := p[3:]
		if path == "" {
			continue
		}
		e := entry{Path: path, Status: statusLabel(code)}
		if strings.ContainsAny(code, "RC") {
			i++
			if i < len(parts) {
				e.OldPath = parts[i]
			}
		}
		out = append(out, e)
	}
	return out
}

// statusLabel collapses a porcelain XY code (index + worktree status,
// independently) to one label the app can style off directly.
func statusLabel(code string) string {
	switch {
	case code == "??":
		return "untracked"
	case strings.ContainsRune(code, 'R'):
		return "renamed"
	case strings.ContainsRune(code, 'A'):
		return "added"
	case strings.ContainsRune(code, 'D'):
		return "deleted"
	default:
		return "modified"
	}
}

// splitUnifiedDiff splits `git diff`'s combined output into one entry per
// file, keyed by the file's current path (the "b/" side of its "diff --git"
// header — the new path for a rename, the same path either side otherwise).
func splitUnifiedDiff(raw []byte) map[string]string {
	if len(raw) == 0 {
		return nil
	}
	lines := strings.Split(string(raw), "\n")
	m := map[string]string{}
	var curKey string
	var buf strings.Builder
	flush := func() {
		if curKey != "" {
			m[curKey] = strings.TrimRight(buf.String(), "\n")
		}
		buf.Reset()
	}
	for _, l := range lines {
		if strings.HasPrefix(l, "diff --git ") {
			flush()
			curKey = bSidePath(l)
		}
		if curKey != "" {
			buf.WriteString(l)
			buf.WriteByte('\n')
		}
	}
	flush()
	return m
}

// bSidePath pulls the path out of a "diff --git a/X b/Y" header line by its
// last " b/" — good enough short of a real path containing that literal
// substring, which git diff headers don't otherwise escape against either.
func bSidePath(header string) string {
	const marker = " b/"
	idx := strings.LastIndex(header, marker)
	if idx == -1 {
		return ""
	}
	return header[idx+len(marker):]
}

// countChanges counts a unified diff's added/removed content lines, skipping
// the "+++"/"---" file-header lines so they aren't double-counted as changes.
func countChanges(diff string) (adds, dels int) {
	for _, l := range strings.Split(diff, "\n") {
		switch {
		case strings.HasPrefix(l, "+++"), strings.HasPrefix(l, "---"):
			continue
		case strings.HasPrefix(l, "+"):
			adds++
		case strings.HasPrefix(l, "-"):
			dels++
		}
	}
	return adds, dels
}

// untrackedMaxBytes caps how much of a new file's content becomes a synthetic
// diff — plenty for a glance, without shipping a multi-MB payload for a large
// generated/vendored file that happens to be untracked.
const untrackedMaxBytes = 64 * 1024

// untrackedDiff synthesizes a "every line added" pseudo-diff for a file `git
// diff` has nothing to say about (it's outside HEAD and the index entirely).
// Gives the app one diff shape to render for every FileChange rather than a
// separate "new file" code path. A binary or unreadable file gets a short
// placeholder instead of raw bytes.
func untrackedDiff(cwd, path string) (string, int) {
	data, err := os.ReadFile(filepath.Join(cwd, path))
	if err != nil {
		return "", 0
	}
	truncated := false
	if len(data) > untrackedMaxBytes {
		data = data[:untrackedMaxBytes]
		truncated = true
	}
	if !utf8.Valid(data) {
		return "Binary file, not shown.", 0
	}
	lines := strings.Split(string(data), "\n")
	var b strings.Builder
	fmt.Fprintf(&b, "--- /dev/null\n+++ b/%s\n", path)
	for _, l := range lines {
		b.WriteByte('+')
		b.WriteString(l)
		b.WriteByte('\n')
	}
	if truncated {
		b.WriteString("… (truncated)\n")
	}
	return strings.TrimRight(b.String(), "\n"), len(lines)
}

// gitRaw runs git in cwd and returns stdout. Errors carry stderr for
// diagnosability (mirrors internal/herdr's run()).
func gitRaw(cwd string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = cwd
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return out, fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(ee.Stderr)))
		}
		return out, fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return out, nil
}

// gitString is gitRaw with its output as a string, for the small commands
// (branch name) that don't need byte-level NUL parsing.
func gitString(cwd string, args ...string) (string, error) {
	out, err := gitRaw(cwd, args...)
	return string(out), err
}
