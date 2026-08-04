package agentstate

import (
	"regexp"
	"strings"
)

// opencodeParser maps opencode's TUI onto the common State.
//
// opencode does not draw closed boxes like Hermes. It marks blocks with a heavy
// left gutter and nothing else:
//
//	┃
//	┃  What should we work on next in gothalo?
//	┃
//	┃  1. Explore the Go bridge
//	┃     Deep-dive into internal/ packages (herdr client, …)
//	┃  2. Work on the Flutter app
//	┃     Build or improve a screen in app/ (…)
//	┃
//	┃  ↑↓ select  enter submit  esc dismiss
//
// Two things follow. The gutter is NOT unique to the blocker — tool output uses
// it too — so the prompt is found by taking the last gutter run that actually
// contains numbered options, not simply the last gutter run. And each option
// spans two lines: a label, then a more-indented description. Only the label
// becomes Option.Label; Option carries no description field and this is not the
// place to invent schema.
//
// Unlike the other kinds, opencode's status comes from its plugin's lifecycle
// hooks rather than screen detection — `herdr agent explain` reports
// `screen_detection_skip_reason: full_lifecycle_hook_authority` and no matched
// rule — so a blocked opencode pane carries no Blocked.Category. That is
// expected rather than a gap: the field is documented as omitted when herdr has
// nothing to say.
type opencodeParser struct{}

func init() { Register(opencodeParser{}) }

func (opencodeParser) Kind() string { return "opencode" }

func (p opencodeParser) Parse(in Input) State {
	st := State{Parsed: true}

	st.Transcript = lastN(opencodeReadable(in.Recent), 12)

	if in.Status == "blocked" {
		if b := parseOpencodeBlocked(in.Detection); b != nil {
			st.Blocked = b
			st.Headline = truncate(b.Question, 120)
			st.Detail = lastOpencodeMessage(in.Detection)
			if st.Detail == "" {
				st.Detail = b.Question
			}
			return st
		}
		// Blocked on something we don't recognise — keep a non-nil Blocked so the
		// app still knows a reply is required.
		st.Blocked = &Blocked{Question: firstLine(lastOpencodeMessage(in.Detection))}
	}

	msg := lastOpencodeMessage(in.Recent)
	if msg == "" {
		msg = lastOpencodeMessage(in.Detection)
	}
	if msg != "" {
		st.Detail = msg
		st.Headline = truncate(firstLine(msg), 120)
		return st
	}

	st.Headline = truncate(in.Title, 120)
	return st
}

// opencodeGutter is the heavy bar opencode fronts a block with.
const opencodeGutter = "┃"

// opencodeFooterRE matches the key-hint footer inside a prompt block.
var opencodeFooterRE = regexp.MustCompile(`(?i)(↑↓|enter submit|esc dismiss|esc cancel)`)

// opencodeMarkerRE matches the glyphs opencode fronts tool/status lines with, so
// they are not mistaken for assistant prose.
var opencodeMarkerRE = regexp.MustCompile(`^\s*[✱→←▣✓✗●○+*]\s`)

// isOpencodeGutter reports whether a line belongs to a gutter block.
func isOpencodeGutter(line string) bool {
	return strings.HasPrefix(strings.TrimSpace(line), opencodeGutter)
}

// stripOpencodeGutter removes the leading gutter, returning the content and
// whether the line had one. Inner indentation is preserved, so the caller can
// still tell an option label from its description.
func stripOpencodeGutter(line string) (string, bool) {
	t := strings.TrimLeft(line, " \t")
	if !strings.HasPrefix(t, opencodeGutter) {
		return "", false
	}
	return strings.TrimRight(strings.TrimPrefix(t, opencodeGutter), " \t"), true
}

// opencodeGutterRuns returns the contiguous runs of gutter lines, each as its
// stripped content lines.
func opencodeGutterRuns(lines []string) [][]string {
	var runs [][]string
	var cur []string
	for _, l := range lines {
		if content, ok := stripOpencodeGutter(l); ok {
			cur = append(cur, content)
			continue
		}
		if cur != nil {
			runs = append(runs, cur)
			cur = nil
		}
	}
	if cur != nil {
		runs = append(runs, cur)
	}
	return runs
}

// parseOpencodeBlocked pulls the question and choices out of the prompt block,
// picking the last gutter run that contains numbered options.
func parseOpencodeBlocked(detection string) *Blocked {
	var prompt []string
	for _, run := range opencodeGutterRuns(splitLines(detection)) {
		for _, l := range run {
			if numberedOptionRE.MatchString(l) {
				prompt = run
				break
			}
		}
	}
	if prompt == nil {
		return nil
	}

	var (
		question string
		options  []Option
		hasFoot  bool
	)
	for _, l := range prompt {
		t := strings.TrimSpace(l)
		if t == "" {
			continue
		}
		if opencodeFooterRE.MatchString(t) {
			hasFoot = true
			continue
		}
		if m := numberedOptionRE.FindStringSubmatch(l); m != nil {
			options = append(options, Option{
				Index:    atoi(m[2]),
				Label:    strings.TrimSpace(m[3]),
				Selected: m[1] != "",
			})
			continue
		}
		// Neither an option nor the footer: the question when it precedes any
		// option, otherwise an option's description line, which is dropped.
		if len(options) == 0 && question == "" {
			question = t
		}
	}
	if question == "" && len(options) == 0 {
		return nil
	}
	// "esc dismiss" is reachable but unnumbered — expose it the way Claude's
	// decline action is, so the app can offer it as a real choice.
	if hasFoot {
		options = append(options, Option{Key: "esc", Label: "Dismiss"})
	}
	return &Blocked{Question: question, Options: options}
}

// lastOpencodeMessage returns the last run of assistant prose: the plain,
// non-gutter, non-marker lines opencode prints between blocks.
func lastOpencodeMessage(text string) string {
	var block, last []string
	flush := func() {
		if len(block) > 0 {
			last = block
			block = nil
		}
	}
	for _, l := range splitLines(text) {
		t := strings.TrimSpace(l)
		if t == "" || isOpencodeGutter(l) || opencodeMarkerRE.MatchString(l) || isChromeLine(t) {
			flush()
			continue
		}
		block = append(block, t)
	}
	flush()
	return strings.TrimSpace(strings.Join(last, "\n"))
}

// opencodeReadable flattens a snapshot into plain conversational lines for the
// Transcript field: gutter content and prose kept, chrome and key hints dropped.
func opencodeReadable(text string) []string {
	var out []string
	for _, l := range splitLines(text) {
		if content, ok := stripOpencodeGutter(l); ok {
			t := strings.TrimSpace(content)
			if t == "" || opencodeFooterRE.MatchString(t) {
				continue
			}
			out = append(out, t)
			continue
		}
		t := strings.TrimSpace(l)
		if t == "" || isChromeLine(t) {
			continue
		}
		out = append(out, t)
	}
	return out
}
