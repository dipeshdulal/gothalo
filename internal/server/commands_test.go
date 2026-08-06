package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/herdr"
)

func commandsRequest(target string) *http.Request {
	req := httptest.NewRequest(http.MethodGet, target, nil)
	req.Header.Set("Authorization", "Bearer admin-tok")
	return req
}

// decodeCommands unmarshals from the recorder's bytes rather than reading its
// Body, so a test can also inspect the raw payload afterwards — a Decoder would
// drain the buffer and leave the second look with nothing.
func decodeCommands(t *testing.T, rec *httptest.ResponseRecorder) commandsResponse {
	t.Helper()
	var got commandsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return got
}

func TestCommandsAuth(t *testing.T) {
	s := newTestServer(t)
	for _, header := range []string{"", "Bearer nope"} {
		req := httptest.NewRequest(http.MethodGet, "/commands?pane=wN:p1", nil)
		if header != "" {
			req.Header.Set("Authorization", header)
		}
		rec := httptest.NewRecorder()
		s.handleCommands(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("header %q: status = %d, want 401", header, rec.Code)
		}
	}
}

func TestCommandsWantsPane(t *testing.T) {
	s := newTestServer(t)
	rec := httptest.NewRecorder()
	s.handleCommands(rec, commandsRequest("/commands"))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400 without ?pane=", rec.Code)
	}
}

// A pane that does not exist is the one genuine failure this endpoint keeps as
// an error.
func TestCommandsUnknownPane(t *testing.T) {
	s := newTestServer(t)
	s.agents = &fakeAgents{err: herdr.ErrAgentNotFound}
	rec := httptest.NewRecorder()
	s.handleCommands(rec, commandsRequest("/commands?pane=wN:p9"))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404 for a missing agent", rec.Code)
	}
}

// The happy path: a claude pane gets its project's own commands and skills
// alongside the built-ins, with the discovered ones leading.
func TestCommandsListsProjectAndBuiltins(t *testing.T) {
	cwd := t.TempDir()
	mustWrite(t, filepath.Join(cwd, ".claude", "commands", "ship.md"),
		"---\ndescription: Ship it\nargument-hint: [env]\n---\n")
	mustWrite(t, filepath.Join(cwd, ".claude", "skills", "deploy", "SKILL.md"),
		"---\nname: deploy\ndescription: Deploy the thing\n---\n")

	s := newTestServer(t)
	s.agents = &fakeAgents{cwd: cwd, kind: "claude"}
	rec := httptest.NewRecorder()
	s.handleCommands(rec, commandsRequest("/commands?pane=wN:p1"))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	got := decodeCommands(t, rec)
	if got.AgentKind != "claude" {
		t.Errorf("agent_kind = %q, want claude", got.AgentKind)
	}
	if got.Pane != "wN:p1" {
		t.Errorf("pane = %q, want the requested pane echoed back", got.Pane)
	}

	byName := map[string]string{} // name -> source
	for _, c := range got.Commands {
		byName[c.Name] = c.Source
	}
	for name, wantSource := range map[string]string{
		"ship":    "command",
		"deploy":  "skill",
		"compact": "builtin",
	} {
		if byName[name] != wantSource {
			t.Errorf("command %q source = %q, want %q", name, byName[name], wantSource)
		}
	}
	if len(got.Commands) > 0 && got.Commands[0].Source == "builtin" {
		t.Errorf("built-ins lead the list; want the project's own commands first (got %+v)", got.Commands[0])
	}
}

// An agent kind with no lister answers 200 with an empty list, NOT an error:
// "this agent has no typeahead" is a normal state and must not put an error in
// front of a working pane. The JSON array must be present and empty rather than
// null, so a client can render it without a null check.
func TestCommandsUnsupportedKindIsEmptyNotError(t *testing.T) {
	s := newTestServer(t)
	s.agents = &fakeAgents{cwd: t.TempDir(), kind: "gemini"}
	rec := httptest.NewRecorder()
	s.handleCommands(rec, commandsRequest("/commands?pane=wN:p1"))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 for an agent kind with no command surface", rec.Code)
	}
	got := decodeCommands(t, rec)
	if len(got.Commands) != 0 {
		t.Errorf("want no commands, got %+v", got.Commands)
	}
	if got.AgentKind != "gemini" {
		t.Errorf("agent_kind = %q, want the kind echoed so the client knows WHY it is empty", got.AgentKind)
	}
	if !jsonHasEmptyArray(t, rec) {
		t.Error(`want "commands":[] in the payload, not null`)
	}
}

// A session-qualified pane id resolves like everywhere else — the "<session>/"
// prefix is stripped before the Herdr lookup.
func TestCommandsSessionQualifiedPane(t *testing.T) {
	agents := &fakeAgents{cwd: t.TempDir(), kind: "claude"}
	s := newTestServer(t)
	s.agents = agents
	rec := httptest.NewRecorder()
	s.handleCommands(rec, commandsRequest("/commands?pane=acme%2Fw1:p2"))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if agents.asked != "w1:p2" {
		t.Errorf("herdr asked for %q, want the bare pane id w1:p2", agents.asked)
	}
}

func jsonHasEmptyArray(t *testing.T, rec *httptest.ResponseRecorder) bool {
	t.Helper()
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return string(raw["commands"]) == "[]"
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
