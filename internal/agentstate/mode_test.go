package agentstate

import "testing"

// TestClaudePermissionMode drives the mode footer bar wording captured live from
// Claude's TUI (⏸/⏵⏵ … mode on) through the parser and asserts the canonical
// token. The last bar on screen wins, and an absent bar yields "".
func TestClaudePermissionMode(t *testing.T) {
	cases := []struct {
		name      string
		detection string
		want      string
	}{
		{"manual->default", "  ⏸ manual mode on · ? for shortcuts · ← 1 agent", "default"},
		{"accept-edits", "  ⏵⏵ accept edits on (shift+tab to cycle) · ← 1 agent", "acceptEdits"},
		{"plan", "  ⏸ plan mode on (shift+tab to cycle)", "plan"},
		{"auto", "  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt", "auto"},
		{"bypass-permissions", "  ⏵⏵ bypass permissions on (shift+tab to cycle)", "bypassPermissions"},
		{"no-glyph-still-parses", "manual mode on", "default"},
		{"absent-bar", "⏺ Some assistant prose\n❯ type here", ""},
		{"empty", "", ""},
		{
			// The live footer at the bottom wins over any earlier mode wording that
			// scrolled up into the history region.
			name:      "last-bar-wins",
			detection: "  ⏸ manual mode on\n⏺ … work …\n  ⏵⏵ plan mode on (shift+tab to cycle)",
			want:      "plan",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := claudePermissionMode(c.detection); got != c.want {
				t.Errorf("claudePermissionMode(%q) = %q, want %q", c.detection, got, c.want)
			}
		})
	}
}

// TestModeSupported pins the kind gate: only claude (case-insensitively) exposes a
// permission mode; every other kind (and the empty/unknown kind) does not, so the
// endpoint omits permission_mode and the cycle handler 409s.
func TestModeSupported(t *testing.T) {
	for _, k := range []string{"claude", "Claude", "  claude "} {
		if !ModeSupported(k) {
			t.Errorf("ModeSupported(%q) = false, want true", k)
		}
	}
	for _, k := range []string{"codex", "opencode", "gemini", "", "unknown"} {
		if ModeSupported(k) {
			t.Errorf("ModeSupported(%q) = true, want false", k)
		}
	}
}

// TestPermissionModeKindGating verifies the exported reader omits the mode for
// non-claude kinds even when a claude-shaped bar is (implausibly) present, so a
// mislabelled pane can't leak a Claude-only value onto another kind.
func TestPermissionModeKindGating(t *testing.T) {
	bar := "  ⏵⏵ auto mode on (shift+tab to cycle)"
	if got := PermissionMode("claude", bar); got != "auto" {
		t.Errorf("PermissionMode(claude) = %q, want auto", got)
	}
	if got := PermissionMode("codex", bar); got != "" {
		t.Errorf("PermissionMode(codex) = %q, want \"\" (omitted)", got)
	}
}

// TestBuildSetsPermissionMode threads the real captured detection fixtures through
// Build (the endpoint's entry point) and asserts permission_mode lands on the
// State only for claude, omitting it when the bar isn't on screen.
func TestBuildSetsPermissionMode(t *testing.T) {
	cases := []struct {
		name          string
		kind          string
		status        string
		detectionFile string
		want          string
	}{
		{"claude-idle-auto", "claude", "idle", "claude_idle_detection.txt", "auto"},
		{"claude-working-auto", "claude", "working", "claude_working_detection.txt", "auto"},
		{"claude-done-manual", "claude", "done", "claude_done_detection.txt", "default"},
		{"claude-blocked-no-bar", "claude", "blocked", "claude_blocked_detection.txt", ""},
		// A non-claude kind never carries permission_mode, whatever the frame holds.
		{"codex-omits", "codex", "idle", "claude_idle_detection.txt", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			st := Build(Input{
				PaneID:    "wN:p1",
				Kind:      c.kind,
				Status:    c.status,
				Detection: read(t, c.detectionFile),
			})
			if st.PermissionMode != c.want {
				t.Errorf("PermissionMode = %q, want %q", st.PermissionMode, c.want)
			}
		})
	}
}
