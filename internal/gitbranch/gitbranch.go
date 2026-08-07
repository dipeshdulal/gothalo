// Package gitbranch answers the questions that decide whether a git branch may
// be deleted, and then deletes it. It backs GET /branch-info and
// POST /branch-delete — the "also delete the branch" half of removing a
// worktree from the phone.
//
// Herdr has no notion of branches at all: `worktree.remove` drops the checkout
// and closes the workspace, and the ref it was on stays behind forever. There
// is no socket method to delete it, so this is the one place the bridge reaches
// past Herdr and drives git itself. It mirrors internal/gitdiff — shell out to
// the git binary, keep every read best-effort, and never let git hang a
// request.
//
// The safety rules live here rather than in the handler (or the app) because
// they are the substance of the feature and they must hold for any caller:
//
//   - the repository's default branch is never deletable, whatever it is named;
//   - a branch checked out in ANY worktree is never deletable;
//   - merged and unmerged are different operations (`git branch -d` vs `-D`),
//     and the unmerged one only happens when the caller asked for it.
//
// Deleting a local branch never touches its remote. [Info.Upstream] is reported
// so a caller can say so rather than implying the remote went with it.
package gitbranch

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Refusal reasons. Each is a distinct HTTP status at the handler, and each is
// a different sentence to the user, so they are separate sentinels rather than
// one "cannot delete" error.
var (
	// ErrNotARepo — repoRoot is not a git work tree.
	ErrNotARepo = errors.New("not a git repository")
	// ErrNoBranch — no local ref by that name (already deleted, or a typo).
	ErrNoBranch = errors.New("branch does not exist")
	// ErrDefaultBranch — the branch IS the repository's default branch.
	ErrDefaultBranch = errors.New("refusing to delete the default branch")
	// ErrUnknownDefault — the default branch could not be resolved, so
	// "is this the default branch" and "is this merged" are both unanswerable.
	// Refusing is the only safe reading of that.
	ErrUnknownDefault = errors.New("cannot resolve the repository's default branch")
	// ErrCheckedOut — some worktree still has the branch checked out. git would
	// refuse too; refusing here means the caller gets a sentence instead of a
	// git diagnostic.
	ErrCheckedOut = errors.New("branch is checked out")
	// ErrUnmerged — deleting would lose commits and force was not asked for.
	ErrUnmerged = errors.New("branch is not merged")
	// ErrBadBranch — the name is unusable as a ref (empty, or option-shaped).
	ErrBadBranch = errors.New("invalid branch name")
	// ErrGit — git ran and refused for a reason we did not predict. Surfaced
	// with git's own stderr rather than reinterpreted.
	ErrGit = errors.New("git refused")
)

// Info is everything a client needs to decide, and to explain, whether a branch
// can go. Every field is filled best-effort: a repo with no remotes still gets
// an answer, it just has fewer facts in it.
type Info struct {
	RepoRoot string `json:"repo_root"`
	Branch   string `json:"branch"`
	// Exists is false when there is no local ref by this name — the honest
	// answer for a detached-HEAD worktree or an already-deleted branch.
	Exists bool `json:"exists"`
	// DefaultBranch is the repo's default branch as resolved (NOT assumed to be
	// "main"), or "" when it could not be determined.
	DefaultBranch string `json:"default_branch"`
	IsDefault     bool   `json:"is_default"`
	// CheckedOutAt lists every worktree path currently on this branch — the
	// main working tree included. Empty means nothing holds it.
	CheckedOutAt []string `json:"checked_out_at"`
	// Merged is true when the branch is an ancestor of the default branch, i.e.
	// deleting it loses nothing. Checked against the LOCAL default branch and
	// its remote-tracking counterpart, because a branch merged on the forge but
	// not yet pulled is still merged in every sense the user cares about.
	Merged bool `json:"merged"`
	// MergedInto names the ref that proved it ("main", "origin/main"), "" when
	// unmerged. A branch merged only into `origin/<default>` is worth
	// distinguishing: `git branch -d` may still refuse it.
	MergedInto string `json:"merged_into"`
	// UnmergedCommits is how many commits are on the branch and not in the
	// default branch — 0 when merged. The number that makes "this loses work"
	// concrete instead of abstract.
	UnmergedCommits int `json:"unmerged_commits"`
	// Upstream is the tracking ref ("origin/feat/x"), "" when the branch has
	// none. Deleting locally leaves it alone; the caller is expected to say so.
	Upstream string `json:"upstream"`
}

// Deletable reports whether [Delete] would go through, and why not when it
// would not. force mirrors Delete's argument: the unmerged case is deletable
// only when the caller has already opted into losing the commits.
func (i Info) Deletable(force bool) (bool, string) {
	switch {
	case !i.Exists:
		return false, fmt.Sprintf("no local branch %q", i.Branch)
	case i.DefaultBranch == "":
		return false, "the repository's default branch could not be resolved"
	case i.IsDefault:
		return false, fmt.Sprintf("%q is the repository's default branch", i.Branch)
	case len(i.CheckedOutAt) > 0:
		return false, fmt.Sprintf("%q is checked out at %s", i.Branch, strings.Join(i.CheckedOutAt, ", "))
	case !i.Merged && !force:
		return false, fmt.Sprintf("%q is not merged into %q", i.Branch, i.DefaultBranch)
	}
	return true, ""
}

// Outcome is what a delete actually did — reported rather than assumed, because
// "worktree gone, branch kept" is a normal result and has to be visible.
type Outcome struct {
	Branch  string `json:"branch"`
	Deleted bool   `json:"deleted"`
	// Forced is true when `git branch -D` was used, i.e. commits were dropped.
	// Note this is the command actually run, not what the caller asked for: a
	// force request on an already-merged branch still deletes with `-d`.
	Forced bool `json:"forced"`
	// Merged/MergedInto are the state at the moment of deletion.
	Merged     bool   `json:"merged"`
	MergedInto string `json:"merged_into"`
	// SHA is the commit the branch pointed at, read BEFORE the delete. It is the
	// only handle left for `git branch <name> <sha>` afterwards, so it is worth
	// the extra rev-parse.
	SHA string `json:"sha"`
	// Upstream is the tracking ref the branch had, if any.
	Upstream string `json:"upstream"`
	// RemoteDeleted is always false: this never runs `git push --delete`. It is
	// a field rather than a comment so the payload itself says so and no client
	// has to infer it.
	RemoteDeleted bool `json:"remote_deleted"`
}

// Inspect gathers everything known about branch in repoRoot without changing
// anything. Safe to call on a branch that does not exist (Exists is false) and
// on a repo with no remotes.
func Inspect(repoRoot, branch string) (Info, error) {
	if err := checkBranchName(branch); err != nil {
		return Info{}, err
	}
	if _, err := gitOut(repoRoot, "rev-parse", "--git-dir"); err != nil {
		return Info{}, fmt.Errorf("%w: %s", ErrNotARepo, repoRoot)
	}

	info := Info{RepoRoot: repoRoot, Branch: branch}
	info.Exists = refExists(repoRoot, "refs/heads/"+branch)
	def, remote := defaultBranch(repoRoot)
	info.DefaultBranch = def
	info.IsDefault = def != "" && def == branch
	info.CheckedOutAt = checkedOutAt(repoRoot, branch)
	info.Upstream = upstreamOf(repoRoot, branch)
	if info.Exists && def != "" && !info.IsDefault {
		info.Merged, info.MergedInto, info.UnmergedCommits = mergeState(repoRoot, branch, def, remote)
	}
	return info, nil
}

// Delete removes a local branch, re-running every safety check first — the
// client's preflight is a UI convenience, not the guard. force opts into losing
// unmerged commits; it does NOT override the default-branch or checked-out
// rules, which have no legitimate override from a phone.
//
// Callers must remove the worktree first: a branch checked out anywhere is
// refused, so calling this before the checkout is gone can only fail.
func Delete(repoRoot, branch string, force bool) (Outcome, error) {
	info, err := Inspect(repoRoot, branch)
	if err != nil {
		return Outcome{}, err
	}
	switch {
	case !info.Exists:
		return Outcome{}, fmt.Errorf("%w: %s", ErrNoBranch, branch)
	case info.DefaultBranch == "":
		return Outcome{}, fmt.Errorf("%w: refusing to delete %s", ErrUnknownDefault, branch)
	case info.IsDefault:
		return Outcome{}, fmt.Errorf("%w: %s", ErrDefaultBranch, branch)
	case len(info.CheckedOutAt) > 0:
		return Outcome{}, fmt.Errorf("%w: %s is checked out at %s", ErrCheckedOut, branch, strings.Join(info.CheckedOutAt, ", "))
	case !info.Merged && !force:
		return Outcome{}, fmt.Errorf("%w: %s has %d commit(s) not in %s", ErrUnmerged, branch, info.UnmergedCommits, info.DefaultBranch)
	}

	sha := ""
	if out, err := gitOut(repoRoot, "rev-parse", "--short", "refs/heads/"+branch); err == nil {
		sha = strings.TrimSpace(out)
	}

	// The least destructive command that can succeed: a force request on an
	// already-merged branch is still a plain `-d`, so "forced" in the outcome
	// means commits were genuinely dropped.
	flag := "-d"
	if !info.Merged {
		flag = "-D"
	}
	if _, err := gitOut(repoRoot, "branch", flag, "--", branch); err != nil {
		return Outcome{}, fmt.Errorf("%w: %v", ErrGit, err)
	}

	return Outcome{
		Branch:     branch,
		Deleted:    true,
		Forced:     flag == "-D",
		Merged:     info.Merged,
		MergedInto: info.MergedInto,
		SHA:        sha,
		Upstream:   info.Upstream,
	}, nil
}

// checkBranchName rejects the two names that are not a branch at all. Anything
// else is left to git: every call site passes the name inside `refs/heads/…` or
// after a `--`, so a strange-but-real branch name still works.
func checkBranchName(branch string) error {
	switch {
	case strings.TrimSpace(branch) == "":
		return fmt.Errorf("%w: empty", ErrBadBranch)
	case strings.HasPrefix(branch, "-"):
		// Would be read as a flag by any git command that takes one.
		return fmt.Errorf("%w: %q starts with a dash", ErrBadBranch, branch)
	case strings.ContainsAny(branch, "\x00\n"):
		return fmt.Errorf("%w: contains a control character", ErrBadBranch)
	}
	return nil
}

// defaultBranch resolves the repository's default branch — the one thing this
// package must not guess. Order matters:
//
//  1. `refs/remotes/<remote>/HEAD`, the remote's own answer, written by clone
//     and refreshable with `git remote set-head`. This is authoritative and is
//     right for the repos that call `trunk`, `develop` or `release` their
//     default.
//  2. Failing that (a repo with no remote, or a clone whose remote HEAD was
//     never set), the first conventional local branch that exists.
//
// Both can miss, and "" is a legitimate answer — callers refuse to delete
// anything rather than fall back to assuming "main".
//
// It also returns the remote it consulted (preferring `origin`), so the merged
// check can look at `refs/remotes/<remote>/<default>` without re-deriving it.
func defaultBranch(repoRoot string) (name, remote string) {
	rems := remotes(repoRoot)
	if len(rems) > 0 {
		remote = rems[0]
	}
	for _, r := range rems {
		out, err := gitOut(repoRoot, "symbolic-ref", "--short", "refs/remotes/"+r+"/HEAD")
		if err != nil {
			continue
		}
		// "origin/main" -> "main"
		if b := strings.TrimPrefix(strings.TrimSpace(out), r+"/"); b != "" && b != strings.TrimSpace(out) {
			return b, r
		}
	}
	for _, n := range []string{"main", "master", "trunk", "develop"} {
		if refExists(repoRoot, "refs/heads/"+n) {
			return n, remote
		}
	}
	return "", remote
}

// remotes lists the repo's remotes with `origin` first, so the conventional
// answer wins in a repo that has several.
func remotes(repoRoot string) []string {
	out, err := gitOut(repoRoot, "remote")
	if err != nil {
		return nil
	}
	var rest []string
	origin := false
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		switch l = strings.TrimSpace(l); l {
		case "":
		case "origin":
			origin = true
		default:
			rest = append(rest, l)
		}
	}
	if origin {
		return append([]string{"origin"}, rest...)
	}
	return rest
}

// mergeState answers "would deleting this lose commits", against the local
// default branch first and its remote-tracking ref second.
//
// Both are consulted because they disagree in a case that happens constantly
// with this app: the PR was merged on GitHub, `origin/main` knows, and the
// local `main` has not been pulled in a week. Reporting that branch as unmerged
// would push the user onto the destructive path for a branch that lost nothing.
// MergedInto names which ref answered, so a caller can tell the two apart.
func mergeState(repoRoot, branch, def, remote string) (merged bool, into string, unmerged int) {
	type base struct{ ref, name string }
	var bases []base
	if refExists(repoRoot, "refs/heads/"+def) {
		bases = append(bases, base{"refs/heads/" + def, def})
	}
	if remote != "" && refExists(repoRoot, "refs/remotes/"+remote+"/"+def) {
		bases = append(bases, base{"refs/remotes/" + remote + "/" + def, remote + "/" + def})
	}

	head := "refs/heads/" + branch
	unmerged = -1
	for _, b := range bases {
		if _, err := gitOut(repoRoot, "merge-base", "--is-ancestor", head, b.ref); err == nil {
			return true, b.name, 0
		}
		if n, err := countCommits(repoRoot, b.ref, head); err == nil && (unmerged < 0 || n < unmerged) {
			unmerged = n
		}
	}
	if unmerged < 0 {
		unmerged = 0
	}
	return false, "", unmerged
}

// countCommits is `git rev-list --count base..head`.
func countCommits(repoRoot, base, head string) (int, error) {
	out, err := gitOut(repoRoot, "rev-list", "--count", base+".."+head)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(out))
}

// refExists reports whether a fully-qualified ref resolves.
func refExists(repoRoot, ref string) bool {
	_, err := gitOut(repoRoot, "show-ref", "--verify", "--quiet", ref)
	return err == nil
}

// upstreamOf returns the branch's tracking ref in short form ("origin/feat/x"),
// or "" when it has none.
func upstreamOf(repoRoot, branch string) string {
	out, err := gitOut(repoRoot, "for-each-ref", "--format=%(upstream:short)", "refs/heads/"+branch)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// checkedOutAt lists the worktrees holding branch, parsed from
// `git worktree list --porcelain`: blank-line-separated records of
// "worktree <path>" / "HEAD <sha>" / "branch <ref>" (or "detached"/"bare").
//
// This is the check `git branch -d` makes too, but doing it up front is what
// lets the app not offer an impossible action — and it names the worktree that
// is in the way, which git's own refusal does only for the main tree.
func checkedOutAt(repoRoot, branch string) []string {
	out, err := gitOut(repoRoot, "worktree", "list", "--porcelain")
	if err != nil {
		return nil
	}
	var paths []string
	cur := ""
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "worktree "):
			cur = strings.TrimPrefix(line, "worktree ")
		case line == "":
			cur = ""
		case strings.HasPrefix(line, "branch "):
			if cur != "" && strings.TrimPrefix(line, "branch ") == "refs/heads/"+branch {
				paths = append(paths, cur)
			}
		}
	}
	return paths
}

// gitTimeout bounds a single git invocation, for the same reason as
// internal/gitdiff's: git can block indefinitely on a held index.lock or an
// unresponsive filesystem, and unbounded that hangs the HTTP handler. These are
// all ref-level reads and one ref delete, so the budget is tighter than the
// diff package's.
const gitTimeout = 15 * time.Second

// gitOut runs git in repoRoot and returns stdout. Errors carry stderr, which is
// the part worth showing: `git branch -d`'s refusal explains itself better than
// anything this package could write.
func gitOut(repoRoot string, args ...string) (string, error) {
	if repoRoot == "" {
		return "", fmt.Errorf("%w: no repo root given", ErrNotARepo)
	}
	ctx, cancel := context.WithTimeout(context.Background(), gitTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = repoRoot
	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return string(out), fmt.Errorf("git %s: timed out after %s", strings.Join(args, " "), gitTimeout)
		}
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if stderr := strings.TrimSpace(string(ee.Stderr)); stderr != "" {
				return string(out), fmt.Errorf("git %s: %s", strings.Join(args, " "), stderr)
			}
		}
		return string(out), fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return string(out), nil
}
