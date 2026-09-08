package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/config"
)

func firebaseConfigServer(t *testing.T, contents string) *Server {
	t.Helper()
	dir := t.TempDir()
	if contents != "" {
		if err := os.WriteFile(filepath.Join(dir, firebaseWebFileName), []byte(contents), 0o600); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
	}
	return &Server{cfg: &config.Config{DataDir: dir}}
}

func getFirebaseConfig(t *testing.T, srv *Server) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/firebase-config", nil)
	rec := httptest.NewRecorder()
	srv.handleFirebaseConfig(rec, req)
	return rec
}

// The generic web build boots against whichever bridge it pairs with, so the
// endpoint must serve that bridge's project verbatim — no auth (these are
// public identifiers), no envelope.
func TestFirebaseConfigServesFile(t *testing.T) {
	srv := firebaseConfigServer(t, `{"apiKey":"AIzaA","projectId":"p","vapidKey":"V"}`)
	rec := getFirebaseConfig(t, srv)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var got map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got["apiKey"] != "AIzaA" || got["projectId"] != "p" || got["vapidKey"] != "V" {
		t.Fatalf("body = %v, want the file's values", got)
	}
}

// No web push configured: a 404 that says what to run, not an empty 200 the
// client would try to initialise Firebase with.
func TestFirebaseConfigMissingIs404(t *testing.T) {
	srv := firebaseConfigServer(t, "")
	rec := getFirebaseConfig(t, srv)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

// A hand-edited file with broken JSON must fail loudly, not serve half a config.
func TestFirebaseConfigInvalidIs500(t *testing.T) {
	srv := firebaseConfigServer(t, `{"apiKey":`)
	rec := getFirebaseConfig(t, srv)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
}
