package herdr

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// asAgentError is the only place herdr's zero-exit error objects become Go
// errors, and two of those codes drive control flow upstream: agent_not_found
// becomes a 404, agent_not_idle makes /agent-state fall back to --source
// visible. Anything else must stay a plain error so it keeps being logged.
func TestAsAgentError(t *testing.T) {
	tests := []struct {
		name string
		out  string
		want error
	}{
		{
			name: "not found maps to sentinel",
			out:  `{"error":{"code":"agent_not_found","message":"no agent in w5:p18"}}`,
			want: ErrAgentNotFound,
		},
		{
			name: "not idle maps to sentinel",
			out:  `{"error":{"code":"agent_not_idle","message":"cannot read 80 lines while w5:p18 is working"}}`,
			want: ErrAgentNotIdle,
		},
		{
			name: "no error object",
			out:  `{"result":{"agent":{}}}`,
			want: nil,
		},
		{
			name: "plain text is not an error payload",
			out:  "some terminal text\n",
			want: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := asAgentError([]byte(tt.out))
			if !errors.Is(got, tt.want) {
				t.Fatalf("asAgentError() = %v, want %v", got, tt.want)
			}
		})
	}
}

// An unrecognised code must not collapse into either sentinel — callers would
// silently degrade instead of surfacing a real failure.
func TestAsAgentErrorUnknownCode(t *testing.T) {
	err := asAgentError([]byte(`{"error":{"code":"pane_gone","message":"boom"}}`))
	if err == nil {
		t.Fatal("asAgentError() = nil, want an error")
	}
	if errors.Is(err, ErrAgentNotFound) || errors.Is(err, ErrAgentNotIdle) {
		t.Fatalf("asAgentError() = %v, want a generic error", err)
	}
	if want := "herdr: pane_gone: boom"; err.Error() != want {
		t.Fatalf("asAgentError() = %q, want %q", err, want)
	}
}

// TestRunForTimesOut is the guard against the failure this bound exists for: a
// herdr that accepts the invocation and never returns.
//
// Unbounded, that hang is permanent rather than temporary — several callers
// claim work with a flag they only release when their goroutine ends, so a
// blocked exec silently retires an agent for the life of the process.
func TestRunForTimesOut(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "herdr-hang")
	script := "#!/bin/sh\nsleep 60\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake binary: %v", err)
	}

	c := &Client{bin: bin}
	start := time.Now()
	_, err := c.runFor(300*time.Millisecond, "api", "snapshot")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("a hanging herdr returned no error; the caller would block forever")
	}
	if !strings.Contains(err.Error(), "timed out") {
		t.Errorf("error = %q, want it to name the timeout so logs are diagnosable", err)
	}
	// Must actually give up, not merely report lateness.
	if elapsed > 5*time.Second {
		t.Errorf("took %s to abandon a hung call", elapsed)
	}
}

// TestRunForPassesThroughFastCalls: the deadline must not interfere with a call
// that answers normally.
func TestRunForPassesThroughFastCalls(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "herdr-ok")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\necho '{\"ok\":true}'\n"), 0o755); err != nil {
		t.Fatalf("write fake binary: %v", err)
	}

	c := &Client{bin: bin}
	out, err := c.runFor(5*time.Second, "api", "snapshot")
	if err != nil {
		t.Fatalf("runFor: %v", err)
	}
	if !strings.Contains(string(out), `"ok":true`) {
		t.Errorf("output = %q, want the command's stdout", out)
	}
}
