package agentstate

import "strings"

// Permission mode is Claude-specific: Claude Code cycles a "permission mode" with
// Shift+Tab and shows the active one in a footer bar of its TUI, e.g.
//
//	⏸ manual mode on
//	⏵⏵ accept edits on (shift+tab to cycle)
//	⏸ plan mode on (shift+tab to cycle)
//	⏵⏵ auto mode on (shift+tab to cycle)
//
// This footer bar (in the `detection` frame the parser already receives) is the
// AUTHORITATIVE, LIVE source of the current mode. Claude's own transcript JSONL
// also records a `permissionMode`, but — verified against a live pane — it is
// only stamped on message activity and goes STALE for an idle pane: cycling the
// mode with Shift+Tab while idle does not append a new transcript line. Since the
// app's flow is "cycle → re-fetch /agent-state" on an idle pane, reading the
// transcript would show no change, so we read the live footer bar instead. See
// docs/CONTRACT-agent-mode.md for the full finding.
//
// Only Claude has this concept; other kinds omit permission_mode (ModeSupported
// gates them) so the contract stays kind-agnostic.

// claudeModePhrases maps the footer-bar wording of each Claude permission mode to
// a canonical token. The tokens mirror Claude's own `permissionMode` vocabulary
// (default/acceptEdits/plan) so the value is consistent with the transcript field
// the app may already know; "manual" is Claude's TUI label for the default mode,
// and "auto" is this build's fourth (full-auto) mode. Ordered longest/most-
// specific first so a scan can't mis-match a shorter phrase inside a longer line.
var claudeModePhrases = []struct{ phrase, canonical string }{
	{"bypass permissions on", "bypassPermissions"},
	{"bypasspermissions mode on", "bypassPermissions"},
	{"accept edits on", "acceptEdits"},
	{"acceptedits mode on", "acceptEdits"},
	{"plan mode on", "plan"},
	{"auto mode on", "auto"},
	{"manual mode on", "default"},
	{"default mode on", "default"},
}

// ModeSupported reports whether an agent kind exposes a permission mode. Only
// Claude does today; every other kind returns false so /agent-state omits
// permission_mode and POST /agent-mode/cycle 409s instead of sending a keystroke
// a non-Claude TUI would not understand.
func ModeSupported(kind string) bool {
	return strings.EqualFold(strings.TrimSpace(kind), "claude")
}

// PermissionMode extracts the current permission mode from a `detection` frame for
// the given kind. It returns "" for kinds without the concept (ModeSupported) and
// when no mode footer is present, so callers can omit the field rather than error.
// Exported so the /agent-mode/cycle handler can read the mode back after a cycle
// without rebuilding a full State.
func PermissionMode(kind, detection string) string {
	if !ModeSupported(kind) {
		return ""
	}
	return claudePermissionMode(detection)
}

// claudePermissionMode returns the canonical permission-mode token from a Claude
// detection frame, or "" when the footer bar isn't present. It scans every line
// and keeps the LAST match, so a transient earlier bar (e.g. a scrolled-off
// history line) can't win over the live footer at the bottom of the screen.
func claudePermissionMode(detection string) string {
	mode := ""
	for _, l := range splitLines(detection) {
		low := strings.ToLower(l)
		for _, m := range claudeModePhrases {
			if strings.Contains(low, m.phrase) {
				mode = m.canonical
				break
			}
		}
	}
	return mode
}
