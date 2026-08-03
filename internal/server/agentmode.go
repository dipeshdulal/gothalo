package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/agentstate"
	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// modeReadbackAttempts / modeReadbackInterval bound the best-effort read-back of
// the new mode after a cycle. Claude's TUI redraws the footer a beat after the
// keystroke lands, so we poll the detection frame a few times (≈1s total) for the
// mode to change. This is only a convenience field on the response — the app's
// authoritative flow is still "cycle → re-fetch /agent-state" (see the contract),
// so a miss here is fine: we just omit permission_mode.
const (
	modeReadbackAttempts = 6
	modeReadbackInterval = 180 * time.Millisecond
)

// POST /agent-mode/cycle {"pane":"wN:p2"} -> advance a Claude pane's permission
// mode by one Shift+Tab (default -> acceptEdits -> plan -> …), the mobile app's
// remote of the key an operator would press at the keyboard.
//
// It is Claude-specific: the mode concept only exists for Claude's TUI, so a
// non-Claude pane returns 409 ("mode switching not supported for this agent
// kind") rather than blindly injecting a keystroke another agent wouldn't
// understand. On success it sends the CSI Z sequence over the existing send path
// (herdr.CyclePermissionMode) and returns 200. As a convenience it then polls the
// live footer bar briefly and, if the mode visibly changed, echoes the new
// permission_mode; the app should still re-fetch /agent-state for the
// authoritative value. Same auth as every other endpoint.
func (s *Server) handleAgentModeCycle(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "use POST", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Pane string `json:"pane"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Pane == "" {
		http.Error(w, "want {pane}", http.StatusBadRequest)
		return
	}

	c, _, pane, err := s.target(body.Pane)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}
	agent, err := c.Get(pane)
	if err != nil {
		if errors.Is(err, herdr.ErrAgentNotFound) {
			http.Error(w, "no such agent", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	// Kind guard: only Claude has a Shift+Tab permission mode. Everything else
	// degrades to a clean 409 the app can show, never a stray keystroke.
	if !agentstate.ModeSupported(agent.Kind) {
		http.Error(w, "mode switching not supported for this agent kind: "+agent.Kind, http.StatusConflict)
		return
	}

	// Read the current mode first so the read-back can tell when the cycle landed.
	before := readPermissionMode(c, pane, agent.Kind)

	if err := c.CyclePermissionMode(pane); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	log.Info("cycled agent mode", "pane", body.Pane, "kind", agent.Kind, "from", before)

	newMode := pollModeChange(c, pane, agent.Kind, before)

	s.publish(events.TypeModeCycled, map[string]any{"pane": body.Pane, "permission_mode": newMode})

	out := map[string]any{"ok": true, "cycled": true}
	if newMode != "" {
		out["permission_mode"] = newMode
	}
	writeJSON(w, out)
}

// readPermissionMode reads a pane's live permission mode from its detection frame,
// returning "" on any read failure or when the pane has no mode footer (so the
// caller degrades gracefully).
func readPermissionMode(c *herdr.Client, pane, kind string) string {
	detection, err := c.ReadText(pane, "detection", 0)
	if err != nil {
		return ""
	}
	return agentstate.PermissionMode(kind, detection)
}

// pollModeChange waits briefly for the footer to redraw after a cycle and returns
// the new mode once it differs from before (or the first non-empty mode when
// before was unknown). It returns "" if nothing changed within the window — the
// signal to omit permission_mode and let the app re-fetch /agent-state.
func pollModeChange(c *herdr.Client, pane, kind, before string) string {
	for i := 0; i < modeReadbackAttempts; i++ {
		time.Sleep(modeReadbackInterval)
		m := readPermissionMode(c, pane, kind)
		if m != "" && m != before {
			return m
		}
	}
	return ""
}
