package agentstate

import (
	"strings"
)

// hermesParser maps Hermes's TUI onto the common State.
//
// Hermes draws everything in rounded/square box panels, which is the one thing a
// parser has to cope with: the useful text is *inside* borders, so every shared
// helper (numberedOptionRE and friends) only matches after the border columns are
// stripped. The panels seen live:
//
//	╭─ ⚕ Hermes ──────────╮   assistant prose
//	┌─ Reasoning ─────────┐   its thinking; not conversation, dropped
//	╭─ Hermes needs your input ─╮   the blocker: question + numbered choices
//	● some text               a user turn, under a ──── rule
//
// Herdr classifies the block for us (`clarification_prompt` etc., surfaced as
// Blocked.Category by the endpoint via agent.explain) but exposes no structured
// question or options — its rule evidence is a truncated raw-text preview. So the
// question and choices are extracted here, from the panel.
type hermesParser struct{}

func init() { Register(hermesParser{}) }

func (hermesParser) Kind() string { return "hermes" }

func (p hermesParser) Parse(in Input) State {
	st := State{Parsed: true}

	st.Transcript = lastN(hermesReadable(in.Recent), 12)

	if in.Status == "blocked" {
		if b := parseHermesBlocked(in.Detection); b != nil {
			st.Blocked = b
			st.Headline = truncate(b.Question, 120)
			// The prose above the panel is what the question is about — Hermes
			// usually sets it up there ("Quick one right now — what do you wanna
			// do?"), so it makes a better card body than repeating the question.
			st.Detail = lastHermesMessage(in.Detection)
			if st.Detail == "" {
				st.Detail = b.Question
			}
			return st
		}
		// Blocked on something we don't recognise (free-form input). Keep an empty
		// Blocked so the app still knows a response is required.
		st.Blocked = &Blocked{Question: firstLine(lastHermesMessage(in.Detection))}
	}

	msg := lastHermesMessage(in.Recent)
	if msg == "" {
		msg = lastHermesMessage(in.Detection)
	}
	if msg != "" {
		st.Detail = msg
		st.Headline = truncate(firstLine(msg), 120)
		return st
	}

	// Nothing readable on screen — fall back to the pane title rather than an
	// empty card.
	st.Headline = truncate(in.Title, 120)
	return st
}

// hermesBoxRunes are the border characters Hermes draws panels with. They are
// stripped from both ends of a line so the shared matchers see plain text.
const hermesBoxRunes = "│┃┊╎┆┇┋║"

// stripHermesBorders removes a line's panel borders and surrounding space,
// leaving the content. A line that is only border/rule characters becomes "".
func stripHermesBorders(line string) string {
	t := strings.TrimSpace(line)
	t = strings.TrimLeft(t, hermesBoxRunes)
	t = strings.TrimRight(t, hermesBoxRunes)
	t = strings.TrimSpace(t)
	if t == "" || isHermesRule(t) {
		return ""
	}
	return t
}

// isHermesRule reports whether a line is pure box drawing / a horizontal rule,
// i.e. carries no content.
func isHermesRule(t string) bool {
	if t == "" {
		return false
	}
	for _, r := range t {
		switch r {
		case '─', '━', '│', '┃', '╭', '╮', '╰', '╯', '┌', '┐', '└', '┘',
			'├', '┤', '┬', '┴', '┼', '═', '║', '╔', '╗', '╚', '╝', ' ', '\t':
		default:
			return false
		}
	}
	return true
}

// hermesPanelTitle returns a panel's title when line opens one
// ("╭─ Hermes needs your input ─╮" -> "Hermes needs your input"), else "".
func hermesPanelTitle(line string) string {
	t := strings.TrimSpace(line)
	if t == "" {
		return ""
	}
	switch []rune(t)[0] {
	case '╭', '┌', '╔':
	default:
		return ""
	}
	t = strings.Trim(t, "╭╮╰╯┌┐└┘╔╗╚╝─━═ ")
	return strings.TrimSpace(t)
}

// isHermesPanelEnd reports whether line closes a panel.
func isHermesPanelEnd(line string) bool {
	t := strings.TrimSpace(line)
	if t == "" {
		return false
	}
	switch []rune(t)[0] {
	case '╰', '└', '╚':
		return true
	}
	return false
}

// hermesBlockerTitles are the panel titles that carry a blocking prompt. Hermes
// labels its clarify panel "Hermes needs your input"; the match is on the
// "needs your input" substring so a reworded or differently-branded title still
// resolves.
func isHermesBlockerTitle(title string) bool {
	low := strings.ToLower(title)
	return strings.Contains(low, "needs your input") ||
		strings.Contains(low, "needs input") ||
		strings.Contains(low, "your input")
}

// parseHermesBlocked pulls the question and numbered choices out of the blocker
// panel. It returns nil when no such panel is on screen, so the caller can fall
// back to the free-form path.
func parseHermesBlocked(detection string) *Blocked {
	lines := splitLines(detection)

	// Find the LAST blocker panel — the live one is at the bottom of the screen.
	start := -1
	for i, l := range lines {
		if t := hermesPanelTitle(l); t != "" && isHermesBlockerTitle(t) {
			start = i
		}
	}
	if start < 0 {
		return nil
	}

	var content []string
	for i := start + 1; i < len(lines); i++ {
		if isHermesPanelEnd(lines[i]) {
			break
		}
		if s := stripHermesBorders(lines[i]); s != "" {
			content = append(content, s)
		}
	}
	if len(content) == 0 {
		return nil
	}

	// Inside the panel the shared scanner does the work: the question is the text
	// above the list, the options are the "❯ 1. …" lines.
	question, options := scanBlocked(content)
	if question == "" {
		// Hermes does not always end the prompt with "?" — take the first content
		// line that isn't itself an option.
		for _, c := range content {
			if !numberedOptionRE.MatchString(c) {
				question = c
				break
			}
		}
	}
	if question == "" && len(options) == 0 {
		return nil
	}
	return &Blocked{Question: question, Options: options}
}

// lastHermesMessage returns the prose from the last assistant panel
// ("╭─ ⚕ Hermes ─╮"), stripped of borders. Reasoning panels are skipped: they are
// the model's own scratchpad, not something to show as the agent's message.
func lastHermesMessage(text string) string {
	lines := splitLines(text)

	start, end := -1, -1
	for i, l := range lines {
		title := hermesPanelTitle(l)
		if title == "" {
			continue
		}
		if isHermesReasoningTitle(title) || isHermesBlockerTitle(title) {
			continue
		}
		if !strings.Contains(strings.ToLower(title), "hermes") {
			continue
		}
		start = i
		end = -1
		for j := i + 1; j < len(lines); j++ {
			if isHermesPanelEnd(lines[j]) {
				end = j
				break
			}
		}
	}
	if start < 0 {
		return ""
	}
	if end < 0 {
		end = len(lines)
	}

	var body []string
	for i := start + 1; i < end; i++ {
		s := stripHermesBorders(lines[i])
		if s == "" {
			// Keep paragraph breaks, but never lead with one.
			if len(body) > 0 && body[len(body)-1] != "" {
				body = append(body, "")
			}
			continue
		}
		// The status ticker Hermes prints inside its own panel ("❓ preparing
		// clarify…") is chrome, not prose.
		if isHermesStatusLine(s) {
			continue
		}
		body = append(body, s)
	}
	return strings.TrimSpace(strings.Join(body, "\n"))
}

func isHermesReasoningTitle(title string) bool {
	return strings.EqualFold(strings.TrimSpace(title), "reasoning")
}

// isHermesStatusLine reports whether a panel line is Hermes's transient activity
// ticker rather than prose.
func isHermesStatusLine(s string) bool {
	t := strings.TrimSpace(s)
	return strings.HasPrefix(t, "❓") || strings.HasPrefix(t, "⚕") ||
		strings.HasPrefix(t, "🔄") || strings.HasPrefix(t, "⏱")
}

// hermesReadable flattens a snapshot into plain conversational lines for the
// Transcript field: panel borders removed, reasoning panels and chrome dropped,
// user turns ("● …") kept without their bullet.
func hermesReadable(text string) []string {
	lines := splitLines(text)
	var out []string
	inReasoning := false

	for _, l := range lines {
		if title := hermesPanelTitle(l); title != "" {
			inReasoning = isHermesReasoningTitle(title)
			continue
		}
		if isHermesPanelEnd(l) {
			inReasoning = false
			continue
		}
		if inReasoning {
			continue
		}
		s := stripHermesBorders(l)
		if s == "" || isHermesStatusLine(s) || isChromeLine(s) {
			continue
		}
		// A user turn is printed as "● text" between rules.
		s = strings.TrimSpace(strings.TrimPrefix(s, "●"))
		if s == "" {
			continue
		}
		out = append(out, s)
	}
	return out
}
