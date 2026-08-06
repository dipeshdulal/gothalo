package suggest

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// gitRepo makes a real repository in a temp dir. Real git rather than a
// hand-built .git: the sources read marker files git itself writes, and a
// fixture that guesses their names would pass while the production path fails.
func gitRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"config", "user.email", "t@example.com"},
		{"config", "user.name", "t"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	return dir
}

func write(t *testing.T, dir, name, body string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func commitAll(t *testing.T, dir string) {
	t.Helper()
	for _, args := range [][]string{{"add", "-A"}, {"commit", "-qm", "x"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
}

// kinds names the suggestions a pane produced, for assertions that care about
// which sources fired rather than about their prose.
func kinds(list []Suggestion) []string {
	out := make([]string, 0, len(list))
	for _, s := range list {
		out = append(out, s.Kind)
	}
	return out
}

// TestDirtyTreeSuggestsReview is the core agent-pane case: an agent has written
// files and the phone should offer the diff.
func TestDirtyTreeSuggestsReview(t *testing.T) {
	dir := gitRepo(t)
	write(t, dir, "a.txt", "one\n")
	commitAll(t, dir)
	write(t, dir, "a.txt", "two\n")
	write(t, dir, "b.txt", "new\n")

	got := For(Pane{ID: "w1:p1", HasAgent: true, AgentKind: "claude", Cwd: dir})
	if len(got) != 1 || got[0].Kind != KindGitDirty {
		t.Fatalf("suggestions = %v, want one git_dirty", kinds(got))
	}
	if got[0].Action != ActionOpenDiff {
		t.Errorf("action = %q, want %q", got[0].Action, ActionOpenDiff)
	}
	if got[0].Params["pane"] != "w1:p1" {
		t.Errorf("params[pane] = %q, want the pane id", got[0].Params["pane"])
	}
	if got[0].Detail != "2 files changed" {
		t.Errorf("detail = %q, want the changed-file count", got[0].Detail)
	}
}

// TestCleanTreeSuggestsNothing pins the steady state. Most panes most of the
// time must produce an empty row, or the affordance becomes furniture.
func TestCleanTreeSuggestsNothing(t *testing.T) {
	dir := gitRepo(t)
	write(t, dir, "a.txt", "one\n")
	commitAll(t, dir)

	got := For(Pane{ID: "w1:p1", HasAgent: true, Cwd: dir})
	if len(got) != 0 {
		t.Fatalf("suggestions = %v, want none for a clean tree", kinds(got))
	}
}

// TestConflictSupersedesDirty covers the ordering rule that matters most: a
// conflicted tree is also a dirty tree, and two chips onto the same screen is
// the noise this feature is meant not to make.
func TestConflictSupersedesDirty(t *testing.T) {
	dir := gitRepo(t)
	write(t, dir, "a.txt", "base\n")
	commitAll(t, dir)
	// A marker file is exactly what an interrupted merge leaves behind, and it
	// is what inProgress reads — no need to stage a real conflict.
	write(t, dir, ".git/MERGE_HEAD", "0000000000000000000000000000000000000000\n")
	write(t, dir, "a.txt", "ours\n")

	got := For(Pane{ID: "w1:p1", HasAgent: true, Cwd: dir})
	if len(got) != 1 || got[0].Kind != KindGitConflict {
		t.Fatalf("suggestions = %v, want only git_conflict", kinds(got))
	}
	if got[0].Detail != "merge in progress" {
		t.Errorf("detail = %q, want the operation named", got[0].Detail)
	}
}

// TestIdleShellInRepoSuggestsAgent is the plain-pane case: a pane parked at a
// prompt inside a worktree is somewhere an agent could be started.
func TestIdleShellInRepoSuggestsAgent(t *testing.T) {
	dir := gitRepo(t)
	got := For(Pane{ID: "w1:p2", AtShellPrompt: true, Cwd: dir})
	if len(got) != 1 || got[0].Kind != KindShellIdle {
		t.Fatalf("suggestions = %v, want one shell_idle", kinds(got))
	}
	if got[0].Action != ActionStartAgent {
		t.Errorf("action = %q, want %q", got[0].Action, ActionStartAgent)
	}
	if want := "idle shell in " + filepath.Base(dir); got[0].Detail != want {
		t.Errorf("detail = %q, want %q", got[0].Detail, want)
	}
}

// TestIdleShellOutsideRepoSuggestsNothing is the guard that keeps the chip off
// every shell on the host — a pane in ~ is not somewhere to start an agent.
func TestIdleShellOutsideRepoSuggestsNothing(t *testing.T) {
	got := For(Pane{ID: "w1:p2", AtShellPrompt: true, Cwd: t.TempDir()})
	if len(got) != 0 {
		t.Fatalf("suggestions = %v, want none outside a repository", kinds(got))
	}
}

// TestBusyShellSuggestsNothing: a pane running a command is not free, whatever
// its directory says.
func TestBusyShellSuggestsNothing(t *testing.T) {
	dir := gitRepo(t)
	got := For(Pane{ID: "w1:p2", AtShellPrompt: false, Foreground: "npm run dev", Cwd: dir})
	if len(got) != 0 {
		t.Fatalf("suggestions = %v, want none while a command holds the pane", kinds(got))
	}
}

// TestAgentPaneNeverOffersStartAgent: an agent pane is not an empty pane, and
// offering to start a second agent in it would be an action that fails.
func TestAgentPaneNeverOffersStartAgent(t *testing.T) {
	dir := gitRepo(t)
	write(t, dir, "a.txt", "one\n")
	got := For(Pane{ID: "w1:p1", HasAgent: true, AtShellPrompt: true, Cwd: dir})
	for _, s := range got {
		if s.Action == ActionStartAgent {
			t.Fatalf("agent pane offered start_agent: %v", kinds(got))
		}
	}
}

// TestNoCwdSuggestsNothing: every source is filesystem-backed, so a pane whose
// directory could not be resolved must produce nothing rather than guess.
func TestNoCwdSuggestsNothing(t *testing.T) {
	if got := For(Pane{ID: "w1:p1", HasAgent: true, AtShellPrompt: true}); len(got) != 0 {
		t.Fatalf("suggestions = %v, want none without a cwd", kinds(got))
	}
}

// TestForIsCappedAndOrdered pins the two invariants the app codes against: at
// most [Max] entries, highest rank first. Driven off a substituted registry
// because the real sources are mutually exclusive by construction — today no
// pane can produce enough of them to reach the cap, and the cap still has to
// hold when one day it can.
func TestForIsCappedAndOrdered(t *testing.T) {
	fixed := func(kind string, rank int) source {
		return func(Pane) *Suggestion {
			return &Suggestion{Kind: kind, Action: ActionOpenDiff, Rank: rank}
		}
	}
	restore := sources
	t.Cleanup(func() { sources = restore })
	sources = []source{
		fixed("low", 1), fixed("high", 9), fixed("mid", 5), fixed("lowest", 0),
	}

	got := For(Pane{ID: "w1:p1"})
	if len(got) != Max {
		t.Fatalf("got %d suggestions, want the cap of %d", len(got), Max)
	}
	if want := []string{"high", "mid", "low"}; !equal(kinds(got), want) {
		t.Errorf("kinds = %v, want %v (descending rank, lowest dropped)", kinds(got), want)
	}
	for _, s := range got {
		if s.Params["pane"] != "w1:p1" {
			t.Errorf("%s: params[pane] = %q, want the pane id stamped by For", s.Kind, s.Params["pane"])
		}
	}
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
