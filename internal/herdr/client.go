// Package herdr is a typed wrapper over the `herdr` CLI: read state (Agents),
// control (Send), and block on transitions (Wait). It shells out to the binary
// exactly as the original bridge did.
package herdr

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ErrAgentNotFound is returned by Get/ReadText when the pane has no agent (or the
// pane id is unknown). Herdr signals this with an `agent_not_found` error object
// on a zero exit code, so callers can map it to a 404 rather than a 502.
var ErrAgentNotFound = errors.New("agent not found")

// ErrAgentNotIdle is returned by ReadText when the requested source needs
// scrollback (e.g. "recent-unwrapped") but the agent is mid-turn: Herdr can only
// capture an alternate-screen pane's history by scrolling it while idle. Herdr's
// own hint is to retry or fall back to --source visible, so callers get a
// sentinel to branch on rather than an opaque error.
var ErrAgentNotIdle = errors.New("agent not idle")

// Client talks to the local Herdr server for one session.
//
// Control calls go over Herdr's Unix socket. The `herdr` binary is a thin
// wrapper over that same socket — confirmed with lsof: each `herdr agent wait`
// child held exactly one unix fd — so shelling out only ever bought us a process
// per call. Responses are byte-identical either way (`session.snapshot` returns
// exactly what `herdr api snapshot` prints), which is what makes the swap safe.
//
// The CLI is still used where a process is genuinely the point (`agent attach`),
// and to bootstrap the socket path itself.
type Client struct {
	bin     string
	session string // "" targets the default session (no --session flag)

	// sockMu guards the memoised control-socket path. Resolving it costs a
	// `herdr status server` exec, so caching is what makes socket calls actually
	// cheaper rather than merely equivalent: without it every request would still
	// spawn a process just to learn where to connect.
	sockMu   sync.Mutex
	sockPath string
}

// New returns a Client that invokes `herdr` from PATH against the default session.
func New() *Client { return &Client{bin: "herdr"} }

// NewForSession returns a Client scoped to the named Herdr session ("default"
// and "" both mean the default session).
func NewForSession(name string) *Client {
	if name == defaultSessionName {
		name = ""
	}
	return &Client{bin: "herdr", session: name}
}

// Session returns the session name this client targets ("" = default).
func (c *Client) Session() string { return c.session }

// SessionLabel returns the human session name, "default" for the default session.
func (c *Client) SessionLabel() string {
	if c.session == "" {
		return defaultSessionName
	}
	return c.session
}

// args prepends the --session flag for non-default sessions.
func (c *Client) args(a ...string) []string {
	if c.session == "" {
		return a
	}
	return append([]string{"--session", c.session}, a...)
}

// cliTimeout bounds an ordinary herdr CLI call. Every one of these is a
// request/response that should answer in milliseconds; 30s is "the CLI is not
// coming back" rather than "the CLI is slow".
//
// The bound matters more than the number. Without one, a wedged herdr blocks the
// caller forever, and several callers guard work with a flag they only clear on
// return — the watcher marks a pane as watched and releases it when its goroutine
// ends, so a permanently blocked `agent wait` silently retires that agent for the
// life of the process. An unbounded exec turns a temporary hang into a permanent
// one.
const cliTimeout = 30 * time.Second

// waitWindow is how long a single `agent.wait` parks before Herdr answers
// "nothing happened". Wait loops on that, so it only bounds one iteration.
const waitWindow = 10 * time.Minute

// waitBound is the transport deadline on a wait. It sits just past waitWindow so
// Herdr's own timeout always wins; this only fires when Herdr has stopped
// honouring it, turning a wedged socket into an error rather than a goroutine
// parked forever.
//
// The bound matters more than the number. Several callers guard work with a flag
// they only clear on return — the watcher marks a pane as watched and releases it
// when its goroutine ends — so an unbounded wait silently retires that agent for
// the life of the process, turning a temporary hang into a permanent one.
const waitBound = 11 * time.Minute

func (c *Client) run(args ...string) ([]byte, error) {
	return c.runFor(cliTimeout, args...)
}

// runFor executes the herdr CLI under a deadline. A timeout is reported as an
// ordinary error, which every caller already handles: the watcher drops the pane
// and rediscovers it within 10s, the ingester's liveness probe reports "can't
// tell" rather than guessing, and the notification path degrades to the pane
// title instead of the parsed prompt.
func (c *Client) runFor(d time.Duration, args ...string) ([]byte, error) {
	args = c.args(args...)
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()

	out, err := exec.CommandContext(ctx, c.bin, args...).CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return out, fmt.Errorf("herdr %s: timed out after %s", strings.Join(args, " "), d)
		}
		return out, fmt.Errorf("herdr %s: %w: %s", strings.Join(args, " "), err, bytes.TrimSpace(out))
	}
	return out, nil
}

// SnapshotRaw returns this session's snapshot payload (`session.snapshot`) — the
// `{type, snapshot}` result object, which is what `herdr api snapshot` prints
// inside its `result` envelope.
//
// This is the hottest read the app drives: every event nudges a debounced
// /snapshot refetch, so it ran once per change burst as a process spawn.
func (c *Client) SnapshotRaw() ([]byte, error) {
	return c.Request("session.snapshot", struct{}{})
}

// Agent is the subset of snapshot agent fields gothalo uses.
type Agent struct {
	Kind      string `json:"agent"`
	Status    string `json:"agent_status"`
	PaneID    string `json:"pane_id"`
	Title     string `json:"terminal_title_stripped"`
	Workspace string `json:"workspace_id"`
	// Name is the agent's Herdr label, set at `agent.start` time and empty for an
	// agent someone launched by hand. A restart reuses it so the operator's own
	// name for a pane survives — Herdr releases the name when the agent exits, so
	// the same one is free again by the time the replacement starts.
	Name string `json:"name"`
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

// Agents returns every agent Herdr knows about (`agent.list`).
//
// This is the hottest read in the bridge — the watcher rediscovers agents on a
// 10s loop and the ingester's liveness probe compares against it — so it asks
// for the agent list directly rather than pulling a full snapshot and throwing
// away the workspace/tab/pane trees.
func (c *Client) Agents() ([]Agent, error) {
	res, err := c.Request("agent.list", struct{}{})
	if err != nil {
		return nil, err
	}
	var body struct {
		Agents []Agent `json:"agents"`
	}
	if err := json.Unmarshal(res, &body); err != nil {
		return nil, fmt.Errorf("parse agent.list: %w", err)
	}
	return body.Agents, nil
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
// missing target, ErrAgentNotIdle for a scrollback read on a working pane, a
// generic error for anything else, or nil when there is no error object. Herdr
// returns exit 0 even for these, so run() won't have caught them — every command
// that can fail this way must check the body.
func asAgentError(out []byte) error {
	var e herdrError
	if json.Unmarshal(out, &e) == nil && e.Error != nil {
		switch e.Error.Code {
		case "agent_not_found":
			return ErrAgentNotFound
		case "agent_not_idle":
			return ErrAgentNotIdle
		}
		return fmt.Errorf("herdr: %s: %s", e.Error.Code, e.Error.Message)
	}
	return nil
}

// Get returns a single agent by pane id (`agent.get`). It returns
// ErrAgentNotFound when the pane has no agent, so the caller can 404.
//
// Status and state_change_seq come back in one response, which is what lets the
// notification-clearer compare them without risking a torn pair.
func (c *Client) Get(pane string) (Agent, error) {
	res, err := c.Request("agent.get", targetParams{Target: pane})
	if err != nil {
		return Agent{}, asSocketAgentError(err)
	}
	var body struct {
		Agent Agent `json:"agent"`
	}
	if err := json.Unmarshal(res, &body); err != nil {
		return Agent{}, fmt.Errorf("parse agent.get: %w", err)
	}
	return body.Agent, nil
}

// targetParams is the {"target": …} shape every pane-scoped Herdr method takes.
type targetParams struct {
	Target string `json:"target"`
}

// asSocketAgentError maps a structured socket error to the same sentinels the
// CLI path produced, so callers keep their 404/502 branching. Over the socket
// these arrive as a proper error object rather than a zero-exit JSON body, so
// the code is read directly instead of sniffing stdout.
func asSocketAgentError(err error) error {
	var serr *SocketError
	if errors.As(err, &serr) {
		switch serr.Code {
		case "agent_not_found", "pane_not_found":
			return ErrAgentNotFound
		case "agent_not_idle":
			return ErrAgentNotIdle
		}
	}
	return err
}

// ReadText returns the plain-text terminal snapshot for a pane from the given
// source (`herdr agent read <pane> --source <source> --format text`). Sources of
// interest: "detection" (the parsed current-state view) and "recent-unwrapped"
// (recent transcript, unwrapped). lines caps the snapshot when > 0. Herdr strips
// ANSI for --format text. Returns ErrAgentNotFound when the pane has no agent,
// and ErrAgentNotIdle when a scrollback source is asked of a working pane.
func (c *Client) ReadText(pane, source string, lines int) (string, error) {
	params := struct {
		Target string `json:"target"`
		Source string `json:"source"`
		Format string `json:"format"`
		Lines  *int   `json:"lines,omitempty"`
	}{Target: pane, Source: source, Format: "text"}
	if lines > 0 {
		params.Lines = &lines
	}
	res, err := c.Request("agent.read", params)
	if err != nil {
		return "", asSocketAgentError(err)
	}
	var body struct {
		Read struct {
			Text string `json:"text"`
		} `json:"read"`
	}
	if err := json.Unmarshal(res, &body); err != nil {
		return "", fmt.Errorf("parse agent.read: %w", err)
	}
	return body.Read.Text, nil
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
	return exec.Command(c.bin, c.args("agent", "attach", target)...)
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

// PaneHistoryRows is what the attach bridge asks for when seeding a plain pane's
// scrollback, and it is also Herdr's ceiling: `pane read` returns at most 1000
// rows however many are requested. Measured on two panes holding far more than
// that — a `docker compose logs -f` pane with 10,467 rows of scrollback and a
// server log with 1,960 — where `--lines` of 1100, 1500 and 20000 all returned
// exactly 999. There is no offset parameter either, so those 1000 rows are the
// entire reachable history; asking for more only costs a slower read.
const PaneHistoryRows = 1000

// ReadPaneHistory returns up to [PaneHistoryRows] rows of a pane's recent
// scrollback with ANSI colour, soft wraps joined (`herdr pane read --source
// recent-unwrapped`). Unwrapped because the phone re-wraps at its own width: the
// rows Herdr captured are folded at the *desktop's* column count, and replaying
// those folds on a narrow viewport double-wraps every long log line.
//
// Reading does not disturb the operator — on a pane sitting 1,254 rows back, a
// read left `offset_from_bottom` exactly where it was.
func (c *Client) ReadPaneHistory(paneID string) ([]byte, error) {
	return c.run("pane", "read", paneID,
		"--source", "recent-unwrapped",
		"--lines", strconv.Itoa(PaneHistoryRows),
		"--format", "ansi")
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

// Wait blocks until the agent in pane enters one of the given statuses, looping
// past internal timeouts. Returns (result, true) on a transition, or
// (zero, false) if the agent went away (a non-timeout error) — the caller's
// signal to stop watching it.
func (c *Client) Wait(pane string, until ...string) (WaitResult, bool) {
	params := struct {
		Target    string   `json:"target"`
		Until     []string `json:"until"`
		TimeoutMS int      `json:"timeout_ms"`
	}{Target: pane, Until: until, TimeoutMS: int(waitWindow / time.Millisecond)}

	for {
		// One connection per wait, parked for the window. This used to be a child
		// `herdr agent wait` process — which opened exactly this connection itself
		// and then respawned every time the window elapsed. Same socket, same
		// blocking, one fewer process per agent for the life of the bridge.
		res, err := c.RequestFor(waitBound, "agent.wait", params)
		if err == nil {
			var body struct {
				Agent Agent `json:"agent"`
			}
			if jerr := json.Unmarshal(res, &body); jerr != nil {
				return WaitResult{}, false
			}
			return WaitResult{
				Status:         body.Agent.Status,
				PaneID:         body.Agent.PaneID,
				Title:          body.Agent.Title,
				StateChangeSeq: body.Agent.StateChangeSeq,
			}, true
		}
		if isWaitTimeout(err) {
			continue // no transition within the window; keep waiting
		}
		return WaitResult{}, false // agent gone / unrecoverable
	}
}

// isWaitTimeout reports whether a failed wait was Herdr's own "nothing happened
// in the window" answer rather than a real failure. Herdr replies with a
// structured {"code":"timeout"} error; a transport-level deadline (waitBound
// firing because Herdr stopped honouring its own timeout) is deliberately NOT
// treated as one, so a wedged socket ends the wait instead of spinning on it.
func isWaitTimeout(err error) bool {
	var serr *SocketError
	return errors.As(err, &serr) && serr.Code == "timeout"
}
