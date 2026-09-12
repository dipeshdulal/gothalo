package opencode

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// writeService points Discover at an httptest server by writing the same
// service.json the TUI writes, under a temp HOME.
func writeService(t *testing.T, url string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_STATE_HOME", "")
	dir := filepath.Join(home, ".local", "state", "opencode")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(Service{URL: url, Password: "secret"})
	if err := os.WriteFile(filepath.Join(dir, "service.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestDiscoverAndQuestion(t *testing.T) {
	form := Form{
		ID: "frm_1", SessionID: "ses_1", Title: "Questions",
		Fields: []Field{{Key: "q0", Description: "Pick one", Options: []Option{{Value: "A", Label: "A"}}}},
	}
	form.Metadata.Kind = FormKindQuestion

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/session/ses_1/form":
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []Form{form}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	writeService(t, srv.URL)

	svc, err := Discover()
	if err != nil {
		t.Fatal(err)
	}
	got, err := svc.Question("ses_1")
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.ID != "frm_1" || got.Fields[0].Description != "Pick one" {
		t.Fatalf("Question = %+v", got)
	}
}

// TestQuestionSkipsOtherForms: only the question tool's metadata.kind counts.
func TestQuestionSkipsOtherForms(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []Form{
			{ID: "frm_plugin", SessionID: "ses_1"},
		}})
	}))
	defer srv.Close()
	writeService(t, srv.URL)

	svc, _ := Discover()
	got, err := svc.Question("ses_1")
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Errorf("Question = %+v, want nil (not a question form)", got)
	}
}

func TestReplyAndCancelPaths(t *testing.T) {
	var paths []string
	var lastBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.Method+" "+r.URL.Path)
		if r.Method == http.MethodPost {
			raw, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &lastBody)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	writeService(t, srv.URL)
	svc, _ := Discover()

	if err := svc.ReplyForm("ses_1", "frm_1", map[string]any{"q0": "A"}); err != nil {
		t.Fatal(err)
	}
	if err := svc.CancelForm("ses_1", "frm_1"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"POST /api/session/ses_1/form/frm_1/reply",
		"POST /api/session/ses_1/form/frm_1/cancel",
	}
	if len(paths) != len(want) {
		t.Fatalf("paths = %v, want %v", paths, want)
	}
	for i := range want {
		if paths[i] != want[i] {
			t.Errorf("path %d = %q, want %q", i, paths[i], want[i])
		}
	}
	if lastBody["answer"] == nil {
		t.Errorf("reply body = %+v, want an answer object", lastBody)
	}
}

func TestVerifyAndSessionForCwd(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/session/ses_1":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": map[string]any{"location": map[string]string{"directory": "/tmp/project"}},
			})
		case "/api/session":
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []map[string]any{
				{"id": "ses_child", "parentID": "ses_parent", "location": map[string]string{"directory": "/tmp/project"}},
				{"id": "ses_1", "location": map[string]string{"directory": "/tmp/project"}},
			}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	writeService(t, srv.URL)
	svc, _ := Discover()

	if err := svc.Verify("ses_1", "/tmp/project"); err != nil {
		t.Errorf("Verify matching cwd: %v", err)
	}
	if err := svc.Verify("ses_1", "/tmp/other"); err != ErrNotFound {
		t.Errorf("Verify mismatched cwd = %v, want ErrNotFound", err)
	}
	id, err := svc.SessionForCwd("/tmp/project")
	if err != nil {
		t.Fatal(err)
	}
	if id != "ses_1" {
		t.Errorf("SessionForCwd = %q, want the top-level session (child skipped)", id)
	}
}

func TestDiscoverMissing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_STATE_HOME", "")
	if _, err := Discover(); !os.IsNotExist(err) {
		t.Errorf("Discover = %v, want a not-exist error", err)
	}
}
