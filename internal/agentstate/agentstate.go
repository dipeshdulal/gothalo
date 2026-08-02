// Package agentstate turns raw `herdr agent read` terminal snapshots into a
// compact, phone-readable JSON state for a single agent pane. It is the parsed
// alternative to the raw PTY stream (WS /attach): instead of a full terminal the
// mobile app gets one struct — what the agent is doing, its last message, and,
// when blocked, the exact question and choices it's waiting on.
//
// The design is agent-kind-agnostic. A per-kind Parser (claude today; codex and
// opencode next) reads the same Input and fills the same State; unknown kinds
// fall back to a generic best-effort text dump (Parsed=false). Adding a new agent
// is one new file that implements Parser and calls Register in its init — the
// endpoint, the JSON contract, and existing parsers stay untouched.
package agentstate

import (
	"regexp"
	"strings"
)

// State is the agent-agnostic contract returned to the app. No field is specific
// to any one agent kind: a parser maps its agent's UI onto these common slots.
type State struct {
	PaneID    string `json:"pane_id"`
	AgentKind string `json:"agent_kind"`
	// AgentStatus is the authoritative status from herdr: idle|working|blocked|done|unknown.
	AgentStatus string `json:"agent_status"`
	// Headline is a one-line summary of what the agent is doing / last did. When
	// blocked it is the question. Always safe to render on its own.
	Headline string `json:"headline"`
	// Detail is a short plain-text body (current activity or last assistant
	// message), already stripped of ANSI and box-drawing, wrapped-safe for a phone.
	Detail string `json:"detail"`
	// Blocked is present only when AgentStatus == "blocked": the prompt and the
	// selectable choices the agent is waiting on (pairs with POST /approve).
	Blocked *Blocked `json:"blocked,omitempty"`
	// Transcript is a few recent plain-text lines, when cheap to include.
	Transcript []string `json:"transcript,omitempty"`
	// Parsed is false when we fell back to a raw recent-text dump because the
	// agent kind has no dedicated parser. The app can still render Detail/Headline.
	Parsed bool `json:"parsed"`
}

// Blocked is the question + choices a blocked agent is waiting on.
type Blocked struct {
	// Question is the prompt line, e.g. "Do you want to proceed?".
	Question string `json:"question"`
	// Options are the selectable choices, in display order. May be empty when the
	// agent is blocked on free-form input rather than a menu.
	Options []Option `json:"options"`
}

// Option is one selectable choice in a blocked prompt.
type Option struct {
	// Index is the number the user would type to pick this option (1-based), or 0
	// when the choice isn't numbered.
	Index int `json:"index"`
	// Label is the choice text, e.g. "Yes, and always allow…".
	Label string `json:"label"`
	// Selected marks the currently-highlighted default (the one POST /approve's
	// Enter keystroke would accept).
	Selected bool `json:"selected"`
}

// Input is the raw material a Parser works from. The endpoint gathers it by
// shelling out to herdr; parsers must not perform I/O.
type Input struct {
	PaneID string
	Kind   string
	// Status is the authoritative agent_status from herdr — parsers trust it and
	// do not re-detect the state, they only extract the presentation for it.
	Status string
	// Title is terminal_title_stripped (the agent's task/headline hint).
	Title string
	// Detection is `herdr agent read --source detection` text: the parsed
	// current-state view (best for the live blocker form and current activity).
	Detection string
	// Recent is `herdr agent read --source recent-unwrapped` text: recent
	// transcript, unwrapped (best for the last assistant message and history).
	Recent string
}

// Parser maps one agent kind's terminal output onto the common State.
//
// Implementations MUST be pure and panic-free and degrade gracefully: return a
// partially-filled State rather than failing. They never set PaneID/AgentKind/
// AgentStatus — Build stamps those from the authoritative Input so a parser can't
// contradict herdr. A parser sets Parsed=true when it recognised the layout.
type Parser interface {
	// Kind is the herdr agent kind this parser handles ("claude", "codex", …).
	Kind() string
	// Parse fills the presentation fields (Headline, Detail, Blocked, Transcript,
	// Parsed) from in. The zero value of the returned State is a valid result.
	Parse(in Input) State
}

// registry maps agent kind -> parser. Populated by each parser's init via
// Register. Guarded only at startup (inits run single-threaded), read-only after.
var registry = map[string]Parser{}

// Register adds a parser to the registry, keyed by p.Kind(). Call it from a
// parser file's init(). A later Register for the same kind wins (last loaded).
func Register(p Parser) { registry[p.Kind()] = p }

// parserFor returns the parser for a kind, or the generic fallback for an
// unregistered/unknown kind.
func parserFor(kind string) Parser {
	if p, ok := registry[strings.ToLower(strings.TrimSpace(kind))]; ok {
		return p
	}
	return genericParser{}
}

// Build produces the State for a pane. It routes to the kind's parser (or the
// generic fallback), then stamps the authoritative identity/status from in so the
// parser can never disagree with herdr about which pane or state this is. Build
// never returns an error — a parser that recognises nothing still yields a valid,
// renderable State (Parsed=false).
func Build(in Input) State {
	st := parserFor(in.Kind).Parse(in)
	st.PaneID = in.PaneID
	st.AgentKind = in.Kind
	st.AgentStatus = normalizeStatus(in.Status)
	if st.AgentStatus != "blocked" {
		st.Blocked = nil // a stray blocked payload can't ride on a non-blocked state
	}
	return st
}

// normalizeStatus clamps herdr's status to the contract's enum, mapping anything
// unexpected (or empty) to "unknown".
func normalizeStatus(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "idle", "working", "blocked", "done":
		return strings.ToLower(strings.TrimSpace(s))
	default:
		return "unknown"
	}
}

// ---- shared text helpers (used by every parser) ----

// ansiRE matches ANSI/CSI escape sequences. `herdr --format text` already strips
// these, but parsers apply it defensively so a stray escape never reaches the app.
var ansiRE = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)

// stripANSI removes escape sequences from a line.
func stripANSI(s string) string { return ansiRE.ReplaceAllString(s, "") }

// ruleRE matches a pure horizontal rule — a run of the box-drawing "─" that
// Claude (and most TUIs) use to fence the prompt box and blocker form.
var ruleRE = regexp.MustCompile(`^[\s─]*─{6,}[\s─]*$`)

// heavyRuleRE matches a long dash run even when a centered title is embedded in
// it (Claude's prompt-box title bar: "──── Some task ────"), so those bars are
// treated as chrome too.
var heavyRuleRE = regexp.MustCompile(`─{20,}`)

// isRuleLine reports whether a line is a horizontal rule (pure or title-bar).
func isRuleLine(s string) bool { return ruleRE.MatchString(s) || heavyRuleRE.MatchString(s) }

// boxOnlyRE matches lines made up solely of box-drawing / block glyphs and space
// (banner art, borders) — noise for a phone card.
var boxOnlyRE = regexp.MustCompile(`^[\s─│╭╮╰╯├┤┬┴┼█▛▜▝▘▀▄▐▌▙▟▖▗✻✳·]*$`)

// isBoxOnly reports whether a line carries no readable text.
func isBoxOnly(s string) bool { return strings.TrimSpace(s) == "" || boxOnlyRE.MatchString(s) }

// numberedOptionRE matches a selectable menu choice: an optional "❯" selection
// caret, a number, a dot, then the label — e.g. "❯ 1. Yes" or "2. No". Shared
// because a numbered choice list is how most agents render a blocked prompt.
var numberedOptionRE = regexp.MustCompile(`^\s*(❯\s*)?(\d+)\.\s+(.*)$`)

// cleanLine strips ANSI and trailing whitespace from a raw terminal line.
func cleanLine(s string) string { return strings.TrimRight(stripANSI(s), " \t") }

// splitLines splits a snapshot into cleaned lines (ANSI/trailing-space removed).
func splitLines(s string) []string {
	raw := strings.Split(s, "\n")
	out := make([]string, len(raw))
	for i, l := range raw {
		out[i] = cleanLine(l)
	}
	return out
}

// firstLine returns the first non-empty line of s (for deriving a headline from a
// multi-line detail), trimmed.
func firstLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(l); t != "" {
			return t
		}
	}
	return ""
}

// truncate caps a one-line string to n runes, appending an ellipsis when cut, so
// a headline stays a single tidy line on a phone.
func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return strings.TrimRight(string(r[:n-1]), " ") + "…"
}
