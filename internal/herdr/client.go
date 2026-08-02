// Package herdr is a typed wrapper over the `herdr` CLI: read state (Agents),
// control (Send), and block on transitions (Wait). It shells out to the binary
// exactly as the original bridge did.
package herdr

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

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

// Send types text into a pane (`herdr pane send-text`).
func (c *Client) Send(pane, text string) error {
	_, err := c.run("pane", "send-text", pane, text)
	return err
}

// WaitResult is the settled agent state returned by Wait.
type WaitResult struct {
	Status string
	PaneID string
	Title  string
}

type waitEnvelope struct {
	Result struct {
		Agent struct {
			Status string `json:"agent_status"`
			PaneID string `json:"pane_id"`
			Title  string `json:"terminal_title_stripped"`
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
				Status: w.Result.Agent.Status,
				PaneID: w.Result.Agent.PaneID,
				Title:  w.Result.Agent.Title,
			}, true
		}
		if bytes.Contains(out, []byte(`"code":"timeout"`)) {
			continue // no transition within the window; keep waiting
		}
		return WaitResult{}, false // agent gone / unrecoverable
	}
}
