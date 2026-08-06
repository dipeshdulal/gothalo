package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/dipeshdulal/gothalo/internal/timeline"
)

// seedTimeline appends one entry per (pane, status) pair, a minute apart, and
// returns the server holding them. The ring is the handler's only data source —
// no herdr call is involved — so this is the whole fixture.
func seedTimeline(t *testing.T, rows ...[2]string) *Server {
	t.Helper()
	s := newTestServer(t)
	start := time.Now().Add(-time.Duration(len(rows)) * time.Minute)
	for i, r := range rows {
		s.timeline.Append(timeline.Entry{
			TS:   start.Add(time.Duration(i) * time.Minute).UnixMilli(),
			Pane: r[0], Agent: "claude", To: r[1],
		})
	}
	return s
}

// get issues an authenticated GET and returns the recorder.
func get(t *testing.T, s *Server, target string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, target, nil)
	req.Header.Set("Authorization", "Bearer admin-tok")
	rec := httptest.NewRecorder()
	s.handleTimeline(rec, req)
	return rec
}

// decodeEntries unwraps the response body, failing the test on any surprise.
func decodeEntries(t *testing.T, rec *httptest.ResponseRecorder) ([]timeline.Entry, int) {
	t.Helper()
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", rec.Code, rec.Body.String())
	}
	var body struct {
		Entries []timeline.Entry `json:"entries"`
		Limit   int              `json:"limit"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body %q: %v", rec.Body.String(), err)
	}
	return body.Entries, body.Limit
}

// TestTimelineAuth asserts the endpoint rejects unauthenticated callers before
// it reads anything — same auth model as every other endpoint.
func TestTimelineAuth(t *testing.T) {
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
			req := httptest.NewRequest(http.MethodGet, "/timeline", nil)
			if c.header != "" {
				req.Header.Set("Authorization", c.header)
			}
			rec := httptest.NewRecorder()
			s.handleTimeline(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Errorf("status = %d, want 401", rec.Code)
			}
		})
	}
}

// Newest first is the contract: a client renders the response in order and must
// never have to sort it itself.
func TestTimelineNewestFirst(t *testing.T) {
	s := seedTimeline(t,
		[2]string{"w1:p1", "working"},
		[2]string{"w1:p1", "blocked"},
		[2]string{"w1:p2", "idle"},
	)
	entries, limit := decodeEntries(t, get(t, s, "/timeline"))
	if len(entries) != 3 {
		t.Fatalf("len = %d, want 3", len(entries))
	}
	if entries[0].To != "idle" || entries[2].To != "working" {
		t.Errorf("order = %q…%q, want idle…working", entries[0].To, entries[2].To)
	}
	if limit != timeline.DefaultLimit {
		t.Errorf("limit = %d, want the default %d", limit, timeline.DefaultLimit)
	}
}

func TestTimelinePaneFilter(t *testing.T) {
	s := seedTimeline(t,
		[2]string{"w1:p1", "working"},
		[2]string{"acme/w1:p2", "blocked"},
		[2]string{"w1:p1", "idle"},
	)
	entries, _ := decodeEntries(t, get(t, s, "/timeline?pane=acme%2Fw1%3Ap2"))
	if len(entries) != 1 {
		t.Fatalf("len = %d, want 1", len(entries))
	}
	if entries[0].Pane != "acme/w1:p2" {
		t.Errorf("pane = %q, want acme/w1:p2", entries[0].Pane)
	}
}

func TestTimelineLimit(t *testing.T) {
	rows := make([][2]string, 12)
	for i := range rows {
		rows[i] = [2]string{"w1:p1", "working"}
	}
	s := seedTimeline(t, rows...)

	t.Run("honoured", func(t *testing.T) {
		entries, limit := decodeEntries(t, get(t, s, "/timeline?limit=5"))
		if len(entries) != 5 || limit != 5 {
			t.Errorf("len = %d, limit = %d, want 5, 5", len(entries), limit)
		}
	})

	// The cap bounds the RESPONSE, so one request can never be asked to marshal
	// the whole ring — and the echoed limit tells the client what it really got.
	t.Run("clamped to the cap", func(t *testing.T) {
		_, limit := decodeEntries(t, get(t, s, "/timeline?limit=100000"))
		if limit != timeline.MaxLimit {
			t.Errorf("limit = %d, want %d", limit, timeline.MaxLimit)
		}
	})

	// A malformed value is rejected rather than silently defaulted: a client that
	// asked for something specific and got a different page size back would have
	// no way to notice.
	for _, raw := range []string{"abc", "0", "-5", "1.5"} {
		t.Run("rejects "+raw, func(t *testing.T) {
			rec := get(t, s, "/timeline?limit="+raw)
			if rec.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400", rec.Code)
			}
		})
	}
}

// A fresh bridge has recorded nothing yet. That is a normal state, not an error,
// and the body must carry an empty array rather than `null` so a client has one
// shape to parse.
func TestTimelineEmptyIsAnEmptyArray(t *testing.T) {
	s := newTestServer(t)
	rec := get(t, s, "/timeline")
	entries, _ := decodeEntries(t, rec)
	if len(entries) != 0 {
		t.Fatalf("len = %d, want 0", len(entries))
	}
	var body map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if string(body["entries"]) != "[]" {
		t.Errorf("entries = %s, want []", body["entries"])
	}
}

// "No recorder running" and "nothing happened yet" are different answers, and a
// client should be able to tell them apart.
func TestTimelineDisabledReports503(t *testing.T) {
	s := newTestServer(t)
	s.timeline = nil
	rec := get(t, s, "/timeline")
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", rec.Code)
	}
}
