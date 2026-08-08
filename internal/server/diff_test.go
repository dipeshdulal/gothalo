package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/gitdiff"
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

// expandRequest builds an authenticated GET for the context-expansion endpoint.
func expandRequest(url string) *http.Request {
	req := httptest.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer admin-tok")
	return req
}

func TestDiffExpandAuth(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/diff/expand?pane=wN:p1&path=a.go&start=1&count=5", nil)
	rec := httptest.NewRecorder()
	s.handleDiffExpand(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

// Both request-shape guards run before any herdr call, so neither needs an
// agent to exist.
func TestDiffExpandMissingParams(t *testing.T) {
	s := newTestServer(t)
	for _, url := range []string{"/diff/expand", "/diff/expand?pane=wN:p1", "/diff/expand?path=a.go"} {
		rec := httptest.NewRecorder()
		s.handleDiffExpand(rec, expandRequest(url))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status = %d, want 400", url, rec.Code)
		}
	}
}

func TestDiffExpandServesFileLines(t *testing.T) {
	cwd := t.TempDir()
	if err := os.WriteFile(filepath.Join(cwd, "a.go"), []byte("one\ntwo\nthree\nfour\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := newTestServer(t)
	s.agents = &fakeAgents{cwd: cwd}

	rec := httptest.NewRecorder()
	s.handleDiffExpand(rec, expandRequest("/diff/expand?pane=wN:p1&path=a.go&start=2&count=2"))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var got gitdiff.Expansion
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v (body %s)", err, rec.Body.String())
	}
	if got.Start != 2 || len(got.Lines) != 2 || got.Lines[0] != "two" || got.Lines[1] != "three" {
		t.Errorf("got %+v, want lines two/three at start 2", got)
	}
	if got.Total != 4 || got.EOF {
		t.Errorf("got total=%d eof=%v, want 4 and not-at-EOF", got.Total, got.EOF)
	}
}

// The refusal statuses the app codes against — each maps to its own gitdiff
// sentinel rather than one catch-all error.
func TestDiffExpandRefusals(t *testing.T) {
	cwd := t.TempDir()
	if err := os.WriteFile(filepath.Join(cwd, "bin"), []byte{0xff, 0xfe, 0x00}, 0o600); err != nil {
		t.Fatal(err)
	}
	s := newTestServer(t)
	s.agents = &fakeAgents{cwd: cwd}

	cases := []struct {
		name string
		url  string
		want int
	}{
		{"traversal", "/diff/expand?pane=wN:p1&path=../escape.txt&start=1&count=1", http.StatusBadRequest},
		{"missing file", "/diff/expand?pane=wN:p1&path=nope.go&start=1&count=1", http.StatusNotFound},
		{"binary file", "/diff/expand?pane=wN:p1&path=bin&start=1&count=1", http.StatusUnsupportedMediaType},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			s.handleDiffExpand(rec, expandRequest(c.url))
			if rec.Code != c.want {
				t.Errorf("status = %d, want %d: %s", rec.Code, c.want, rec.Body.String())
			}
		})
	}
}

// TestDiffContextOnly covers the narrowed read behind the app's "Create PR"
// gate: the `git` object is populated and `files` is present-but-empty, even
// though the tree has a change the full response would have listed.
func TestDiffContextOnly(t *testing.T) {
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"config", "user.email", "test@example.com"},
		{"config", "user.name", "Test"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	// A change the FULL response would have listed, so "files is empty" below
	// means "context mode skipped the diff" and not "there was nothing to say".
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("hi\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	s := newTestServer(t)
	s.agents = &fakeAgents{cwd: dir}
	req := httptest.NewRequest(http.MethodGet, "/diff?pane=wN:p1&context=1", nil)
	req.Header.Set("Authorization", "Bearer admin-tok")
	rec := httptest.NewRecorder()
	s.handleDiff(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var got gitdiff.Result
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v (body %s)", err, rec.Body.String())
	}
	if !got.Git.Repo {
		t.Errorf("git.repo = false, want true for a real repo")
	}
	if got.Git.Branch != "main" || got.Branch != "main" {
		t.Errorf("branch = %q / git.branch = %q, want main", got.Branch, got.Git.Branch)
	}
	if got.Files == nil {
		t.Errorf("files = null, want an empty array — the narrowed response keeps the full shape")
	}
	if len(got.Files) != 0 {
		t.Errorf("files = %+v, want none in context mode", got.Files)
	}
	if !got.Git.Dirty {
		t.Errorf("git.dirty = false with an untracked file present, want true")
	}
}

// TestDiffContextFlag pins which spellings narrow the response — anything but
// "1"/"true" must still return the full diff.
func TestDiffContextFlag(t *testing.T) {
	for _, value := range []string{"1", "true", "", "0", "yes", "on"} {
		req := httptest.NewRequest(http.MethodGet, "/diff?pane=p&context="+value, nil)
		want := value == "1" || value == "true"
		if got := contextOnly(req); got != want {
			t.Errorf("contextOnly(context=%q) = %v, want %v", value, got, want)
		}
	}
}
