package server

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// confirmKeys maps a Herdr agent kind to the logical key that accepts its
// blocked prompt (D7 — the one bit of per-agent code). Names are what
// `herdr pane send-keys` accepts. Kinds absent here fall back to defaultConfirmKey,
// so an unrecognized agent still gets a sane "press Enter to confirm". Add an
// override only when an agent's confirm key genuinely differs from Enter.
var confirmKeys = map[string]string{
	"claude":   "enter",
	"codex":    "enter",
	"gemini":   "enter",
	"cursor":   "enter",
	"amp":      "enter",
	"opencode": "enter",
}

// defaultConfirmKey is used for any agent kind not in confirmKeys.
const defaultConfirmKey = "enter"

// confirmKeyFor returns the confirm key for an agent kind, defaulting to Enter.
func confirmKeyFor(kind string) string {
	if k, ok := confirmKeys[kind]; ok {
		return k
	}
	return defaultConfirmKey
}

// POST /approve {"agent":"wN:p2","seq":42} -> idempotently confirm a blocked
// agent (D8). It sends the agent's confirm keystroke ONLY if that agent is
// still blocked at the given state_change_seq; otherwise it no-ops and reports
// why. This guard lives here so every approval surface (banner, Live Activity,
// in-app) inherits it — a stale lock-screen tap can't fire a confirm the human
// no longer intends.
func (s *Server) handleApprove(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "use POST", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Agent string `json:"agent"`
		Seq   int    `json:"seq"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Agent == "" {
		http.Error(w, "want {agent,seq}", http.StatusBadRequest)
		return
	}

	// finish publishes the outcome as gothalo.approve_applied and responds. Every
	// approval surface (banner, Live Activity, in-app) goes through /approve, so
	// emitting here means the bus always reflects what an approval actually did.
	finish := func(applied bool, reason string) {
		s.publish(events.TypeApproveApplied, map[string]any{
			"pane": body.Agent, "seq": body.Seq, "applied": applied, "reason": reason,
		})
		respondApprove(w, applied, reason)
	}

	agents, err := s.herdr.Agents()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	var found bool
	for _, a := range agents {
		if a.PaneID != body.Agent {
			continue
		}
		found = true
		if a.Status != "blocked" {
			finish(false, "agent is "+a.Status+", not blocked")
			return
		}
		if a.StateChangeSeq != body.Seq {
			finish(false, "stale seq: approve carried "+strconv.Itoa(body.Seq)+
				", agent now at "+strconv.Itoa(a.StateChangeSeq))
			return
		}
		key := confirmKeyFor(a.Kind)
		if err := s.herdr.SendKeys(body.Agent, key); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		log.Info("approved agent", "agent", body.Agent, "kind", a.Kind, "key", key, "seq", body.Seq)
		finish(true, "")
		return
	}
	if !found {
		finish(false, "no such agent")
	}
}

func respondApprove(w http.ResponseWriter, applied bool, reason string) {
	out := map[string]any{"ok": true, "applied": applied}
	if reason != "" {
		out["reason"] = reason
	}
	writeJSON(w, out)
}
