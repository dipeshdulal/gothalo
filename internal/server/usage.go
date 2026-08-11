package server

import (
	"encoding/json"
	"net/http"
	"time"
)

// GET /usage returns live provider quota data gathered on this bridge's host.
// Providers that are not installed or authenticated are represented as
// unavailable, allowing the app to omit their cards without treating absence as
// an error. No credential or raw provider response crosses this boundary.
func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodGet {
		writeJSON(w, map[string]string{"error": "GET only"})
		return
	}
	if s.usage == nil {
		writeJSON(w, map[string]any{"claude": map[string]any{"available": false}})
		return
	}
	result := s.usage.FetchClaude(r.Context())
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"fetched_at": time.Now().UTC().Format(time.RFC3339),
		"claude":     result,
	})
}
