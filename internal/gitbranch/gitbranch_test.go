package gitbranch

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// newRepo builds a throwaway repo on `main` with one commit, and returns its
// path. Every test drives real git — the safety rules are claims about what git
// does, so a fake would only test the fake.
func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	runGit(t, dir, "init", "-q", "-b", "main")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test")
	commit(t, dir, "base.txt", "base\n", "base")
	return dir
}

func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

func commit(t *testing.T, dir, name, body, msg string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, dir, "add", ".")
	runGit(t, dir, "commit", "-q", "-m", msg)
}

// branchWithCommit creates branch off the current HEAD and puts one commit on
// it, leaving the repo back on its original branch.
func branchWithCommit(t *testing.T, dir, branch string) {
	t.Helper()
	start := strings.TrimSpace(runGit(t, dir, "rev-parse", "--abbrev-ref", "HEAD"))
	runGit(t, dir, "checkout", "-q", "-b", branch)
	commit(t, dir, branch2file(branch), "work\n", "work on "+branch)
	runGit(t, dir, "checkout", "-q", start)
}

func branch2file(branch string) string {
	return strings.ReplaceAll(branch, "/", "_") + ".txt"
}

func TestInspect_MergedBranch(t *testing.T) {
	dir := newRepo(t)
	branchWithCommit(t, dir, "feat/done")
	runGit(t, dir, "merge", "-q", "--no-ff", "-m", "merge", "feat/done")

	info, err := Inspect(dir, "feat/done")
	if err != nil {
		t.Fatalf("Inspect: %v", err)
	}
	if !info.Exists {
		t.Fatal("Exists = false, want true")
	}
	if info.DefaultBranch != "main" {
		t.Errorf("DefaultBranch = %q, want main", info.DefaultBranch)
	}
	if info.IsDefault {
		t.Error("IsDefault = true for a feature branch")
	}
	if !info.Merged || info.MergedInto != "main" {
		t.Errorf("Merged = %v into %q, want true into main", info.Merged, info.MergedInto)
	}
	if info.UnmergedCommits != 0 {
		t.Errorf("UnmergedCommits = %d, want 0", info.UnmergedCommits)
	}
	if len(info.CheckedOutAt) != 0 {
		t.Errorf("CheckedOutAt = %v, want none", info.CheckedOutAt)
	}
	if ok, why := info.Deletable(false); !ok {
		t.Errorf("Deletable(false) = false (%s), want true", why)
	}
}

func TestInspect_UnmergedBranchCountsCommits(t *testing.T) {
	dir := newRepo(t)
	runGit(t, dir, "checkout", "-q", "-b", "feat/wip")
	commit(t, dir, "a.txt", "a\n", "a")
	commit(t, dir, "b.txt", "b\n", "b")
	runGit(t, dir, "checkout", "-q", "main")

	info, err := Inspect(dir, "feat/wip")
	if err != nil {
		t.Fatalf("Inspect: %v", err)
	}
	if info.Merged {
		t.Error("Merged = true for a branch with commits not in main")
	}
	if info.UnmergedCommits != 2 {
		t.Errorf("UnmergedCommits = %d, want 2", info.UnmergedCommits)
	}
	if ok, _ := info.Deletable(false); ok {
		t.Error("Deletable(false) = true for an unmerged branch")
	}
	if ok, why := info.Deletable(true); !ok {
		t.Errorf("Deletable(true) = false (%s), want true — force is the opt-in", why)
	}
}

func TestInspect_DetectsCheckedOutWorktree(t *testing.T) {
	dir := newRepo(t)
	branchWithCommit(t, dir, "feat/live")
	wt := filepath.Join(t.TempDir(), "linked")
	runGit(t, dir, "worktree", "add", "-q", wt, "feat/live")

	info, err := Inspect(dir, "feat/live")
	if err != nil {
		t.Fatalf("Inspect: %v", err)
	}
	if len(info.CheckedOutAt) != 1 {
		t.Fatalf("CheckedOutAt = %v, want the one linked worktree", info.CheckedOutAt)
	}
	// macOS resolves t.TempDir() through /private, so compare on the suffix.
	if !strings.HasSuffix(info.CheckedOutAt[0], "linked") {
		t.Errorf("CheckedOutAt[0] = %q, want the linked worktree path", info.CheckedOutAt[0])
	}
	if ok, _ := info.Deletable(false); ok {
		t.Error("Deletable = true for a branch checked out in a worktree")
	}
}

func TestInspect_MainWorktreeCounts(t *testing.T) {
	// The branch the main working tree is sitting on is checked out too, even
	// though no linked worktree exists.
	dir := newRepo(t)
	info, err := Inspect(dir, "main")
	if err != nil {
		t.Fatalf("Inspect: %v", err)
	}
	if len(info.CheckedOutAt) != 1 {
		t.Errorf("CheckedOutAt = %v, want the main working tree", info.CheckedOutAt)
	}
}

func TestInspect_MissingBranch(t *testing.T) {
	dir := newRepo(t)
	info, err := Inspect(dir, "no/such")
	if err != nil {
		t.Fatalf("Inspect on a missing branch should not error: %v", err)
	}
	if info.Exists {
		t.Error("Exists = true for a branch that was never created")
	}
	if ok, _ := info.Deletable(false); ok {
		t.Error("Deletable = true for a nonexistent branch")
	}
}

func TestInspect_NotARepo(t *testing.T) {
	if _, err := Inspect(t.TempDir(), "main"); !errors.Is(err, ErrNotARepo) {
		t.Errorf("err = %v, want ErrNotARepo", err)
	}
}

func TestInspect_UpstreamReported(t *testing.T) {
	// A bare "remote" plus a push gives the branch a real tracking ref, which is
	// what tells the app to say the remote branch was left alone.
	dir := newRepo(t)
	remote := filepath.Join(t.TempDir(), "origin.git")
	runGit(t, dir, "init", "-q", "--bare", remote)
	runGit(t, dir, "remote", "add", "origin", remote)
	runGit(t, dir, "push", "-q", "-u", "origin", "main")
	branchWithCommit(t, dir, "feat/pushed")
	runGit(t, dir, "push", "-q", "-u", "origin", "feat/pushed")

	info, err := Inspect(dir, "feat/pushed")
	if err != nil {
		t.Fatalf("Inspect: %v", err)
	}
	if info.Upstream != "origin/feat/pushed" {
		t.Errorf("Upstream = %q, want origin/feat/pushed", info.Upstream)
	}
}

func TestDefaultBranch_ResolvedNotAssumed(t *testing.T) {
	t.Run("from the remote HEAD, whatever it is called", func(t *testing.T) {
		dir := t.TempDir()
		runGit(t, dir, "init", "-q", "-b", "trunk")
		runGit(t, dir, "config", "user.email", "test@example.com")
		runGit(t, dir, "config", "user.name", "Test")
		commit(t, dir, "f.txt", "x\n", "base")
		// A `main` also exists, so a package that assumed "main" would pick the
		// wrong one.
		runGit(t, dir, "branch", "main")
		remote := filepath.Join(t.TempDir(), "origin.git")
		runGit(t, dir, "init", "-q", "--bare", remote)
		runGit(t, dir, "remote", "add", "origin", remote)
		runGit(t, dir, "push", "-q", "origin", "trunk", "main")
		runGit(t, dir, "remote", "set-head", "origin", "trunk")

		if got, _ := defaultBranch(dir); got != "trunk" {
			t.Errorf("defaultBranch = %q, want trunk", got)
		}
	})

	t.Run("falls back to a conventional local name with no remote", func(t *testing.T) {
		dir := newRepo(t)
		if got, _ := defaultBranch(dir); got != "main" {
			t.Errorf("defaultBranch = %q, want main", got)
		}
	})

	t.Run("empty when nothing conventional exists", func(t *testing.T) {
		dir := t.TempDir()
		runGit(t, dir, "init", "-q", "-b", "wip/one")
		runGit(t, dir, "config", "user.email", "test@example.com")
		runGit(t, dir, "config", "user.name", "Test")
		commit(t, dir, "f.txt", "x\n", "base")
		if got, _ := defaultBranch(dir); got != "" {
			t.Errorf("defaultBranch = %q, want empty rather than a guess", got)
		}
	})
}

func TestDelete_MergedBranchGoesQuietly(t *testing.T) {
	dir := newRepo(t)
	branchWithCommit(t, dir, "feat/done")
	runGit(t, dir, "merge", "-q", "--no-ff", "-m", "merge", "feat/done")

	out, err := Delete(dir, "feat/done", false)
	if err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if !out.Deleted || out.Forced {
		t.Errorf("Outcome = %+v, want deleted without force", out)
	}
	if out.SHA == "" {
		t.Error("SHA is empty; the pre-delete sha is the only handle left for recovery")
	}
	if refExists(dir, "refs/heads/feat/done") {
		t.Error("branch still exists after Delete")
	}
}

func TestDelete_RefusesTheDefaultBranch(t *testing.T) {
	dir := newRepo(t)
	// Move off main so the "checked out" rule cannot be what refuses it — this
	// must fail because it is the DEFAULT branch, not because it is in use.
	branchWithCommit(t, dir, "feat/side")
	runGit(t, dir, "checkout", "-q", "feat/side")

	_, err := Delete(dir, "main", true)
	if !errors.Is(err, ErrDefaultBranch) {
		t.Fatalf("err = %v, want ErrDefaultBranch", err)
	}
	if !refExists(dir, "refs/heads/main") {
		t.Error("main was deleted")
	}
}

func TestDelete_RefusesTheDefaultBranchUnderAnyName(t *testing.T) {
	dir := t.TempDir()
	runGit(t, dir, "init", "-q", "-b", "trunk")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test")
	commit(t, dir, "f.txt", "x\n", "base")
	remote := filepath.Join(t.TempDir(), "origin.git")
	runGit(t, dir, "init", "-q", "--bare", remote)
	runGit(t, dir, "remote", "add", "origin", remote)
	runGit(t, dir, "push", "-q", "origin", "trunk")
	runGit(t, dir, "remote", "set-head", "origin", "trunk")
	runGit(t, dir, "checkout", "-q", "-b", "elsewhere")

	if _, err := Delete(dir, "trunk", true); !errors.Is(err, ErrDefaultBranch) {
		t.Fatalf("err = %v, want ErrDefaultBranch for a repo whose default is 'trunk'", err)
	}
}

func TestDelete_RefusesACheckedOutBranch(t *testing.T) {
	dir := newRepo(t)
	branchWithCommit(t, dir, "feat/live")
	runGit(t, dir, "merge", "-q", "--no-ff", "-m", "merge", "feat/live")
	wt := filepath.Join(t.TempDir(), "linked")
	runGit(t, dir, "worktree", "add", "-q", wt, "feat/live")

	// Merged and not the default branch — the only thing wrong is that a
	// worktree still holds it, and force must not override that.
	_, err := Delete(dir, "feat/live", true)
	if !errors.Is(err, ErrCheckedOut) {
		t.Fatalf("err = %v, want ErrCheckedOut", err)
	}
	if !strings.Contains(err.Error(), "linked") {
		t.Errorf("err = %v, want it to name the worktree in the way", err)
	}
}

func TestDelete_UnmergedNeedsForce(t *testing.T) {
	dir := newRepo(t)
	branchWithCommit(t, dir, "feat/wip")

	_, err := Delete(dir, "feat/wip", false)
	if !errors.Is(err, ErrUnmerged) {
		t.Fatalf("err = %v, want ErrUnmerged", err)
	}
	if !refExists(dir, "refs/heads/feat/wip") {
		t.Fatal("branch was deleted despite the refusal")
	}

	out, err := Delete(dir, "feat/wip", true)
	if err != nil {
		t.Fatalf("forced Delete: %v", err)
	}
	if !out.Deleted || !out.Forced {
		t.Errorf("Outcome = %+v, want deleted with Forced=true", out)
	}
	if out.Merged {
		t.Error("Outcome.Merged = true for an unmerged branch")
	}
}

func TestDelete_ForceOnAMergedBranchStaysGentle(t *testing.T) {
	// force is an opt-in to losing commits, not a request for `-D`. When there
	// is nothing to lose, the outcome must not claim there was.
	dir := newRepo(t)
	branchWithCommit(t, dir, "feat/done")
	runGit(t, dir, "merge", "-q", "--no-ff", "-m", "merge", "feat/done")

	out, err := Delete(dir, "feat/done", true)
	if err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if out.Forced {
		t.Error("Forced = true for a merged branch; nothing was dropped")
	}
}

func TestDelete_MissingBranch(t *testing.T) {
	dir := newRepo(t)
	if _, err := Delete(dir, "no/such", true); !errors.Is(err, ErrNoBranch) {
		t.Errorf("err = %v, want ErrNoBranch", err)
	}
}

func TestDelete_RefusesWhenTheDefaultBranchIsUnknowable(t *testing.T) {
	// No remote and no conventional branch name: "is this the default" and "is
	// this merged" are both unanswerable, so nothing is deletable.
	dir := t.TempDir()
	runGit(t, dir, "init", "-q", "-b", "wip/one")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test")
	commit(t, dir, "f.txt", "x\n", "base")
	runGit(t, dir, "branch", "wip/two")

	if _, err := Delete(dir, "wip/two", true); !errors.Is(err, ErrUnknownDefault) {
		t.Errorf("err = %v, want ErrUnknownDefault", err)
	}
}

func TestDelete_MergedOnlyIntoTheRemoteDefault(t *testing.T) {
	// The case this app hits constantly: the branch was merged on the forge and
	// origin/main knows, but local main has not been pulled. Reporting it as
	// unmerged would push the user onto the destructive path for a branch that
	// loses nothing.
	dir := newRepo(t)
	remote := filepath.Join(t.TempDir(), "origin.git")
	runGit(t, dir, "init", "-q", "--bare", remote)
	runGit(t, dir, "remote", "add", "origin", remote)
	runGit(t, dir, "push", "-q", "-u", "origin", "main")
	branchWithCommit(t, dir, "feat/merged-upstream")

	// Merge on a clone and push, so origin/main advances while local main does not.
	clone := filepath.Join(t.TempDir(), "clone")
	runGit(t, t.TempDir(), "clone", "-q", remote, clone)
	runGit(t, clone, "config", "user.email", "test@example.com")
	runGit(t, clone, "config", "user.name", "Test")
	runGit(t, dir, "push", "-q", "origin", "feat/merged-upstream")
	runGit(t, clone, "fetch", "-q", "origin")
	runGit(t, clone, "merge", "-q", "--no-ff", "-m", "merge", "origin/feat/merged-upstream")
	runGit(t, clone, "push", "-q", "origin", "main")
	runGit(t, dir, "fetch", "-q", "origin")

	info, err := Inspect(dir, "feat/merged-upstream")
	if err != nil {
		t.Fatalf("Inspect: %v", err)
	}
	if !info.Merged {
		t.Fatalf("Merged = false; want true via origin/main (info=%+v)", info)
	}
	if info.MergedInto != "origin/main" {
		t.Errorf("MergedInto = %q, want origin/main so the caller can tell the two apart", info.MergedInto)
	}
}

func TestCheckBranchName(t *testing.T) {
	for _, bad := range []string{"", "   ", "-D", "-", "with\nnewline"} {
		if err := checkBranchName(bad); !errors.Is(err, ErrBadBranch) {
			t.Errorf("checkBranchName(%q) = %v, want ErrBadBranch", bad, err)
		}
	}
	for _, ok := range []string{"main", "feat/x", "release-1.2", "user/wip.2"} {
		if err := checkBranchName(ok); err != nil {
			t.Errorf("checkBranchName(%q) = %v, want nil", ok, err)
		}
	}
}
