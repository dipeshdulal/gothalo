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
		// What runPaneStream writes for the history seed. A clear here would
		// erase the client's viewport at the moment the seed lands, and — worse
		// — anything the client had already scrolled to.
		got := crlf([]byte("old line\nolder line\n"))
		if bytes.Contains(got, []byte("\x1b[2J")) {
			t.Errorf("seed = %q, must not contain an erase-display", got)
		}
	})
}

// The kind watcher filters a global subscription down to one pane, and Herdr
// puts the pane id in two different places depending on the event: at the top
// level on the agent events, nested under "pane" on the structural ones. Miss
// either shape and a backend swap is silently never noticed.
func TestMentionsPane(t *testing.T) {
	cases := []struct {
		name string
		data string
		want bool
	}{
		{"top-level pane_id (pane.agent_detected)", `{"pane_id":"w1:p1","agent":"claude"}`, true},
		{"nested pane_id (pane.updated)", `{"pane":{"pane_id":"w1:p1","agent":""}}`, true},
		{"the departure signal, which carries no agent", `{"pane_id":"w1:p1","agent":"","agent_status":"unknown"}`, true},
		{"another pane", `{"pane_id":"w1:p9"}`, false},
		{"another pane, nested", `{"pane":{"pane_id":"w1:p9"}}`, false},
		{"no pane id at all", `{"workspace_id":"w1"}`, false},
		{"not an object", `["w1:p1"]`, false},
		{"malformed", `{`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mentionsPane([]byte(tc.data), "w1:p1"); got != tc.want {
				t.Errorf("mentionsPane(%s) = %v, want %v", tc.data, got, tc.want)
			}
		})
	}
}

// The cheap skip in the kind watcher rests entirely on this: a payload naming
// an agent proves one is present, while an empty name proves nothing (the
// departure signal and a trailing pane.updated both carry one). Treat an empty
// name as "agent present" and a departure is skipped and never noticed.
func TestNamesAgent(t *testing.T) {
	cases := []struct {
		name string
		data string
		want bool
	}{
		{"agent named at the top level", `{"pane_id":"w1:p1","agent":"claude"}`, true},
		{"agent named under pane", `{"pane":{"pane_id":"w1:p1","agent":"codex"}}`, true},
		{"the departure signal", `{"pane_id":"w1:p1","agent":"","agent_status":"unknown"}`, false},
		{"no agent field at all", `{"pane_id":"w1:p1"}`, false},
		{"malformed", `{`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := namesAgent([]byte(tc.data)); got != tc.want {
				t.Errorf("namesAgent(%s) = %v, want %v", tc.data, got, tc.want)
			}
		})
	}
}
