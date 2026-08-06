// Package gitdiff collects a working tree's pending changes — the branch, the
// changed-file list, and a per-file unified diff — for GET /diff. It shells
// out to the git binary directly against a pane's cwd; there is no Herdr API
// for this, and the bridge already reads other local state directly (see
// internal/transcript), so a direct git invocation fits the same model.
package gitdiff

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
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
	// fails the whole request. Same value as Git.Branch; kept at the top level
	// because the app read it before Git existed.
	Branch string       `json:"branch"`
	Git    Context      `json:"git"`
	Files  []FileChange `json:"files"`
}

// Context is the pane's git *situation* rather than its contents: which branch,
// where it sits relative to the default branch, and whether there is a remote
// to push to. Everything an "is opening a pull request from this pane even
// meaningful?" decision needs, and nothing that requires diffing a file.
//
// It lives here, on /diff, rather than on an endpoint of its own: it is the
// same shell-out to git against the same pane cwd, and a second endpoint
// overlapping this one would be two answers to one question.
//
// Every field is best-effort. A repo with no remote, no commits, or a detached
// HEAD is a perfectly ordinary state, so those report zero values rather than
// failing — the *caller* decides what is disqualifying.
type Context struct {
	// Repo is the gate: cwd is inside a git work tree. False makes every other
	// field meaningless (they are all zero anyway).
	Repo bool `json:"repo"`

	// Branch is the checked-out branch, "" on a detached HEAD. An unborn
	// branch (a fresh `git init` with no commits) still names itself here.
	Branch string `json:"branch"`

	// DefaultBranch is the repo's trunk — what a PR would target. Resolved
	// from the remote's own HEAD when it is set, else the first of
	// main/master that exists. "" when neither is found.
	DefaultBranch string `json:"default_branch"`

	// DefaultRef is the ref Ahead/Behind were actually counted against
	// ("refs/remotes/origin/main", "refs/heads/main"). Reported so a caller can
	// say what the comparison meant instead of guessing.
	DefaultRef string `json:"default_ref"`

	// Remote is the remote a push would go to — "origin" when it exists, else
	// the first configured remote. "" means there is nowhere to push, which is
	// disqualifying for a PR.
	Remote string `json:"remote"`

	// Upstream is the current branch's tracking ref ("origin/feat/x"), "" when
	// it has never been pushed. Absence is not disqualifying — `git push -u`
	// is exactly what the agent is being asked to do.
	Upstream string `json:"upstream"`

	// Ahead is how many commits HEAD has that DefaultRef does not — the work a
	// PR would contain. Behind is the reverse.
	Ahead  int `json:"ahead"`
	Behind int `json:"behind"`

	// Dirty is "the working tree has uncommitted changes" (including untracked
	// files). Not disqualifying either: committing them is step one of what the
	// agent is asked to do.
	Dirty bool `json:"dirty"`
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

// ReadContext reports the pane's git situation (see [Context]) without diffing
// anything. It is what GET /diff?context=1 answers: the same git reads Collect
// does for its header, minus the working-tree diff, which is the expensive part
// and is not needed to decide whether a pull request is possible.
//
// Never errors: a non-repo cwd is a zero-value Context with Repo false.
//
// Overlaps internal/gitbranch, which resolves a default branch too (for "may
// this branch be deleted?"). The two are not merged yet because they key off
// different things — this takes a pane cwd and wants the *ref* to count commits
// against, gitbranch takes a repo root and wants the *name* plus the remote it
// came from — and because unifying them is a change to a just-landed safety
// path, not a change to fit alongside it. What they must not do is disagree, so
// the fallback list is shared by construction; see [conventionalDefaults].
func ReadContext(cwd string) Context {
	c := gitContext(cwd)
	if !c.Repo {
		return c
	}
	// Same status read Collect uses, for the same reason — untracked files
	// count as "there is work here that is not committed yet".
	if raw, err := gitRaw(cwd, "status", "--porcelain=v1", "-z", "--untracked-files=all"); err == nil {
		c.Dirty = len(parsePorcelain(raw)) > 0
	}
	return c
}

// gitContext resolves everything in a [Context] except Dirty, which its two
// callers fill from a status read they are each already doing — [Collect] from
// its changed-file list, [ReadContext] from a status of its own.
func gitContext(cwd string) Context {
	if cwd == "" {
		return Context{}
	}
	out, err := gitString(cwd, "rev-parse", "--is-inside-work-tree")
	if err != nil || strings.TrimSpace(out) != "true" {
		return Context{}
	}
	c := Context{Repo: true}

	// symbolic-ref rather than `rev-parse --abbrev-ref HEAD`: it answers ""
	// (not the literal string "HEAD") on a detached HEAD, and it still names an
	// unborn branch in a repo with no commits yet.
	if b, err := gitString(cwd, "symbolic-ref", "--quiet", "--short", "HEAD"); err == nil {
		c.Branch = strings.TrimSpace(b)
	}
	c.Remote = pickRemote(cwd)
	if u, err := gitString(cwd, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"); err == nil {
		c.Upstream = strings.TrimSpace(u)
	}
	c.DefaultBranch, c.DefaultRef = defaultBranch(cwd, c.Remote)
	if c.DefaultRef != "" {
		c.Ahead, c.Behind = aheadBehind(cwd, c.DefaultRef)
	}
	return c
}

// pickRemote names the remote a push would go to: "origin" when it exists, else
// whichever remote is configured first. "" when there is none.
func pickRemote(cwd string) string {
	out, err := gitString(cwd, "remote")
	if err != nil {
		return ""
	}
	first := ""
	for _, line := range strings.Split(out, "\n") {
		name := strings.TrimSpace(line)
		switch {
		case name == "":
		case name == "origin":
			return "origin"
		case first == "":
			first = name
		}
	}
	return first
}

// conventionalDefaults are the branch names to fall back to when the remote
// never said which branch is its HEAD. Kept identical to
// gitbranch.defaultBranch's list on purpose: two packages in one binary that
// disagree about what "the default branch" means on a `trunk`-based repo would
// be a bug nobody could see from either file alone. (Sharing the resolution
// outright is the better end state — see the note on [ReadContext].)
var conventionalDefaults = []string{"main", "master", "trunk", "develop"}

// defaultBranch resolves the repo's trunk and the ref to compare against.
//
// The remote's own HEAD is authoritative when it is set — but it is only set by
// a clone or an explicit `git remote set-head`, so a repo that was `git init`ed
// locally and later given a remote has none. The conventional-name fallback
// covers that case; a repo whose trunk is none of them reports "" and the
// caller degrades to "can't tell" rather than to a wrong guess.
func defaultBranch(cwd, remote string) (name, ref string) {
	if remote != "" {
		if out, err := gitString(cwd, "symbolic-ref", "--quiet", "--short", "refs/remotes/"+remote+"/HEAD"); err == nil {
			full := strings.TrimSpace(out) // "origin/main"
			if n := strings.TrimPrefix(full, remote+"/"); n != "" && n != full {
				return n, "refs/remotes/" + full
			}
		}
	}
	for _, n := range conventionalDefaults {
		// Remote-tracking first: it is what a PR would actually be opened
		// against, and a stale local `main` is common on a worktree checkout.
		if remote != "" {
			if r := "refs/remotes/" + remote + "/" + n; refExists(cwd, r) {
				return n, r
			}
		}
		if r := "refs/heads/" + n; refExists(cwd, r) {
			return n, r
		}
	}
	return "", ""
}

func refExists(cwd, ref string) bool {
	_, err := gitRaw(cwd, "rev-parse", "--verify", "--quiet", ref)
	return err == nil
}

// aheadBehind counts HEAD against base. `--left-right --count` prints
// "<left>\t<right>" — left is base-only (behind), right is HEAD-only (ahead).
// An unresolvable base or an unborn HEAD counts as (0, 0).
func aheadBehind(cwd, base string) (ahead, behind int) {
	out, err := gitString(cwd, "rev-list", "--left-right", "--count", base+"...HEAD")
	if err != nil {
		return 0, 0
	}
	fields := strings.Fields(out)
	if len(fields) != 2 {
		return 0, 0
	}
	behind, _ = strconv.Atoi(fields[0])
	ahead, _ = strconv.Atoi(fields[1])
	return ahead, behind
}

// Collect runs git against cwd and returns its pending changes. A cwd that
// isn't a git repository (or has no changes) returns a zero-value Result, not
// an error — only a git invocation that fails outright (e.g. git missing)
// errors, so a quiet non-repo pane just shows "no changes" instead of an
// error screen.
func Collect(cwd string) (Result, error) {
	gc := gitContext(cwd)

	// --untracked-files=all expands an untracked directory into its individual
	// files (git's default collapses it to one opaque directory entry) — a new
	// package like internal/gitdiff/ should list its actual files, not itself.
	statusRaw, err := gitRaw(cwd, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		// Most likely "not a git repository" — not a bridge error, just
		// nothing to show.
		return Result{Git: gc}, nil
	}
	entries := parsePorcelain(statusRaw)
	gc.Dirty = len(entries) > 0
	if len(entries) == 0 {
		return Result{Branch: gc.Branch, Git: gc}, nil
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
	return Result{Branch: gc.Branch, Git: gc, Files: files}, nil
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

// gitTimeout bounds a single git invocation. git can block indefinitely on
// things that have nothing to do with the repo being large — an index.lock held
// by another process, a filesystem that stops answering, a credential prompt on
// a misconfigured remote. Unbounded, that hangs the HTTP request serving it and
// ties up the handler for as long as git sulks.
const gitTimeout = 30 * time.Second

// gitRaw runs git in cwd and returns stdout. Errors carry stderr for
// diagnosability (mirrors internal/herdr's run()).
func gitRaw(cwd string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = cwd
	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return out, fmt.Errorf("git %s: timed out after %s", strings.Join(args, " "), gitTimeout)
		}
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
