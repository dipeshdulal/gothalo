// Package suggest turns "what is actually going on in this pane" into a short,
// ordered list of one-tap actions, for GET /suggestions.
//
// The generalisation of internal/ports: that package answers one question (is a
// dev server up in this pane, and can the phone reach it) from one signal. This
// one keeps the same bar — a suggestion that appears is a suggestion you can
// tap — and widens the signals to whatever is cheap to read about a pane: what
// Herdr says holds the pane's foreground (`pane.process_info`), whether an agent
// lives there, and a handful of stat() calls on the pane's working directory.
//
// Everything here is a pure function of an already-collected [Pane]. The Herdr
// round-trips and the caching live in the server package, so a source is a
// twenty-line function with no I/O beyond the filesystem — which is what makes
// adding the next one cheap and testable.
package suggest

import (
	"sort"
	"strconv"
)

// Action is what the app DOES on tap. Deliberately a small closed vocabulary
// rather than free-form: the app switches on it, so every value has to have a
// screen behind it. A client that meets an action it does not know drops the
// suggestion — which is what lets a newer bridge ship a new one without
// breaking an older app.
const (
	// ActionOpenDiff pushes the pane's Changes screen (GET /diff).
	ActionOpenDiff = "open_diff"
	// ActionStartAgent opens the start-an-agent sheet targeting this pane.
	ActionStartAgent = "start_agent"
)

// Kind is WHY a suggestion was offered — the source that produced it. Separate
// from Action because several kinds legitimately land on the same screen (a
// conflict and a dirty tree both open the diff), and collapsing them would lose
// the only part the user reads.
const (
	KindGitConflict = "git_conflict"
	KindGitDirty    = "git_dirty"
	KindShellIdle   = "shell_idle"
)

// Suggestion is one offered action.
type Suggestion struct {
	Kind string `json:"kind"`
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

// Pane is everything the sources are allowed to look at: the observations the
// server has already paid for. Collecting it is the caller's job (one
// `pane.process_info` and one `agent.get`), so the sources stay pure.
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
}

// source examines a pane and returns the suggestion it wants to offer, if any.
type source func(Pane) *Suggestion

// sources is the registry, in no particular order — ordering is by Rank, so a
// source decides its own weight rather than inheriting one from this list.
var sources = []source{
	gitConflict,
	gitDirty,
	shellIdle,
}

// For returns the suggestions for a pane, best first and capped at [Max].
//
// Never errors and never returns nil: "nothing to suggest" is the steady state
// for most panes most of the time, and a convenience surface that can fail is a
// convenience surface with an error state to render.
func For(p Pane) []Suggestion {
	out := make([]Suggestion, 0, len(sources))
	for _, src := range sources {
		if s := src(p); s != nil {
			if s.Params == nil {
				s.Params = map[string]string{}
			}
			s.Params["pane"] = p.ID
			out = append(out, *s)
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
func gitConflict(p Pane) *Suggestion {
	if !p.HasAgent || p.Cwd == "" {
		return nil
	}
	op, ok := inProgress(p.Cwd)
	if !ok {
		return nil
	}
	return &Suggestion{
		Kind:   KindGitConflict,
		Label:  "Resolve",
		Detail: op + " in progress",
		Action: ActionOpenDiff,
		Rank:   30,
	}
}

// gitDirty offers the diff screen when the agent's tree has pending changes —
// "what has it actually done", which is the question you open the app to ask.
//
// Suppressed while a merge/rebase is in progress: that tree is dirty too, and
// two chips onto the same screen is exactly the noise this feature is supposed
// not to make.
func gitDirty(p Pane) *Suggestion {
	if !p.HasAgent || p.Cwd == "" {
		return nil
	}
	if _, mid := inProgress(p.Cwd); mid {
		return nil
	}
	n, ok := dirtyCount(p.Cwd)
	if !ok || n == 0 {
		return nil
	}
	return &Suggestion{
		Kind:   KindGitDirty,
		Label:  "Review changes",
		Detail: plural(n, "file") + " changed",
		Action: ActionOpenDiff,
		Rank:   20,
	}
}

// shellIdle offers to start an agent in a pane that is sitting at a prompt
// inside a git work tree.
//
// The work-tree test is what keeps this from firing on every idle shell on the
// host. A pane parked in ~ or in a log directory is not somewhere you want an
// agent; a pane parked in a worktree is a pane someone opened to do work in and
// then walked away from, which is precisely the thing worth one tap from a
// phone.
func shellIdle(p Pane) *Suggestion {
	if p.HasAgent || !p.AtShellPrompt || p.Cwd == "" {
		return nil
	}
	name, ok := repoName(p.Cwd)
	if !ok {
		return nil
	}
	return &Suggestion{
		Kind:   KindShellIdle,
		Label:  "Start an agent",
		Detail: "idle shell in " + name,
		Action: ActionStartAgent,
		Rank:   10,
	}
}

// plural renders a count with its noun, for a detail line that reads like a
// sentence instead of a debug print.
func plural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return strconv.Itoa(n) + " " + noun + "s"
}
