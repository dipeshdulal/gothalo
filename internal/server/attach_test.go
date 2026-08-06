package server

import (
	"bytes"
	"testing"
)

// The scrollback seed and the repaint share one line-ending normaliser but must
// differ in exactly one way: the seed carries no clear-screen, or it would wipe
// the very history it is delivering. Assert both halves of that split.
func TestCRLFAndRepaint(t *testing.T) {
	const clear = "\x1b[H\x1b[2J"

	t.Run("crlf gives every row a CRLF ending", func(t *testing.T) {
		got := crlf([]byte("a\nb\nc"))
		if want := []byte("a\r\nb\r\nc"); !bytes.Equal(got, want) {
			t.Errorf("crlf = %q, want %q", got, want)
		}
	})

	t.Run("crlf is idempotent", func(t *testing.T) {
		once := crlf([]byte("a\nb"))
		if twice := crlf(once); !bytes.Equal(once, twice) {
			t.Errorf("crlf twice = %q, want %q — CRLF must not become CRCRLF", twice, once)
		}
	})

	t.Run("repaint clears the screen first", func(t *testing.T) {
		got := repaint([]byte("row\n"))
		if !bytes.HasPrefix(got, []byte(clear)) {
			t.Errorf("repaint = %q, want the %q prefix", got, clear)
		}
	})

	t.Run("the seed carries no clear-screen", func(t *testing.T) {
		// What attachPaneStream writes for the history seed. A clear here would
		// erase the client's viewport at the moment the seed lands, and — worse
		// — anything the client had already scrolled to.
		got := crlf([]byte("old line\nolder line\n"))
		if bytes.Contains(got, []byte("\x1b[2J")) {
			t.Errorf("seed = %q, must not contain an erase-display", got)
		}
	})
}
