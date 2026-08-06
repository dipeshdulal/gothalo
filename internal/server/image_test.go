package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/imagedrop"
)

// fakeAgents stands in for the per-session herdr client on the pane -> cwd path
// (Server.agents). It records the id it was asked for, which is how the
// session-qualified-id test proves the "<session>/" prefix was stripped before
// the lookup rather than passed through to Herdr.
type fakeAgents struct {
	cwd   string
	asked string
	err   error
}

func (f *fakeAgents) Get(pane string) (herdr.Agent, error) {
	f.asked = pane
	if f.err != nil {
		return herdr.Agent{}, f.err
	}
	return herdr.Agent{PaneID: pane, Cwd: f.cwd}, nil
}

func pngUpload() []byte {
	return append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, 64)...)
}

func imageRequest(target string, body []byte) *http.Request {
	req := httptest.NewRequest(http.MethodPost, target, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-tok")
	return req
}

// TestImageAuth asserts the endpoint rejects unauthenticated callers before it
// reads a single byte of the upload — same auth model as every other endpoint.
func TestImageAuth(t *testing.T) {
	s := newTestServer(t)
	for _, header := range []string{"", "Bearer nope"} {
		req := httptest.NewRequest(http.MethodPost, "/image?pane=wN:p1", bytes.NewReader(pngUpload()))
		if header != "" {
			req.Header.Set("Authorization", header)
		}
		rec := httptest.NewRecorder()
		s.handleImage(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("header %q: status = %d, want 401", header, rec.Code)
		}
	}
}

// TestImageRequestGuards covers the request-shape checks that run after auth but
// before any herdr call — including the two that keep junk out of a repo.
func TestImageRequestGuards(t *testing.T) {
	cases := []struct {
		name   string
		method string
		target string
		body   []byte
		want   int
	}{
		{"wrong-method", http.MethodGet, "/image?pane=wN:p1", nil, http.StatusMethodNotAllowed},
		{"missing-pane", http.MethodPost, "/image", pngUpload(), http.StatusBadRequest},
		{"empty-body", http.MethodPost, "/image?pane=wN:p1", nil, http.StatusBadRequest},
		{"not-an-image", http.MethodPost, "/image?pane=wN:p1", []byte("#!/bin/sh\nrm -rf /\n"), http.StatusUnsupportedMediaType},
		{"too-large", http.MethodPost, "/image?pane=wN:p1",
			append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, imagedrop.MaxBytes)...),
			http.StatusRequestEntityTooLarge},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTestServer(t)
			// A fake agent is wired so a guard that failed to fire would write a
			// file rather than silently 502 — the failure stays visible.
			s.agents = &fakeAgents{cwd: t.TempDir()}
			req := httptest.NewRequest(c.method, c.target, bytes.NewReader(c.body))
			req.Header.Set("Authorization", "Bearer admin-tok")
			rec := httptest.NewRecorder()
			s.handleImage(rec, req)
			if rec.Code != c.want {
				t.Errorf("status = %d, want %d (%s)", rec.Code, c.want, rec.Body.String())
			}
		})
	}
}

// TestImageSizeCapBoundary pins the cap where the two guards meet. The handler
// reads MaxBytes+1 through a LimitReader, so an upload of exactly MaxBytes must
// come back whole (and be accepted) while one byte more must be refused — an
// off-by-one in that reader would silently truncate a legal upload into a
// corrupt image rather than fail loudly.
func TestImageSizeCapBoundary(t *testing.T) {
	png := func(n int) []byte {
		return append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, n-8)...)
	}
	cases := []struct {
		name string
		size int
		want int
	}{
		{"at-the-cap", imagedrop.MaxBytes, http.StatusOK},
		{"one-over", imagedrop.MaxBytes + 1, http.StatusRequestEntityTooLarge},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTestServer(t)
			s.agents = &fakeAgents{cwd: t.TempDir()}
			rec := httptest.NewRecorder()
			s.handleImage(rec, imageRequest("/image?pane=w1:p2", png(c.size)))
			if rec.Code != c.want {
				t.Fatalf("status = %d, want %d (%s)", rec.Code, c.want, rec.Body.String())
			}
			if c.want != http.StatusOK {
				return
			}
			var res imagedrop.Result
			if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
				t.Fatalf("decode: %v", err)
			}
			if res.Bytes != c.size {
				t.Errorf("stored %d bytes, want %d — the body was truncated", res.Bytes, c.size)
			}
		})
	}
}

// TestImageOversizedIsRefusedUnread asserts the declared-length guard fires
// before the body is buffered: a Content-Length past the cap is a 413 without
// the bridge reading (and holding in memory) whatever the phone was sending.
func TestImageOversizedIsRefusedUnread(t *testing.T) {
	s := newTestServer(t)
	s.agents = &fakeAgents{cwd: t.TempDir()}

	body := &countingReader{Reader: bytes.NewReader(pngUpload())}
	req := httptest.NewRequest(http.MethodPost, "/image?pane=w1:p2", body)
	req.Header.Set("Authorization", "Bearer admin-tok")
	req.ContentLength = imagedrop.MaxBytes + 1

	rec := httptest.NewRecorder()
	s.handleImage(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413 (%s)", rec.Code, rec.Body.String())
	}
	if body.n != 0 {
		t.Errorf("read %d bytes of an over-cap body, want 0", body.n)
	}
}

// countingReader records how much of a request body a handler actually consumed.
type countingReader struct {
	io.Reader
	n int
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.Reader.Read(p)
	c.n += n
	return n, err
}

// TestImageWritesIntoAgentCwd is the happy path: the bytes land inside the
// agent's own tree and the response hands back the absolute path the app types
// into the composer.
func TestImageWritesIntoAgentCwd(t *testing.T) {
	s := newTestServer(t)
	cwd := t.TempDir()
	s.agents = &fakeAgents{cwd: cwd}

	rec := httptest.NewRecorder()
	s.handleImage(rec, imageRequest("/image?pane=w1:p2", pngUpload()))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}

	var res imagedrop.Result
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if res.ContentType != "image/png" {
		t.Errorf("content_type = %q", res.ContentType)
	}
	wantDir := filepath.Join(cwd, ".gothalo", "images")
	if filepath.Dir(res.Path) != wantDir {
		t.Fatalf("path = %q, want a file in %q", res.Path, wantDir)
	}
	if _, err := os.Stat(res.Path); err != nil {
		t.Errorf("returned path does not exist: %v", err)
	}
}

// TestImageSessionQualifiedPane asserts the endpoint resolves a
// "<session>/<pane>" id the same way /diff does: the prefix picks the session
// and is stripped before the agent lookup, never forwarded to Herdr as part of
// the pane id.
func TestImageSessionQualifiedPane(t *testing.T) {
	s := newTestServer(t)
	agents := &fakeAgents{cwd: t.TempDir()}
	s.agents = agents

	rec := httptest.NewRecorder()
	s.handleImage(rec, imageRequest("/image?pane=acme%2Fw1:p2", pngUpload()))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	if agents.asked != "w1:p2" {
		t.Errorf("herdr was asked for %q, want the bare id %q", agents.asked, "w1:p2")
	}
}

// TestImageUnknownSession exercises the production resolution path (no test
// seam): an id naming a session this bridge has no client for is a 404, not a
// 502 or a write into the wrong tree.
func TestImageUnknownSession(t *testing.T) {
	s := newTestServer(t)
	rec := httptest.NewRecorder()
	s.handleImage(rec, imageRequest("/image?pane=nosuch%2Fw1:p2", pngUpload()))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404 (%s)", rec.Code, rec.Body.String())
	}
}

// TestImageNoAgentInPane asserts a plain (non-agent) pane 404s: there is no cwd
// to resolve, so there is nowhere the image could land that the agent would read.
func TestImageNoAgentInPane(t *testing.T) {
	s := newTestServer(t)
	s.agents = &fakeAgents{err: herdr.ErrAgentNotFound}
	rec := httptest.NewRecorder()
	s.handleImage(rec, imageRequest("/image?pane=w1:p9", pngUpload()))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404 (%s)", rec.Code, rec.Body.String())
	}
}

// TestImageIgnoresClientSuppliedName is the traversal guard. The endpoint takes
// raw bytes and a pane — deliberately no filename — so nothing a client sends
// can steer where the file lands or what it is called. This asserts that
// property end to end: filename-ish parameters and a Content-Disposition header
// full of "../" leave the written path inside the agent's drop directory, with a
// bridge-generated name and a sniffed extension.
func TestImageIgnoresClientSuppliedName(t *testing.T) {
	s := newTestServer(t)
	cwd := t.TempDir()
	s.agents = &fakeAgents{cwd: cwd}

	req := imageRequest(
		"/image?pane=w1:p2&name=..%2F..%2F..%2Fetc%2Fpwn.sh&filename=..%2F..%2Fevil.png",
		pngUpload(),
	)
	req.Header.Set("Content-Disposition", `attachment; filename="../../../../tmp/pwn.png"`)
	req.Header.Set("Content-Type", "application/x-sh")
	rec := httptest.NewRecorder()
	s.handleImage(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}

	var res imagedrop.Result
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatalf("decode: %v", err)
	}
	dropDir := filepath.Join(cwd, ".gothalo", "images")
	clean := filepath.Clean(res.Path)
	if !strings.HasPrefix(clean, dropDir+string(filepath.Separator)) {
		t.Fatalf("path %q escaped %q", clean, dropDir)
	}
	if strings.Contains(res.Path, "pwn") || strings.Contains(res.Path, "evil") {
		t.Errorf("client-supplied name leaked into %q", res.Path)
	}
	// The declared Content-Type was a shell script; the sniffed one wins.
	if res.ContentType != "image/png" || filepath.Ext(res.Path) != ".png" {
		t.Errorf("client Content-Type influenced the result: %q %q", res.ContentType, res.Path)
	}
}
