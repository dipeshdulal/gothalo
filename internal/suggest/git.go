package suggest

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// The git-shaped sources read the repository the cheap way — stat() on a few
// well-known paths inside the git dir — and only shell out for the one question
// the filesystem cannot answer directly (is the tree dirty). That split is the
// whole cost story of this package: a pane in a clean repo never spawns a
// process, and a pane in a dirty one spawns exactly one, behind the server's
// cache.
//
// internal/gitdiff also shells out to git, and deliberately is not reused here:
// it collects a full per-file diff for GET /diff, which is orders of magnitude
// more work than "is anything changed". Sharing the call would make every
// suggestion refresh as expensive as opening the diff screen.

// maxWalk bounds the search for a repository root. A pane's cwd is a real
// directory a person navigated to, not an adversarial path, so this only has to
// be larger than any plausible tree — it exists so a symlink loop or a mount
// oddity cannot spin the handler.
const maxWalk = 40

// gitDir resolves cwd's git directory and the root of its work tree.
//
// Both forms are handled because both are normal here: a plain clone has `.git`
// as a directory, and a **worktree** has `.git` as a FILE containing
// `gitdir: /repo/.git/worktrees/<name>`. Worktrees are not an edge case in this
// codebase — parallel agents are the reason the feature exists — and treating
// their `.git` file as "not a repo" would silence every source in exactly the
// panes that matter most.
func gitDir(cwd string) (dir, root string, ok bool) {
	if cwd == "" {
		return "", "", false
	}
	at := cwd
	for range maxWalk {
		candidate := filepath.Join(at, ".git")
		info, err := os.Lstat(candidate)
		switch {
		case err != nil:
			// Keep walking: a subdirectory of a repo has no .git of its own.
		case info.IsDir():
			return candidate, at, true
		default:
			if resolved, ok := readGitFile(candidate); ok {
				return resolved, at, true
			}
			// A .git that is neither a directory nor a parseable pointer is not
			// something to guess about.
			return "", "", false
		}
		parent := filepath.Dir(at)
		if parent == at {
			return "", "", false
		}
		at = parent
	}
	return "", "", false
}

// readGitFile parses a worktree's `.git` file. Its payload may be relative to
// the file's own directory, which is why it is joined rather than used as-is.
func readGitFile(path string) (string, bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	line := strings.TrimSpace(string(raw))
	target, ok := strings.CutPrefix(line, "gitdir:")
	if !ok {
		return "", false
	}
	target = strings.TrimSpace(target)
	if target == "" {
		return "", false
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(path), target)
	}
	if info, err := os.Stat(target); err != nil || !info.IsDir() {
		return "", false
	}
	return target, true
}

// midFlight names an operation git leaves a marker for, and the marker it
// leaves. Order matters: the first match wins, and a rebase that stops on a
// conflict has both a rebase directory and (during `rebase --merge`) merge
// state, so the more specific operation is listed first.
var midFlight = []struct {
	op     string
	marker string
}{
	{"rebase", "rebase-merge"},
	{"rebase", "rebase-apply"},
	{"cherry-pick", "CHERRY_PICK_HEAD"},
	{"revert", "REVERT_HEAD"},
	{"merge", "MERGE_HEAD"},
}

// inProgress reports an unfinished merge/rebase/cherry-pick/revert in cwd's
// repository, naming it for the chip's detail line.
//
// Marker files rather than `git status`: these are the states where a person is
// needed, so the check has to be reliable even when the tree is huge and a
// status call would be slow. A stat is neither.
func inProgress(cwd string) (string, bool) {
	dir, _, ok := gitDir(cwd)
	if !ok {
		return "", false
	}
	for _, m := range midFlight {
		if _, err := os.Stat(filepath.Join(dir, m.marker)); err == nil {
			return m.op, true
		}
	}
	return "", false
}

// repoName is the work tree's directory name — "feat-pane-suggestions" for a
// worktree, "gothalo" for a plain clone. It doubles as the "is this a repo at
// all" test for [shellIdle].
//
// The directory name, not the remote's: with several worktrees of one project
// checked out at once, the remote name is the same for all of them and tells
// you nothing, while the directory is what the person named the branch after.
func repoName(cwd string) (string, bool) {
	_, root, ok := gitDir(cwd)
	if !ok {
		return "", false
	}
	name := filepath.Base(root)
	if name == "." || name == string(filepath.Separator) {
		return "", false
	}
	return name, true
}

// statusTimeout bounds the one git invocation this package makes. A status on a
// warm repo answers in milliseconds; anything past this is a repository doing
// something pathological (a cold NFS mount, an index lock held by a long
// operation), and a suggestion is not worth holding a request open for.
const statusTimeout = 3 * time.Second

// dirtyCount counts changed files in cwd's work tree, ok=false when the answer
// is unknown (not a repo, git missing, timed out).
//
// `--untracked-files=normal` on purpose: `all` is what GET /diff wants, because
// it lists the files, but here the number is only ever rendered as "N files
// changed" — and expanding a fresh node_modules into its members would both cost
// real time and print a number that says nothing.
func dirtyCount(cwd string) (int, bool) {
	if _, _, ok := gitDir(cwd); !ok {
		return 0, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), statusTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", "status", "--porcelain=v1", "-z",
		"--untracked-files=normal")
	cmd.Dir = cwd
	out, err := cmd.Output()
	if err != nil {
		return 0, false
	}
	return countPorcelain(out), true
}

// countPorcelain counts the entries in `git status --porcelain -z` output.
//
// The one subtlety is renames: `R  new\x00old\x00` is ONE changed file spread
// over two NUL-separated records, and the origin path is a bare path with no
// status code. It is consumed explicitly rather than filtered by shape — a path
// like `old name.go` has a space in column three too, and would otherwise be
// counted as a file of its own.
func countPorcelain(raw []byte) int {
	parts := bytes.Split(raw, []byte{0})
	n := 0
	for i := 0; i < len(parts); i++ {
		rec := parts[i]
		if len(rec) < 4 {
			continue // the trailing empty split
		}
		n++
		if bytes.ContainsAny(rec[:2], "RC") {
			i++ // the origin path belongs to the entry just counted
		}
	}
	return n
}
