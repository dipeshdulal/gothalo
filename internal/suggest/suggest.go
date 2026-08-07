// Package suggest turns "what is actually going on in this pane" into a short,
// ordered list of one-tap actions, for GET /suggestions.
//
// This is the one mechanism for "what can I do with this pane". Dev-server
// discovery (internal/ports) started as a second, parallel answer to the same
// question and is now folded in as one more source: the port scan is still that
// package's job, but its result arrives here as [Pane.Servers] and comes out as
// chips in the same row, ranked against the git-shaped ones. GET /ports remains
// as the raw host-wide feed behind it — see docs/CONTRACT-suggestions.md.
//
// The bar every source has to clear: a suggestion that appears is a suggestion
// you can tap. The signals are whatever is cheap to know about a pane — what
// Herdr says holds its foreground (`pane.process_info`), whether an agent lives
// there, a handful of stat() calls on its working directory, and the listeners
// already attributed to it.
//
// Everything here is a pure function of an already-collected [Pane]. The Herdr
// round-trips, the port scan and the caching all live in the server package, so
// a source is a twenty-line function with no I/O beyond the filesystem — which
// is what makes adding the next one cheap and testable.
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
	// ActionOpenURL hands params["url"] to the system browser.
	ActionOpenURL = "open_url"
	// ActionShowNote shows params["note"] and nothing else. It exists for the
	// one state that is worth reporting but cannot be acted on remotely — a dev
	// server bound to loopback — where the note names the fix. Without it that
	// server would either be hidden (and the user left wondering why there is no
	// preview chip) or shown as a chip that does nothing when tapped.
	ActionShowNote = "show_note"
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
	// KindDevServerLocal is a server that is up but bound to loopback, so
	// nothing on the tailnet can reach it. Its own kind rather than a flag on
	// KindDevServer: the two render differently and do different things on tap,
	// and a client should not have to infer that from an absent url.
	KindDevServerLocal = "dev_server_local"
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

// Ranks, in one block on purpose. Now that dev servers and the git-shaped
// suggestions share a row, "which of these matters more" is a single argument
// rather than one per feature, and it is only reviewable if the numbers sit
// next to each other.
//
// The order reads: something is stuck and needs a person; something is serving
// that you probably came here to look at; something changed that you probably
// came here to read; something is up but unreachable, which is worth knowing
// but not urgent; and finally an empty pane you could put an agent in.
//
// Gaps of five leave room to slot a source in without renumbering.
const (
	RankGitConflict    = 30
	RankDevServer      = 25
	RankGitDirty       = 20
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
	if !p.HasAgent || p.Cwd == "" {
		return nil
	}
	op, ok := inProgress(p.Cwd)
	if !ok {
		return nil
	}
	return []Suggestion{{
		Kind:   KindGitConflict,
		Label:  "Resolve",
		Detail: op + " in progress",
		Action: ActionOpenDiff,
		Rank:   RankGitConflict,
	}}
}

// gitDirty offers the diff screen when the agent's tree has pending changes —
// "what has it actually done", which is the question you open the app to ask.
//
// Suppressed while a merge/rebase is in progress: that tree is dirty too, and
// two chips onto the same screen is exactly the noise this feature is supposed
// not to make.
func gitDirty(p Pane) []Suggestion {
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
	return []Suggestion{{
		Kind:   KindGitDirty,
		Label:  "Review changes",
		Detail: plural(n, "file") + " changed",
		Action: ActionOpenDiff,
		Rank:   RankGitDirty,
	}}
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
	if p.HasAgent || !p.AtShellPrompt || p.Cwd == "" {
		return nil
	}
	name, ok := repoName(p.Cwd)
	if !ok {
		return nil
	}
	return []Suggestion{{
		Kind:   KindShellIdle,
		Label:  "Start an agent",
		Detail: "idle shell in " + name,
		Action: ActionStartAgent,
		Rank:   RankShellIdle,
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
