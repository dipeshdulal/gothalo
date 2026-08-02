// Package herdr is a typed wrapper over the `herdr` CLI: read state (Agents),
// control (Send), and block on transitions (Wait). It shells out to the binary
// exactly as the original bridge did.
package herdr

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// ErrAgentNotFound is returned by Get/ReadText when the pane has no agent (or the
// pane id is unknown). Herdr signals this with an `agent_not_found` error object
// on a zero exit code, so callers can map it to a 404 rather than a 502.
var ErrAgentNotFound = errors.New("agent not found")

// Client talks to the local herdr CLI.
type Client struct {
	bin string
}

// New returns a Client that invokes `herdr` from PATH.
func New() *Client { return &Client{bin: "herdr"} }

func (c *Client) run(args ...string) ([]byte, error) {
	out, err := exec.Command(c.bin, args...).CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("herdr %s: %w: %s", strings.Join(args, " "), err, bytes.TrimSpace(out))
	}
	return out, nil
}

// SnapshotRaw returns the raw `herdr api snapshot` JSON, for endpoints that
// pass Herdr state straight through to the client.
func (c *Client) SnapshotRaw() ([]byte, error) {
	return c.run("api", "snapshot")
}

// Agent is the subset of snapshot agent fields gothalo uses.
type Agent struct {
	Kind      string `json:"agent"`
	Status    string `json:"agent_status"`
	PaneID    string `json:"pane_id"`
	Title     string `json:"terminal_title_stripped"`
	Workspace string `json:"workspace_id"`
	// StateChangeSeq is a monotonically increasing counter Herdr bumps on every
	// agent state transition. It is the idempotency token for approvals (D8): an
	// approve only applies if the agent is still blocked at the same seq.
	StateChangeSeq int `json:"state_change_seq"`
}

type snapshotEnvelope struct {
	Result struct {
		Snapshot struct {
			Agents []Agent `json:"agents"`
		} `json:"snapshot"`
	} `json:"result"`
}

// Agents parses the snapshot into the agent list.
func (c *Client) Agents() ([]Agent, error) {
	out, err := c.SnapshotRaw()
	if err != nil {
		return nil, err
	}
	var env snapshotEnvelope
	if err := json.Unmarshal(out, &env); err != nil {
		return nil, fmt.Errorf("parse snapshot: %w", err)
	}
	return env.Result.Snapshot.Agents, nil
}

// herdrError is the error object herdr prints (on a zero exit) when a command
// can't resolve its target, e.g. {"error":{"code":"agent_not_found",...}}.
type herdrError struct {
	Error *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// asAgentError maps a herdr error payload to a Go error: ErrAgentNotFound for a
// missing target, a generic error for anything else, or nil when there is no
// error object. Herdr returns exit 0 even for these, so run() won't have caught
// them — every command that can fail this way must check the body.
func asAgentError(out []byte) error {
	var e herdrError
	if json.Unmarshal(out, &e) == nil && e.Error != nil {
		if e.Error.Code == "agent_not_found" {
			return ErrAgentNotFound
		}
		return fmt.Errorf("herdr: %s: %s", e.Error.Code, e.Error.Message)
	}
	return nil
}

type agentGetEnvelope struct {
	Result struct {
		Agent Agent `json:"agent"`
	} `json:"result"`
}

// Get returns a single agent by pane id (`herdr agent get`). It returns
// ErrAgentNotFound when the pane has no agent, so the caller can 404.
func (c *Client) Get(pane string) (Agent, error) {
	out, err := c.run("agent", "get", pane)
	if aerr := asAgentError(out); aerr != nil {
		return Agent{}, aerr
	}
	if err != nil {
		return Agent{}, err
	}
	var env agentGetEnvelope
	if err := json.Unmarshal(out, &env); err != nil {
		return Agent{}, fmt.Errorf("parse agent get: %w", err)
	}
	return env.Result.Agent, nil
}

// ReadText returns the plain-text terminal snapshot for a pane from the given
// source (`herdr agent read <pane> --source <source> --format text`). Sources of
// interest: "detection" (the parsed current-state view) and "recent-unwrapped"
// (recent transcript, unwrapped). lines caps the snapshot when > 0. Herdr strips
// ANSI for --format text. Returns ErrAgentNotFound when the pane has no agent.
func (c *Client) ReadText(pane, source string, lines int) (string, error) {
	args := []string{"agent", "read", pane, "--source", source, "--format", "text"}
	if lines > 0 {
		args = append(args, "--lines", strconv.Itoa(lines))
	}
	out, err := c.run(args...)
	// A text read still emits a JSON error object (exit 0) when the target is gone.
	if bytes.HasPrefix(bytes.TrimSpace(out), []byte(`{"error"`)) {
		if aerr := asAgentError(out); aerr != nil {
			return "", aerr
		}
	}
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// Send types text into a pane (`herdr pane send-text`).
func (c *Client) Send(pane, text string) error {
	_, err := c.run("pane", "send-text", pane, text)
	return err
}

// SendKeys sends one or more logical keys to a pane (`herdr pane send-keys`),
// e.g. "enter" to confirm a blocked prompt. This is the keystroke analog of
// Send's `pane send-text`: it writes to the pane's terminal, which is where the
// hosted agent reads its input. The pane-level path is used (not the
// agent-level one) because `herdr agent send-keys` only accepts a currently
// "active named agent" and would reject an approval mid-transition; a pane
// always accepts keys. Key names are the ones Herdr accepts (see
// `herdr pane send-keys` help).
func (c *Client) SendKeys(pane string, keys ...string) error {
	args := append([]string{"pane", "send-keys", pane}, keys...)
	_, err := c.run(args...)
	return err
}

// AttachCommand builds (but does not start) the `herdr agent attach <target>`
// command used to stream a live terminal. The caller starts it under a PTY and
// wires its stdio to the WebSocket. Kept here so the herdr binary path stays
// owned by the client.
func (c *Client) AttachCommand(target string) *exec.Cmd {
	return exec.Command(c.bin, "agent", "attach", target)
}

// WaitResult is the settled agent state returned by Wait.
type WaitResult struct {
	Status         string
	PaneID         string
	Title          string
	StateChangeSeq int
}

type waitEnvelope struct {
	Result struct {
		Agent struct {
			Status         string `json:"agent_status"`
			PaneID         string `json:"pane_id"`
			Title          string `json:"terminal_title_stripped"`
			StateChangeSeq int    `json:"state_change_seq"`
		} `json:"agent"`
	} `json:"result"`
}

// Wait blocks until the agent in pane enters one of the given statuses, looping
// past internal timeouts. Returns (result, true) on a transition, or
// (zero, false) if the agent went away (a non-timeout error) — the caller's
// signal to stop watching it.
func (c *Client) Wait(pane string, until ...string) (WaitResult, bool) {
	args := []string{"agent", "wait", pane}
	for _, u := range until {
		args = append(args, "--until", u)
	}
	args = append(args, "--timeout", "600000") // 10 min; loop on timeout

	for {
		out, err := c.run(args...)
		if err == nil {
			var w waitEnvelope
			_ = json.Unmarshal(out, &w)
			return WaitResult{
				Status:         w.Result.Agent.Status,
				PaneID:         w.Result.Agent.PaneID,
				Title:          w.Result.Agent.Title,
				StateChangeSeq: w.Result.Agent.StateChangeSeq,
			}, true
		}
		if bytes.Contains(out, []byte(`"code":"timeout"`)) {
			continue // no transition within the window; keep waiting
		}
		return WaitResult{}, false // agent gone / unrecoverable
	}
}
