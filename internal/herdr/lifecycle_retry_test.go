package herdr

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// These cover the three ways Herdr reports "not yet" — and the reason none of
// them can be predicted from the state it exposes.
//
// Each was a live failure before this change, on every attempt:
//
//   - agent.start rejected with `agent_pane_busy` against a pane the bridge had
//     already confirmed was at its shell prompt, so every start that created its
//     own pane failed. The same start ~1.5s later succeeded.
//   - agent.prompt rejected with `agent_not_ready` against an agent whose name
//     already resolved through agent.get, so every opening prompt was dropped.
//   - agent.start rejected with `agent_name_taken` during a restart, naming the
//     agent the restart had just killed — losing the agent and its replacement.

// scriptedSocket serves one canned reply per connection, in order, and counts
// the connections made. Each Request opens its own short-lived connection, so
// one entry in replies == one attempt.
func scriptedSocket(t *testing.T, replies []string) (path string, attempts *int) {
	t.Helper()
	// Unix socket paths are capped (~104 bytes on macOS); keep this shallow.
	dir, err := os.MkdirTemp("", "h")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path = filepath.Join(dir, "s.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	n := 0
	attempts = &n
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			// Read the request so the client's write completes, then answer with
			// the scripted line for this attempt (the last one repeats forever).
			dec := json.NewDecoder(bufio.NewReader(conn))
			var req struct {
				ID string `json:"id"`
			}
			_ = dec.Decode(&req)

			idx := n
			if idx >= len(replies) {
				idx = len(replies) - 1
			}
			n++
			w := bufio.NewWriter(conn)
			fmt.Fprintf(w, replies[idx], req.ID)
			_, _ = w.WriteString("\n")
			_ = w.Flush()
			conn.Close()
		}
	}()
	return path, attempts
}

const (
	replyOK        = `{"id":%q,"result":{"type":"ok"}}`
	replyPaneBusy  = `{"id":%q,"error":{"code":"agent_pane_busy","message":"pane is not an available shell"}}`
	replyNameTaken = `{"id":%q,"error":{"code":"agent_name_taken","message":"name already used"}}`
	replyNotReady  = `{"id":%q,"error":{"code":"agent_not_ready","message":"not an active named agent"}}`
	replyNoAgent   = `{"id":%q,"error":{"code":"agent_not_found","message":"no agent"}}`
	replyBadKind   = `{"id":%q,"error":{"code":"unknown_kind","message":"no such kind"}}`
)

func testClient(t *testing.T, path string) *Client {
	t.Helper()
	return &Client{sockPath: path}
}

// shortenStartRetries makes the give-up path testable in milliseconds.
func shortenStartRetries(t *testing.T) {
	t.Helper()
	budget, interval := startRetryBudget, startRetryInterval
	startRetryBudget, startRetryInterval = 300*time.Millisecond, 5*time.Millisecond
	t.Cleanup(func() { startRetryBudget, startRetryInterval = budget, interval })
}

// TestStartAgentRetriesWhilePaneNotStartable is the regression test for the bug
// that made starting an agent from the phone fail every single time.
func TestStartAgentRetriesWhilePaneNotStartable(t *testing.T) {
	shortenStartRetries(t)
	// The name-release probe runs first and must see the name free.
	path, attempts := scriptedSocket(t, []string{
		replyNoAgent,  // WaitForNameRelease: name is free
		replyPaneBusy, // start attempt 1 — the failure that used to be fatal
		replyPaneBusy, // start attempt 2
		replyOK,       // start attempt 3 succeeds
	})
	if err := testClient(t, path).StartAgent("a1", "claude", "w1:p1", time.Second); err != nil {
		t.Fatalf("StartAgent = %v, want nil after retrying a settling pane", err)
	}
	if *attempts != 4 {
		t.Errorf("socket attempts = %d, want 4 (1 name probe + 3 starts)", *attempts)
	}
}

// TestStartAgentRetriesNameTaken covers the destructive restart race: the name
// of the agent just stopped is still held, and giving up there leaves the pane
// with no agent at all — the old one is already dead.
func TestStartAgentRetriesNameTaken(t *testing.T) {
	shortenStartRetries(t)
	path, _ := scriptedSocket(t, []string{
		replyNoAgent,
		replyNameTaken,
		replyOK,
	})
	if err := testClient(t, path).StartAgent("a1", "claude", "w1:p1", time.Second); err != nil {
		t.Fatalf("StartAgent = %v, want nil once the name is released", err)
	}
}

// TestStartAgentSurfacesHerdrsErrorOnGiveUp: retrying must not swallow the
// diagnosis. A pane that is genuinely busy still has to report as such.
func TestStartAgentSurfacesHerdrsErrorOnGiveUp(t *testing.T) {
	shortenStartRetries(t)
	path, _ := scriptedSocket(t, []string{replyNoAgent, replyPaneBusy})
	err := testClient(t, path).StartAgent("a1", "claude", "w1:p1", time.Second)
	var serr *SocketError
	if !errors.As(err, &serr) || serr.Code != "agent_pane_busy" {
		t.Fatalf("StartAgent = %v, want Herdr's own agent_pane_busy error", err)
	}
}

// TestStartAgentDoesNotRetryPermanentFailures: an unknown kind is not going to
// become known, and retrying it would turn a fast 400 into a slow one.
func TestStartAgentDoesNotRetryPermanentFailures(t *testing.T) {
	shortenStartRetries(t)
	path, attempts := scriptedSocket(t, []string{replyNoAgent, replyBadKind})
	if err := testClient(t, path).StartAgent("a1", "nope", "w1:p1", time.Second); err == nil {
		t.Fatal("StartAgent = nil, want the unknown-kind error")
	}
	if *attempts != 2 {
		t.Errorf("socket attempts = %d, want 2 (1 name probe + 1 start, no retry)", *attempts)
	}
}

// TestPromptAgentWhenReadyRetries is the regression test for the silently
// dropped opening prompt: the agent is up and its name resolves, but Herdr does
// not consider it promptable for a moment longer.
func TestPromptAgentWhenReadyRetries(t *testing.T) {
	path, attempts := scriptedSocket(t, []string{replyNotReady, replyNotReady, replyOK})
	if err := testClient(t, path).PromptAgentWhenReady("a1", "hello", time.Second); err != nil {
		t.Fatalf("PromptAgentWhenReady = %v, want nil once the agent is promptable", err)
	}
	if *attempts != 3 {
		t.Errorf("prompt attempts = %d, want 3", *attempts)
	}
}

// TestPromptAgentWhenReadyReturnsOtherErrors: only agent_not_ready is transient.
func TestPromptAgentWhenReadyReturnsOtherErrors(t *testing.T) {
	path, attempts := scriptedSocket(t, []string{replyNoAgent})
	if err := testClient(t, path).PromptAgentWhenReady("a1", "hello", time.Second); err == nil {
		t.Fatal("PromptAgentWhenReady = nil, want the not-found error")
	}
	if *attempts != 1 {
		t.Errorf("prompt attempts = %d, want 1 (no retry on a permanent error)", *attempts)
	}
}

func TestIsRetryableStartError(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"pane still settling", &SocketError{Code: "agent_pane_busy"}, true},
		{"name not yet released", &SocketError{Code: "agent_name_taken"}, true},
		{"unknown kind is permanent", &SocketError{Code: "unknown_kind"}, false},
		{"startup timeout is permanent", &SocketError{Code: "agent_start_timeout"}, false},
		{"transport failure is not a herdr verdict", errors.New("dial: connection refused"), false},
		{"nil", nil, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isRetryableStartError(tc.err); got != tc.want {
				t.Errorf("isRetryableStartError(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
