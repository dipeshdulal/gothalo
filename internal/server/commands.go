package server

import (
	"errors"
	"net/http"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/commands"
)

// commandsResponse is the GET /commands payload. AgentKind is echoed so a client
// that caches per pane can tell WHY the list is empty — an agent kind with no
// known command surface reads differently from a claude pane with nothing
// installed, even though both send zero commands.
type commandsResponse struct {
	Pane      string             `json:"pane"`
	AgentKind string             `json:"agent_kind"`
	Commands  []commands.Command `json:"commands"`
}

// GET /commands?pane=<pane_id> -> the slash commands the agent in that pane will
// accept, for the composer's typeahead.
//
// Read-only and cheap: a walk of at most four .claude directories plus a static
// built-in list, with no Herdr call beyond resolving the pane and no agent
// process touched. Cheap enough that the app refetches on screen open rather
// than caching across sessions, which keeps a command added on the desktop
// visible on the phone within one screen open. Not cached server-side for the
// same reason — a cache would be the only thing standing between a new file and
// the typeahead.
//
// An unknown or unsupported agent kind is **200 with an empty list**, not an
// error. "This agent has no typeahead" is a normal answer, and making it a 404
// would put an error state in front of the user for a pane that is working fine.
// The one genuine failure — the pane does not exist — keeps its 404.
func (s *Server) handleCommands(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}

	// Resolve the agent for its kind AND cwd: the kind picks the lister, the cwd
	// is where project-scoped commands live. paneCwd would give only half of it.
	agent, status, err := s.paneAgent(pane)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}

	list, err := commands.List(agent.Kind, agent.Cwd)
	switch {
	case errors.Is(err, commands.ErrUnsupportedKind):
		// Expected for any agent kind without a lister. Not logged as a warning:
		// it is the steady state for those panes, and a per-fetch warning would
		// be pure noise in the bridge log.
		list = nil
	case err != nil:
		// A discovery failure (an unreadable home directory) should not cost the
		// user their composer. Log it and answer with what a pane with no
		// commands would get.
		log.Warn("commands: discovery failed", "pane", pane, "kind", agent.Kind,
			"cwd", agent.Cwd, "err", err)
		list = nil
	}

	if list == nil {
		list = []commands.Command{}
	}
	writeJSON(w, commandsResponse{
		Pane:      pane,
		AgentKind: agent.Kind,
		Commands:  list,
	})
}
