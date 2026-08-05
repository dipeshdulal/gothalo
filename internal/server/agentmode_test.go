package server

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/store"
	"github.com/dipeshdulal/gothalo/internal/timeline"
)

// newTestServer builds a Server wired with a real store and admin token but a
// herdr client that is never reached on the auth/validation paths under test
// (those return before any herdr call). Enough to exercise the guards that don't
// need a live pane; the kind guard itself is unit-tested via
// agentstate.ModeSupported.
func newTestServer(t *testing.T) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "devices.json"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	cfg := &config.Config{AdminToken: "admin-tok"}
	return New(cfg, herdr.NewManager(nil), nil, st, nil, nil, nil, timeline.Open(filepath.Join(t.TempDir(), "timeline.json")))
}

// TestAgentModeCycleAuth asserts the endpoint rejects unauthenticated callers
// before it ever touches herdr — same auth model as every other endpoint.
func TestAgentModeCycleAuth(t *testing.T) {
	s := newTestServer(t)
	cases := []struct {
		name   string
		header string
	}{
		{"no-token", ""},
		{"bad-token", "Bearer nope"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/agent-mode/cycle", strings.NewReader(`{"pane":"wN:p1"}`))
			if c.header != "" {
				req.Header.Set("Authorization", c.header)
			}
			rec := httptest.NewRecorder()
			s.handleAgentModeCycle(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Errorf("status = %d, want 401", rec.Code)
			}
		})
	}
}

// TestAgentModeCycleValidation covers the request-shape guards that run after auth
// but before any herdr call: wrong method and a missing pane.
func TestAgentModeCycleValidation(t *testing.T) {
	s := newTestServer(t)
	auth := func(r *http.Request) { r.Header.Set("Authorization", "Bearer admin-tok") }

	t.Run("wrong-method", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/agent-mode/cycle", nil)
		auth(req)
		rec := httptest.NewRecorder()
		s.handleAgentModeCycle(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("status = %d, want 405", rec.Code)
		}
	})

	t.Run("missing-pane", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/agent-mode/cycle", strings.NewReader(`{}`))
		auth(req)
		rec := httptest.NewRecorder()
		s.handleAgentModeCycle(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", rec.Code)
		}
	})
}
