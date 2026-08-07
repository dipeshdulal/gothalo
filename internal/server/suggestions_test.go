package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dipeshdulal/gothalo/internal/gitdiff"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/suggest"
)

// fakeProcessInfo stands in for the Herdr socket, and counts calls so the cache
// can be asserted on directly rather than inferred from timing.
type fakeProcessInfo struct {
	info  herdr.PaneProcessInfo
	err   error
	calls int
}

func (f *fakeProcessInfo) PaneProcessInfo(string) (herdr.PaneProcessInfo, error) {
	f.calls++
	return f.info, f.err
}

// fakeAgent is the paneAgent seam: an agent pane returns one, a plain pane
// returns herdr's own not-found.
type fakeAgent struct {
	agent herdr.Agent
	err   error
}

func (f fakeAgent) Get(string) (herdr.Agent, error) { return f.agent, f.err }

// dirtyRepo is a repository with one uncommitted change — the state the
// review-changes suggestion keys off.
func dirtyRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"config", "user.email", "t@example.com"},
		{"config", "user.name", "t"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// noServers stubs the dev-server half of the observation. Set in every test
// that does not care about it: the production path shells out to `lsof` and
// probes every listener on the machine running the tests, which is neither
// cheap nor deterministic.
func noServers(*Server) func(context.Context, string) []suggest.Server {
	return func(context.Context, string) []suggest.Server { return nil }
}

// stubServers stubs the scan with a fixed set of listeners for the pane.
func stubServers(list ...suggest.Server) func(context.Context, string) []suggest.Server {
	return func(context.Context, string) []suggest.Server { return list }
}

func getSuggestions(t *testing.T, s *Server, query string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/suggestions"+query, nil)
	req.Header.Set("Authorization", "Bearer admin-tok")
	rec := httptest.NewRecorder()
	s.handleSuggestions(rec, req)
	return rec
}

// TestSuggestionsAuth asserts the endpoint rejects unauthenticated callers
// before it ever touches herdr — same auth model as every other endpoint.
func TestSuggestionsAuth(t *testing.T) {
	s := newTestServer(t)
	for _, c := range []struct{ name, header string }{
		{"no-token", ""},
		{"bad-token", "Bearer nope"},
	} {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/suggestions?pane=wN:p1", nil)
			if c.header != "" {
				req.Header.Set("Authorization", c.header)
			}
			rec := httptest.NewRecorder()
			s.handleSuggestions(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Errorf("status = %d, want 401", rec.Code)
			}
		})
	}
}

// TestSuggestionsMissingPane covers the request-shape guard that runs after
// auth but before any herdr call.
func TestSuggestionsMissingPane(t *testing.T) {
	s := newTestServer(t)
	if rec := getSuggestions(t, s, ""); rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rec.Code)
	}
}

// TestSuggestionsForAgentPane walks the whole path an agent pane takes:
// process_info + agent.get -> observation -> sources -> payload.
func TestSuggestionsForAgentPane(t *testing.T) {
	dir := dirtyRepo(t)
	s := newTestServer(t)
	s.processInfo = &fakeProcessInfo{info: herdr.PaneProcessInfo{
		ShellPID:                 100,
		ForegroundProcessGroupID: 200,
		ForegroundProcesses:      []herdr.PaneProcess{{PID: 200, Name: "claude", Cwd: dir}},
	}}
	s.agents = fakeAgent{agent: herdr.Agent{Kind: "claude", Cwd: dir}}
	s.serversFor = noServers(s)

	rec := getSuggestions(t, s, "?pane=acme/w1:p1")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body)
	}
	var body suggestionsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Pane != "acme/w1:p1" {
		t.Errorf("pane = %q, want the session-qualified id back", body.Pane)
	}
	if len(body.Suggestions) != 1 {
		t.Fatalf("suggestions = %+v, want one", body.Suggestions)
	}
	got := body.Suggestions[0]
	if got.Kind != suggest.KindGitDirty || got.Action != suggest.ActionOpenDiff {
		t.Errorf("suggestion = %+v, want a git_dirty/open_diff", got)
	}
	// The action has to address the pane the app knows, prefix and all —
	// /diff takes the qualified form.
	if got.Params["pane"] != "acme/w1:p1" {
		t.Errorf("params[pane] = %q, want the qualified pane id", got.Params["pane"])
	}
}

// TestSuggestionsForPlainPane: a pane with no agent is not an error, it is the
// ordinary input to the start-an-agent source.
func TestSuggestionsForPlainPane(t *testing.T) {
	dir := dirtyRepo(t)
	s := newTestServer(t)
	s.processInfo = &fakeProcessInfo{info: herdr.PaneProcessInfo{
		ShellPID:                 100,
		ForegroundProcessGroupID: 100,
		ForegroundProcesses:      []herdr.PaneProcess{{PID: 100, Name: "zsh", Cwd: dir}},
	}}
	s.agents = fakeAgent{err: herdr.ErrAgentNotFound}
	s.serversFor = noServers(s)

	rec := getSuggestions(t, s, "?pane=w1:p2")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body)
	}
	var body suggestionsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Suggestions) != 1 || body.Suggestions[0].Action != suggest.ActionStartAgent {
		t.Fatalf("suggestions = %+v, want one start_agent", body.Suggestions)
	}
}

// TestSuggestionsUnknownPane: the one genuine failure keeps its 404, so the app
// can tell "this pane is gone" from "this pane has nothing to suggest".
func TestSuggestionsUnknownPane(t *testing.T) {
	s := newTestServer(t)
	s.processInfo = &fakeProcessInfo{err: errors.New("pane not found: w9:p9")}
	s.agents = fakeAgent{err: herdr.ErrAgentNotFound}
	s.serversFor = noServers(s)

	if rec := getSuggestions(t, s, "?pane=w9:p9"); rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}

// TestSuggestionsAreCached is the cost guarantee. The app is told it may
// refetch on focus, on reconnect and on every agent status change; the cache is
// the only thing standing between that and a Herdr round-trip per event.
func TestSuggestionsAreCached(t *testing.T) {
	dir := dirtyRepo(t)
	s := newTestServer(t)
	fake := &fakeProcessInfo{info: herdr.PaneProcessInfo{
		ShellPID:                 100,
		ForegroundProcessGroupID: 200,
		ForegroundProcesses:      []herdr.PaneProcess{{PID: 200, Cwd: dir}},
	}}
	s.processInfo = fake
	s.agents = fakeAgent{agent: herdr.Agent{Kind: "claude", Cwd: dir}}
	s.serversFor = noServers(s)

	now := time.Now()
	s.suggestions.now = func() time.Time { return now }

	for range 3 {
		if rec := getSuggestions(t, s, "?pane=w1:p1"); rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
	}
	if fake.calls != 1 {
		t.Errorf("process_info called %d times for 3 requests, want 1", fake.calls)
	}

	// A different pane must not be served the first one's answer.
	if rec := getSuggestions(t, s, "?pane=w1:p2"); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if fake.calls != 2 {
		t.Errorf("process_info called %d times, want a second pane to miss the cache", fake.calls)
	}

	// Past the TTL the observation is paid for again.
	now = now.Add(suggestTTL + time.Second)
	if rec := getSuggestions(t, s, "?pane=w1:p1"); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if fake.calls != 3 {
		t.Errorf("process_info called %d times, want a re-observation past the TTL", fake.calls)
	}
}

// TestForegroundCwdPrefersTheGroupLeader: under a running command the list also
// carries the pane's shell, whose cwd does not follow a `cd` inside a script.
func TestForegroundCwdPrefersTheGroupLeader(t *testing.T) {
	info := herdr.PaneProcessInfo{
		ShellPID:                 100,
		ForegroundProcessGroupID: 200,
		ForegroundProcesses: []herdr.PaneProcess{
			{PID: 100, Name: "zsh", Cwd: "/home/me"},
			{PID: 200, Name: "npm", Cwd: "/work/repo"},
		},
	}
	if got := foregroundCwd(info); got != "/work/repo" {
		t.Errorf("foregroundCwd = %q, want the group leader's /work/repo", got)
	}
	// With no leader entry, any known cwd beats none.
	info.ForegroundProcessGroupID = 999
	if got := foregroundCwd(info); got != "/home/me" {
		t.Errorf("foregroundCwd = %q, want the first available cwd", got)
	}
	if got := foregroundCwd(herdr.PaneProcessInfo{}); got != "" {
		t.Errorf("foregroundCwd(zero) = %q, want empty", got)
	}
}

// TestSuggestionsIncludeDevServers is the convergence, end to end through the
// handler: the port scan's attribution for this pane arrives as chips in the
// same row as the git-shaped ones, ranked against them.
//
// This is the behaviour GET /ports used to be the only route to. It has to keep
// working here, because this is now the endpoint the app asks.
func TestSuggestionsIncludeDevServers(t *testing.T) {
	dir := dirtyRepo(t)
	s := newTestServer(t)
	s.processInfo = &fakeProcessInfo{info: herdr.PaneProcessInfo{
		ShellPID:                 100,
		ForegroundProcessGroupID: 200,
		ForegroundProcesses:      []herdr.PaneProcess{{PID: 200, Cwd: dir}},
	}}
	s.agents = fakeAgent{agent: herdr.Agent{Kind: "claude", Cwd: dir}}
	s.serversFor = stubServers(
		suggest.Server{Port: 5173, Proc: "node", URL: "http://100.84.12.3:5173"},
	)

	rec := getSuggestions(t, s, "?pane=w1:p1")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body)
	}
	var body suggestionsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Suggestions) != 2 {
		t.Fatalf("suggestions = %+v, want the server and the diff", body.Suggestions)
	}
	first := body.Suggestions[0]
	if first.Kind != suggest.KindDevServer || first.Action != suggest.ActionOpenURL {
		t.Errorf("first = %+v, want the dev server ranked above the diff", first)
	}
	if first.Params["url"] != "http://100.84.12.3:5173" {
		t.Errorf("params[url] = %q, want the url the scan built", first.Params["url"])
	}
	if body.Suggestions[1].Kind != suggest.KindGitDirty {
		t.Errorf("second = %+v, want the dirty-tree chip", body.Suggestions[1])
	}
}

// TestSuggestionsSurviveAScanFailure: /ports answers 502 when the scan fails,
// because there the scan IS the response. Here it is one source of several, and
// a host without `lsof` must not lose its other chips.
func TestSuggestionsSurviveAScanFailure(t *testing.T) {
	dir := dirtyRepo(t)
	s := newTestServer(t)
	s.processInfo = &fakeProcessInfo{info: herdr.PaneProcessInfo{
		ShellPID:                 100,
		ForegroundProcessGroupID: 200,
		ForegroundProcesses:      []herdr.PaneProcess{{PID: 200, Cwd: dir}},
	}}
	s.agents = fakeAgent{agent: herdr.Agent{Kind: "claude", Cwd: dir}}
	// paneServers swallows the error and returns nothing — this is that shape.
	s.serversFor = stubServers()

	rec := getSuggestions(t, s, "?pane=w1:p1")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 despite the scan failing: %s", rec.Code, rec.Body)
	}
	var body suggestionsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Suggestions) != 1 || body.Suggestions[0].Kind != suggest.KindGitDirty {
		t.Fatalf("suggestions = %+v, want the dirty-tree chip alone", body.Suggestions)
	}
}

// TestSuggestionsIncludeCreatePR is the third feature folded in, end to end:
// the pane's git situation is read ONCE, by the package that owns git for this
// bridge, and comes out as an agent-performed chip carrying its prompt.
func TestSuggestionsIncludeCreatePR(t *testing.T) {
	dir := branchWithWork(t)
	s := newTestServer(t)
	s.processInfo = &fakeProcessInfo{info: herdr.PaneProcessInfo{
		ShellPID:                 100,
		ForegroundProcessGroupID: 200,
		ForegroundProcesses:      []herdr.PaneProcess{{PID: 200, Cwd: dir}},
	}}
	s.agents = fakeAgent{agent: herdr.Agent{Kind: "claude", Cwd: dir}}
	s.serversFor = noServers(s)

	rec := getSuggestions(t, s, "?pane=w1:p1")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body)
	}
	var body suggestionsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	var pr *suggest.Suggestion
	for i := range body.Suggestions {
		if body.Suggestions[i].Kind == suggest.KindCreatePR {
			pr = &body.Suggestions[i]
		}
	}
	if pr == nil {
		t.Fatalf("suggestions = %+v, want a create_pr", body.Suggestions)
	}
	if pr.Performer != suggest.PerformerAgent {
		t.Errorf("performer = %q — a PR is opened by the agent", pr.Performer)
	}
	if pr.Action != suggest.ActionPromptAgent {
		t.Errorf("action = %q, want %q", pr.Action, suggest.ActionPromptAgent)
	}
	// The prompt is the payload; without it the app has nothing to put in front
	// of the user to edit, which is the step that keeps this reversible.
	if !strings.Contains(pr.Params["prompt"], "gh pr create") {
		t.Errorf("prompt = %q, want the PR instruction", pr.Params["prompt"])
	}
	if !strings.Contains(pr.Params["prompt"], "feat/thing") {
		t.Errorf("prompt = %q, want the real branch named", pr.Params["prompt"])
	}
}

// TestSuggestionsAgreeWithTheDiffScreen is the point of reading git once. The
// chip's file count and the diff endpoint's file list are the same number
// because they are the same read, not two implementations that happen to agree.
func TestSuggestionsAgreeWithTheDiffScreen(t *testing.T) {
	dir := branchWithWork(t)
	for _, name := range []string{"x.txt", "y.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("n\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	s := newTestServer(t)
	s.processInfo = &fakeProcessInfo{info: herdr.PaneProcessInfo{
		ShellPID:                 100,
		ForegroundProcessGroupID: 200,
		ForegroundProcesses:      []herdr.PaneProcess{{PID: 200, Cwd: dir}},
	}}
	s.agents = fakeAgent{agent: herdr.Agent{Kind: "claude", Cwd: dir}}
	s.serversFor = noServers(s)

	rec := getSuggestions(t, s, "?pane=w1:p1")
	var body suggestionsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	var detail string
	for _, sg := range body.Suggestions {
		if sg.Kind == suggest.KindGitDirty {
			detail = sg.Detail
		}
	}
	res, err := gitdiff.Collect(dir)
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if want := fmt.Sprintf("%d files changed", len(res.Files)); detail != want {
		t.Errorf("chip says %q, diff screen would list %d files", detail, len(res.Files))
	}
}

// branchWithWork is a repo on a feature branch, with a remote and one commit
// the default branch does not have — the state a pull request is offered from.
func branchWithWork(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("init", "-q", "-b", "main")
	run("config", "user.email", "t@example.com")
	run("config", "user.name", "t")
	// A remote that need not exist: nothing here pushes, and `git remote add` is
	// what "there is somewhere to push" means to the gate.
	run("remote", "add", "origin", "https://example.invalid/x.git")
	write("a.txt", "one\n")
	run("add", "-A")
	run("commit", "-qm", "one")
	run("checkout", "-qb", "feat/thing")
	write("b.txt", "two\n")
	run("add", "-A")
	run("commit", "-qm", "two")
	return dir
}
