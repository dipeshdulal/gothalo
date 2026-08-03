package agentstate

import (
	"regexp"
	"strings"
)

// claudeParser parses Claude Code's TUI. Claude renders assistant prose as
// "⏺ …" bullets, tool actions as "⏺ Running…"/"⎿ …" lines, an in-progress
// spinner ("✻ Germinating…"), a fenced input box ("❯"), and — when blocked — a
// permission/choice form after the last horizontal rule ("Do you want to
// proceed?" + a numbered list). We trust herdr's authoritative status and only
// extract the presentation for it. See docs/API.md and CONTRACT.md.
type claudeParser struct{}

func init() { Register(claudeParser{}) }

func (claudeParser) Kind() string { return "claude" }

func (p claudeParser) Parse(in Input) State {
	st := State{Parsed: true}

	// The permission mode is read from the live detection footer bar (see mode.go).
	// Set once here so every return path below carries it; it's "" (omitted) when
	// the bar isn't on screen, so this never fails the parse.
	st.PermissionMode = claudePermissionMode(in.Detection)

	// Transcript is a cheap few lines of recent readable content, useful in every
	// state. Recent-unwrapped carries more history than the detection screen.
	st.Transcript = lastN(claudeReadable(in.Recent), 12)

	if in.Status == "blocked" {
		if b := parseClaudeBlocked(in.Detection); b != nil {
			st.Blocked = b
			st.Headline = truncate(b.Question, 120)
			st.Detail = claudeBlockedContext(in.Detection, b.Question)
			if st.Detail == "" {
				st.Detail = b.Question
			}
			return st
		}
		// Blocked but the form didn't match a shape we know (e.g. a free-form
		// prompt). Fall through to the message path but keep an empty Blocked so
		// the app still learns it must respond.
		st.Blocked = &Blocked{Question: firstLine(lastClaudeMessage(in.Detection))}
	}

	// idle / working / done (and unrecognised blocked): surface the last assistant
	// *prose* message. Prefer recent (fuller history) over the live screen.
	msg := lastClaudeMessage(in.Recent)
	if msg == "" {
		msg = lastClaudeMessage(in.Detection)
	}
	if msg != "" {
		st.Detail = msg
		st.Headline = truncate(firstLine(msg), 120)
		return st
	}

	// No prose on screen (a long tool-only working stretch, or a freshly-cleared
	// "done" pane): fall back to the task title for the headline and the current
	// tool activity for the detail, so the card still says something useful.
	activity := lastClaudeActivity(in.Recent)
	if activity == "" {
		activity = lastClaudeActivity(in.Detection)
	}
	st.Headline = truncate(in.Title, 120)
	if st.Headline == "" {
		st.Headline = truncate(activity, 120)
	}
	if st.Headline == "" {
		st.Headline = "Agent " + normalizeStatus(in.Status)
	}
	switch {
	case activity != "":
		st.Detail = activity
	case in.Title != "":
		st.Detail = in.Title
	}
	return st
}

// bulletPrefix is Claude's assistant-line marker "⏺ ".
const bulletPrefix = "⏺"

// claudeActionRE matches the first line of a *summary-style* tool-action bullet
// ("Running 1 shell command…", "Read 3 files", "Reading…") as opposed to
// assistant prose. Claude also renders tool calls as `ToolName(args)` — see
// toolCallRE. Either shape is an action; we prefer prose for Detail.
var claudeActionRE = regexp.MustCompile(`^(Running|Ran|Read|Reading|List(ed|ing)?|Search(ed|ing)?|Wrote|Writing|Updat(ed|ing)|Creat(ed|ing)|Delet(ed|ing)|Fetch(ed|ing)|Call(ed|ing)|Explor(ed|ing)|Analy(zed|zing|sed|sing)|Wait(ed|ing)|Bash|Compact(ed|ing)|Referenc(ed|ing))\b`)

// toolCallRE matches Claude's tool-invocation bullet, e.g. "Update(docs/API.md)",
// "Bash(git status)", "Read(main.go)" — an identifier immediately followed by a
// parenthesised argument. These are actions, not prose.
var toolCallRE = regexp.MustCompile(`^[A-Za-z][\w.-]*\(`)

// isClaudeAction reports whether a bullet head is a tool action (either shape)
// rather than assistant prose.
func isClaudeAction(head string) bool {
	return claudeActionRE.MatchString(head) || toolCallRE.MatchString(head)
}

// claudeBlock is one assistant bullet: its body (head + wrapped continuation) and
// whether it is a tool action vs prose.
type claudeBlock struct {
	body   string
	action bool
}

// claudeBlocks splits a snapshot into assistant bullet blocks in order. A block
// is a "⏺ " line plus the blank/indented continuation lines under it (its wrapped
// body and bullet list), stopping at the next bullet, a dedent, or nested tool
// output ("⎿ …").
func claudeBlocks(text string) []claudeBlock {
	lines := splitLines(text)
	var blocks []claudeBlock
	for i := 0; i < len(lines); i++ {
		if !strings.HasPrefix(strings.TrimLeft(lines[i], " "), bulletPrefix) {
			continue
		}
		head := strings.TrimSpace(strings.TrimPrefix(strings.TrimLeft(lines[i], " "), bulletPrefix))
		var buf []string
		if head != "" {
			buf = append(buf, head)
		}
		j := i + 1
		for ; j < len(lines); j++ {
			l := lines[j]
			t := strings.TrimSpace(l)
			if t == "" {
				buf = append(buf, "")
				continue
			}
			if !strings.HasPrefix(l, " ") { // dedented -> block ended
				break
			}
			if strings.HasPrefix(t, "⎿") { // nested tool result -> not prose body
				break
			}
			buf = append(buf, t)
		}
		i = j - 1
		body := strings.TrimSpace(strings.Join(buf, "\n"))
		if body == "" {
			continue
		}
		blocks = append(blocks, claudeBlock{body: body, action: isClaudeAction(head)})
	}
	return blocks
}

// lastClaudeMessage returns the last assistant *prose* block body in text, or ""
// when the screen holds only tool actions (a long tool-only stretch).
func lastClaudeMessage(text string) string {
	blocks := claudeBlocks(text)
	for k := len(blocks) - 1; k >= 0; k-- {
		if !blocks[k].action {
			return blocks[k].body
		}
	}
	return ""
}

// lastClaudeActivity returns the first line of the last bullet of any kind — the
// current tool step — used as a detail fallback when there is no prose to show.
func lastClaudeActivity(text string) string {
	blocks := claudeBlocks(text)
	if len(blocks) == 0 {
		return ""
	}
	return firstLine(blocks[len(blocks)-1].body)
}

// parseClaudeBlocked extracts the question + options from Claude's blocker
// form. The active menu always restarts its numbering at "1.", so the last
// "1." (or "❯ 1.") line in the screen anchors where it begins — this also
// works when Claude splits the menu across a rule, appending a trailing meta
// option ("5. Chat about this") below its own rule, after the boxed 1-4
// choices: scanning from the anchor to the end of the screen still picks up
// every option regardless of the rule in between. The question is the nearest
// qualifying line above the anchor. Falls back to the old last-rule-region (and
// then whole-screen) scan for any shape that doesn't fit. Returns nil when
// nothing recognisable is present (caller degrades gracefully).
func parseClaudeBlocked(detection string) *Blocked {
	lines := splitLines(detection)
	if start := lastOptionOneIndex(lines); start >= 0 {
		_, opts := scanBlocked(lines[start:])
		if len(opts) > 0 {
			b := &Blocked{Question: questionBefore(lines, start), Options: opts}
			if len(opts) <= 1 {
				b.Options = append(b.Options, hintNoOption(lines)...)
			}
			return b
		}
	}
	region := afterLastRule(detection)
	if q, opts := scanBlocked(region); q != "" || len(opts) > 0 {
		return &Blocked{Question: q, Options: opts}
	}
	if q, opts := scanBlocked(lines); q != "" || len(opts) > 0 {
		return &Blocked{Question: q, Options: opts}
	}
	return nil
}

// firstOptionRE matches the line that (re)starts a menu's numbering at 1,
// optionally ❯-marked — the anchor for where the CURRENT blocker form begins.
var firstOptionRE = regexp.MustCompile(`^\s*(❯\s*)?1\.\s+`)

// lastOptionOneIndex returns the index of the last "1." line in lines (the
// start of the active menu, since a fresh menu always renumbers from 1), or -1
// if there is none.
func lastOptionOneIndex(lines []string) int {
	idx := -1
	for i, l := range lines {
		if firstOptionRE.MatchString(l) {
			idx = i
		}
	}
	return idx
}

// questionBefore searches backward from just above lines[start] for the
// prompt line the menu at start answers: the nearest non-blank, non-chrome
// line above it. Returns "" (rather than guessing) when that nearest line
// isn't question-shaped, or when a rule is hit first — the question lives in
// the same section as its menu, not across a divider.
func questionBefore(lines []string, start int) string {
	for i := start - 1; i >= 0; i-- {
		if isRuleLine(lines[i]) {
			return ""
		}
		t := strings.TrimSpace(lines[i])
		if t == "" || isBoxOnly(lines[i]) {
			continue
		}
		if strings.HasSuffix(t, "?") || questionRE.MatchString(t) {
			return t
		}
		return ""
	}
	return ""
}

// escHintRE matches Claude's footer key hint for declining outright, e.g.
// "Esc to cancel" (one "·"-separated segment of "Esc to cancel · Tab to amend
// · ctrl+e to explain").
var escHintRE = regexp.MustCompile(`(?i)\bEsc\s+to\s+cancel\b`)

// hintNoOption returns a synthetic "No" Option keyed "esc" when lines carry
// Claude's "Esc to cancel" footer hint. Claude's newer single-choice approval
// form ("❯ 1. Yes") has no numbered decline — Esc is the only way to say no —
// so without this the app would have a Yes button and nothing else. Callers
// only append it when the menu had one option or fewer, so a classic 3-option
// form (which also prints this same footer, redundantly) doesn't get a
// duplicate "No".
func hintNoOption(lines []string) []Option {
	for _, l := range lines {
		if escHintRE.MatchString(l) {
			return []Option{{Key: "esc", Label: "No"}}
		}
	}
	return nil
}

// questionRE matches the prompt line Claude ends its blocker with.
var questionRE = regexp.MustCompile(`(?i)(do you want to|would you like to|proceed\?|allow this|trust the files|overwrite\?)`)

// scanBlocked pulls the question line and the numbered options out of a set of
// lines. The question is the last line ending in "?" (or matching questionRE);
// options are the numbered choices, with Selected set on the "❯"-marked default.
func scanBlocked(lines []string) (question string, options []Option) {
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if t == "" {
			continue
		}
		if m := numberedOptionRE.FindStringSubmatch(l); m != nil {
			idx := atoi(m[2])
			options = append(options, Option{
				Index:    idx,
				Label:    strings.TrimSpace(m[3]),
				Selected: m[1] != "",
			})
			continue
		}
		if strings.HasSuffix(t, "?") || questionRE.MatchString(t) {
			// Keep the last question before the options (Claude prints it directly
			// above the list); options after this reset any earlier false positive.
			if len(options) == 0 {
				question = t
			}
		}
	}
	return question, options
}

// claudeBlockedContext returns the short context Claude prints above the question
// (e.g. "Bash command / touch demo_output.txt / Create empty …") as the Detail,
// so a phone card explains what's being approved. It takes the readable lines in
// the blocker region that precede the question and aren't options/chrome.
func claudeBlockedContext(detection, question string) string {
	region := afterLastRule(detection)
	var ctx []string
	for _, l := range region {
		t := strings.TrimSpace(l)
		if t == "" || isRuleLine(l) {
			continue
		}
		if t == question {
			break
		}
		if numberedOptionRE.MatchString(l) || isChromeLine(t) {
			continue
		}
		ctx = append(ctx, t)
	}
	return strings.TrimSpace(strings.Join(ctx, "\n"))
}

// afterLastRule returns the cleaned lines that follow the last horizontal rule in
// text — the region Claude draws its live blocker form and footer in. When there
// is no rule, it returns all lines.
func afterLastRule(text string) []string {
	lines := splitLines(text)
	last := -1
	for i, l := range lines {
		if isRuleLine(l) {
			last = i
		}
	}
	if last < 0 {
		return lines
	}
	return lines[last+1:]
}

// claudeReadable returns Claude content lines for the transcript: readable lines
// with the assistant bullet marker stripped and Claude's spinner/recap chrome
// removed, on top of the shared chrome filter.
func claudeReadable(text string) []string {
	var out []string
	for _, l := range splitLines(text) {
		t := strings.TrimSpace(l)
		if t == "" || isRuleLine(l) || isBoxOnly(l) || isChromeLine(t) {
			continue
		}
		if claudeSpinnerRE.MatchString(t) { // "✻ Germinating… (…)" progress line
			continue
		}
		if strings.HasPrefix(t, "⎿") { // nested tool-result line — noise for a card
			continue
		}
		t = strings.TrimSpace(strings.TrimPrefix(t, bulletPrefix))
		if t == "" {
			continue
		}
		out = append(out, t)
	}
	return out
}

// claudeSpinnerRE matches Claude's in-progress spinner line: a spinner glyph
// (braille/asterisk) then a gerund and an ellipsis, e.g. "✻ Germinating… (3m…)".
var claudeSpinnerRE = regexp.MustCompile(`^[✻✳✽∗\x{2800}-\x{28FF}]\s+\S+…`)

// atoi parses a small non-negative integer, returning 0 on failure (options with
// an unparseable index simply get Index 0).
func atoi(s string) int {
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}
