package server

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// TestValidateCWDRejectsTraversal is the guard the whole feature rests on: the
// cwd names where a shell — and then an agent with tool access — will run, and it
// arrives from a phone. Every rejected form here is a different way of naming a
// directory the caller did not literally write.
func TestValidateCWDRejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name string
		cwd  string
		want string // substring the error must explain
	}{
		{"parent-traversal", dir + "/../elsewhere", "canonical"},
		{"embedded-traversal", dir + "/sub/../../etc", "canonical"},
		{"dot-segment", dir + "/./sub", "canonical"},
		{"double-slash", dir + "//sub", "canonical"},
		{"trailing-slash", dir + "/", "canonical"},
		{"relative", "projects/app", "absolute"},
		{"relative-traversal", "../../etc", "absolute"},
		{"dot", ".", "absolute"},
		{"empty", "", "absolute"},
		{"tilde", "~/projects", "absolute"},
		{"nul-byte", "/tmp/a\x00b", "NUL"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := validateCWD(c.cwd)
			if err == nil {
				t.Fatalf("validateCWD(%q) = nil, want a rejection", c.cwd)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("error %q must explain %q", err, c.want)
			}
		})
	}
}

// TestValidateCWDRejectsMissingAndNonDirectories covers the "absolute, clean,
// but not usable" cases — caught here so the failure is a 400 rather than a
// broken shell inside a pane that has already been created.
func TestValidateCWDRejectsMissingAndNonDirectories(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "a-file")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	t.Run("missing", func(t *testing.T) {
		err := validateCWD(filepath.Join(dir, "nope"))
		if err == nil || !strings.Contains(err.Error(), "does not exist") {
			t.Errorf("err = %v, want a does-not-exist rejection", err)
		}
	})
	t.Run("file-not-directory", func(t *testing.T) {
		err := validateCWD(file)
		if err == nil || !strings.Contains(err.Error(), "not a directory") {
			t.Errorf("err = %v, want a not-a-directory rejection", err)
		}
	})
}

// TestValidateCWDAcceptsRealDirectories asserts the guard is not so strict it
// rejects ordinary input — including a symlinked directory, which macOS makes
// unavoidable (/tmp and /var are symlinks) and which is not a traversal.
func TestValidateCWDAcceptsRealDirectories(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "project")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	for _, cwd := range []string{dir, real, link} {
		if err := validateCWD(cwd); err != nil {
			t.Errorf("validateCWD(%q) = %v, want nil", cwd, err)
		}
	}
}

// TestAgentNameDerivation asserts the auto-minted name satisfies Herdr's rule
// ([a-z][a-z0-9_-]{0,31}) for real pane ids, which contain both uppercase
// letters and a colon and so cannot be used raw.
func TestAgentNameDerivation(t *testing.T) {
	cases := []struct {
		kind, pane, want string
	}{
		{"claude", "wN:p2N", "claude-wn-p2n"},
		{"codex", "w4:pG", "codex-w4-pg"},
		{"opencode", "w1:p1", "opencode-w1-p1"},
	}
	for _, c := range cases {
		got, err := agentName("", c.kind, c.pane)
		if err != nil {
			t.Fatalf("agentName(%q,%q): %v", c.kind, c.pane, err)
		}
		if got != c.want {
			t.Errorf("agentName(%q,%q) = %q, want %q", c.kind, c.pane, got, c.want)
		}
		if !agentNameRe.MatchString(got) {
			t.Errorf("derived name %q does not satisfy herdr's rule", got)
		}
	}
}

// TestAgentNameLengthCap asserts a long kind+pane pair is still a legal name.
// Herdr caps a name at 32 characters and rejects one that ends on a separator,
// so both the truncation and the trim have to hold.
func TestAgentNameLengthCap(t *testing.T) {
	got, err := agentName("", "mastracode", "wLONG:pIDENTIFIERTHATKEEPSGOING")
	if err != nil {
		t.Fatalf("agentName: %v", err)
	}
	if len(got) > 32 {
		t.Errorf("name %q is %d chars, herdr allows 32", got, len(got))
	}
	if !agentNameRe.MatchString(got) {
		t.Errorf("truncated name %q does not satisfy herdr's rule", got)
	}
}

// TestAgentNameExplicit asserts a caller-supplied name is validated against
// Herdr's rule here, rather than being rejected by Herdr after a pane has
// already been created.
func TestAgentNameExplicit(t *testing.T) {
	if got, err := agentName("reviewer", "claude", "w1:p1"); err != nil || got != "reviewer" {
		t.Errorf("agentName(reviewer) = %q, %v; want reviewer, nil", got, err)
	}
	for _, bad := range []string{"Reviewer", "9lives", "has space", "-leading", "a" + strings.Repeat("b", 32)} {
		if _, err := agentName(bad, "claude", "w1:p1"); err == nil {
			t.Errorf("agentName(%q) = nil error, want a rejection", bad)
		}
	}
}

// TestStartTarget asserts exactly-one targeting. Ambiguity is an error rather
// than a precedence rule: starting an agent in the wrong place is not something
// a retry undoes.
func TestStartTarget(t *testing.T) {
	cases := []struct {
		name string
		body agentStartRequest
		id   string
		mode startMode
		err  bool
	}{
		{"pane", agentStartRequest{PaneID: "w1:p1"}, "w1:p1", targetExistingPane, false},
		{"split", agentStartRequest{SplitFrom: "w1:p1"}, "w1:p1", targetSplit, false},
		{"tab", agentStartRequest{WorkspaceID: "w1"}, "w1", targetNewTab, false},
		{"none", agentStartRequest{}, "", 0, true},
		{"two", agentStartRequest{PaneID: "w1:p1", WorkspaceID: "w1"}, "", 0, true},
		{"all-three", agentStartRequest{PaneID: "w1:p1", SplitFrom: "w1:p2", WorkspaceID: "w1"}, "", 0, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			id, mode, err := startTarget(c.body)
			if (err != nil) != c.err {
				t.Fatalf("err = %v, wantErr %v", err, c.err)
			}
			if err != nil {
				return
			}
			if id != c.id || mode != c.mode {
				t.Errorf("target = (%q,%v), want (%q,%v)", id, mode, c.id, c.mode)
			}
		})
	}
}

// TestStartTimeoutClamp asserts a phone's number is clamped into the window
// Herdr accepts (3s–300s) instead of being forwarded and rejected as a 502.
func TestStartTimeoutClamp(t *testing.T) {
	cases := []struct {
		ms   int
		want time.Duration
	}{
		{0, startTimeoutDefault},
		{-1, startTimeoutDefault},
		{1, startTimeoutMin},
		{1_000_000, startTimeoutMax},
		{45_000, 45 * time.Second},
	}
	for _, c := range cases {
		if got := startTimeout(c.ms); got != c.want {
			t.Errorf("startTimeout(%d) = %s, want %s", c.ms, got, c.want)
		}
	}
}

// TestAvailableAgentsFiltersToInstalled is the discovery contract: the catalog
// comes from Herdr, "installed" comes from PATH, and a kind that is not
// installed never reaches the app — the launch picker must not offer something
// that cannot start.
func TestAvailableAgentsFiltersToInstalled(t *testing.T) {
	kinds := []string{"pi", "claude", "codex", "opencode", "hermes"}
	manifests := []string{"pi", "claude", "codex", "opencode", "hermes"}
	installed := map[string]string{
		"claude":   "/opt/homebrew/bin/claude",
		"opencode": "/home/me/.opencode/bin/opencode",
	}
	lookPath := func(name string) (string, error) {
		if p, ok := installed[name]; ok {
			return p, nil
		}
		return "", exec.ErrNotFound
	}

	got := availableAgents(kinds, manifests, lookPath)
	want := []availableAgent{
		{Kind: "claude", Path: "/opt/homebrew/bin/claude", StateReporting: true},
		{Kind: "opencode", Path: "/home/me/.opencode/bin/opencode", StateReporting: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("availableAgents = %#v\nwant %#v", got, want)
	}
}

// TestAvailableAgentsMarksMissingManifest asserts an installed kind Herdr cannot
// classify is still offered, but flagged. It will run; it will just never leave
// `unknown`, which the app should warn about rather than silently produce.
func TestAvailableAgentsMarksMissingManifest(t *testing.T) {
	lookPath := func(name string) (string, error) { return "/usr/local/bin/" + name, nil }
	got := availableAgents([]string{"omp", "claude"}, []string{"claude"}, lookPath)
	want := []availableAgent{
		{Kind: "omp", Path: "/usr/local/bin/omp", StateReporting: false},
		{Kind: "claude", Path: "/usr/local/bin/claude", StateReporting: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("availableAgents = %#v\nwant %#v", got, want)
	}
}

// TestAvailableAgentsPreservesHerdrOrder asserts the app renders the picker in
// Herdr's own order rather than an arbitrary map iteration order, so the list
// does not reshuffle between refreshes.
func TestAvailableAgentsPreservesHerdrOrder(t *testing.T) {
	kinds := []string{"pi", "claude", "codex", "gemini"}
	lookPath := func(name string) (string, error) { return "/bin/" + name, nil }
	got := availableAgents(kinds, nil, lookPath)
	for i, a := range got {
		if a.Kind != kinds[i] {
			t.Fatalf("order = %v, want %v", got, kinds)
		}
	}
}

// TestAvailableAgentsEmptyHost asserts a host with nothing installed answers an
// empty list rather than nil-panicking or falling back to a hardcoded set.
func TestAvailableAgentsEmptyHost(t *testing.T) {
	got := availableAgents([]string{"claude"}, nil, func(string) (string, error) {
		return "", errors.New("not found")
	})
	if len(got) != 0 {
		t.Errorf("availableAgents = %v, want empty", got)
	}
}

// ---- HTTP guards ----

// TestAgentLifecycleAuth asserts every lifecycle endpoint rejects an
// unauthenticated caller before it reaches herdr. These start and kill
// processes; an auth hole here is materially worse than on a read endpoint.
func TestAgentLifecycleAuth(t *testing.T) {
	s := newTestServer(t)
	endpoints := []struct {
		name    string
		method  string
		path    string
		body    string
		handler http.HandlerFunc
	}{
		{"available", http.MethodGet, "/agents/available", "", s.handleAgentsAvailable},
		{"start", http.MethodPost, "/agent/start", `{"kind":"claude","pane_id":"w1:p1"}`, s.handleAgentStart},
		{"restart", http.MethodPost, "/agent/restart", `{"pane_id":"w1:p1"}`, s.handleAgentRestart},
		{"stop", http.MethodPost, "/agent/stop", `{"pane_id":"w1:p1"}`, s.handleAgentStop},
	}
	for _, e := range endpoints {
		for _, header := range []string{"", "Bearer nope"} {
			t.Run(e.name+"/"+header, func(t *testing.T) {
				req := httptest.NewRequest(e.method, e.path, strings.NewReader(e.body))
				if header != "" {
					req.Header.Set("Authorization", header)
				}
				rec := httptest.NewRecorder()
				e.handler(rec, req)
				if rec.Code != http.StatusUnauthorized {
					t.Errorf("status = %d, want 401", rec.Code)
				}
			})
		}
	}
}

// TestAgentStartRequestParsing covers every guard that runs after auth but
// before any herdr call — the checks that must reject a bad request without
// leaving a pane behind.
func TestAgentStartRequestParsing(t *testing.T) {
	s := newTestServer(t)
	dir := t.TempDir()
	cases := []struct {
		name   string
		method string
		body   string
		want   int
	}{
		{"wrong-method", http.MethodGet, "", http.StatusMethodNotAllowed},
		{"bad-json", http.MethodPost, `{`, http.StatusBadRequest},
		{"missing-kind", http.MethodPost, `{"pane_id":"w1:p1"}`, http.StatusBadRequest},
		{"no-target", http.MethodPost, `{"kind":"claude"}`, http.StatusBadRequest},
		{"two-targets", http.MethodPost, `{"kind":"claude","pane_id":"w1:p1","workspace_id":"w1"}`, http.StatusBadRequest},
		{"cwd-with-existing-pane", http.MethodPost, `{"kind":"claude","pane_id":"w1:p1","cwd":"` + dir + `"}`, http.StatusBadRequest},
		{"relative-cwd", http.MethodPost, `{"kind":"claude","split_from":"w1:p1","cwd":"projects/app"}`, http.StatusBadRequest},
		{"traversal-cwd", http.MethodPost, `{"kind":"claude","split_from":"w1:p1","cwd":"/etc/../root"}`, http.StatusBadRequest},
		{"missing-cwd", http.MethodPost, `{"kind":"claude","split_from":"w1:p1","cwd":"` + filepath.Join(dir, "nope") + `"}`, http.StatusBadRequest},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(c.method, "/agent/start", strings.NewReader(c.body))
			req.Header.Set("Authorization", "Bearer admin-tok")
			rec := httptest.NewRecorder()
			s.handleAgentStart(rec, req)
			if rec.Code != c.want {
				t.Errorf("status = %d, want %d (body %q)", rec.Code, c.want, rec.Body.String())
			}
		})
	}
}

// TestAgentStopRestartRequestParsing covers the shape guards on the two
// destructive endpoints.
func TestAgentStopRestartRequestParsing(t *testing.T) {
	s := newTestServer(t)
	for _, h := range []struct {
		name    string
		path    string
		handler http.HandlerFunc
	}{
		{"stop", "/agent/stop", s.handleAgentStop},
		{"restart", "/agent/restart", s.handleAgentRestart},
	} {
		t.Run(h.name+"/wrong-method", func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, h.path, nil)
			req.Header.Set("Authorization", "Bearer admin-tok")
			rec := httptest.NewRecorder()
			h.handler(rec, req)
			if rec.Code != http.StatusMethodNotAllowed {
				t.Errorf("status = %d, want 405", rec.Code)
			}
		})
		t.Run(h.name+"/missing-pane", func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, h.path, strings.NewReader(`{}`))
			req.Header.Set("Authorization", "Bearer admin-tok")
			rec := httptest.NewRecorder()
			h.handler(rec, req)
			if rec.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400", rec.Code)
			}
		})
	}
}

// TestAgentStartUnknownSessionIs404 asserts a session-qualified target naming a
// session this bridge does not have fails at routing, before any herdr call —
// and that the session-qualified id form is understood at all, since every id on
// this surface is qualified.
func TestAgentStartUnknownSessionIs404(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/agent/start",
		strings.NewReader(`{"kind":"claude","pane_id":"nosuchsession/w1:p1"}`))
	req.Header.Set("Authorization", "Bearer admin-tok")
	rec := httptest.NewRecorder()
	s.handleAgentStart(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404 (body %q)", rec.Code, rec.Body.String())
	}
}
