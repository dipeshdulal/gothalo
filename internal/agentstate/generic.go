package agentstate

import "strings"

// genericParser is the fallback for any agent kind without a dedicated parser. It
// makes no assumptions about the TUI layout: it dumps recent readable text as the
// detail/transcript and always reports Parsed=false, so the app knows to treat
// the result as best-effort. This is what keeps the endpoint "unknown-safe" — a
// brand-new agent kind still returns a renderable card instead of a 500.
//
// It is also the base every kind-specific parser can lean on for its non-blocked
// path (see claudeParser): recent-text extraction is generic; only the blocker
// form and message markers are agent-specific.
type genericParser struct{}

func (genericParser) Kind() string { return "" } // not registered; used as fallback

func (genericParser) Parse(in Input) State {
	lines := readableLines(in.Recent)
	if len(lines) == 0 {
		lines = readableLines(in.Detection)
	}

	st := State{Parsed: false}
	st.Transcript = lastN(lines, 12)
	st.Detail = strings.Join(st.Transcript, "\n")
	switch {
	case len(st.Transcript) > 0:
		st.Headline = truncate(st.Transcript[len(st.Transcript)-1], 120)
	case in.Title != "":
		st.Headline = truncate(in.Title, 120)
	}
	if st.Headline == "" {
		st.Headline = "Agent " + normalizeStatus(in.Status)
	}
	return st
}

// readableLines returns the non-empty, non-decorative lines of a snapshot: it
// drops rules, box art, and the input/footer chrome common to TUI agents so the
// leftover is actual content. Kept deliberately agent-agnostic.
func readableLines(text string) []string {
	var out []string
	for _, l := range splitLines(text) {
		t := strings.TrimSpace(l)
		if t == "" || isRuleLine(l) || isBoxOnly(l) {
			continue
		}
		if isChromeLine(t) {
			continue
		}
		out = append(out, t)
	}
	return out
}

// chromeMarkers are substrings that identify the TUI's own furniture (mode line,
// hints, welcome banner) rather than agent content. Conservative and shared —
// specific parsers add their own markers on top.
var chromeMarkers = []string{
	"mode on (shift+tab",
	"manual mode on",
	"auto mode on",
	"esc to interrupt",
	"? for shortcuts",
	"enter to select",
	"esc to cancel",
	"tab to amend",
	"ctrl+e to explain",
	"tab/arrow keys",
	"↑/↓ to navigate",
	"for getting started",
	"welcome back",
	"/release-notes",
	"claude code v",
}

// isChromeLine reports whether a trimmed line is TUI chrome to hide from the app.
func isChromeLine(t string) bool {
	low := strings.ToLower(t)
	for _, m := range chromeMarkers {
		if strings.Contains(low, m) {
			return true
		}
	}
	// The prompt input line (a bare "❯" or "❯ typed text") is chrome, but a
	// numbered/❯-marked menu option is not — those are handled by the blocker
	// parser, which runs before this on blocked panes.
	if strings.HasPrefix(t, "❯") && !numberedOptionRE.MatchString(t) {
		return true
	}
	return false
}

// lastN returns the last n elements of s (or all of them when fewer).
func lastN(s []string, n int) []string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
