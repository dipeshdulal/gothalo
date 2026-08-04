package transcript

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
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
	case "codex", "opencode":
		return "", ErrUnsupportedKind
	default:
		return "", ErrUnsupportedKind
	}
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
