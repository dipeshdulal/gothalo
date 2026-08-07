package server

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
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

// agentGetter is the single herdr call paneCwd needs. *herdr.Client satisfies
// it; tests substitute a fake (Server.agents) so the whole pane -> cwd path,
// including the session-qualified "<session>/<pane>" form, is exercisable
// without a live Herdr socket. Same seam shape as Server.requester for /herdr.
type agentGetter interface {
	Get(pane string) (herdr.Agent, error)
}

// paneCwd resolves a possibly session-qualified pane id ("acme/w1:p2") to the
// working directory of the agent hosted in it, plus the status to report if it
// cannot.
//
// This is deliberately ONE resolution shared by every endpoint that needs a
// pane's tree — GET /diff and POST /image today. They must agree: an image
// written somewhere /diff wouldn't look is an image the agent can't read, and
// two copies of "which directory is this pane in?" is exactly the kind of drift
// that produces that. Scoped to agent panes, since a plain shell pane has no
// agent cwd to resolve -> 404.
func (s *Server) paneCwd(id string) (string, int, error) {
	agent, status, err := s.paneAgent(id)
	if err != nil {
		return "", status, err
	}
	return agent.Cwd, http.StatusOK, nil
}

// paneGetter is the single herdr call paneDropCwd needs when no agent answers.
// *herdr.Client satisfies it; tests substitute a fake (Server.panes), the same
// seam shape as agentGetter above.
type paneGetter interface {
	GetPane(paneID string) (herdr.Pane, error)
}

// paneDropCwd resolves a pane id to the directory POST /image writes into: the
// agent's cwd when the pane hosts one, otherwise the pane's own cwd.
//
// Deliberately wider than paneCwd, which stays agent-only for /diff. An image
// drop needs somewhere the *path it returns* makes sense from, and every pane
// has that — the terminal screen attaches to plain panes too, and typing a path
// into a shell (or into a program Herdr doesn't recognise as an agent) is just
// as useful as typing it into Claude. /diff is a different question: it asks
// what an agent changed, and a pane with no agent has no answer.
//
// The pane's cwd, not its foreground_cwd: the drop directory should stay put
// while the shell wanders, so retention keeps sweeping one place.
func (s *Server) paneDropCwd(id string) (string, int, error) {
	cwd, status, err := s.paneCwd(id)
	if err == nil {
		return cwd, status, nil
	}
	// Anything other than "no agent in this pane" (an unknown session, a herdr
	// failure) is the real answer — only fall through for the agentless case.
	if status != http.StatusNotFound {
		return "", status, err
	}

	session, bare := herdr.SplitTarget(id)
	var g paneGetter = s.panes
	if g == nil {
		c, cerr := s.sessions.Client(session)
		if cerr != nil {
			return "", herdrStatus(cerr), cerr
		}
		g = c
	}
	pane, perr := g.GetPane(bare)
	if perr != nil {
		return "", herdrStatus(perr), perr
	}
	if pane.Cwd == "" {
		// A pane Herdr knows but reports no directory for: there is nowhere to
		// put the file, and inventing one (a temp dir, the bridge's own cwd)
		// would hand back a path nothing in that pane can use.
		return "", http.StatusNotFound, errors.New("pane has no working directory")
	}
	return pane.Cwd, http.StatusOK, nil
}

// paneAgent is paneCwd's resolution step, returning the whole agent rather than
// just its cwd — for callers that also need the KIND, like GET /commands, where
// the kind picks the lister and the cwd says where to look.
//
// Split out rather than copied so there stays exactly one answer to "which agent
// is in this pane?", including the session-qualified form and the s.agents test
// seam. Errors carry the HTTP status to report, same contract as paneCwd.
func (s *Server) paneAgent(id string) (herdr.Agent, int, error) {
	session, bare := herdr.SplitTarget(id)
	var g agentGetter = s.agents
	if g == nil {
		c, err := s.sessions.Client(session)
		if err != nil {
			return herdr.Agent{}, herdrStatus(err), err
		}
		g = c
	}
	agent, err := g.Get(bare)
	if err != nil {
		if errors.Is(err, herdr.ErrAgentNotFound) {
			return herdr.Agent{}, http.StatusNotFound, errors.New("no such agent")
		}
		return herdr.Agent{}, http.StatusBadGateway, err
	}
	return agent, http.StatusOK, nil
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

	// Both target forms may carry a session prefix; the new pane lands in (and is
	// addressed back with) that session.
	var (
		pane    herdr.Pane
		session string
		err     error
	)
	switch {
	case body.SplitFrom != "":
		var c *herdr.Client
		var bare string
		if c, session, bare, err = s.target(body.SplitFrom); err == nil {
			pane, err = c.SplitPane(bare, body.Direction, body.CWD)
		}
	case body.WorkspaceID != "":
		var c *herdr.Client
		var bare string
		if c, session, bare, err = s.target(body.WorkspaceID); err == nil {
			pane, err = c.CreateTab(bare, body.CWD, body.Label)
		}
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
		c, _ := s.sessions.Client(session)
		if e := c.RunInPane(pane.PaneID, body.Command); e != nil {
			log.Error("pane/new: run command failed", "pane", pane.PaneID, "err", e)
		}
	}

	paneID := herdr.Qualify(session, pane.PaneID)
	tabID := herdr.Qualify(session, pane.TabID)
	workspaceID := herdr.Qualify(session, pane.Workspace)
	log.Info("created pane", "pane", paneID, "tab", tabID, "workspace", workspaceID)
	// gothalo.pane_created marks an APP-initiated pane (distinct from Herdr's own
	// pane_created, which fires for every pane however created).
	s.publish(events.TypeGothaloPaneCreated, map[string]any{
		"pane_id":      paneID,
		"tab_id":       tabID,
		"workspace_id": workspaceID,
	})
	writeJSON(w, map[string]string{
		"pane_id":      paneID,
		"tab_id":       tabID,
		"workspace_id": workspaceID,
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
	c, _, bare, err := s.target(body.PaneID)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}
	if err := c.ClosePane(bare); err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}
	log.Info("closed pane", "pane", body.PaneID)
	s.publish(events.TypeGothaloPaneClosed, map[string]any{"pane_id": body.PaneID})
	writeJSON(w, map[string]any{"closed": true, "pane_id": body.PaneID})
}
