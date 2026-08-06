package server

import (
	"net/http"
	"strconv"

	"github.com/dipeshdulal/gothalo/internal/timeline"
)

// GET /timeline?limit=<n>&pane=<pane_id> -> the recent agent-activity log,
// newest first: one entry per status transition, each carrying how long the
// agent spent in the status it just left.
//
// This is the one read surface that answers a question about the PAST. Every
// other endpoint describes the present, which is why none of them can tell you
// whether an agent blocked fifty minutes ago or ten seconds ago — the status is
// the same either way. See internal/timeline for what is recorded and why.
//
// Purely a read of an in-memory ring: no Herdr call, so it stays cheap enough to
// poll and still answers while Herdr is down (which is exactly when a client
// most wants to see what happened before things went quiet). Same bearer auth as
// every other endpoint.
func (s *Server) handleTimeline(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if s.timeline == nil {
		http.Error(w, "timeline not enabled", http.StatusServiceUnavailable)
		return
	}
	limit, ok := timelineLimit(r)
	if !ok {
		http.Error(w, "limit must be a positive integer", http.StatusBadRequest)
		return
	}
	writeJSON(w, map[string]any{
		"entries": s.timeline.Entries(limit, r.URL.Query().Get("pane")),
		"limit":   limit,
	})
}

// timelineLimit reads ?limit, defaulting when absent and clamping when too
// large. A malformed value is rejected rather than silently defaulted: a client
// that asked for something specific and got a different page size back would
// have no way to notice.
func timelineLimit(r *http.Request) (int, bool) {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return timeline.DefaultLimit, true
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return 0, false
	}
	return min(n, timeline.MaxLimit), true
}
