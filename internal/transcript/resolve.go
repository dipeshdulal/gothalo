package transcript

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ErrNoTranscript means no transcript file could be resolved for the pane (the
// agent has none yet, or the mapping failed). The handler maps it to HTTP 404.
var ErrNoTranscript = errors.New("no transcript file for pane")

// ErrUnsupportedKind means the agent kind has a reader stub but no on-disk
// transcript layout wired up yet (codex/opencode). Mapped to 404 with a clear
// message so the app can fall back to /attach or /agent-state.
var ErrUnsupportedKind = errors.New("transcript not supported for this agent kind")

// EncodeProjectDir maps a project cwd to Claude Code's project-directory name.
//
// Claude Code stores each session as
//
//	~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
//
// where <encoded-cwd> is the absolute cwd with every "/" AND "." replaced by "-".
// Verified against live directories: e.g.
//
//	/Users/x/.herdr/worktrees/foo  ->  -Users-x--herdr-worktrees-foo
//
// (note the "/." in "/.herdr" becomes "--"). Alphanumerics and existing "-" are
// preserved.
func EncodeProjectDir(cwd string) string {
	return strings.Map(func(r rune) rune {
		if r == '/' || r == '.' {
			return '-'
		}
		return r
	}, cwd)
}

// claudeProjectsRoot returns ~/.claude/projects.
func claudeProjectsRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".claude", "projects"), nil
}

// Locate resolves the transcript file path for a pane, per agent kind.
//
// How the claude mapping is resolved (documented in CONTRACT.md):
//  1. Compute the project dir from cwd (EncodeProjectDir) and try
//     <dir>/<sessionID>.jsonl. Herdr's agent_session.value is Claude Code's own
//     session id and equals the filename, so this is the direct hit.
//  2. Harden against encoding drift: if that misses but a sessionID is known, glob
//     ~/.claude/projects/*/<sessionID>.jsonl (the session id is globally unique),
//     which finds the file regardless of how the dir name was encoded.
//  3. Fallback: ONLY when the session id is unknown, pick the
//     most-recently-modified *.jsonl in the project dir whose own recorded cwd
//     equals the pane's cwd.
//
// A KNOWN session id that misses both lookups stops at ErrNoTranscript — it is
// never handed to the fallback. Claude writes a session's .jsonl lazily, so a
// pane whose agent has not spoken yet has a real session id and no file. The
// fallback would then return the newest *other* transcript in the same project
// dir — i.e. a different pane's conversation. Two agents in one directory is
// ordinary, so that misfire is the common case, not a corner: it showed pane A's
// chat under pane B in the mobile app. "Not written yet" must read as absent,
// not as license to guess.
//
// codex/opencode return ErrUnsupportedKind (their layouts aren't wired up yet).
func Locate(kind, cwd, sessionID string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "claude":
		return locateClaude(cwd, sessionID)
	case "pi":
		return locatePi(cwd, sessionID)
	case "codex", "opencode":
		return "", ErrUnsupportedKind
	default:
		return "", ErrUnsupportedKind
	}
}

// locatePi resolves the transcript file path for a pi pane.
//
// Herdr's pi integration sets agent_session.value to the FULL PATH of the
// session's jsonl (unlike Claude Code, which stores a bare session id):
//
//	~/.pi/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl
//
// So the direct hit IS the session id, not a dir + name join:
//  1. A session id ending in .jsonl is a path: an existing file opens directly;
//     a missing one stops at ErrNoTranscript so the opener can serve the pending
//     path (pi writes the file lazily, on the first message).
//  2. A bare session id globs the sessions root (filenames embed the uuid, so
//     the match is "*<sessionID>.jsonl"), hardening against encoding drift.
//  3. Fallback — ONLY when the session id is unknown — picks the
//     most-recently-modified session in the encoded-cwd dir whose recorded cwd
//     equals the pane's cwd (mirrors locateClaude's step 3).
func locatePi(cwd, sessionID string) (string, error) {
	root, err := piSessionsRoot()
	if err != nil {
		return "", err
	}

	if sessionID != "" && strings.HasSuffix(sessionID, ".jsonl") {
		if isFile(sessionID) {
			return sessionID, nil
		}
		// A named session whose file is not written yet. Not ErrUnsupportedKind,
		// and the opener turns it into a source that streams in when pi writes.
		return "", ErrNoTranscript
	}

	if sessionID != "" {
		if matches, _ := filepath.Glob(filepath.Join(root, "*", "*"+sessionID+".jsonl")); len(matches) > 0 {
			return matches[0], nil
		}
		return "", ErrNoTranscript
	}

	if p := newestMatchingSession(filepath.Join(root, EncodePiSessionDir(cwd)), cwd); p != "" {
		return p, nil
	}
	return "", ErrNoTranscript
}

func locateClaude(cwd, sessionID string) (string, error) {
	root, err := claudeProjectsRoot()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, EncodeProjectDir(cwd))

	// 1. Direct hit: encoded dir + session id.
	if sessionID != "" {
		p := filepath.Join(dir, sessionID+".jsonl")
		if isFile(p) {
			return p, nil
		}
		// 2. Encoding-drift hardening: find the session file anywhere under projects.
		if matches, _ := filepath.Glob(filepath.Join(root, "*", sessionID+".jsonl")); len(matches) > 0 {
			return matches[0], nil
		}
		// Both lookups missed for a session we can name: the file does not exist
		// yet. Stop here rather than fall through — see the note on Locate.
		return "", ErrNoTranscript
	}

	// 3. Fallback (session id unknown only): newest *.jsonl in the project dir
	// whose recorded cwd matches.
	if p := newestMatchingSession(dir, cwd); p != "" {
		return p, nil
	}
	return "", ErrNoTranscript
}

func isFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}

// newestMatchingSession returns the most-recently-modified *.jsonl in dir whose
// first recorded cwd equals cwd, or "" when none match. Matching on cwd guards
// against picking another project's session that happens to share the dir.
func newestMatchingSession(dir, cwd string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	type cand struct {
		path    string
		modUnix int64
	}
	var cands []cand
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		path := filepath.Join(dir, e.Name())
		if cwd != "" && firstLineCwd(path) != cwd {
			continue
		}
		cands = append(cands, cand{path: path, modUnix: info.ModTime().UnixNano()})
	}
	if len(cands) == 0 {
		return ""
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].modUnix > cands[j].modUnix })
	return cands[0].path
}

// firstLineCwd returns the transcript's first recorded `cwd`, or "" if none is
// found early on. Newer Claude Code transcripts open with cwd-less metadata lines
// (mode, permission-mode, file-history-snapshot), so scan a bounded number of
// lines rather than just the first — still cheap, never the whole file.
func firstLineCwd(path string) string {
	const maxProbeLines = 10
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for n := 0; n < maxProbeLines && sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var probe struct {
			Cwd string `json:"cwd"`
		}
		if json.Unmarshal([]byte(line), &probe) == nil && probe.Cwd != "" {
			return probe.Cwd
		}
	}
	return ""
}

// LastActivity reports when this agent last wrote to its transcript, and whether
// that could be determined at all.
//
// It answers the question every live-status read cannot: not WHAT an agent is
// doing but HOW LONG it has been doing it. `/snapshot` says "blocked"; it cannot
// say whether that started ten seconds or fifty minutes ago, and that difference
// is the entire reason to look at a phone. state_change_seq is a counter, not a
// clock.
//
// The transcript's modification time is the right source for it, and a better
// one than anything the bridge can observe itself:
//
//   - It survives a bridge restart, a redeploy and a reboot, because it lives on
//     disk rather than in a process's memory.
//   - It knows spans that STARTED BEFORE the bridge ever ran. An observer can
//     only measure what it witnessed; a file remembers regardless. An agent idle
//     for fifty hours reports fifty hours to a bridge started a minute ago.
//
// The last ENTRY'S timestamp, not the file's mtime. mtime is tempting — an
// append is a write — but it is not owned by the agent: anything that touches
// the file moves it. Observed on a real machine, three unrelated agents reported
// an identical age to the tenth of a minute (1343.8m) because something had
// swept their files together, while their actual last entries were 1416m and
// 3030m apart. An age that plausible and that wrong is worse than none.
//
// Only the tail is read, so cost does not grow with a long conversation.
//
// Only the per-session-file kinds are answerable: claude and pi append one jsonl
// per session, so its newest entry is this agent's. hermes and opencode keep
// every session in one shared SQLite database, so its mtime describes the newest
// activity of ANY agent, not this one — reporting that as this agent's age would
// be confidently wrong, which is worse than reporting nothing. Hence the bool.
func LastActivity(kind, cwd, sessionID string) (time.Time, bool) {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "claude", "pi":
	default:
		return time.Time{}, false
	}
	path, err := Locate(kind, cwd, sessionID)
	if err != nil {
		return time.Time{}, false
	}
	return lastEntryTime(path)
}

// lastActivityTailBytes is how much of the end of a transcript is read looking
// for the newest timestamp. Generously larger than any single entry, so the tail
// always contains at least one complete line, and small enough that this stays
// cheap on a hot read of a multi-megabyte conversation.
const lastActivityTailBytes = 64 << 10

// lastEntryTime returns the timestamp of the newest entry carrying one.
//
// It scans BACKWARDS through the tail and stops at the first timestamp it finds,
// because entries are appended in order — so the last one is the newest, and
// there is no reason to parse the rest. Lines are parsed loosely: a transcript
// mixes shapes, and any line without a usable timestamp is simply skipped rather
// than failing the read.
func lastEntryTime(path string) (time.Time, bool) {
	f, err := os.Open(path)
	if err != nil {
		return time.Time{}, false
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return time.Time{}, false
	}
	size := info.Size()
	start := size - lastActivityTailBytes
	if start < 0 {
		start = 0
	}
	buf := make([]byte, size-start)
	if _, err := f.ReadAt(buf, start); err != nil && err != io.EOF {
		return time.Time{}, false
	}

	lines := strings.Split(string(buf), "\n")
	// The first line is a fragment unless the read started at the file's head.
	if start > 0 && len(lines) > 0 {
		lines = lines[1:]
	}
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		var e struct {
			Timestamp string `json:"timestamp"`
		}
		if json.Unmarshal([]byte(line), &e) != nil || e.Timestamp == "" {
			continue
		}
		if at, err := time.Parse(time.RFC3339Nano, e.Timestamp); err == nil {
			return at, true
		}
	}
	return time.Time{}, false
}
