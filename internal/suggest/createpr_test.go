package suggest

import (
	"strings"
	"testing"
)

// TestCreatePROffersAnEditablePrompt is the shape that makes this feature what
// it is: the bridge does not open the pull request, it hands the agent the
// words and lets a person edit them first.
func TestCreatePROffersAnEditablePrompt(t *testing.T) {
	s := only(t, For(Pane{ID: "w1:p1", HasAgent: true, Git: repo()}), KindCreatePR)

	if s.Performer != PerformerAgent {
		t.Errorf("performer = %q — a PR is opened by the agent, not by the app", s.Performer)
	}
	if s.Action != ActionPromptAgent {
		t.Errorf("action = %q, want %q", s.Action, ActionPromptAgent)
	}
	prompt := s.Params["prompt"]
	if prompt == "" {
		t.Fatal("no prompt — the whole payload of an agent-performed action")
	}
	// The branch, remote and base are named rather than left to the agent: the
	// bridge knows them, and an agent that guesses pushes to the wrong place.
	for _, want := range []string{"feat/thing", "git push -u origin feat/thing", "against main", "gh pr create"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt is missing %q:\n%s", want, prompt)
		}
	}
	// Staying put matters: a phone user cannot recover from an agent that
	// decided to rebase or force-push on its way to opening a PR.
	if !strings.Contains(prompt, "do not switch, rebase or force-push") {
		t.Errorf("prompt does not tell the agent to stay on the branch:\n%s", prompt)
	}
	if s.Detail != "feat/thing → main · 1 commit ahead" {
		t.Errorf("detail = %q, want a summary of what the PR would contain", s.Detail)
	}
}

// The gate, condition by condition. Each of these is a state where offering a
// pull request would produce an agent turn that cannot succeed.
func TestCreatePRGate(t *testing.T) {
	cases := []struct {
		name string
		mut  func(*Pane)
	}{
		{"no agent to ask", func(p *Pane) { p.HasAgent = false }},
		{"not a repository", func(p *Pane) { p.Git = Git{} }},
		{"detached HEAD", func(p *Pane) { p.Git.Branch = "" }},
		{"no remote to push to", func(p *Pane) { p.Git.Remote = "" }},
		{"already on the default branch", func(p *Pane) { p.Git.Branch = "main" }},
		{"nothing ahead and nothing uncommitted", func(p *Pane) { p.Git.Ahead = 0 }},
		{"mid-rebase", func(p *Pane) { p.Git.Operation = "rebase" }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := Pane{ID: "w1:p1", HasAgent: true, Git: repo()}
			c.mut(&p)
			for _, s := range For(p) {
				if s.Kind == KindCreatePR {
					t.Fatalf("offered a PR anyway: %+v", s)
				}
			}
		})
	}
}

// Uncommitted work with no commits yet is still a pull request worth offering —
// committing it is step one of what the agent is asked to do, and the prompt
// says so.
func TestCreatePRAcceptsUncommittedWorkAlone(t *testing.T) {
	g := repo()
	g.Ahead, g.Dirty, g.Changed = 0, true, 4

	got := For(Pane{ID: "w1:p1", HasAgent: true, Git: g})
	var pr *Suggestion
	for i := range got {
		if got[i].Kind == KindCreatePR {
			pr = &got[i]
		}
	}
	if pr == nil {
		t.Fatalf("suggestions = %v, want a create_pr for an uncommitted branch", kinds(got))
	}
	if !strings.Contains(pr.Params["prompt"], "Conventional Commits") {
		t.Errorf("a dirty tree's prompt must ask for the commit first:\n%s", pr.Params["prompt"])
	}
	if !strings.Contains(pr.Detail, "uncommitted changes") {
		t.Errorf("detail = %q, want the uncommitted work named", pr.Detail)
	}
}

// A clean tree does NOT get told to commit anything — the prompt is composed
// from the situation, not from a template with a constant preamble.
func TestCreatePRSkipsTheCommitStepWhenClean(t *testing.T) {
	s := only(t, For(Pane{ID: "w1:p1", HasAgent: true, Git: repo()}), KindCreatePR)
	if strings.Contains(s.Params["prompt"], "Conventional Commits") {
		t.Errorf("a clean tree was told to commit:\n%s", s.Params["prompt"])
	}
}

// An unresolvable default branch is not disqualifying: `gh pr create` resolves
// the repo's own default, which is a better answer than a guess. The base is
// simply left out of the prompt.
func TestCreatePRWithoutAKnownDefaultBranch(t *testing.T) {
	g := repo()
	g.DefaultBranch = ""

	s := only(t, For(Pane{ID: "w1:p1", HasAgent: true, Git: g}), KindCreatePR)
	if strings.Contains(s.Params["prompt"], "against ") {
		t.Errorf("named a base it could not resolve:\n%s", s.Params["prompt"])
	}
	if !strings.Contains(s.Params["prompt"], "gh pr create") {
		t.Errorf("dropped the PR step along with the base:\n%s", s.Params["prompt"])
	}
}

// A never-pushed branch says so in the detail line, because "not pushed yet" is
// the part a person double-checks before sending.
func TestCreatePRFlagsAnUnpushedBranch(t *testing.T) {
	g := repo()
	g.Upstream = ""
	s := only(t, For(Pane{ID: "w1:p1", HasAgent: true, Git: g}), KindCreatePR)
	if !strings.Contains(s.Detail, "not pushed yet") {
		t.Errorf("detail = %q, want the unpushed state named", s.Detail)
	}
}

// TestReviewChangesOutranksCreatePR: when the agent has just finished, both
// fire, and reading the diff before opening the PR is the order a person wants.
func TestReviewChangesOutranksCreatePR(t *testing.T) {
	g := repo()
	g.Dirty, g.Changed = true, 6

	got := For(Pane{ID: "w1:p1", HasAgent: true, Git: g})
	if len(got) != 2 {
		t.Fatalf("suggestions = %v, want the diff and the PR", kinds(got))
	}
	if got[0].Kind != KindGitDirty || got[1].Kind != KindCreatePR {
		t.Errorf("order = %v, want review-changes first", kinds(got))
	}
}
