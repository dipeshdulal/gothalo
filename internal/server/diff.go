package server

import (
	"net/http"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/gitdiff"
)

// GET /diff?pane=<pane_id> -> the agent's working-tree changes: branch, and
// one entry per changed file with a per-file unified diff. The "Changes"
// review screen — reviewing what an agent has actually done — without
// dropping to the raw terminal and running `git diff` by hand.
//
// Scoped to agent panes: the agent's `cwd` (from `herdr agent get`) is the
// tree gothalo diffs. A pane with no agent, or an agent pane whose cwd isn't
// a git repository, both degrade to an empty file list rather than erroring —
// "nothing to review" is a normal state, not a failure.
func (s *Server) handleDiff(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}
	cwd, status, err := s.paneCwd(pane)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}

	result, err := gitdiff.Collect(cwd)
	if err != nil {
		log.Warn("diff: collect failed", "pane", pane, "cwd", cwd, "err", err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	writeJSON(w, result)
}
