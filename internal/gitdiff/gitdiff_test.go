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

// ---- test helpers ----

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
