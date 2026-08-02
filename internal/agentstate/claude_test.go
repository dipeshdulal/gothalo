package agentstate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// read loads a captured herdr snapshot from testdata, failing the test if the
// fixture is missing. Fixtures were captured from a live Claude Code pane with
// `herdr agent read <pane> --source <detection|recent-unwrapped> --format text`.
func read(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return string(b)
}

// TestClaudeParseStates drives real captured output for each herdr status through
// Build (which routes via the registry to claudeParser) and asserts the common
// contract. Table-style: one row per captured state.
func TestClaudeParseStates(t *testing.T) {
	cases := []struct {
		name          string
		status        string
		title         string
		detectionFile string
		recentFile    string

		wantParsed      bool
		wantStatus      string
		wantDetailHas   string // substring the Detail must contain
		wantHeadlineHas string // substring the Headline must contain
	}{
		{
			name:          "idle",
			status:        "idle",
			title:         "Implement multi-warehouse shipping logic and delivery timelines",
			detectionFile: "claude_idle_detection.txt",
			recentFile:    "claude_idle_recent.txt",
			wantParsed:    true,
			wantStatus:    "idle",
			wantDetailHas: "Both PRs are open",
		},
		{
			name:          "working",
			status:        "working",
			title:         "Implement pane control endpoints for Go backend",
			detectionFile: "claude_working_detection.txt",
			recentFile:    "claude_working_recent.txt",
			wantParsed:    true,
			wantStatus:    "working",
			wantDetailHas: "task tracking",
		},
		{
			name:            "blocked",
			status:          "blocked",
			title:           "claude",
			detectionFile:   "claude_blocked_detection.txt",
			recentFile:      "claude_blocked_recent.txt",
			wantParsed:      true,
			wantStatus:      "blocked",
			wantDetailHas:   "touch demo_output.txt",
			wantHeadlineHas: "proceed",
		},
		{
			name:          "done",
			status:        "done",
			title:         "Claude Code",
			detectionFile: "claude_done_detection.txt",
			recentFile:    "claude_done_recent.txt",
			wantParsed:    true,
			wantStatus:    "done",
			wantDetailHas: "created demo_output.txt",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			st := Build(Input{
				PaneID:    "wX:p1",
				Kind:      "claude",
				Status:    tc.status,
				Title:     tc.title,
				Detection: read(t, tc.detectionFile),
				Recent:    read(t, tc.recentFile),
			})

			if st.PaneID != "wX:p1" {
				t.Errorf("PaneID = %q, want stamped wX:p1", st.PaneID)
			}
			if st.AgentKind != "claude" {
				t.Errorf("AgentKind = %q, want claude", st.AgentKind)
			}
			if st.AgentStatus != tc.wantStatus {
				t.Errorf("AgentStatus = %q, want %q", st.AgentStatus, tc.wantStatus)
			}
			if st.Parsed != tc.wantParsed {
				t.Errorf("Parsed = %v, want %v", st.Parsed, tc.wantParsed)
			}
			if st.Headline == "" {
				t.Errorf("Headline is empty")
			}
			if tc.wantHeadlineHas != "" && !strings.Contains(st.Headline, tc.wantHeadlineHas) {
				t.Errorf("Headline = %q, want it to contain %q", st.Headline, tc.wantHeadlineHas)
			}
			if tc.wantDetailHas != "" && !strings.Contains(st.Detail, tc.wantDetailHas) {
				t.Errorf("Detail = %q, want it to contain %q", st.Detail, tc.wantDetailHas)
			}
			// Only the blocked state may carry a Blocked payload.
			if tc.wantStatus != "blocked" && st.Blocked != nil {
				t.Errorf("non-blocked state carries Blocked = %+v", st.Blocked)
			}
		})
	}
}

// TestClaudeBlockedOptions checks the exact question/choices parsed from the live
// permission form, since that payload is what POST /approve and the app's tap
// targets depend on.
func TestClaudeBlockedOptions(t *testing.T) {
	st := Build(Input{
		PaneID:    "wX:p2",
		Kind:      "claude",
		Status:    "blocked",
		Detection: read(t, "claude_blocked_detection.txt"),
		Recent:    read(t, "claude_blocked_recent.txt"),
	})

	if st.Blocked == nil {
		t.Fatal("Blocked is nil for a blocked pane")
	}
	if !strings.Contains(st.Blocked.Question, "Do you want to proceed?") {
		t.Errorf("Question = %q, want it to contain the proceed prompt", st.Blocked.Question)
	}
	if len(st.Blocked.Options) != 3 {
		t.Fatalf("got %d options, want 3: %+v", len(st.Blocked.Options), st.Blocked.Options)
	}

	want := []struct {
		index    int
		selected bool
		labelHas string
	}{
		{1, true, "Yes"},
		{2, false, "always allow"},
		{3, false, "No"},
	}
	for i, w := range want {
		got := st.Blocked.Options[i]
		if got.Index != w.index {
			t.Errorf("option %d Index = %d, want %d", i, got.Index, w.index)
		}
		if got.Selected != w.selected {
			t.Errorf("option %d Selected = %v, want %v", i, got.Selected, w.selected)
		}
		if !strings.Contains(got.Label, w.labelHas) {
			t.Errorf("option %d Label = %q, want it to contain %q", i, got.Label, w.labelHas)
		}
	}
}

// TestUnknownKindFallsBack verifies the unknown-safe contract: an unregistered
// agent kind routes to the generic parser (Parsed=false) and still returns a
// renderable card rather than erroring.
func TestUnknownKindFallsBack(t *testing.T) {
	st := Build(Input{
		PaneID:    "wX:p3",
		Kind:      "some-future-agent",
		Status:    "working",
		Title:     "Do a thing",
		Detection: read(t, "claude_idle_detection.txt"),
		Recent:    read(t, "claude_idle_recent.txt"),
	})

	if st.Parsed {
		t.Errorf("Parsed = true for unknown kind, want false (generic fallback)")
	}
	if st.AgentKind != "some-future-agent" {
		t.Errorf("AgentKind = %q, want passthrough", st.AgentKind)
	}
	if st.AgentStatus != "working" {
		t.Errorf("AgentStatus = %q, want working", st.AgentStatus)
	}
	if st.Headline == "" {
		t.Errorf("generic fallback produced an empty Headline")
	}
}

// TestRegisteredStubKinds documents that codex/opencode are wired into the
// registry (proving the one-file extensibility seam) even though their parsers
// currently delegate to the generic fallback.
func TestRegisteredStubKinds(t *testing.T) {
	for _, kind := range []string{"codex", "opencode"} {
		if _, ok := registry[kind]; !ok {
			t.Errorf("kind %q not registered; extensibility seam broken", kind)
		}
	}
}

// TestNormalizeStatus checks the enum clamp: anything unexpected becomes unknown.
func TestNormalizeStatus(t *testing.T) {
	cases := map[string]string{
		"idle": "idle", "WORKING": "working", "blocked": "blocked",
		"done": "done", "": "unknown", "starting": "unknown",
	}
	for in, want := range cases {
		if got := normalizeStatus(in); got != want {
			t.Errorf("normalizeStatus(%q) = %q, want %q", in, got, want)
		}
	}
}
