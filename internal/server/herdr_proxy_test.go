package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/store"
)

// fakeRequester records the last call and returns a canned result/error so the
// proxy can be exercised without a live Herdr socket.
type fakeRequester struct {
	called     bool
	lastMethod string
	lastParams json.RawMessage
	result     json.RawMessage
	err        error
}

func (f *fakeRequester) Request(method string, params any) (json.RawMessage, error) {
	f.called = true
	f.lastMethod = method
	if raw, ok := params.(json.RawMessage); ok {
		f.lastParams = raw
	}
	return f.result, f.err
}

// newProxyServer builds a minimal Server wired only for the /herdr handler: an
// admin token for auth, an empty device store (so the wrong-bearer path resolves
// to "no device" rather than nil-panicking), and a fake requester in place of
// the socket client.
func newProxyServer(t *testing.T, fake herdrRequester) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "devices.json"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return &Server{
		cfg:       &config.Config{AdminToken: "admintok"},
		store:     st,
		requester: fake,
	}
}

func proxyRequest(t *testing.T, srv *Server, bearer, bodyJSON string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/herdr", strings.NewReader(bodyJSON))
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	srv.handleHerdrProxy(rec, req)
	return rec
}

func TestHerdrProxyAllowedForwards(t *testing.T) {
	fake := &fakeRequester{result: json.RawMessage(`{"type":"pane_list","panes":[]}`)}
	srv := newProxyServer(t, fake)

	rec := proxyRequest(t, srv, "admintok", `{"method":"pane.list","params":{"workspace_id":"w5"}}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if !fake.called {
		t.Fatal("requester was not called for an allowlisted method")
	}
	if fake.lastMethod != "pane.list" {
		t.Errorf("forwarded method = %q, want pane.list", fake.lastMethod)
	}
	if !strings.Contains(string(fake.lastParams), `"workspace_id":"w5"`) {
		t.Errorf("params not passed through verbatim: %s", fake.lastParams)
	}
	var env struct {
		Result json.RawMessage `json:"result"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatalf("response not JSON: %v (%s)", err, rec.Body.String())
	}
	if !strings.Contains(string(env.Result), "pane_list") {
		t.Errorf("result not wrapped through: %s", env.Result)
	}
}

func TestHerdrProxyDisallowedIs403(t *testing.T) {
	fake := &fakeRequester{}
	srv := newProxyServer(t, fake)

	// server.stop is a real Herdr method but deliberately NOT on the allowlist.
	rec := proxyRequest(t, srv, "admintok", `{"method":"server.stop","params":{}}`)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if fake.called {
		t.Fatal("requester was called for a disallowed method — allowlist bypassed")
	}
	var env struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil || env.Error == "" {
		t.Errorf("want normalized {error}, got %s", rec.Body.String())
	}
}

// Every method the app-facing contract advertises must actually be allowlisted,
// so a rename in one place can't silently 403 the app.
func TestHerdrProxyAllowlistCoversContract(t *testing.T) {
	fake := &fakeRequester{result: json.RawMessage(`{}`)}
	srv := newProxyServer(t, fake)
	for _, m := range []string{
		"worktree.create", "worktree.remove", "worktree.list",
		"tab.create", "tab.close", "pane.split", "pane.close",
		"pane.focus", "tab.focus", "agent.focus",
		"pane.list", "pane.get", "agent.list", "session.snapshot",
	} {
		fake.called = false
		rec := proxyRequest(t, srv, "admintok", `{"method":"`+m+`","params":{}}`)
		if rec.Code == http.StatusForbidden {
			t.Errorf("%s should be allowlisted but returned 403", m)
		}
		if !fake.called {
			t.Errorf("%s did not reach the requester", m)
		}
	}
}

func TestHerdrProxyBadBodyIs400(t *testing.T) {
	srv := newProxyServer(t, &fakeRequester{})
	for _, body := range []string{`{"params":{}}`, `not json`, `{"method":""}`} {
		rec := proxyRequest(t, srv, "admintok", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q: status = %d, want 400", body, rec.Code)
		}
	}
}

func TestHerdrProxyUnauthedIs401(t *testing.T) {
	srv := newProxyServer(t, &fakeRequester{})
	rec := proxyRequest(t, srv, "", `{"method":"pane.list","params":{}}`)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
	rec = proxyRequest(t, srv, "wrongtok", `{"method":"pane.list","params":{}}`)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("bad token: status = %d, want 401", rec.Code)
	}
}

func TestHerdrProxyNotFoundIs404(t *testing.T) {
	fake := &fakeRequester{err: &herdr.SocketError{Code: "pane_not_found", Message: "no pane wX:p9"}}
	srv := newProxyServer(t, fake)
	rec := proxyRequest(t, srv, "admintok", `{"method":"pane.get","params":{"pane_id":"wX:p9"}}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 (body: %s)", rec.Code, rec.Body.String())
	}
}

func TestHerdrProxySocketErrorIs502(t *testing.T) {
	fake := &fakeRequester{err: &herdr.SocketError{Code: "invalid_params", Message: "bad direction"}}
	srv := newProxyServer(t, fake)
	rec := proxyRequest(t, srv, "admintok", `{"method":"pane.split","params":{}}`)
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502 (body: %s)", rec.Code, rec.Body.String())
	}
}
