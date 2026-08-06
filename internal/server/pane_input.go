package server

import (
	"strings"
)

// A plain (non-agent) pane has no PTY we can write to directly — input goes
// through Herdr's pane commands. `pane send-text` types *text*: it silently
// drops terminal control sequences, so an arrow key arrives as nothing at all
// (verified live: `send-text $'\e[B'` leaves a `less` pane exactly where it
// was, while `send-keys down` scrolls it). Keys must therefore go through
// `pane send-keys`, which takes logical names.
//
// So client bytes are split into two kinds of chunk — text to type and keys to
// press — preserving order, and each is sent over the command that can actually
// deliver it. Agent panes are unaffected: they own a real PTY and take raw
// bytes (see attachAgentPTY).

// paneChunk is one ordered piece of client input: either literal [text] to type
// or a logical [key] to press. Exactly one field is set.
type paneChunk struct {
	key  string
	text string
}

// paneKeySeq maps a control sequence a terminal client sends to the logical key
// name Herdr's send-keys accepts. Longest match wins, so entries that share a
// prefix (ESC alone vs. ESC [ A) resolve correctly.
//
// Only names Herdr actually accepts appear here; unsupported ones (home, end,
// page up/down) are deliberately absent and fall through to being typed, which
// is the same no-op as today rather than a hard error.
var paneKeySeq = map[string]string{
	"\x1b[A": "up",
	"\x1b[B": "down",
	"\x1b[C": "right",
	"\x1b[D": "left",
	// SS3 forms, sent while the application cursor-key mode is on.
	"\x1bOA": "up",
	"\x1bOB": "down",
	"\x1bOC": "right",
	"\x1bOD": "left",
	"\x1b[Z": "shift+tab",
	"\x1b":   "esc",
	"\r\n":   "enter",
	"\r":     "enter",
	"\n":     "enter",
	"\t":     "tab",
	"\x7f":   "backspace",
	"\x08":   "backspace",
}

// longestPaneKeySeq is how far ahead splitPaneInput has to look for a match.
const longestPaneKeySeq = 3

// splitPaneInput turns raw client bytes into ordered chunks. Runs of ordinary
// characters coalesce into one text chunk so a paste stays a single send-text.
func splitPaneInput(s string) []paneChunk {
	var out []paneChunk
	var text strings.Builder

	flush := func() {
		if text.Len() > 0 {
			out = append(out, paneChunk{text: text.String()})
			text.Reset()
		}
	}

	for i := 0; i < len(s); {
		key, width := paneKeyAt(s, i)
		if key != "" {
			flush()
			out = append(out, paneChunk{key: key})
			i += width
			continue
		}
		text.WriteByte(s[i])
		i++
	}
	flush()
	return out
}

// paneKeyAt reports the logical key starting at s[i] and how many bytes it
// spans, preferring the longest match. Returns "" when s[i] starts ordinary
// text.
func paneKeyAt(s string, i int) (string, int) {
	for n := longestPaneKeySeq; n >= 1; n-- {
		if i+n > len(s) {
			continue
		}
		if key, ok := paneKeySeq[s[i:i+n]]; ok {
			return key, n
		}
	}
	// Ctrl-letter is a whole family (0x01–0x1A) — derive it rather than listing
	// 26 entries. Tab/CR/LF live in the table above and never reach here.
	if c := s[i]; c >= 0x01 && c <= 0x1a {
		return "ctrl+" + string(rune('a'+c-1)), 1
	}
	return "", 0
}
