package suggest

import (
	"strings"
	"testing"
)

// The sources are pure functions over an already-collected observation, so
// these tests are data, not fixtures on disk. The git reading they used to do
// themselves now belongs to internal/gitdiff and is tested there — including
// against real repositories and real worktrees.

// repo is a plausible git situation to vary from: on a feature branch, pushed,
// one commit ahead, clean.
func repo() Git {
	return Git{
		Repo:          true,
		Root:          "/Users/me/.herdr/worktrees/gothalo/feat-thing",
		Branch:        "feat/thing",
		DefaultBranch: "main",
		Remote:        "origin",
		Upstream:      "origin/feat/thing",
		Ahead:         1,
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

func only(t *testing.T, got []Suggestion, kind string) Suggestion {
	t.Helper()
	if len(got) != 1 || got[0].Kind != kind {
		t.Fatalf("suggestions = %v, want exactly one %s", kinds(got), kind)
	}
	return got[0]
}

// TestDirtyTreeSuggestsReview is the core agent-pane case: an agent has written
// files and the phone should offer the diff.
func TestDirtyTreeSuggestsReview(t *testing.T) {
	// On the default branch, so create_pr stays out of the way and this test is
	// about the one source it names.
	g := repo()
	g.Branch = g.DefaultBranch
	g.Ahead, g.Dirty, g.Changed = 0, true, 2

	s := only(t, For(Pane{ID: "w1:p1", HasAgent: true, AgentKind: "claude", Git: g}), KindGitDirty)
	if s.Action != ActionOpenDiff || s.Performer != PerformerApp {
		t.Errorf("suggestion = %+v, want an app-performed open_diff", s)
	}
	if s.Params["pane"] != "w1:p1" {
		t.Errorf("params[pane] = %q, want the pane id", s.Params["pane"])
	}
	if s.Detail != "2 files changed" {
		t.Errorf("detail = %q, want the changed-file count", s.Detail)
	}
}

// TestCleanTreeSuggestsNothing pins the steady state. Most panes most of the
// time must produce an empty row, or the affordance becomes furniture.
func TestCleanTreeSuggestsNothing(t *testing.T) {
	g := repo()
	g.Ahead = 0 // nothing to review, nothing to open a PR with
	if got := For(Pane{ID: "w1:p1", HasAgent: true, Git: g}); len(got) != 0 {
		t.Fatalf("suggestions = %v, want none for a clean, unpushed-nothing tree", kinds(got))
	}
}

// TestConflictSupersedesEverythingGitShaped: a conflicted tree is also dirty,
// and it is also technically a branch with work on it. Only the chip that needs
// a person should appear — anything else is telling you to do the wrong thing
// next.
func TestConflictSupersedesEverythingGitShaped(t *testing.T) {
	g := repo()
	g.Operation, g.Dirty, g.Changed, g.Ahead = "rebase", true, 3, 2

	s := only(t, For(Pane{ID: "w1:p1", HasAgent: true, Git: g}), KindGitConflict)
	if s.Detail != "rebase in progress" {
		t.Errorf("detail = %q, want the operation named", s.Detail)
	}
}

// TestIdleShellInRepoSuggestsAgent is the plain-pane case: a pane parked at a
// prompt inside a worktree is somewhere an agent could be started.
func TestIdleShellInRepoSuggestsAgent(t *testing.T) {
	s := only(t, For(Pane{ID: "w1:p2", AtShellPrompt: true, Git: repo()}), KindShellIdle)
	if s.Action != ActionStartAgent {
		t.Errorf("action = %q, want %q", s.Action, ActionStartAgent)
	}
	// The worktree's own directory name, not the repo's — several worktrees of
	// one project are the normal shape here and the remote is identical for all.
	if s.Detail != "idle shell in feat-thing" {
		t.Errorf("detail = %q, want the checkout named", s.Detail)
	}
}

// TestIdleShellOutsideRepoSuggestsNothing is the guard that keeps the chip off
// every shell on the host — a pane in ~ is not somewhere to start an agent.
func TestIdleShellOutsideRepoSuggestsNothing(t *testing.T) {
	if got := For(Pane{ID: "w1:p2", AtShellPrompt: true}); len(got) != 0 {
		t.Fatalf("suggestions = %v, want none outside a repository", kinds(got))
	}
}

// TestBusyShellSuggestsNothing: a pane running a command is not free, whatever
// its directory says.
func TestBusyShellSuggestsNothing(t *testing.T) {
	got := For(Pane{ID: "w1:p2", Foreground: "npm run dev", Git: repo()})
	if len(got) != 0 {
		t.Fatalf("suggestions = %v, want none while a command holds the pane", kinds(got))
	}
}

// TestAgentPaneNeverOffersStartAgent: an agent pane is not an empty pane, and
// offering to start a second agent in it would be an action that fails.
func TestAgentPaneNeverOffersStartAgent(t *testing.T) {
	got := For(Pane{ID: "w1:p1", HasAgent: true, AtShellPrompt: true, Git: repo()})
	for _, s := range got {
		if s.Action == ActionStartAgent {
			t.Fatalf("agent pane offered start_agent: %v", kinds(got))
		}
	}
}

// TestNoRepoSuggestsNothingGitShaped: every git source is gated on a real
// host-side read, never on a path or a guess.
func TestNoRepoSuggestsNothingGitShaped(t *testing.T) {
	if got := For(Pane{ID: "w1:p1", HasAgent: true, AtShellPrompt: true}); len(got) != 0 {
		t.Fatalf("suggestions = %v, want none outside a repository", kinds(got))
	}
}

// TestForIsCappedAndOrdered pins the two invariants the app codes against: at
// most [Max] entries, highest rank first. Driven off a substituted registry so
// the cap is exercised even though no real pane reaches it today.
func TestForIsCappedAndOrdered(t *testing.T) {
	fixed := func(kind string, rank int) source {
		return func(Pane) []Suggestion {
			return []Suggestion{{Kind: kind, Action: ActionOpenDiff, Rank: rank}}
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

// TestEveryRealSuggestionNamesItsPerformer. The app branches on this, and a
// suggestion with an empty performer would be treated as neither — so it must
// not be possible to add a source that forgets it.
func TestEveryRealSuggestionNamesItsPerformer(t *testing.T) {
	g := repo()
	g.Dirty, g.Changed = true, 1
	panes := []Pane{
		{ID: "w1:p1", HasAgent: true, Git: g},
		{ID: "w1:p2", AtShellPrompt: true, Git: repo()},
		{ID: "w1:p3", Servers: []Server{
			{Port: 5173, Proc: "node", URL: "http://h:5173"},
			{Port: 5174, Proc: "node", Loopback: true},
		}},
		{ID: "w1:p4", HasAgent: true, Git: func() Git { c := repo(); c.Operation = "merge"; return c }()},
	}
	seen := 0
	for _, p := range panes {
		for _, s := range For(p) {
			seen++
			if s.Performer != PerformerApp && s.Performer != PerformerAgent {
				t.Errorf("%s: performer = %q, want app or agent", s.Kind, s.Performer)
			}
			if s.Action == "" || s.Label == "" {
				t.Errorf("%s: action/label must never be empty: %+v", s.Kind, s)
			}
		}
	}
	if seen == 0 {
		t.Fatal("no suggestions produced — the fixtures stopped exercising anything")
	}
}

// TestPromptIsSingleLine is a wire-level constraint, not a style preference:
// POST /send pastes the body and delivers Enter as a separate key event, so an
// embedded newline submits half a message on any agent without bracketed paste.
func TestPromptIsSingleLine(t *testing.T) {
	g := repo()
	s := only(t, For(Pane{ID: "w1:p1", HasAgent: true, Git: g}), KindCreatePR)
	if strings.ContainsAny(s.Params["prompt"], "\n\r") {
		t.Errorf("prompt contains a line break, which would submit early:\n%q", s.Params["prompt"])
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
