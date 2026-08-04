package agentstate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readOpencodeFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestOpencodeBlocked runs the parser over a live capture of a blocked opencode
// pane. The fixture matters: the same "┃" gutter fronts tool output higher up the
// screen, so this proves the prompt is found by its numbered options rather than
// by being the last gutter run.
func TestOpencodeBlocked(t *testing.T) {
	st := Build(Input{
		PaneID:    "wN:p1B",
		Kind:      "opencode",
		Status:    "blocked",
		Title:     "opencode",
		Detection: readOpencodeFixture(t, "opencode_blocked_detection.txt"),
		Recent:    readOpencodeFixture(t, "opencode_blocked_recent.txt"),
	})

	if !st.Parsed {
		t.Fatal("Parsed = false, want true")
	}
	if st.Blocked == nil {
		t.Fatal("Blocked = nil, want the question prompt")
	}
	if got, want := st.Blocked.Question, "What should we work on next in gothalo?"; got != want {
		t.Errorf("Question = %q, want %q", got, want)
	}

	// Labels only — the indented description under each option is dropped, since
	// Option has no field for it.
	wantLabels := []string{
		"Explore the Go bridge",
		"Work on the Flutter app",
		"Fix the README blank line",
		"Plan a feature",
		"Type your own answer",
	}
	if len(st.Blocked.Options) != len(wantLabels)+1 {
		t.Fatalf("got %d options, want %d numbered + esc: %+v",
			len(st.Blocked.Options), len(wantLabels), st.Blocked.Options)
	}
	for i, w := range wantLabels {
		o := st.Blocked.Options[i]
		if o.Label != w {
			t.Errorf("option %d label = %q, want %q", i+1, o.Label, w)
		}
		if o.Index != i+1 {
			t.Errorf("option %d index = %d, want %d", i+1, o.Index, i+1)
		}
		if strings.Contains(o.Label, "Deep-dive") || strings.Contains(o.Label, "Build or improve") {
			t.Errorf("option %d absorbed its description line: %q", i+1, o.Label)
		}
	}

	// "esc dismiss" is reachable but unnumbered, so it rides as a keyed option.
	esc := st.Blocked.Options[len(st.Blocked.Options)-1]
	if esc.Key != "esc" || esc.Index != 0 {
		t.Errorf("last option = %+v, want the keyed esc action", esc)
	}

	// opencode reports state via lifecycle hooks, not screen detection, so herdr
	// supplies no rule id — Category stays empty and that is correct.
	if st.Blocked.Category != "" {
		t.Errorf("Category = %q, want empty (opencode has no detection rule)", st.Blocked.Category)
	}

	if st.Headline != "What should we work on next in gothalo?" {
		t.Errorf("Headline = %q, want the question", st.Headline)
	}
	assertNoGutter(t, "Detail", st.Detail)
	for _, l := range st.Transcript {
		assertNoGutter(t, "transcript line", l)
	}
}

// TestOpencodeGutterIsNotEnough guards the specific trap: a gutter run of tool
// output that follows the prompt must not be mistaken for the prompt.
func TestOpencodeGutterIsNotEnough(t *testing.T) {
	detection := strings.Join([]string{
		"  ┃",
		"  ┃  What should we do?",
		"  ┃",
		"  ┃  1. First choice",
		"  ┃     a description",
		"  ┃  2. Second choice",
		"  ┃",
		"     ✱ Read some/file.go",
		"  ┃",
		"  ┃  file contents that happen to be quoted",
		"  ┃  and span a few lines",
		"  ┃",
	}, "\n")

	b := parseOpencodeBlocked(detection)
	if b == nil {
		t.Fatal("parseOpencodeBlocked = nil, want the prompt")
	}
	if b.Question != "What should we do?" {
		t.Errorf("Question = %q, want the prompt's question not the tool output", b.Question)
	}
	if len(b.Options) != 2 {
		t.Fatalf("got %d options, want 2: %+v", len(b.Options), b.Options)
	}
}

// TestOpencodeBlockedFreeForm: blocked with no recognisable prompt must still
// report a non-nil Blocked so the app knows a reply is owed.
func TestOpencodeBlockedFreeForm(t *testing.T) {
	st := Build(Input{
		PaneID: "wN:p1B", Kind: "opencode", Status: "blocked",
		Detection: "     Just some prose, no prompt block here.\n",
	})
	if st.Blocked == nil {
		t.Fatal("Blocked = nil; a blocked pane must always report Blocked")
	}
}

// TestOpencodeMessagePath covers the non-blocked path.
func TestOpencodeMessagePath(t *testing.T) {
	st := Build(Input{
		PaneID: "wN:p1B", Kind: "opencode", Status: "idle",
		Recent: readOpencodeFixture(t, "opencode_blocked_recent.txt"),
	})
	if st.Blocked != nil {
		t.Errorf("Blocked = %+v, want nil when not blocked", st.Blocked)
	}
	if st.Detail == "" {
		t.Error("Detail is empty, want the last prose block")
	}
	assertNoGutter(t, "Detail", st.Detail)
}

// TestOpencodeIdleCardIsNotChrome is the regression for a card whose headline
// was a row of block characters.
//
// An idle opencode screen ends with its input box, a rule drawn from BLOCK
// elements ("╹▀▀▀…" — not the box-drawing pieces the gutter uses), and a status
// bar carrying the cwd and context usage. Neither the rule nor the status bar is
// a gutter line or a marker line, so both survived as "the last prose block" and
// became the card's headline and detail.
func TestOpencodeIdleCardIsNotChrome(t *testing.T) {
	st := Build(Input{
		PaneID:    "wN:p1B",
		Kind:      "opencode",
		Status:    "idle",
		Title:     "opencode",
		Detection: readOpencodeFixture(t, "opencode_idle_detection.txt"),
		Recent:    readOpencodeFixture(t, "opencode_idle_recent.txt"),
	})

	for _, bad := range []string{"▀", "╹", "█", "▄"} {
		if strings.Contains(st.Headline, bad) {
			t.Errorf("Headline contains block drawing %q: %q", bad, st.Headline)
		}
		if strings.Contains(st.Detail, bad) {
			t.Errorf("Detail contains block drawing %q: %q", bad, st.Detail)
		}
	}
	// The status bar (cwd + "41.6K (21%)" + "ctrl+p commands") is furniture too.
	for _, s := range []string{"ctrl+p", "(21%)"} {
		if strings.Contains(st.Headline, s) || strings.Contains(st.Detail, s) {
			t.Errorf("card leaked the status bar (%q): headline=%q detail=%q", s, st.Headline, st.Detail)
		}
	}
	for _, l := range st.Transcript {
		if isOpencodeDrawing(l) {
			t.Errorf("transcript line is pure drawing: %q", l)
		}
	}
}

// TestIsOpencodeDrawing pins the classifier: rules are furniture, text is not,
// even when the text sits inside a bordered line.
func TestIsOpencodeDrawing(t *testing.T) {
	drawing := []string{"╹▀▀▀▀▀▀▀", "─────────", "  ┃  ", "━━━━", "████"}
	content := []string{"┃  Build · Big Pickle", "hello", "1. An option", "┃", ""}
	for _, s := range drawing {
		if !isOpencodeDrawing(s) {
			t.Errorf("isOpencodeDrawing(%q) = false, want true", s)
		}
	}
	for _, s := range content {
		if s == "" || strings.TrimSpace(s) == "┃" {
			continue // empty and a bare gutter are handled elsewhere
		}
		if isOpencodeDrawing(s) {
			t.Errorf("isOpencodeDrawing(%q) = true, want false", s)
		}
	}
}

// TestOpencodeRegistered guards the wiring.
func TestOpencodeRegistered(t *testing.T) {
	if _, ok := parserFor("opencode").(opencodeParser); !ok {
		t.Errorf("parserFor(\"opencode\") = %T, want opencodeParser", parserFor("opencode"))
	}
}

func assertNoGutter(t *testing.T, what, s string) {
	t.Helper()
	if strings.Contains(s, opencodeGutter) {
		t.Errorf("%s leaked the gutter: %q", what, s)
	}
}
