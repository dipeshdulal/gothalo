package gitdiff

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func TestParsePorcelain(t *testing.T) {
	// "XY path\0" per entry; a rename ('R' in the code) consumes a second
	// NUL-separated field, the origin path.
	raw := "M  modified.go\x00?? new.go\x00R  renamed_to.go\x00renamed_from.go\x00 D deleted.go\x00"
	entries := parsePorcelain([]byte(raw))

	want := map[string]entry{
		"modified.go":   {Path: "modified.go", Status: "modified"},
		"new.go":        {Path: "new.go", Status: "untracked"},
		"renamed_to.go": {Path: "renamed_to.go", OldPath: "renamed_from.go", Status: "renamed"},
		"deleted.go":    {Path: "deleted.go", Status: "deleted"},
	}
	if len(entries) != len(want) {
		t.Fatalf("got %d entries, want %d: %+v", len(entries), len(want), entries)
	}
	for _, e := range entries {
		w, ok := want[e.Path]
		if !ok {
			t.Errorf("unexpected entry for path %q: %+v", e.Path, e)
			continue
		}
		if e != w {
			t.Errorf("entry for %q = %+v, want %+v", e.Path, e, w)
		}
	}
}

func TestStatusLabel(t *testing.T) {
	cases := map[string]string{
		"??": "untracked",
		"A ": "added",
		" A": "added",
		"R ": "renamed",
		"D ": "deleted",
		" D": "deleted",
		" M": "modified",
		"M ": "modified",
		"MM": "modified",
	}
	for code, want := range cases {
		if got := statusLabel(code); got != want {
			t.Errorf("statusLabel(%q) = %q, want %q", code, got, want)
		}
	}
}

func TestSplitUnifiedDiff(t *testing.T) {
	raw := `diff --git a/foo.go b/foo.go
index 1111111..2222222 100644
--- a/foo.go
+++ b/foo.go
@@ -1 +1 @@
-old
+new
diff --git a/bar/old.go b/bar/new.go
similarity index 90%
rename from bar/old.go
rename to bar/new.go
index 3333333..4444444 100644
--- a/bar/old.go
+++ b/bar/new.go
@@ -1 +1,2 @@
 unchanged
+added
`
	diffs := splitUnifiedDiff([]byte(raw))
	if len(diffs) != 2 {
		t.Fatalf("got %d diffs, want 2: keys=%v", len(diffs), keys(diffs))
	}
	if d, ok := diffs["foo.go"]; !ok || !strings.Contains(d, "-old") || !strings.Contains(d, "+new") {
		t.Errorf("foo.go diff = %q, missing expected content", d)
	}
	// Rename is keyed by the NEW ("b/") path.
	if d, ok := diffs["bar/new.go"]; !ok || !strings.Contains(d, "+added") {
		t.Errorf("bar/new.go diff = %q, missing expected content", d)
	}
	if _, ok := diffs["bar/old.go"]; ok {
		t.Errorf("rename should be keyed by the new path only, not the old one")
	}
}

func TestCountChanges(t *testing.T) {
	diff := "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-removed line\n+added line 1\n+added line 2\n"
	adds, dels := countChanges(diff)
	if adds != 2 || dels != 1 {
		t.Errorf("countChanges = (%d,%d), want (2,1)", adds, dels)
	}
}

func TestCollect_RealRepo(t *testing.T) {
	dir := t.TempDir()
	runGit(t, dir, "init", "-q", "-b", "main")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test")

	mustWrite(t, dir, "tracked.txt", "line one\nline two\n")
	mustWrite(t, dir, "to_delete.txt", "bye\n")
	mustWrite(t, dir, "to_rename.txt", "stays the same\n")
	runGit(t, dir, "add", ".")
	runGit(t, dir, "commit", "-q", "-m", "base")

	// Modify a tracked file (unstaged).
	mustWrite(t, dir, "tracked.txt", "line one\nline two CHANGED\n")
	// Delete a tracked file.
	if err := os.Remove(filepath.Join(dir, "to_delete.txt")); err != nil {
		t.Fatal(err)
	}
	// Rename a tracked file (staged, so git detects it as a rename).
	runGit(t, dir, "mv", "to_rename.txt", "renamed.txt")
	// A brand new, untracked file.
	mustWrite(t, dir, "untracked.txt", "hello\nworld\n")

	result, err := Collect(dir)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if result.Branch != "main" {
		t.Errorf("Branch = %q, want main", result.Branch)
	}
	byPath := map[string]FileChange{}
	for _, f := range result.Files {
		byPath[f.Path] = f
	}
	if len(byPath) != 4 {
		t.Fatalf("got %d files, want 4: %+v", len(byPath), byPath)
	}

	if f := byPath["tracked.txt"]; f.Status != "modified" || f.Additions == 0 {
		t.Errorf("tracked.txt = %+v, want status=modified with additions", f)
	}
	if f := byPath["to_delete.txt"]; f.Status != "deleted" {
		t.Errorf("to_delete.txt = %+v, want status=deleted", f)
	}
	if f := byPath["renamed.txt"]; f.Status != "renamed" || f.OldPath != "to_rename.txt" {
		t.Errorf("renamed.txt = %+v, want status=renamed from to_rename.txt", f)
	}
	if f := byPath["untracked.txt"]; f.Status != "untracked" || !strings.Contains(f.Diff, "+hello") || !strings.Contains(f.Diff, "+world") {
		t.Errorf("untracked.txt = %+v, want a synthetic added-lines diff", f)
	}
}

func TestCollect_NotAGitRepo(t *testing.T) {
	dir := t.TempDir()
	result, err := Collect(dir)
	if err != nil {
		t.Fatalf("Collect on a non-repo should degrade quietly, got err: %v", err)
	}
	if len(result.Files) != 0 {
		t.Errorf("Files = %+v, want none for a non-repo", result.Files)
	}
}

func TestBranch(t *testing.T) {
	t.Run("reports the checked-out branch", func(t *testing.T) {
		dir := t.TempDir()
		runGit(t, dir, "init", "-q", "-b", "feat/x")
		runGit(t, dir, "config", "user.email", "test@example.com")
		runGit(t, dir, "config", "user.name", "Test")
		mustWrite(t, dir, "f.txt", "hi\n")
		runGit(t, dir, "add", ".")
		runGit(t, dir, "commit", "-q", "-m", "base")

		if got := Branch(dir); got != "feat/x" {
			t.Errorf("Branch = %q, want feat/x", got)
		}
	})

	t.Run("empty for a non-repo dir", func(t *testing.T) {
		if got := Branch(t.TempDir()); got != "" {
			t.Errorf("Branch = %q, want empty for a non-repo", got)
		}
	})

	t.Run("empty for an empty cwd", func(t *testing.T) {
		if got := Branch(""); got != "" {
			t.Errorf("Branch(%q) = %q, want empty", "", got)
		}
	})

	t.Run("empty on a detached HEAD", func(t *testing.T) {
		dir := t.TempDir()
		runGit(t, dir, "init", "-q", "-b", "main")
		runGit(t, dir, "config", "user.email", "test@example.com")
		runGit(t, dir, "config", "user.name", "Test")
		mustWrite(t, dir, "f.txt", "one\n")
		runGit(t, dir, "add", ".")
		runGit(t, dir, "commit", "-q", "-m", "c1")
		mustWrite(t, dir, "f.txt", "two\n")
		runGit(t, dir, "commit", "-qam", "c2")
		// Detach onto the first commit.
		runGit(t, dir, "checkout", "-q", "HEAD~1")

		if got := Branch(dir); got != "" {
			t.Errorf("Branch = %q, want empty on detached HEAD", got)
		}
	})
}

func TestReadContext(t *testing.T) {
	t.Run("non-repo reports Repo false", func(t *testing.T) {
		c := ReadContext(t.TempDir())
		if c.Repo {
			t.Errorf("Repo = true for a plain directory, want false")
		}
	})

	t.Run("empty cwd reports Repo false", func(t *testing.T) {
		if ReadContext("").Repo {
			t.Errorf("Repo = true for an empty cwd, want false")
		}
	})

	t.Run("feature branch ahead of the default branch", func(t *testing.T) {
		dir := initRepo(t)
		mustWrite(t, dir, "f.txt", "one\n")
		runGit(t, dir, "add", ".")
		runGit(t, dir, "commit", "-q", "-m", "base")
		runGit(t, dir, "checkout", "-q", "-b", "feat/x")
		mustWrite(t, dir, "f.txt", "two\n")
		runGit(t, dir, "commit", "-qam", "work")
		// An uncommitted change on top, so Dirty has something to see.
		mustWrite(t, dir, "g.txt", "untracked\n")

		c := ReadContext(dir)
		if !c.Repo {
			t.Fatalf("Repo = false, want true")
		}
		if c.Branch != "feat/x" {
			t.Errorf("Branch = %q, want feat/x", c.Branch)
		}
		if c.DefaultBranch != "main" {
			t.Errorf("DefaultBranch = %q, want main", c.DefaultBranch)
		}
		if c.DefaultRef != "refs/heads/main" {
			t.Errorf("DefaultRef = %q, want refs/heads/main", c.DefaultRef)
		}
		if c.Ahead != 1 || c.Behind != 0 {
			t.Errorf("ahead/behind = %d/%d, want 1/0", c.Ahead, c.Behind)
		}
		if !c.Dirty {
			t.Errorf("Dirty = false, want true (an untracked file is uncommitted work)")
		}
		if c.Remote != "" {
			t.Errorf("Remote = %q, want empty for a repo with no remote", c.Remote)
		}
		if c.Upstream != "" {
			t.Errorf("Upstream = %q, want empty for an unpushed branch", c.Upstream)
		}
	})

	t.Run("clean tree on the default branch", func(t *testing.T) {
		dir := initRepo(t)
		mustWrite(t, dir, "f.txt", "one\n")
		runGit(t, dir, "add", ".")
		runGit(t, dir, "commit", "-q", "-m", "base")

		c := ReadContext(dir)
		if c.Branch != "main" || c.DefaultBranch != "main" {
			t.Errorf("branch/default = %q/%q, want main/main", c.Branch, c.DefaultBranch)
		}
		if c.Ahead != 0 || c.Behind != 0 || c.Dirty {
			t.Errorf("got ahead=%d behind=%d dirty=%v, want 0/0/false", c.Ahead, c.Behind, c.Dirty)
		}
	})

	t.Run("detached HEAD has no branch", func(t *testing.T) {
		dir := initRepo(t)
		mustWrite(t, dir, "f.txt", "one\n")
		runGit(t, dir, "add", ".")
		runGit(t, dir, "commit", "-q", "-m", "c1")
		mustWrite(t, dir, "f.txt", "two\n")
		runGit(t, dir, "commit", "-qam", "c2")
		runGit(t, dir, "checkout", "-q", "HEAD~1")

		c := ReadContext(dir)
		if !c.Repo {
			t.Fatalf("Repo = false, want true")
		}
		if c.Branch != "" {
			t.Errorf("Branch = %q, want empty on a detached HEAD", c.Branch)
		}
	})

	t.Run("names an unborn branch in a repo with no commits", func(t *testing.T) {
		dir := initRepo(t)
		c := ReadContext(dir)
		if c.Branch != "main" {
			t.Errorf("Branch = %q, want main even before the first commit", c.Branch)
		}
		if c.DefaultBranch != "" {
			t.Errorf("DefaultBranch = %q, want empty — refs/heads/main does not exist yet", c.DefaultBranch)
		}
		if c.Ahead != 0 {
			t.Errorf("Ahead = %d, want 0 with no ref to compare against", c.Ahead)
		}
	})

	t.Run("prefers the remote-tracking default and reports the remote", func(t *testing.T) {
		// A bare "remote" cloned from a seed repo, so origin/main is a real ref
		// and the branch has a real upstream — the shape a PR is opened from.
		origin := t.TempDir()
		runGit(t, origin, "init", "-q", "--bare", "-b", "main")

		seed := initRepo(t)
		mustWrite(t, seed, "f.txt", "one\n")
		runGit(t, seed, "add", ".")
		runGit(t, seed, "commit", "-q", "-m", "base")
		runGit(t, seed, "remote", "add", "origin", origin)
		runGit(t, seed, "push", "-q", "-u", "origin", "main")

		c := ReadContext(seed)
		if c.Remote != "origin" {
			t.Errorf("Remote = %q, want origin", c.Remote)
		}
		if c.DefaultRef != "refs/remotes/origin/main" {
			t.Errorf("DefaultRef = %q, want refs/remotes/origin/main", c.DefaultRef)
		}
		if c.Upstream != "origin/main" {
			t.Errorf("Upstream = %q, want origin/main", c.Upstream)
		}
	})
}

// TestCollectCarriesContext pins the promise that a caller fetching the full
// diff never needs a second call for the git context.
func TestCollectCarriesContext(t *testing.T) {
	dir := initRepo(t)
	mustWrite(t, dir, "f.txt", "one\n")
	runGit(t, dir, "add", ".")
	runGit(t, dir, "commit", "-q", "-m", "base")
	runGit(t, dir, "checkout", "-q", "-b", "feat/y")
	mustWrite(t, dir, "f.txt", "two\n")

	result, err := Collect(dir)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if !result.Git.Repo || result.Git.Branch != "feat/y" {
		t.Errorf("Git = %+v, want a repo on feat/y", result.Git)
	}
	if !result.Git.Dirty {
		t.Errorf("Git.Dirty = false with a modified file, want true")
	}
	if result.Branch != result.Git.Branch {
		t.Errorf("Branch = %q but Git.Branch = %q — they must agree", result.Branch, result.Git.Branch)
	}
}

// ---- test helpers ----

// initRepo makes an empty repo on "main" with an identity configured, which is
// where every context test starts.
func initRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	runGit(t, dir, "init", "-q", "-b", "main")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test")
	return dir
}

// resolve follows symlinks the way `git rev-parse --show-toplevel` does.
func resolve(t *testing.T, path string) string {
	t.Helper()
	out, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatalf("EvalSymlinks(%q): %v", path, err)
	}
	return out
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
}

func mustWrite(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func keys(m map[string]string) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// ---- Root, Changed and Operation ----
//
// These three exist for GET /suggestions, which reads the pane's git situation
// through this package rather than shelling out for it a second time. They are
// tested against real git for the same reason the rest of this file is: the
// interesting cases (a worktree's `.git` file, a stopped rebase) are exactly
// the ones a hand-built fixture would get wrong.

// TestContextRootIsTheCheckout: Root names the work tree, which for a `git
// worktree` is the worktree itself and not the main clone. That distinction is
// the whole point — parallel worktrees of one repo are the normal shape here.
func TestContextRootIsTheCheckout(t *testing.T) {
	main := initRepo(t)
	mustWrite(t, main, "a.txt", "one\n")
	runGit(t, main, "add", "-A")
	runGit(t, main, "commit", "-qm", "one")

	// Compared through EvalSymlinks: `rev-parse --show-toplevel` reports the
	// resolved path, and on macOS every t.TempDir() sits under the /var ->
	// /private/var symlink. Nothing reads Root but its base name, so the
	// resolution is harmless — but a test that ignored it would fail on macOS
	// and pass on Linux, which is worse than either.
	real := resolve(t, main)
	if c := ReadContext(main); c.Root != real {
		t.Errorf("Root = %q, want the repo root %q", c.Root, real)
	}

	// A subdirectory still reports the root, not itself.
	sub := filepath.Join(main, "internal", "deep")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if c := ReadContext(sub); c.Root != real {
		t.Errorf("Root from a subdirectory = %q, want %q", c.Root, real)
	}

	wt := filepath.Join(t.TempDir(), "feat-thing")
	runGit(t, main, "worktree", "add", "-q", "-b", "feat-thing", wt)
	c := ReadContext(wt)
	if !c.Repo {
		t.Fatal("a worktree checkout was not recognised as a repository")
	}
	if want := resolve(t, wt); c.Root != want {
		t.Errorf("Root = %q, want the worktree itself %q", c.Root, want)
	}
	if c.Branch != "feat-thing" {
		t.Errorf("Branch = %q, want the worktree's branch", c.Branch)
	}
}

// TestContextChangedCountsTheSameFilesTheDiffLists is the consistency the
// unification buys: a chip that says "3 files changed" and a diff screen that
// lists three of them are reading one number.
func TestContextChangedCountsTheSameFilesTheDiffLists(t *testing.T) {
	dir := initRepo(t)
	mustWrite(t, dir, "a.txt", "one\n")
	runGit(t, dir, "add", "-A")
	runGit(t, dir, "commit", "-qm", "one")

	if c := ReadContext(dir); c.Changed != 0 || c.Dirty {
		t.Errorf("clean tree: Changed = %d, Dirty = %v, want 0, false", c.Changed, c.Dirty)
	}

	mustWrite(t, dir, "a.txt", "two\n")
	mustWrite(t, dir, "b.txt", "new\n")
	mustWrite(t, dir, "c.txt", "new\n")

	c := ReadContext(dir)
	if c.Changed != 3 || !c.Dirty {
		t.Errorf("Changed = %d, Dirty = %v, want 3, true", c.Changed, c.Dirty)
	}
	res, err := Collect(dir)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if len(res.Files) != c.Changed {
		t.Errorf("Collect listed %d files but Changed says %d — the two must agree",
			len(res.Files), c.Changed)
	}
	if res.Git.Changed != c.Changed {
		t.Errorf("Collect's Git.Changed = %d, ReadContext's = %d", res.Git.Changed, c.Changed)
	}
}

// TestContextOperationNamesAnUnfinishedOperation pins the marker-file mapping.
// These are the states where a person is needed, so a wrong name here is a chip
// that describes the wrong emergency.
func TestContextOperationNamesAnUnfinishedOperation(t *testing.T) {
	cases := map[string]string{
		"MERGE_HEAD":            "merge",
		"CHERRY_PICK_HEAD":      "cherry-pick",
		"REVERT_HEAD":           "revert",
		"rebase-merge/onto":     "rebase",
		"rebase-apply/original": "rebase",
	}
	for marker, want := range cases {
		t.Run(want+"/"+strings.ReplaceAll(marker, "/", "_"), func(t *testing.T) {
			dir := initRepo(t)
			mustWrite(t, dir, "a.txt", "one\n")
			runGit(t, dir, "add", "-A")
			runGit(t, dir, "commit", "-qm", "one")

			path := filepath.Join(dir, ".git", marker)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte("x\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			if got := ReadContext(dir).Operation; got != want {
				t.Errorf("Operation = %q, want %q", got, want)
			}
		})
	}

	dir := initRepo(t)
	if got := ReadContext(dir).Operation; got != "" {
		t.Errorf("Operation on an untouched repo = %q, want none", got)
	}
	if got := ReadContext(t.TempDir()).Operation; got != "" {
		t.Errorf("Operation outside a repo = %q, want none", got)
	}
}

// A worktree's markers live in <repo>/.git/worktrees/<name>, not in the main
// clone — the case that motivated reading the git dir from git itself rather
// than walking up for a `.git` directory.
func TestContextOperationInAWorktree(t *testing.T) {
	main := initRepo(t)
	mustWrite(t, main, "a.txt", "one\n")
	runGit(t, main, "add", "-A")
	runGit(t, main, "commit", "-qm", "one")

	wt := filepath.Join(t.TempDir(), "feat-thing")
	runGit(t, main, "worktree", "add", "-q", "-b", "feat-thing", wt)

	marker := filepath.Join(main, ".git", "worktrees", "feat-thing", "MERGE_HEAD")
	if err := os.WriteFile(marker, []byte("x\n"), 0o644); err != nil {
		t.Fatalf("the worktree git dir is not where it was expected: %v", err)
	}
	if got := ReadContext(wt).Operation; got != "merge" {
		t.Errorf("Operation in a worktree = %q, want %q", got, "merge")
	}
	// The main checkout is unaffected — the markers are genuinely per-worktree.
	if got := ReadContext(main).Operation; got != "" {
		t.Errorf("Operation in the main checkout = %q, want none", got)
	}
}
