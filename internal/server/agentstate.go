package server

import (
	"errors"
	"net/http"
	"strings"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/agentstate"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/transcript"
)

// GET /agent-state?pane=<pane_id> -> a compact, parsed, phone-readable state for
// one agent pane. This is the parsed alternative to WS /attach's raw PTY: instead
// of a full terminal the app gets one JSON struct (headline, detail, and — when
// blocked — the question + choices, pairing with POST /approve).
//
// The bridge stays stateless, and reads from two places by design:
//
//   - The agent's own TRANSCRIPT (internal/transcript) supplies the history —
//     headline, detail, and the recent lines. Structured, already parsed, not
//     truncated by the viewport, and free of side effects.
//   - The pane's CURRENT SCREEN (`herdr agent read --source detection`) supplies
//     the blocked form. That one cannot come from a transcript: a permission or
//     question prompt is UI the agent is drawing right now to ask you something,
//     not conversation, so nothing records it.
//
// Terminal scraping is therefore confined to what only the screen knows. The
// legacy scrollback source is still reachable with `?recent=1` for a kind with
// no transcript reader, at the cost of scrolling the operator's pane — see
// wantRecent.
//
// Parsing never 500s — an unrecognised agent kind degrades to Parsed=false with
// a best-effort raw text dump. Same auth as every other endpoint.
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

	// The live current-state view — the only source for the blocked form, and the
	// fallback for everything else when a kind has no transcript reader. A read
	// failure here is non-fatal: we still return a state from whatever we have, so
	// a momentary hiccup degrades instead of erroring.
	detection, derr := c.ReadText(bare, "detection", 0)
	if derr != nil {
		log.Warn("agent-state: detection read failed", "pane", pane, "err", derr)
	}
	// Off unless asked for — `recent-unwrapped` scrolls the operator's pane. See
	// wantRecent.
	recent, rerr := "", error(nil)
	if wantRecent(r) {
		recent, rerr = c.ReadText(bare, "recent-unwrapped", 80)
	}
	if errors.Is(rerr, herdr.ErrAgentNotIdle) {
		// Expected on a working pane: the unwrapped transcript comes from
		// scrollback, which Herdr will only capture while the agent is idle. Take
		// its hint and fall back to the visible frame — a thinner but live view —
		// instead of polling out a warning per request for the whole turn.
		recent, rerr = c.ReadText(bare, "visible", 80)
	}
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
		History:   agentHistory(c, bare, agent, pane),
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

// agentHistoryEntries is how many recent transcript entries the card reads. Big
// enough that the last assistant message is in there even after a long run of
// tool calls, small enough to stay a cheap read on every poll.
const agentHistoryEntries = 40

// agentHistory reads the tail of the agent's own transcript for the card.
//
// This is the structured alternative to scraping the terminal: already parsed,
// immune to frame furniture, not truncated by the viewport, and — unlike the
// scrollback read it replaces — with no effect on the operator's screen.
//
// Best-effort by design. A kind with no reader, an unresolvable session, or a
// read error all yield nil, and the parser's terminal-derived values stand. The
// card must never fail because a transcript is missing.
func agentHistory(c *herdr.Client, bare string, agent herdr.Agent, pane string) []agentstate.HistoryEntry {
	// Same ambiguity guard as the transcript stream: with no session id and a
	// sibling agent in the same directory, resolution cannot tell the two apart,
	// and a card showing another agent's messages is worse than one showing none.
	if _, ambiguous := siblingSharesCwd(c, bare, agent); ambiguous {
		return nil
	}
	src, err := transcript.Open(agent.Kind, agent.Cwd, agent.SessionID())
	if err != nil {
		// Unsupported kind / no transcript yet is the normal case for some agents,
		// so this is debug-level noise, not a warning.
		return nil
	}
	defer src.Close()

	backlog, err := src.Backlog(agentHistoryEntries)
	if err != nil {
		log.Warn("agent-state: history read failed", "pane", pane, "kind", agent.Kind, "err", err)
		return nil
	}

	out := make([]agentstate.HistoryEntry, 0, len(backlog.Entries))
	for _, e := range backlog.Entries {
		h := agentstate.HistoryEntry{Role: e.Role, Kind: e.Kind, Text: e.Text}
		if e.Tool != nil {
			h.Tool = e.Tool.Name
		}
		out = append(out, h)
	}
	return out
}

// wantRecent reports whether this request wants the scrollback-backed
// `recent-unwrapped` read. It defaults to FALSE and must be asked for with
// `?recent=1`.
//
// The read has a side effect on the operator's machine: Herdr can only capture
// an alternate-screen pane's history by physically scrolling the pane, so every
// call makes that pane jump for whoever is watching it. A polling client turns
// that into continuous movement. Something that disturbs the user's terminal is
// the wrong default — it should be requested deliberately, by a caller that has
// no other way to get history and has decided the trade is worth it.
//
// Nothing in the app asks for it: the chat screen streams the real transcript
// from /agent-transcript, and the activity line wants current state rather than
// history. The blocked question and options come from `detection`, which reads
// the current screen and never scrolls, so the approval path is unaffected
// either way. Opting in costs only extra richness in Detail/Transcript.
func wantRecent(r *http.Request) bool {
	switch strings.ToLower(strings.TrimSpace(r.URL.Query().Get("recent"))) {
	case "1", "true", "yes":
		return true
	}
	return false
}
