package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestDiffAuth asserts the endpoint rejects unauthenticated callers before it
// ever touches herdr — same auth model as every other endpoint.
func TestDiffAuth(t *testing.T) {
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
			req := httptest.NewRequest(http.MethodGet, "/diff?pane=wN:p1", nil)
			if c.header != "" {
				req.Header.Set("Authorization", c.header)
			}
			rec := httptest.NewRecorder()
			s.handleDiff(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Errorf("status = %d, want 401", rec.Code)
			}
		})
	}
}

// TestDiffMissingPane covers the request-shape guard that runs after auth but
// before any herdr call.
func TestDiffMissingPane(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/diff", nil)
	req.Header.Set("Authorization", "Bearer admin-tok")
	rec := httptest.NewRecorder()
	s.handleDiff(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rec.Code)
	}
}
