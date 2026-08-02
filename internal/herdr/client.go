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
	// Cwd is the agent's working directory — the project root the transcript file
	// is keyed under (see internal/transcript.Locate).
	Cwd string `json:"cwd"`
	// AgentSession is Herdr's handle on the agent's own session. For Claude its
	// Value is the JSONL session id (== the transcript filename stem).
	AgentSession AgentSession `json:"agent_session"`
	// StateChangeSeq is a monotonically increasing counter Herdr bumps on every
	// agent state transition. It is the idempotency token for approvals (D8): an
	// approve only applies if the agent is still blocked at the same seq.
	StateChangeSeq int `json:"state_change_seq"`
}

// AgentSession is Herdr's `agent_session` object: the coding agent's own session
// identifier and where it came from. For Claude, Value is the session id used both
// as the transcript filename and as the JSONL's `sessionId` field.
type AgentSession struct {
	Agent  string `json:"agent"`
	Kind   string `json:"kind"`   // e.g. "id"
	Source string `json:"source"` // e.g. "herdr:claude"
	Value  string `json:"value"`  // the session id
}

// SessionID returns the agent's session id (agent_session.value), or "" when the
// pane has no resolved session.
func (a Agent) SessionID() string { return a.AgentSession.Value }

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

// shiftTab is the terminal control sequence for Shift+Tab (CSI Z, aka "backtab").
// Claude Code's TUI binds it to cycle the permission mode.
const shiftTab = "\x1b[Z"

// CyclePermissionMode advances a Claude pane's Shift+Tab permission mode by one
// (default -> acceptEdits -> plan -> …) by sending the CSI Z sequence over the
// existing send-text path. It deliberately does NOT use SendKeys: herdr's
// "shift+tab" key name is accepted but does not emit CSI Z, so the TUI never
// cycles — verified live. A non-Claude TUI simply ignores the bytes, so the
// kind guard lives in the handler, not here.
func (c *Client) CyclePermissionMode(pane string) error {
	return c.Send(pane, shiftTab)
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
// owned by the client. Only agent panes resolve here; non-agent panes stream
// via ReadPane + Send instead (see Pane.IsAgent).
func (c *Client) AttachCommand(target string) *exec.Cmd {
	return exec.Command(c.bin, "agent", "attach", target)
}

// Pane is the subset of `herdr pane get` fields gothalo needs to route attach
// (agent vs plain pane) and to echo identity back after create/split.
type Pane struct {
	PaneID    string `json:"pane_id"`
	TabID     string `json:"tab_id"`
	Workspace string `json:"workspace_id"`
	// Agent is the hosted agent kind (e.g. "claude") when this pane runs one,
	// empty for a plain shell / dev-server / logs pane.
	Agent  string `json:"agent"`
	Status string `json:"agent_status"`
}

// IsAgent reports whether an agent (claude, codex, …) is hosted in the pane.
// Agent panes keep the high-fidelity `agent attach` PTY stream; plain panes use
// the pane read/send bridge.
func (p Pane) IsAgent() bool { return p.Agent != "" }

type paneEnvelope struct {
	Result struct {
		Pane Pane `json:"pane"`
	} `json:"result"`
}

type tabCreateEnvelope struct {
	Result struct {
		RootPane Pane `json:"root_pane"`
	} `json:"result"`
}

// GetPane resolves a pane by id (`herdr pane get`). The error wraps herdr's
// "pane not found" message so callers can map it to 404.
func (c *Client) GetPane(paneID string) (Pane, error) {
	out, err := c.run("pane", "get", paneID)
	if err != nil {
		return Pane{}, err
	}
	var env paneEnvelope
	if err := json.Unmarshal(out, &env); err != nil {
		return Pane{}, fmt.Errorf("parse pane get: %w", err)
	}
	return env.Result.Pane, nil
}

// ReadPane returns the pane's current visible terminal frame with ANSI colour
// (`herdr pane read --source visible --format ansi`). The attach bridge polls
// this and repaints the WebSocket for non-agent panes.
func (c *Client) ReadPane(paneID string) ([]byte, error) {
	return c.run("pane", "read", paneID, "--source", "visible", "--format", "ansi")
}

// CreateTab opens a new tab (and its root pane) in a workspace
// (`herdr tab create`). workspace is required; cwd and label are optional.
// Returns the new root pane's identity. Created unfocused so the operator's
// foreground pane on the host is not stolen.
func (c *Client) CreateTab(workspace, cwd, label string) (Pane, error) {
	args := []string{"tab", "create", "--no-focus"}
	if workspace != "" {
		args = append(args, "--workspace", workspace)
	}
	if cwd != "" {
		args = append(args, "--cwd", cwd)
	}
	if label != "" {
		args = append(args, "--label", label)
	}
	out, err := c.run(args...)
	if err != nil {
		return Pane{}, err
	}
	var env tabCreateEnvelope
	if err := json.Unmarshal(out, &env); err != nil {
		return Pane{}, fmt.Errorf("parse tab create: %w", err)
	}
	return env.Result.RootPane, nil
}

// SplitPane splits an existing pane (`herdr pane split`), returning the new
// pane's identity. direction is "right" or "down"; it defaults to "down" when
// empty (Herdr requires an explicit direction). cwd is optional. Created
// unfocused, like CreateTab.
func (c *Client) SplitPane(pane, direction, cwd string) (Pane, error) {
	if direction == "" {
		direction = "down"
	}
	args := []string{"pane", "split", pane, "--no-focus", "--direction", direction}
	if cwd != "" {
		args = append(args, "--cwd", cwd)
	}
	out, err := c.run(args...)
	if err != nil {
		return Pane{}, err
	}
	var env paneEnvelope
	if err := json.Unmarshal(out, &env); err != nil {
		return Pane{}, fmt.Errorf("parse pane split: %w", err)
	}
	return env.Result.Pane, nil
}

// RunInPane types a command into a pane and submits it (`herdr pane run`). The
// whole command line is passed as a single argument (Herdr joins COMMAND...).
func (c *Client) RunInPane(pane, command string) error {
	_, err := c.run("pane", "run", pane, command)
	return err
}

// ClosePane closes a pane (`herdr pane close`). Closing a tab's last pane
// closes the tab too.
func (c *Client) ClosePane(pane string) error {
	_, err := c.run("pane", "close", pane)
	return err
}

// IsNotFound reports whether a herdr error is a "… not found" resolution
// failure (pane/tab/workspace), which callers map to HTTP 404 vs 502.
func IsNotFound(err error) bool {
	return err != nil && strings.Contains(err.Error(), "not found")
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
