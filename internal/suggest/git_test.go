package suggest

import (
	"os/exec"
	"path/filepath"
	"testing"
)

// TestGitDirInWorktree is the case this codebase runs in every day: agents work
// in `git worktree` checkouts, whose `.git` is a FILE pointing at
// `<repo>/.git/worktrees/<name>`. Reading it as "not a repository" would
// silence every source in exactly the panes the feature exists for.
func TestGitDirInWorktree(t *testing.T) {
	main := gitRepo(t)
	write(t, main, "a.txt", "one\n")
	commitAll(t, main)

	wt := filepath.Join(t.TempDir(), "feat-thing")
	cmd := exec.Command("git", "worktree", "add", "-q", "-b", "feat-thing", wt)
	cmd.Dir = main
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git worktree add: %v: %s", err, out)
	}

	dir, root, ok := gitDir(wt)
	if !ok {
		t.Fatal("gitDir did not resolve a worktree checkout")
	}
	if root != wt {
		t.Errorf("root = %q, want the worktree itself %q", root, wt)
	}
	if filepath.Base(filepath.Dir(dir)) != "worktrees" {
		t.Errorf("git dir = %q, want the per-worktree directory", dir)
	}
	if name, ok := repoName(wt); !ok || name != "feat-thing" {
		t.Errorf("repoName = %q,%v — want the worktree's own directory name", name, ok)
	}
}

// TestGitDirWalksUp: a pane is usually parked in a subdirectory, not at the
// repository root.
func TestGitDirWalksUp(t *testing.T) {
	repo := gitRepo(t)
	write(t, repo, "internal/deep/x.txt", "x\n")

	_, root, ok := gitDir(filepath.Join(repo, "internal", "deep"))
	if !ok || root != repo {
		t.Errorf("gitDir(subdir) = %q,%v, want the repo root %q", root, ok, repo)
	}
}

// TestGitDirOutsideRepo: the negative case has to be a clean "no", since it is
// what keeps the start-an-agent chip off every idle shell on the host.
func TestGitDirOutsideRepo(t *testing.T) {
	if _, _, ok := gitDir(t.TempDir()); ok {
		t.Error("gitDir claimed a plain directory is a repository")
	}
	if _, _, ok := gitDir(""); ok {
		t.Error("gitDir claimed an empty path is a repository")
	}
}

// TestInProgressNamesTheOperation pins the marker-file mapping. These are the
// states where a person is needed, so a wrong name here is a chip that
// describes the wrong emergency.
func TestInProgressNamesTheOperation(t *testing.T) {
	cases := map[string]string{
		"MERGE_HEAD":            "merge",
		"CHERRY_PICK_HEAD":      "cherry-pick",
		"REVERT_HEAD":           "revert",
		"rebase-merge/onto":     "rebase",
		"rebase-apply/original": "rebase",
	}
	for marker, want := range cases {
		t.Run(want+"/"+marker, func(t *testing.T) {
			repo := gitRepo(t)
			write(t, repo, filepath.Join(".git", marker), "x\n")
			op, ok := inProgress(repo)
			if !ok || op != want {
				t.Errorf("inProgress = %q,%v, want %q", op, ok, want)
			}
		})
	}

	repo := gitRepo(t)
	if op, ok := inProgress(repo); ok {
		t.Errorf("inProgress on an untouched repo = %q, want none", op)
	}
}

// TestCountPorcelainCountsRenamesOnce: `R  new\0old\0` is one changed file over
// two records, and the origin path is a bare path with no status code — count
// it and the chip reports more files than the diff screen will list.
func TestCountPorcelainCountsRenamesOnce(t *testing.T) {
	raw := []byte("M  modified.go\x00?? new.go\x00R  renamed_to.go\x00old name.go\x00 D deleted.go\x00")
	if got := countPorcelain(raw); got != 4 {
		t.Errorf("countPorcelain = %d, want 4 (the rename origin is not a file)", got)
	}
	if got := countPorcelain(nil); got != 0 {
		t.Errorf("countPorcelain(nil) = %d, want 0", got)
	}
}

// TestDirtyCountAgainstRealGit checks the parse against git's actual output
// rather than only against a hand-written fixture.
func TestDirtyCountAgainstRealGit(t *testing.T) {
	repo := gitRepo(t)
	write(t, repo, "a.txt", "one\n")
	commitAll(t, repo)
	if n, ok := dirtyCount(repo); !ok || n != 0 {
		t.Errorf("dirtyCount(clean) = %d,%v, want 0,true", n, ok)
	}

	write(t, repo, "a.txt", "two\n")
	write(t, repo, "b.txt", "new\n")
	if n, ok := dirtyCount(repo); !ok || n != 2 {
		t.Errorf("dirtyCount(dirty) = %d,%v, want 2,true", n, ok)
	}

	if _, ok := dirtyCount(t.TempDir()); ok {
		t.Error("dirtyCount answered for a directory that is not a repository")
	}
}
