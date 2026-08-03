package server

import (
	"errors"
	"net/http"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/agentstate"
	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// GET /agent-state?pane=<pane_id> -> a compact, parsed, phone-readable state for
// one agent pane. This is the parsed alternative to WS /attach's raw PTY: instead
// of a full terminal the app gets one JSON struct (headline, detail, and — when
// blocked — the question + choices, pairing with POST /approve).
//
// The bridge stays stateless: it reads the pane's status via `herdr agent get`
// and its terminal text via `herdr agent read`, hands both to the per-kind parser
// registry (claude today; codex/opencode next), and returns the common contract.
// Parsing never 500s — an unrecognised agent kind degrades to Parsed=false with a
// best-effort raw text dump. Same auth as every other endpoint.
func (s *Server) handleAgentState(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}
	c, _, bare, err := s.target(pane)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	agent, err := c.Get(bare)
	if err != nil {
		if errors.Is(err, herdr.ErrAgentNotFound) {
			http.Error(w, "no such agent", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	// The two text snapshots the parsers work from. detection is the live
	// current-state view (best for the blocker form); recent-unwrapped is the
	// unwrapped recent transcript (best for the last assistant message). A read
	// failure here is non-fatal: we still return a state from whatever we have,
	// so a momentary read hiccup degrades instead of erroring.
	detection, derr := c.ReadText(bare, "detection", 0)
	if derr != nil {
		log.Warn("agent-state: detection read failed", "pane", pane, "err", derr)
	}
	recent, rerr := c.ReadText(bare, "recent-unwrapped", 80)
	if rerr != nil {
		log.Warn("agent-state: recent read failed", "pane", pane, "err", rerr)
	}

	state := agentstate.Build(agentstate.Input{
		PaneID:    pane,
		Kind:      agent.Kind,
		Status:    agent.Status,
		Title:     agent.Title,
		Detection: detection,
		Recent:    recent,
	})

	// Enrich a block with Herdr's own detection category (agent.explain): the
	// semantic class — tool_approval / question_panel / dangerous_command_approval
	// / write_file_approval — with NO per-agent plugin, for any agent Herdr
	// detects. Best-effort: a failure just omits the category.
	if state.AgentStatus == "blocked" {
		if det, eerr := c.Explain(bare); eerr != nil {
			log.Warn("agent-state: explain failed", "pane", pane, "err", eerr)
		} else if det != nil && det.RuleID != "" {
			if state.Blocked == nil {
				state.Blocked = &agentstate.Blocked{}
			}
			state.Blocked.Category = det.RuleID
		}
	}

	writeJSON(w, state)
}
