// Package suggest turns "what is actually going on in this pane" into a short,
// ordered list of one-tap actions, for GET /suggestions.
//
// This is the one mechanism for "what can I do with this pane". Three features
// arrived at it separately and are now sources inside it rather than parallel
// answers to the same question:
//
//   - dev-server discovery (internal/ports) → [Pane.Servers]
//   - the pane's git situation (internal/gitdiff) → [Pane.Git]
//   - what holds the pane's foreground (herdr's pane.process_info)
//
// Each of those packages still owns its own reading. What this package owns is
// the judgement: which observations are worth a chip, what the chip says, and
// how they rank against each other. GET /ports and GET /diff remain as the raw
// feeds behind them — see docs/CONTRACT-suggestions.md.
//
// The bar every source has to clear: a suggestion that appears is a suggestion
// you can tap.
//
// Everything here is a pure function of an already-collected [Pane], with no
// I/O and no dependency beyond the standard library. The round-trips, the
// shell-outs and the caching all live in the server package, so a source is a
// fifteen-line function — which is what makes adding the next one cheap and
// testable.
package suggest

import (
	"sort"
	"strconv"
	"strings"
)

// Performer says WHO carries the action out, and it is the one distinction in
// this payload that is not cosmetic.
//
// Most suggestions are things the app does: open a screen, open a URL. But the
// most valuable thing you can do to a pane from a phone is often something only
// the *agent* can do — it holds the shell, the credentials and the context. So
// the mechanism carries both, and says which is which, rather than pretending a
// prompt is a navigation.
//
// The difference is not an implementation detail the app can infer from the
// action name. A PerformerAgent suggestion needs a running agent, needs its text
// shown and editable before anything is sent, and lands in the transcript where
// it can be watched and interrupted. A client that treated one as the other
// would fire an irreversible outward-facing action off a single tap.
const (
	// PerformerApp — the app performs the action itself. Params describe it.
	PerformerApp = "app"
	// PerformerAgent — the app asks the agent in the pane to do it, by sending
	// params["prompt"]. The prompt MUST be shown and editable first.
	PerformerAgent = "agent"
)

// Action is what happens on tap. Deliberately a small closed vocabulary rather
// than free-form: the app switches on it, so every value has to have something
// behind it. A client that meets an action it does not know drops the
// suggestion — which is what lets a newer bridge ship a new one without
// breaking an older app.
const (
	// ActionOpenDiff pushes the pane's Changes screen (GET /diff).
	ActionOpenDiff = "open_diff"
	// ActionStartAgent opens the start-an-agent sheet targeting this pane.
	ActionStartAgent = "start_agent"
	// ActionOpenURL hands params["url"] to the system browser.
	ActionOpenURL = "open_url"
	// ActionShowNote shows params["note"] and nothing else. It exists for the
	// one state that is worth reporting but cannot be acted on remotely — a dev
	// server bound to loopback — where the note names the fix. Without it that
	// server would either be hidden (and the user left wondering why there is no
	// preview chip) or shown as a chip that does nothing when tapped.
	ActionShowNote = "show_note"
	// ActionPromptAgent puts params["prompt"] in front of the user to edit and,
	// on their confirmation, sends it to the agent in the pane. The only action
	// with PerformerAgent, and the only one whose text is a suggestion in the
	// ordinary English sense: the agent may do it differently, or refuse.
	ActionPromptAgent = "prompt_agent"
)

// Kind is WHY a suggestion was offered — the source that produced it. Separate
// from Action because several kinds legitimately land on the same screen (a
// conflict and a dirty tree both open the diff), and collapsing them would lose
// the only part the user reads.
const (
	KindGitConflict = "git_conflict"
	KindGitDirty    = "git_dirty"
	KindShellIdle   = "shell_idle"
	KindDevServer   = "dev_server"
	// KindCreatePR is "this branch has work on it that is not on the default
	// branch yet". The only agent-performed kind today.
	KindCreatePR = "create_pr"
	// KindDevServerLocal is a server that is up but bound to loopback, so
	// nothing on the tailnet can reach it. Its own kind rather than a flag on
	// KindDevServer: the two render differently and do different things on tap,
	// and a client should not have to infer that from an absent url.
	KindDevServerLocal = "dev_server_local"
)

// Suggestion is one offered action.
type Suggestion struct {
	Kind string `json:"kind"`
	// Performer is PerformerApp or PerformerAgent — see [PerformerApp].
	Performer string `json:"performer"`
	// Label is the chip text. Short enough for a phone chip — two words where
	// possible, never a sentence.
	Label string `json:"label"`
	// Detail is the one-line justification ("3 files changed"), shown under the
	// label. It is what stops a chip being a mystery button; empty is allowed
	// but discouraged.
	Detail string `json:"detail,omitempty"`
	Action string `json:"action"`
	// Params is the action's argument, always including the pane. A map rather
	// than typed fields so a new action does not change the envelope.
	Params map[string]string `json:"params,omitempty"`
	// Rank orders the list, highest first. It is a usefulness score, not a
	// priority queue: two suggestions with the same rank are equally worth
	// showing and their relative order is not meaningful.
	Rank int `json:"rank"`
}

// Max is how many suggestions a pane may offer. Three is the point where a row
// of chips stops reading as "here is the obvious next thing" and starts reading
// as a toolbar — and a toolbar is the failure mode this feature exists to
// avoid. Sources are written so a pane rarely produces more than two anyway;
// the cap is the backstop, not the design.
const Max = 3

// Ranks, in one block on purpose. Now that dev servers and the git-shaped
// suggestions share a row, "which of these matters more" is a single argument
// rather than one per feature, and it is only reviewable if the numbers sit
// next to each other.
//
// The order reads: something is stuck and needs a person; something is serving
// that you probably came here to look at; something changed that you probably
// came here to read; something is finished enough to ship; something is up but
// unreachable, which is worth knowing but not urgent; and finally an empty pane
// you could put an agent in.
//
// Create-PR sits just under review-changes on purpose. When both fire they are
// the two halves of one moment — the agent has finished and you are deciding
// what to do about it — and reading the diff before opening the PR is the order
// a person actually wants, not the reverse.
//
// Gaps leave room to slot a source in without renumbering.
const (
	RankGitConflict    = 30
	RankDevServer      = 25
	RankGitDirty       = 20
	RankCreatePR       = 18
	RankDevServerLocal = 15
	RankShellIdle      = 10
)

// Server is one HTTP listener already attributed to this pane by the port scan
// — the shape internal/ports produces, narrowed to what a chip needs.
//
// Declared here rather than imported from internal/ports so this package keeps
// no dependency beyond the standard library: the sources stay pure functions
// over plain data, and the one place that knows about `lsof` stays the one
// place that knows about it. The server package does the mapping.
type Server struct {
	Port int
	// Proc is the executable name ("node", "python3") — the chip's detail line.
	Proc string
	// URL is where the phone should point. Empty for a loopback bind, which is
	// the whole client-side decision: either a working URL or none, never one
	// that cannot connect.
	URL string
	// Loopback reports a bind only the host itself can reach.
	Loopback bool
}

// Pane is everything the sources are allowed to look at: the observations the
// server has already paid for. Collecting it is the caller's job (one
// `pane.process_info`, one `agent.get`, and a read of the cached port scan), so
// the sources stay pure.
type Pane struct {
	// ID is the session-qualified pane id, echoed into every action's params.
	ID string
	// HasAgent is whether a coding agent lives in this pane. It is the single
	// biggest fork in the file: an agent pane is somewhere work is happening,
	// a plain pane is somewhere work could be started.
	HasAgent  bool
	AgentKind string
	// Cwd is the pane's working directory — the agent's cwd for an agent pane,
	// the foreground process's for a plain one. Empty when neither could be
	// resolved, which disables every filesystem-backed source.
	Cwd string
	// AtShellPrompt is Herdr's own "this pane is free" test (shell_pid ==
	// foreground_process_group_id). False while anything at all is running.
	AtShellPrompt bool
	// Foreground is the command line holding the pane, empty at a prompt. Not
	// read by any source yet; it is the hook a "rerun the test runner" source
	// would hang off, and it is collected because process_info already carries
	// it.
	Foreground string
	// Servers are the HTTP listeners the port scan attributed to this pane,
	// sorted by port. Empty when nothing is serving here, when the scan failed,
	// or when the listener's parent chain never crossed this pane's shell.
	Servers []Server
	// Git is the pane's git situation, read once by internal/gitdiff. Zero (with
	// Repo false) for a pane that is not in a repository, which disables every
	// git-shaped source.
	Git Git
}

// Git mirrors gitdiff.Context, narrowed to what the sources read.
//
// Declared here rather than imported for the same reason [Server] is: this
// package stays a pure function over plain data with no dependency beyond the
// standard library, and the one place that knows how to run git stays the one
// place that knows how to run git. The server package does the mapping.
type Git struct {
	// Repo gates every field below it.
	Repo bool
	// Root is the work tree's top level — for a `git worktree`, the worktree
	// itself. Its base name is what identifies a checkout to a person.
	Root string
	// Branch is "" on a detached HEAD.
	Branch        string
	DefaultBranch string
	// Remote is "" when there is nowhere to push, which is disqualifying for a
	// pull request and for nothing else.
	Remote string
	// Upstream is "" when the branch has never been pushed. NOT disqualifying:
	// `git push -u` is step two of what the agent is asked to do.
	Upstream string
	// Ahead counts commits HEAD has that the default ref does not.
	Ahead int
	// Changed is how many files are uncommitted; Dirty is Changed > 0.
	Changed int
	Dirty   bool
	// Operation names an unfinished merge/rebase/cherry-pick/revert, "" the rest
	// of the time. The only field that means a person is needed.
	Operation string
}

// OnDefaultBranch reports a pane sitting on the trunk — where a pull request is
// not a meaningful thing to offer. Unknown default branch reads as false: an
// unresolvable trunk is a repo whose conventions we cannot see, and refusing to
// offer anything there would be a worse guess than offering.
func (g Git) OnDefaultBranch() bool {
	return g.DefaultBranch != "" && g.Branch == g.DefaultBranch
}

// RepoName is the checkout's directory name — "feat-one-tap-pr" for a worktree,
// "gothalo" for a plain clone.
//
// The directory, not the remote: with several worktrees of one project checked
// out at once the remote is the same for all of them and tells you nothing,
// while the directory is what the person named the branch after.
func (g Git) RepoName() string {
	if !g.Repo || g.Root == "" {
		return ""
	}
	i := strings.LastIndex(g.Root, "/")
	if i < 0 {
		return g.Root
	}
	return g.Root[i+1:]
}

// source examines a pane and returns the suggestions it wants to offer.
//
// A slice rather than a single value because one source can legitimately have
// several things to say: a pane running a dev server and an API on two ports is
// two chips, not one chip that hides the other.
type source func(Pane) []Suggestion

// sources is the registry, in no particular order — ordering is by Rank, so a
// source decides its own weight rather than inheriting one from this list.
var sources = []source{
	gitConflict,
	gitDirty,
	createPR,
	shellIdle,
	devServers,
}

// For returns the suggestions for a pane, best first and capped at [Max].
//
// Never errors and never returns nil: "nothing to suggest" is the steady state
// for most panes most of the time, and a convenience surface that can fail is a
// convenience surface with an error state to render.
func For(p Pane) []Suggestion {
	out := make([]Suggestion, 0, len(sources))
	for _, src := range sources {
		for _, s := range src(p) {
			if s.Params == nil {
				s.Params = map[string]string{}
			}
			s.Params["pane"] = p.ID
			out = append(out, s)
		}
	}
	// Stable so two sources at the same rank keep registry order rather than
	// shuffling between two polls seconds apart — a chip row that reorders under
	// the thumb is worse than one in an arguable order.
	sort.SliceStable(out, func(i, j int) bool { return out[i].Rank > out[j].Rank })
	if len(out) > Max {
		out = out[:Max]
	}
	return out
}

// ---- sources ----

// gitConflict offers the diff screen when the pane's tree is mid-merge,
// mid-rebase or mid-cherry-pick. Ranked above everything else because it is the
// one state where the agent is *stuck on something only a person resolves*, and
// the phone is where you find out about it.
//
// Agent panes only, and that is a real limitation rather than a judgement: GET
// /diff resolves its tree through the pane's agent, so a plain pane taps through
// to a 404. See CONTRACT-suggestions.md.
func gitConflict(p Pane) []Suggestion {
	if !p.HasAgent || !p.Git.Repo || p.Git.Operation == "" {
		return nil
	}
	return []Suggestion{{
		Kind:      KindGitConflict,
		Performer: PerformerApp,
		Label:     "Resolve",
		Detail:    p.Git.Operation + " in progress",
		Action:    ActionOpenDiff,
		Rank:      RankGitConflict,
	}}
}

// gitDirty offers the diff screen when the agent's tree has pending changes —
// "what has it actually done", which is the question you open the app to ask.
//
// Suppressed while a merge/rebase is in progress: that tree is dirty too, and
// two chips onto the same screen is exactly the noise this feature is supposed
// not to make.
func gitDirty(p Pane) []Suggestion {
	if !p.HasAgent || !p.Git.Repo || p.Git.Operation != "" || !p.Git.Dirty {
		return nil
	}
	return []Suggestion{{
		Kind:      KindGitDirty,
		Performer: PerformerApp,
		Label:     "Review changes",
		Detail:    plural(p.Git.Changed, "file") + " changed",
		Action:    ActionOpenDiff,
		Rank:      RankGitDirty,
	}}
}

// createPR offers to open a pull request for the work on this branch — by
// asking the agent to do it, not by doing it.
//
// **The bridge runs no git for this.** The agent holds the `gh` auth, the
// repo's commit conventions and enough of the work to write a body worth
// reading; it works identically for every agent Herdr can host; and every step
// lands in the transcript where it can be watched and interrupted. All this
// source contributes is the gate and the words. See D29.
//
// The gate, in the order the conditions actually disqualify:
//
//   - an agent in the pane, because there is nobody to ask otherwise;
//   - a git repository, read from the host and never inferred from the cwd path
//     (a directory called `feat/x` is not evidence of a branch);
//   - a branch, not a detached HEAD;
//   - a remote, since there is otherwise nowhere to push;
//   - not the default branch, where a PR means nothing;
//   - and actual work — commits ahead of the trunk, or uncommitted changes to
//     make into one.
//
// A mid-operation tree is excluded too. "Open a PR" during a stopped rebase is
// the wrong next step by a wide margin, and gitConflict is already saying the
// right one.
func createPR(p Pane) []Suggestion {
	g := p.Git
	switch {
	case !p.HasAgent, !g.Repo, g.Operation != "":
		return nil
	case g.Branch == "", g.Remote == "", g.OnDefaultBranch():
		return nil
	case g.Ahead == 0 && !g.Dirty:
		return nil
	}
	return []Suggestion{{
		Kind:      KindCreatePR,
		Performer: PerformerAgent,
		Label:     "Create PR",
		Detail:    prSummary(g),
		Action:    ActionPromptAgent,
		Params:    map[string]string{"prompt": prPrompt(g)},
		Rank:      RankCreatePR,
	}}
}

// prSummary is the chip's detail line: what the PR would be made of, so the tap
// is never blind even before the sheet opens.
func prSummary(g Git) string {
	base := g.DefaultBranch
	if base == "" {
		base = "default"
	}
	parts := []string{g.Branch + " → " + base}
	if g.Ahead > 0 {
		parts = append(parts, plural(g.Ahead, "commit")+" ahead")
	}
	if g.Dirty {
		parts = append(parts, "uncommitted changes")
	}
	if g.Upstream == "" {
		parts = append(parts, "not pushed yet")
	}
	return strings.Join(parts, " · ")
}

// prPrompt is the instruction the agent receives — the payload of the only
// agent-performed action here, and the reason params carries free text at all.
//
// **One line, deliberately.** POST /send pastes the body and then presses Enter
// as a separate key event, which is what makes an embedded newline
// agent-dependent: Claude Code turns on bracketed paste and reads it as a
// newline, but an agent that does not would read it as a submit and fire the
// prompt off half-written. A single flowing line is understood identically by
// every agent, and numbered clauses keep the steps distinguishable without
// needing line breaks.
//
// It names the branch, the remote and the base explicitly rather than leaving
// the agent to work them out: the bridge already knows them, and an agent that
// guesses wrong pushes to the wrong place. When git could not name a default
// branch the base is left out entirely — `gh pr create` resolves the repo's own
// default, which beats a guess.
//
// Composed here rather than in the app so there is one wording, reviewable in
// one place, identical on every client. It is still shown and editable before
// anything is sent; this is the starting text, not the final one.
func prPrompt(g Git) string {
	branch := g.Branch
	if branch == "" {
		branch = "the current branch"
	}
	remote := g.Remote
	if remote == "" {
		remote = "origin"
	}
	against := ""
	if g.DefaultBranch != "" {
		against = " against " + g.DefaultBranch
	}
	commit := ""
	if g.Dirty {
		commit = "commit everything outstanding with a Conventional Commits message " +
			"(feat:/fix:/docs:/refactor:/test:), "
	}
	return "Open a pull request for the work on " + branch + ": " + commit +
		"push the branch with `git push -u " + remote + " " + branch + "`, then open the PR" +
		against + " with `gh pr create`, writing a title and body that say what " +
		"changed and why. Stay on this branch — do not switch, rebase or " +
		"force-push — and reply with the PR URL when it is open."
}

// shellIdle offers to start an agent in a pane that is sitting at a prompt
// inside a git work tree.
//
// The work-tree test is what keeps this from firing on every idle shell on the
// host. A pane parked in ~ or in a log directory is not somewhere you want an
// agent; a pane parked in a worktree is a pane someone opened to do work in and
// then walked away from, which is precisely the thing worth one tap from a
// phone.
func shellIdle(p Pane) []Suggestion {
	if p.HasAgent || !p.AtShellPrompt || !p.Git.Repo {
		return nil
	}
	name := p.Git.RepoName()
	if name == "" {
		return nil
	}
	return []Suggestion{{
		Kind:      KindShellIdle,
		Performer: PerformerApp,
		Label:     "Start an agent",
		Detail:    "idle shell in " + name,
		Action:    ActionStartAgent,
		Rank:      RankShellIdle,
	}}
}

// plural renders a count with its noun, for a detail line that reads like a
// sentence instead of a debug print.
func plural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return strconv.Itoa(n) + " " + noun + "s"
}
