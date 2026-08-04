package herdr

import (
	"errors"
	"testing"
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
