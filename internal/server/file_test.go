package server

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/imagedrop"
)

func pdfUpload() []byte {
	return append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte{0}, 64)...)
}

// docxUpload is a minimal OOXML container: classification reads the zip's
// entry names, so empty parts are enough.
func docxUpload(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for _, name := range []string{"[Content_Types].xml", "word/document.xml"} {
		if _, err := w.Create(name); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func fileRequest(target string, body []byte) *http.Request {
	req := httptest.NewRequest(http.MethodPost, target, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-tok")
	return req
}

// TestFileAuth asserts the endpoint rejects unauthenticated callers before it
// reads a single byte of the upload — same auth model as every other endpoint.
func TestFileAuth(t *testing.T) {
	s := newTestServer(t)
	for _, header := range []string{"", "Bearer nope"} {
		req := httptest.NewRequest(http.MethodPost, "/file?pane=wN:p1", bytes.NewReader(pdfUpload()))
		if header != "" {
			req.Header.Set("Authorization", header)
		}
		rec := httptest.NewRecorder()
		s.handleFile(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("header %q: status = %d, want 401", header, rec.Code)
		}
	}
}

// TestFileRequestGuards covers the request-shape checks that run after auth but
// before any herdr call. The not-a-document cases matter most: an image
// belongs to POST /image, and a zip that is not an Office file must not land
// in anyone's repository just because it is a well-formed archive.
func TestFileRequestGuards(t *testing.T) {
	plainZip := func() []byte {
		var buf bytes.Buffer
		w := zip.NewWriter(&buf)
		if _, err := w.Create("archive/readme.txt"); err != nil {
			t.Fatal(err)
		}
		if err := w.Close(); err != nil {
			t.Fatal(err)
		}
		return buf.Bytes()
	}
	cases := []struct {
		name   string
		method string
		target string
		body   []byte
		want   int
	}{
		{"wrong-method", http.MethodGet, "/file?pane=wN:p1", nil, http.StatusMethodNotAllowed},
		{"missing-pane", http.MethodPost, "/file", pdfUpload(), http.StatusBadRequest},
		{"empty-body", http.MethodPost, "/file?pane=wN:p1", nil, http.StatusBadRequest},
		{"not-a-document", http.MethodPost, "/file?pane=wN:p1", []byte("#!/bin/sh\nrm -rf /\n"), http.StatusUnsupportedMediaType},
		{"image-goes-to-image", http.MethodPost, "/file?pane=wN:p1", pngUpload(), http.StatusUnsupportedMediaType},
		{"plain-zip", http.MethodPost, "/file?pane=wN:p1", plainZip(), http.StatusUnsupportedMediaType},
		{"too-large", http.MethodPost, "/file?pane=wN:p1",
			append([]byte("%PDF-1.7\n"), bytes.Repeat([]byte{0}, imagedrop.MaxDocumentBytes)...),
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
			s.handleFile(rec, req)
			if rec.Code != c.want {
				t.Errorf("status = %d, want %d (%s)", rec.Code, c.want, rec.Body.String())
			}
		})
	}
}

// TestFileOversizedIsRefusedUnread asserts the declared-length guard fires
// before the body is buffered — with the document cap, not the image one.
func TestFileOversizedIsRefusedUnread(t *testing.T) {
	s := newTestServer(t)
	s.agents = &fakeAgents{cwd: t.TempDir()}

	body := &countingReader{Reader: bytes.NewReader(pdfUpload())}
	req := httptest.NewRequest(http.MethodPost, "/file?pane=w1:p2", body)
	req.Header.Set("Authorization", "Bearer admin-tok")
	req.ContentLength = imagedrop.MaxDocumentBytes + 1

	rec := httptest.NewRecorder()
	s.handleFile(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413 (%s)", rec.Code, rec.Body.String())
	}
	if body.n != 0 {
		t.Errorf("read %d bytes of an over-cap body, want 0", body.n)
	}
}

// TestFileWritesIntoAgentCwd is the happy path: the document lands inside the
// agent's own tree under .gothalo/files, with the extension the contents
// dictate, and the response hands back the absolute path.
func TestFileWritesIntoAgentCwd(t *testing.T) {
	cases := []struct {
		name string
		body func(t *testing.T) []byte
		ct   string
		ext  string
	}{
		{"pdf", func(*testing.T) []byte { return pdfUpload() }, "application/pdf", ".pdf"},
		{"docx", docxUpload,
			"application/vnd.openxmlformats-officedocument.wordprocessingml.document", ".docx"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTestServer(t)
			cwd := t.TempDir()
			s.agents = &fakeAgents{cwd: cwd}

			rec := httptest.NewRecorder()
			s.handleFile(rec, fileRequest("/file?pane=w1:p2", c.body(t)))
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
			}

			var res imagedrop.Result
			if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
				t.Fatalf("decode: %v", err)
			}
			if res.ContentType != c.ct {
				t.Errorf("content_type = %q, want %q", res.ContentType, c.ct)
			}
			wantDir := filepath.Join(cwd, ".gothalo", "files")
			if filepath.Dir(res.Path) != wantDir {
				t.Fatalf("path = %q, want a file in %q", res.Path, wantDir)
			}
			if filepath.Ext(res.Path) != c.ext {
				t.Errorf("extension = %q, want %q", filepath.Ext(res.Path), c.ext)
			}
			if _, err := os.Stat(res.Path); err != nil {
				t.Errorf("returned path does not exist: %v", err)
			}
		})
	}
}

// TestFileSessionQualifiedPane asserts the endpoint resolves a
// "<session>/<pane>" id exactly the way /image does: prefix stripped before
// the lookup, never forwarded to Herdr.
func TestFileSessionQualifiedPane(t *testing.T) {
	s := newTestServer(t)
	agents := &fakeAgents{cwd: t.TempDir()}
	s.agents = agents

	rec := httptest.NewRecorder()
	s.handleFile(rec, fileRequest("/file?pane=acme%2Fw1:p2", pdfUpload()))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	if agents.asked != "w1:p2" {
		t.Errorf("herdr was asked for %q, want the bare id %q", agents.asked, "w1:p2")
	}
}
