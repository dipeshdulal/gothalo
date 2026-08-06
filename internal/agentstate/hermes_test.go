package agentstate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readHermesFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestHermesBlocked runs the parser over a real capture of a blocked Hermes pane
// (herdr agent read --source detection), taken live from a clarify prompt. The
// panel is box-drawn, so this is really a test that borders are stripped before
// the shared option scanner runs.
func TestHermesBlocked(t *testing.T) {
	st := Build(Input{
		PaneID:    "wN:p19",
		Kind:      "hermes",
		Status:    "blocked",
		Title:     "hermes",
		Detection: readHermesFixture(t, "hermes_blocked_detection.txt"),
		Recent:    readHermesFixture(t, "hermes_blocked_recent.txt"),
	})

	if !st.Parsed {
		t.Fatal("Parsed = false, want true")
	}
	if st.Blocked == nil {
		t.Fatal("Blocked = nil, want the clarify prompt")
	}
	if got, want := st.Blocked.Question, "What should we work on?"; got != want {
		t.Errorf("Question = %q, want %q", got, want)
	}

	wantOpts := []string{
		"Set up a new project",
		"Fix something in gothalo",
		"Explore Herdr tools",
		"Just chat, no pressure",
		"Other (type your answer)",
	}
	if len(st.Blocked.Options) != len(wantOpts) {
		t.Fatalf("got %d options, want %d: %+v", len(st.Blocked.Options), len(wantOpts), st.Blocked.Options)
	}
	for i, w := range wantOpts {
		o := st.Blocked.Options[i]
		if o.Label != w {
			t.Errorf("option %d label = %q, want %q", i+1, o.Label, w)
		}
		if o.Index != i+1 {
			t.Errorf("option %d index = %d, want %d", i+1, o.Index, i+1)
		}
	}
	// The "❯" marks the default that Enter would accept.
	if !st.Blocked.Options[0].Selected {
		t.Error("option 1 Selected = false, want true (marked with ❯)")
	}
	for _, o := range st.Blocked.Options[1:] {
		if o.Selected {
			t.Errorf("option %d Selected = true, want only option 1 selected", o.Index)
		}
	}

	if st.Headline != "What should we work on?" {
		t.Errorf("Headline = %q, want the question", st.Headline)
	}

	// Detail should be the assistant prose that set the question up — and must not
	// leak box borders or the transient status ticker.
	if !strings.Contains(st.Detail, "Quick one right now") {
		t.Errorf("Detail = %q, want the prose above the panel", st.Detail)
	}
	assertNoChrome(t, "Detail", st.Detail)
	if strings.Contains(st.Detail, "preparing clarify") {
		t.Errorf("Detail leaked the status ticker: %q", st.Detail)
	}
}

// TestHermesTranscriptExcludesReasoning: the Reasoning panel is the model's
// scratchpad. It must not appear in the transcript or the message body.
func TestHermesTranscriptExcludesReasoning(t *testing.T) {
	st := Build(Input{
		PaneID: "wN:p19", Kind: "hermes", Status: "blocked",
		Detection: readHermesFixture(t, "hermes_blocked_detection.txt"),
		Recent:    readHermesFixture(t, "hermes_blocked_recent.txt"),
	})

	joined := strings.Join(st.Transcript, "\n")
	for _, leak := range []string{
		"The user wants me to use the clarify tool more often",
		"should be saved to memory so it persists",
	} {
		if strings.Contains(joined, leak) {
			t.Errorf("transcript leaked reasoning: %q", leak)
		}
	}
	for _, line := range st.Transcript {
		assertNoChrome(t, "transcript line", line)
	}
}

// TestHermesMessagePath covers the non-blocked path: the last assistant panel
// becomes Detail/Headline, borders stripped.
func TestHermesMessagePath(t *testing.T) {
	st := Build(Input{
		PaneID: "wN:p19", Kind: "hermes", Status: "idle",
		Recent: readHermesFixture(t, "hermes_blocked_recent.txt"),
	})
	if st.Blocked != nil {
		t.Errorf("Blocked = %+v, want nil when not blocked", st.Blocked)
	}
	if st.Detail == "" {
		t.Fatal("Detail is empty, want the last assistant message")
	}
	assertNoChrome(t, "Detail", st.Detail)
	if st.Headline == "" {
		t.Error("Headline is empty")
	}
}

// TestHermesBlockedFreeForm: blocked with no recognisable panel must still report
// a non-nil Blocked, so the app knows a reply is required.
func TestHermesBlockedFreeForm(t *testing.T) {
	st := Build(Input{
		PaneID: "wN:p19", Kind: "hermes", Status: "blocked",
		Detection: "╭─ ⚕ Hermes ────╮\n  type something\n╰───────────────╯\n",
	})
	if st.Blocked == nil {
		t.Fatal("Blocked = nil; a blocked pane must always report Blocked")
	}
}

// TestHermesRegistered guards the wiring: a hermes pane must reach THIS parser,
// not the generic fallback.
func TestHermesRegistered(t *testing.T) {
	if _, ok := parserFor("hermes").(hermesParser); !ok {
		t.Errorf("parserFor(\"hermes\") = %T, want hermesParser", parserFor("hermes"))
	}
}

// assertNoChrome fails if s carries panel borders that should have been stripped.
func assertNoChrome(t *testing.T, what, s string) {
	t.Helper()
	for _, r := range []string{"│", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘"} {
		if strings.Contains(s, r) {
			t.Errorf("%s leaked box drawing %q: %q", what, r, s)
		}
	}
}
