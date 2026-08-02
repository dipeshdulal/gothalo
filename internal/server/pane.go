package server

import (
	"encoding/json"
	"net/http"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// herdrStatus maps a herdr CLI error to an HTTP status: a resolution failure
// (unknown pane/tab/workspace) is a 404, anything else a 502 (herdr unreachable
// or misbehaving). Used by the pane endpoints and the attach lookup.
func herdrStatus(err error) int {
	if herdr.IsNotFound(err) {
		return http.StatusNotFound
	}
	return http.StatusBadGateway
}

// POST /pane/new — create a terminal and return its identity so the app can
// immediately GET /attach to it. Two modes, picked by the body:
//
//	{"split_from":"<pane>", "direction"?:"right|down", "cwd"?, "command"?}
//	    → split an existing pane (adds a pane to that pane's tab)
//	{"workspace_id":"<ws>", "cwd"?, "label"?, "command"?}
//	    → open a new tab in the workspace (its root pane)
//
// split_from wins if both are present. When command is set it is typed and run
// in the new pane. Response: {pane_id, tab_id, workspace_id}.
func (s *Server) handlePaneNew(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	var body struct {
		WorkspaceID string `json:"workspace_id"`
		TabID       string `json:"tab_id"`     // reserved; use split_from to target a tab
		SplitFrom   string `json:"split_from"` // pane id to split
		Direction   string `json:"direction"`  // "right" | "down" (split only)
		CWD         string `json:"cwd"`
		Label       string `json:"label"` // new-tab label (new tab only)
		Command     string `json:"command"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "want {split_from} or {workspace_id}", http.StatusBadRequest)
		return
	}

	var (
		pane herdr.Pane
		err  error
	)
	switch {
	case body.SplitFrom != "":
		pane, err = s.herdr.SplitPane(body.SplitFrom, body.Direction, body.CWD)
	case body.WorkspaceID != "":
		pane, err = s.herdr.CreateTab(body.WorkspaceID, body.CWD, body.Label)
	default:
		http.Error(w, "want {split_from} or {workspace_id}", http.StatusBadRequest)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	// The pane exists now; a command failure must not lose its id (the app still
	// wants to attach), so it is logged, not surfaced as an error.
	if body.Command != "" {
		if e := s.herdr.RunInPane(pane.PaneID, body.Command); e != nil {
			log.Error("pane/new: run command failed", "pane", pane.PaneID, "err", e)
		}
	}

	log.Info("created pane", "pane", pane.PaneID, "tab", pane.TabID, "workspace", pane.Workspace)
	writeJSON(w, map[string]string{
		"pane_id":      pane.PaneID,
		"tab_id":       pane.TabID,
		"workspace_id": pane.Workspace,
	})
}

// POST /pane/close {"pane_id":"..."} — close a pane. Closing a tab's last pane
// closes the tab too (Herdr's own behaviour).
func (s *Server) handlePaneClose(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	var body struct {
		PaneID string `json:"pane_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.PaneID == "" {
		http.Error(w, "want {pane_id}", http.StatusBadRequest)
		return
	}
	if err := s.herdr.ClosePane(body.PaneID); err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}
	log.Info("closed pane", "pane", body.PaneID)
	writeJSON(w, map[string]any{"closed": true, "pane_id": body.PaneID})
}
