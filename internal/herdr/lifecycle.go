package herdr

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Agent lifecycle: discovering which agent kinds this host can run, launching
// one into a pane, and taking one down again.
//
// Herdr owns exactly one half of this. `agent.start` puts a SUPPORTED agent into
// an EXISTING shell pane and only returns once it has verified that the expected
// agent is really running in that same terminal and is ready for input. That
// identity check is the whole reason to go through Herdr rather than typing
// "claude" into a pane and hoping: without it the bridge would report a started
// agent for a pane that actually printed "command not found", and every
// downstream read (agent.get, the watcher, the transcript) would keep answering
// "no agent" with no explanation.
//
// What Herdr does NOT offer is a stop. There is no agent.stop / agent.kill in
// protocol 19 — the full method list from `herdr api schema --json` has
// agent.{explain,focus,get,list,prompt,read,rename,send_keys,start,view.*,wait}
// and nothing else. Taking an agent down is therefore done the way an operator
// does it, by interrupting it at the terminal, and — crucially — CONFIRMED
// rather than assumed: see StopAgent.

const (
	// startSlack is how far past Herdr's own startup timeout the transport
	// deadline sits on an agent.start. Herdr's timeout must always be the one
	// that fires, so a "the agent didn't come up in 30s" answer arrives as a
	// structured Herdr error the caller can explain, not as a severed socket.
	startSlack = 10 * time.Second

	// shellPollInterval is how often a pane is re-read while waiting for it to
	// come back to (or settle at) its interactive shell prompt.
	shellPollInterval = 150 * time.Millisecond

	// interruptGap is the pause between the interrupts StopAgent sends. Agent
	// TUIs deliberately make a single Ctrl-C non-fatal — Claude interrupts the
	// current turn and then asks you to "press again to exit" — so quitting one
	// needs repeated interrupts spaced far enough apart to be seen as separate
	// keypresses, but well inside the "again" window (~2s) that makes the second
	// one mean "quit" rather than starting the sequence over.
	interruptGap = 400 * time.Millisecond

	// interruptRounds bounds how many interrupts StopAgent will send. A working
	// agent typically needs three (abort the turn, arm the quit, quit); the extra
	// round is headroom for a slow redraw. Every round re-checks first, so an
	// agent that quit on round one is never sent a stray keystroke.
	interruptRounds = 4

	// NameSettleWait bounds the wait for a live agent name to appear (after a
	// start) or be released (after a stop). Herdr updates its name registry
	// asynchronously from the start/stop that causes it, so the moment a start
	// returns is not the moment its name resolves, and the moment a stop returns
	// is not the moment its name is free again.
	//
	// A ceiling on a poll loop, not a delay.
	NameSettleWait = 3 * time.Second

	// PromptReadyBudget bounds how long an opening prompt is retried against an
	// agent Herdr has not yet made promptable. Exported because the decision to
	// wait belongs to the caller sending the prompt, not to the transport.
	//
	// Generous on purpose: the alternative to waiting is dropping the operator's
	// first instruction, which is worse than a slow start.
	PromptReadyBudget = 10 * time.Second
)

// Retry pacing for agent.start. These are vars rather than consts only so tests
// can exercise the give-up path without spending the full budget doing it.
var (
	// startRetryBudget bounds how long StartAgent keeps retrying a start Herdr
	// rejects because the pane is not yet startable.
	//
	// This exists because Herdr's notion of "an available shell pane" is STRICTER
	// than the bridge's, and settles later. A freshly created pane reaches
	// PaneProcessInfo.AtShellPrompt in ~0.15s (measured), and the bridge waits for
	// exactly that before starting — yet an agent.start issued at that moment
	// still fails with `agent_pane_busy`, while the same start ~1.5s later
	// succeeds. Whatever Herdr checks in addition is internal to it and not
	// observable through the pane API, so this does not predict readiness: it
	// retries the real operation until Herdr accepts it.
	//
	// Sized in failed attempts rather than seconds: each rejected start costs
	// ~1.5s, so this allows roughly six before giving up and returning Herdr's
	// own error.
	startRetryBudget = 10 * time.Second

	// startRetryInterval is the pause between rejected start attempts. Short,
	// because the attempt itself dominates.
	startRetryInterval = 250 * time.Millisecond
)

// AgentKind names both a Herdr agent kind and, per Herdr's own `--kind` help
// ("Supported agent kind and canonical executable"), the executable that kind
// runs. That equivalence is what lets the bridge answer "is this installed?"
// without a hardcoded kind→binary table.
type AgentKind = string

// possibleValuesRe pulls the enum out of a clap-generated `--help` block:
// "[possible values: pi, claude, codex, …]".
var possibleValuesRe = regexp.MustCompile(`\[possible values:\s*([^\]]*)\]`)

// kindsLineRe matches the "kinds: pi|claude|codex|…" summary line Herdr prints
// when `herdr agent` is run without a subcommand.
var kindsLineRe = regexp.MustCompile(`(?m)^\s*kinds:\s*(\S+)\s*$`)

// AgentKinds returns every agent kind this Herdr build can start, in Herdr's own
// order.
//
// Herdr does not expose the catalog over the control socket: `agent.start`'s
// params type the kind as a bare string, and `server.agent_manifests` reports
// only the kinds that ship a *detection* manifest — 19 of the 21 startable ones
// on the build this was written against, so it is a subset, not the list. The
// binary's own help is the authority, exactly as Herdr's agent skill file says
// ("The installed binary is the authority for command syntax"), which is why
// this shells out instead of asking the socket.
//
// Two forms are read, newest-first: the `--kind` enum in `agent start --help`
// (clap-generated, exit 0, inert — it prints and exits without touching the
// session), then the `kinds:` summary line from the bare `agent` group listing
// (a usage error, exit 2, but it still prints the list). Output is parsed
// regardless of exit status for that reason.
func (c *Client) AgentKinds() ([]AgentKind, error) {
	if out, _ := c.run("agent", "start", "--help"); len(out) > 0 {
		if kinds := kindsFromStartHelp(string(out)); len(kinds) > 0 {
			return kinds, nil
		}
	}
	if out, _ := c.run("agent"); len(out) > 0 {
		if kinds := kindsFromGroupUsage(string(out)); len(kinds) > 0 {
			return kinds, nil
		}
	}
	return nil, fmt.Errorf("herdr did not report its agent kinds")
}

// kindsFromStartHelp extracts the `--kind` enum from `agent start --help`. It
// anchors on the `--kind` option first so a future flag that also carries
// possible values can't be mistaken for the kind list.
func kindsFromStartHelp(help string) []AgentKind {
	i := strings.Index(help, "--kind")
	if i < 0 {
		return nil
	}
	m := possibleValuesRe.FindStringSubmatch(help[i:])
	if m == nil {
		return nil
	}
	return splitKinds(m[1], ",")
}

// kindsFromGroupUsage extracts the pipe-separated `kinds:` line from the bare
// `herdr agent` usage block.
func kindsFromGroupUsage(usage string) []AgentKind {
	m := kindsLineRe.FindStringSubmatch(usage)
	if m == nil {
		return nil
	}
	return splitKinds(m[1], "|")
}

func splitKinds(list, sep string) []AgentKind {
	var kinds []AgentKind
	for _, k := range strings.Split(list, sep) {
		if k = strings.TrimSpace(k); k != "" {
			kinds = append(kinds, k)
		}
	}
	return kinds
}

// AgentManifestKinds returns the kinds Herdr holds an agent-detection manifest
// for (`server.agent_manifests`).
//
// This is NOT "which agents can be started" — it is "which agents Herdr can
// classify once they are running". A kind without a manifest still launches, but
// Herdr can never move it past `unknown`, so the app would show a live agent it
// can never report idle/working/blocked for. Surfacing it lets the launch picker
// warn instead of silently producing a dead-looking agent.
func (c *Client) AgentManifestKinds() ([]AgentKind, error) {
	res, err := c.Request("server.agent_manifests", struct{}{})
	if err != nil {
		return nil, err
	}
	return parseManifestKinds(res)
}

func parseManifestKinds(res json.RawMessage) ([]AgentKind, error) {
	var body struct {
		Manifests []struct {
			Agent string `json:"agent"`
		} `json:"manifests"`
	}
	if err := json.Unmarshal(res, &body); err != nil {
		return nil, fmt.Errorf("parse server.agent_manifests: %w", err)
	}
	kinds := make([]AgentKind, 0, len(body.Manifests))
	for _, m := range body.Manifests {
		if m.Agent != "" {
			kinds = append(kinds, m.Agent)
		}
	}
	return kinds, nil
}

// PaneProcess is one process holding a pane's foreground process group.
type PaneProcess struct {
	Name    string `json:"name"`
	CmdLine string `json:"cmdline"`
	PID     int    `json:"pid"`
	Cwd     string `json:"cwd"`
}

// PaneProcessInfo is `pane.process_info`: who currently owns the pane's
// terminal. It is the only authoritative answer Herdr gives to "is this pane
// free?", and both halves of the lifecycle depend on it — a start needs a pane
// at its shell prompt, and a stop is only really done once the pane is back at
// one.
type PaneProcessInfo struct {
	ForegroundProcessGroupID int           `json:"foreground_process_group_id"`
	ShellPID                 int           `json:"shell_pid"`
	ForegroundProcesses      []PaneProcess `json:"foreground_processes"`
}

// AtShellPrompt reports whether the pane's own shell holds the foreground —
// Herdr's definition of an "available shell pane" (its agent skill: "at its
// interactive prompt, with the shell itself in the foreground and no foreground
// command, editor, or agent running").
//
// The test is the pid comparison, not the process list: a pane running an agent
// reports a foreground group led by the agent (or its wrapper) while shell_pid
// stays put, so equality is exactly "nothing is running in front of the shell".
func (p PaneProcessInfo) AtShellPrompt() bool {
	return p.ShellPID != 0 && p.ForegroundProcessGroupID == p.ShellPID
}

// ForegroundCommand names whatever is holding the pane, for an error message
// that says "pane is busy running npm run dev" instead of "pane is busy".
// Empty when the shell itself is in front.
func (p PaneProcessInfo) ForegroundCommand() string {
	if p.AtShellPrompt() {
		return ""
	}
	for _, proc := range p.ForegroundProcesses {
		if proc.PID == p.ForegroundProcessGroupID && proc.CmdLine != "" {
			return proc.CmdLine
		}
	}
	if len(p.ForegroundProcesses) > 0 {
		return p.ForegroundProcesses[0].CmdLine
	}
	return ""
}

// PaneProcessInfo reads which processes hold a pane's foreground
// (`pane.process_info`).
func (c *Client) PaneProcessInfo(pane string) (PaneProcessInfo, error) {
	res, err := c.Request("pane.process_info", struct {
		PaneID string `json:"pane_id"`
	}{PaneID: pane})
	if err != nil {
		return PaneProcessInfo{}, asSocketAgentError(err)
	}
	var body struct {
		Info PaneProcessInfo `json:"process_info"`
	}
	if err := json.Unmarshal(res, &body); err != nil {
		return PaneProcessInfo{}, fmt.Errorf("parse pane.process_info: %w", err)
	}
	return body.Info, nil
}

// WaitForShellPrompt polls a pane until its shell is back in the foreground, or
// within elapses. It returns the last reading and whether the prompt was
// reached.
//
// A freshly split pane needs this before anything is typed into it: Herdr
// returns from pane.split as soon as the pane exists, but the shell behind it is
// still running its rc files, and bytes written before the prompt appears are
// simply lost. That failure is invisible — the pane looks fine and the agent
// never arrives — so the wait is cheaper than the confusion.
func (c *Client) WaitForShellPrompt(pane string, within time.Duration) (PaneProcessInfo, bool) {
	deadline := time.Now().Add(within)
	var last PaneProcessInfo
	for {
		info, err := c.PaneProcessInfo(pane)
		if err == nil {
			last = info
			if info.AtShellPrompt() {
				return info, true
			}
		}
		if time.Now().After(deadline) {
			return last, false
		}
		time.Sleep(shellPollInterval)
	}
}

// StartAgent launches kind into an existing shell pane under the given name
// (`agent.start`), blocking until Herdr has confirmed the agent is up and ready
// for input.
//
// name must match Herdr's rule — `[a-z][a-z0-9_-]{0,31}`, unique among LIVE
// agents (a name is released when its agent exits, so a restart may reuse it).
// timeout is Herdr's own startup budget; the transport deadline is deliberately
// set past it so Herdr's structured "startup timed out" always wins over a
// severed connection.
//
// Two preconditions are handled here, because neither becomes true at the moment
// the operation causing it returns:
//
//   - The NAME must be free. Herdr releases a name some time after the agent
//     holding it exits, so a restart reusing the same derived name can collide
//     with the agent it just killed. This one IS observable, so it is waited for.
//   - The PANE must be startable by Herdr's own definition, which is stricter
//     than "at a shell prompt" and settles later. That is NOT observable through
//     the pane API, so it is not predicted: the start is retried until Herdr
//     stops rejecting it. See startRetryBudget.
//
// On exhaustion Herdr's own structured error is returned unchanged, so a pane
// that is genuinely busy still reports as `agent_pane_busy` — just later.
func (c *Client) StartAgent(name, kind, pane string, timeout time.Duration) error {
	c.WaitForNameRelease(name, NameSettleWait)

	params := struct {
		Name      string `json:"name"`
		Kind      string `json:"kind"`
		PaneID    string `json:"pane_id"`
		TimeoutMS int    `json:"timeout_ms"`
	}{Name: name, Kind: kind, PaneID: pane, TimeoutMS: int(timeout / time.Millisecond)}

	deadline := time.Now().Add(startRetryBudget)
	for {
		_, err := c.RequestFor(timeout+startSlack, "agent.start", params)
		if err == nil {
			return nil
		}
		if !isRetryableStartError(err) || time.Now().After(deadline) {
			return err
		}
		time.Sleep(startRetryInterval)
	}
}

// isRetryableStartError reports whether a failed agent.start is worth trying
// again. Both codes describe a precondition that is still settling rather than a
// wrong request: the pane is not startable YET, or the previous holder of the
// name has not been reaped YET. Every other failure — an unknown kind, a startup
// timeout, a malformed name — is permanent and returned immediately.
func isRetryableStartError(err error) bool {
	var serr *SocketError
	if !errors.As(err, &serr) {
		return false
	}
	return serr.Code == "agent_pane_busy" || serr.Code == "agent_name_taken"
}

// WaitForNameRelease blocks until name no longer resolves to a live agent,
// reporting whether it came free.
//
// Herdr releases a name some time AFTER the agent holding it exits, so a
// restart that reuses the same derived name races the agent it just killed.
// Unlike the readiness conditions around start and prompt, this one is
// faithfully observable through agent.get, so it is waited for rather than
// discovered by failing.
func (c *Client) WaitForNameRelease(name string, within time.Duration) bool {
	deadline := time.Now().Add(within)
	for {
		if _, err := c.Get(name); errors.Is(err, ErrAgentNotFound) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(shellPollInterval)
	}
}

// PromptAgentWhenReady submits an opening prompt, retrying while Herdr reports
// the agent is not ready to receive one.
//
// A started agent becomes promptable in stages, and none of them coincide with
// agent.start returning: the name enters the registry (agent.get resolves), and
// then — measurably later — the agent becomes an "active named agent" that
// agent.prompt will accept. Waiting on agent.get is NOT enough; that was the
// original bug, where a healthy agent rejected its own opening prompt.
//
// As with StartAgent, the operation is treated as the only authority on its own
// preconditions rather than predicting them from a field that might not be the
// one Herdr consults.
func (c *Client) PromptAgentWhenReady(target, text string, within time.Duration) error {
	deadline := time.Now().Add(within)
	for {
		err := c.PromptAgent(target, text)
		if err == nil {
			return nil
		}
		var serr *SocketError
		if !errors.As(err, &serr) || serr.Code != "agent_not_ready" || time.Now().After(deadline) {
			return err
		}
		time.Sleep(shellPollInterval)
	}
}

// PromptAgent submits text to an agent as one atomic prompt (`agent.prompt`),
// without waiting for the turn.
//
// This is not the same as POST /send typing the text: agent.prompt submits the
// body and its Enter together while honouring the pane's live bracketed-paste
// mode, which is what stops a multi-line opening prompt from landing as several
// half-submitted messages. Herdr still bounds itself (it gives up with
// `agent_prompt_stalled` if the agent shows no lifecycle change within ~5s), so
// no wait option is passed — the caller's HTTP request must not hang on a turn.
func (c *Client) PromptAgent(target, text string) error {
	params := struct {
		Target string `json:"target"`
		Text   string `json:"text"`
	}{Target: target, Text: text}
	_, err := c.Request("agent.prompt", params)
	return asSocketAgentError(err)
}

// StopAgent takes the agent hosted in pane down, leaving the pane itself alive,
// and reports whether the pane actually came back to its shell prompt.
//
// Herdr has no stop method (see the note at the top of this file), so this does
// what an operator does: send the terminal interrupt, repeatedly, until the
// agent quits. Agent TUIs make a single Ctrl-C deliberately non-fatal — it
// aborts the current turn and arms a "press again to exit" — so one interrupt is
// never enough, and a fixed number of them is never *guaranteed* to be enough
// either.
//
// That is why the return value is an observation, not an assumption. Success is
// pane.process_info showing the shell back in the foreground, which is true only
// once the agent process is genuinely gone; a caller that got false must NOT
// report the agent stopped, because the likely state is an agent that merely had
// its turn interrupted and is sitting there, alive, waiting for input.
//
// The pane, its scrollback and its working directory all survive — the shell
// never moved, so a restart lands in the same directory without the bridge
// having to remember or re-enter it.
func (c *Client) StopAgent(pane string, within time.Duration) (bool, error) {
	deadline := time.Now().Add(within)
	for round := 0; round < interruptRounds; round++ {
		// Re-check before every interrupt, so an agent that already quit is never
		// sent a stray Ctrl-C that would land on the bare shell instead.
		if info, err := c.PaneProcessInfo(pane); err == nil && info.AtShellPrompt() {
			return true, nil
		}
		if err := c.SendKeys(pane, "ctrl+c"); err != nil {
			return false, err
		}
		time.Sleep(interruptGap)
		if time.Now().After(deadline) {
			break
		}
	}
	_, ok := c.WaitForShellPrompt(pane, time.Until(deadline))
	return ok, nil
}
