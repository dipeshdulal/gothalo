package transcript

import (
	"strings"
	"testing"
)

// TestStripANSI feeds ANSI- and control-laden input (the kind of colorized stdout a
// coding agent emits) through stripANSI and asserts we get clean plain text: no
// escape bytes, no leftover CSI/OSC noise, with newlines and tabs preserved.
func TestStripANSI(t *testing.T) {
	// SGR color/dim runs, a cursor-move CSI, an OSC hyperlink terminated by BEL,
	// an OSC window title terminated by ST (ESC \), a lone ESC, a bare carriage
	// return, and a NUL — interleaved with the text we want to survive.
	in := "\x1b[2mdim\x1b[22m \x1b[36mcyan\x1b[0m text" +
		"\x1b[1A\x1b[2K" + // cursor up + erase line
		"\x1b]8;;https://example.com\x07link\x1b]8;;\x07" + // OSC 8 hyperlink
		"\x1b]0;window title\x1b\\" + // OSC 0 title, ST-terminated
		"\x00\rmore\ttabbed\nsecond line\x1b"

	got := stripANSI(in)

	want := "dim cyan textlinkmore\ttabbed\nsecond line"
	if got != want {
		t.Fatalf("stripANSI mismatch:\n got  %q\n want %q", got, want)
	}

	// Defensive invariants: no ESC bytes and no residual "[2m"/"[36m" fragments.
	if strings.ContainsRune(got, 0x1b) {
		t.Errorf("output still contains ESC (0x1b): %q", got)
	}
	for _, bad := range []string{"[2m", "[22m", "[36m", "[0m", "]8;", "\x07", "\x00", "\r"} {
		if strings.Contains(got, bad) {
			t.Errorf("output still contains %q: %q", bad, got)
		}
	}

	// Legitimate whitespace must be preserved.
	if !strings.Contains(got, "\t") || !strings.Contains(got, "\n") {
		t.Errorf("stripANSI dropped tab/newline: %q", got)
	}

	// Plain text passes through untouched.
	if plain := "no escapes here\nline two"; stripANSI(plain) != plain {
		t.Errorf("stripANSI altered plain text: %q", stripANSI(plain))
	}
}
