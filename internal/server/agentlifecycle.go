package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// Agent lifecycle from the phone: start an agent, restart one, stop one.
//
// Everything else in this bridge assumes an agent already exists — it can watch,
// steer and approve work, but the work has to have been started at a desk. These
// three endpoints close that loop.
//
// They are deliberately NOT part of the generic POST /herdr proxy. That proxy
// forwards one method with params verbatim, which is exactly wrong here for two
// reasons. First, a start is not one method: it is resolve-target →
// (create pane) → wait for the shell prompt → agent.start → optional first
// prompt, and a client driving those five steps over five round-trips would own
// the failure states in between (a created pane with no agent in it, a started
// agent with no prompt). Second, "params verbatim" means no server-side
// validation, and the one thing this feature must not do is let a phone start a
// process at an arbitrary path — see validateCWD. Herdr has no stop method at
// all, so /agent/stop could not be a proxied call even in principle.
//
// See docs/CONTRACT-agent-lifecycle.md.

const (
	// startTimeoutDefault is Herdr's startup budget when the caller names none.
	// Herdr's own default is 30s; agents on a cold cache (a first `claude` run,
	// an npm-shim launch) routinely take longer than that, and the cost of being
	// generous is only a slower failure.
	startTimeoutDefault = 60 * time.Second

	// startTimeoutMin / startTimeoutMax bracket what a caller may ask for. The
	// bounds are Herdr's (it rejects timeout_ms outside 3s–300s); clamping here
	// turns a phone's bad number into a working request rather than a 502.
	startTimeoutMin = 5 * time.Second
	startTimeoutMax = 300 * time.Second

	// shellSettleWindow is how long a freshly created pane is given to reach its
	// interactive prompt before the start gives up. Shells reach it in well under
	// a second; this is sized for a slow rc file, not for a hung one.
	shellSettleWindow = 8 * time.Second

	// stopWindow bounds the interrupt-and-confirm cycle in StopAgent. Long enough
	// for an agent mid-turn to abort, unwind and quit; short enough that a phone
	// gets a real answer rather than a timeout.
	stopWindow = 12 * time.Second
)

// agentNameRe is Herdr's own rule for an agent name (from its agent skill:
// "Names must match [a-z][a-z0-9_-]{0,31} and be unique among live agents").
// Enforced here so a bad name is a 400 explaining the rule, not an opaque Herdr
// rejection after a pane has already been created.
var agentNameRe = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,31}$`)

// nameSanitizeRe matches every character Herdr will not accept in a name.
var nameSanitizeRe = regexp.MustCompile(`[^a-z0-9_-]+`)

// ---- GET /agents/available ----

// availableAgent is one agent kind this host can actually launch.
type availableAgent struct {
	Kind string `json:"kind"`
	// Path is where the kind's executable was found. Returned because "installed"
	// is a claim about this machine, and the path is what makes it checkable.
	Path string `json:"path"`
	// StateReporting is whether Herdr holds a detection manifest for the kind. False
	// means it will start and run but Herdr can never classify it beyond `unknown`,
	// so it will never go blocked/idle/done in the app — worth warning about before
	// launch rather than explaining afterwards.
	StateReporting bool `json:"state_reporting"`
}

// GET /agents/available — which agent kinds can actually be started here.
//
// Answered by intersecting two sources, neither of them a list in this codebase:
//
//  1. Herdr's own catalog of startable kinds (herdr.Client.AgentKinds) — the
//     `--kind` enum the running binary accepts, 21 kinds on the build this was
//     written against.
//  2. Whether each kind's executable resolves on the bridge's PATH. Herdr
//     documents a kind as its "canonical executable", so the kind name IS the
//     binary name; no kind→command table is needed or kept.
//
// `server.agent_manifests` is read too, but only for state_reporting — it lists
// the kinds Herdr can *classify*, which is a different (and smaller) set than
// the kinds it can *start*, and using it as the catalog would silently hide
// startable agents.
//
// The PATH caveat is real and worth knowing: the set is resolved against the
// bridge daemon's environment, not an interactive login shell. An agent
// installed only by a PATH line in ~/.zshrc is invisible here unless the daemon
// inherited that PATH. That is a false negative (an agent that exists is not
// offered), never a false positive, which is the right way round — the app never
// offers a kind that cannot start.
func (s *Server) handleAgentsAvailable(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "use GET", http.StatusMethodNotAllowed)
		return
	}

	// The kind catalog is a property of the herdr binary, not of a session, so
	// the default client answers for every session.
	c := s.sessions.Default()
	kinds, err := c.AgentKinds()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	// Manifests are a nice-to-have: a failure here downgrades every entry to
	// state_reporting:false rather than failing a request that can still answer
	// the question the app asked.
	manifests, merr := c.AgentManifestKinds()
	if merr != nil {
		log.Warn("agents/available: manifest read failed", "err", merr)
	}

	agents := availableAgents(kinds, manifests, exec.LookPath)
	writeJSON(w, map[string]any{
		"agents":      agents,
		"known_kinds": kinds,
		"discovery":   "herdr agent kinds + PATH lookup",
	})
}

// availableAgents keeps the kinds whose executable resolves, tagging each with
// whether Herdr can classify its state. lookPath is exec.LookPath in production
// and a stub in tests, so discovery is testable without installing agents.
func availableAgents(kinds, manifestKinds []string, lookPath func(string) (string, error)) []availableAgent {
	hasManifest := make(map[string]bool, len(manifestKinds))
	for _, k := range manifestKinds {
		hasManifest[k] = true
	}
	out := make([]availableAgent, 0, len(kinds))
	for _, kind := range kinds {
		path, err := lookPath(kind)
		if err != nil {
			continue
		}
		out = append(out, availableAgent{
			Kind:           kind,
			Path:           path,
			StateReporting: hasManifest[kind],
		})
	}
	return out
}

// ---- working-directory validation ----

// validateCWD is the guard between a phone and an arbitrary process launch.
//
// A start request names the directory a shell — and then an agent with full tool
// access — will run in. That is the single most dangerous field on this surface,
// so it is checked here rather than trusted to Herdr, which will happily open a
// pane anywhere. Four rules, each rejecting a different way of naming somewhere
// unintended:
//
//   - absolute only. A relative path resolves against the daemon's working
//     directory, which is an implementation detail no client can reason about,
//     so the same request would mean different places on different installs.
//   - already clean. `filepath.Clean` collapses `..`, `.` and `//`, so demanding
//     the input equal its own clean form rejects every traversal form outright
//     instead of silently normalising it. Normalising would be worse than
//     rejecting: the path that got logged and the path that got used would agree,
//     but neither would be what the caller wrote.
//   - must exist, and must be a directory. Starting a shell in a missing or
//     non-directory path fails in the terminal, after a pane has been created —
//     far more confusing than a 400.
//
// Symlinks are followed (os.Stat, not Lstat) on purpose: /tmp and /var are
// symlinks on macOS, and rejecting them would reject ordinary directories for
// no security gain — a symlink is not a traversal, it is where the filesystem
// says the directory is.
func validateCWD(dir string) error {
	if !filepath.IsAbs(dir) {
		return fmt.Errorf("cwd must be an absolute path, got %q", dir)
	}
	if strings.Contains(dir, "\x00") {
		return errors.New("cwd contains a NUL byte")
	}
	if clean := filepath.Clean(dir); clean != dir {
		return fmt.Errorf("cwd must be a canonical path with no %q, %q or %q segments (did you mean %q?)", "..", ".", "//", clean)
	}
	info, err := os.Stat(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("cwd does not exist: %s", dir)
		}
		return fmt.Errorf("cwd is unreadable: %v", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("cwd is not a directory: %s", dir)
	}
	return nil
}

// agentName picks the Herdr name for a launch: the caller's if they gave one
// (validated against Herdr's rule), otherwise one derived from the kind and the
// pane.
//
// The derived form is deterministic rather than random because it has to be
// unique among live agents, and a pane hosts at most one agent — so keying on
// the pane id gives uniqueness for free, and a restart of the same pane
// reproduces the same name.
func agentName(explicit, kind, barePane string) (string, error) {
	if explicit != "" {
		if !agentNameRe.MatchString(explicit) {
			return "", fmt.Errorf("name must match [a-z][a-z0-9_-]{0,31}, got %q", explicit)
		}
		return explicit, nil
	}
	derived := nameSanitizeRe.ReplaceAllString(strings.ToLower(kind+"-"+barePane), "-")
	if len(derived) > 32 {
		derived = derived[:32]
	}
	derived = strings.TrimRight(derived, "-_")
	if !agentNameRe.MatchString(derived) {
		return "", fmt.Errorf("could not derive a valid agent name from kind %q and pane %q", kind, barePane)
	}
	return derived, nil
}

// ---- POST /agent/start ----

// agentStartRequest is the POST /agent/start body. Exactly one of pane_id,
// split_from or workspace_id names the target.
type agentStartRequest struct {
	Kind string `json:"kind"`

	PaneID      string `json:"pane_id"`      // target: an existing, idle shell pane
	SplitFrom   string `json:"split_from"`   // target: a new pane split off this one
	Direction   string `json:"direction"`    // "right" | "down" (split only)
	WorkspaceID string `json:"workspace_id"` // target: a new tab in this workspace
	Label       string `json:"label"`        // new-tab label (new-tab only)

	CWD       string `json:"cwd"`
	Prompt    string `json:"prompt"`
	Name      string `json:"name"`
	TimeoutMS int    `json:"timeout_ms"`
}

// POST /agent/start — launch an agent and hand back somewhere to navigate to.
//
//	{"kind":"claude", "split_from":"wN:p1", "cwd":"/src/app", "prompt":"fix the build"}
//	{"kind":"claude", "workspace_id":"wN", "label":"review", "cwd":"/src/app"}
//	{"kind":"claude", "pane_id":"wN:p7"}
//
// Exactly one of pane_id / split_from / workspace_id names the target; the first
// reuses an existing idle shell pane, the other two create one first. cwd is
// optional (the new pane inherits its parent's directory when omitted) and is
// rejected outright for pane_id, because a shell that is already sitting at a
// prompt cannot be moved without typing a `cd` into it — and typing shell
// commands into a pane on a phone's say-so is precisely what validateCWD exists
// to prevent. prompt, when set, is submitted as the agent's opening message once
// it is ready.
//
// The response carries the SESSION-QUALIFIED pane id ("acme/w4:p7"), which is
// what every other endpoint and the app's router address, so a successful start
// can be navigated to without a second lookup.
//
// Ordering matters and is deliberate: everything that can be checked without
// side effects — the body's shape, the working directory, the kind being
// installed, the target being free — is checked BEFORE any pane is created. A
// request that is going to fail should not leave a stray pane behind. Once a
// pane has been created the response is committed to reporting it: if the agent
// then fails to start, the error names the pane id so the app can offer to close
// it, rather than orphaning a pane nobody knows about.
func (s *Server) handleAgentStart(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "use POST", http.StatusMethodNotAllowed)
		return
	}
	var body agentStartRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "want {kind, one of pane_id|split_from|workspace_id}", http.StatusBadRequest)
		return
	}
	if body.Kind == "" {
		http.Error(w, "want {kind}", http.StatusBadRequest)
		return
	}

	target, mode, err := startTarget(body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if body.CWD != "" {
		if mode == targetExistingPane {
			http.Error(w, "cwd cannot be set when starting in an existing pane — it inherits that pane's shell directory", http.StatusBadRequest)
			return
		}
		if err := validateCWD(body.CWD); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}

	c, session, bareTarget, err := s.target(target)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	// Kind check before anything is created: an uninstalled kind would otherwise
	// surface as a 30-second startup timeout on a pane that now exists.
	if status, err := s.checkKindInstalled(body.Kind); err != nil {
		http.Error(w, err.Error(), status)
		return
	}

	pane, created, status, err := s.resolveStartPane(c, mode, bareTarget, body)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}

	name, err := agentName(body.Name, body.Kind, pane.PaneID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	qualified := herdr.Qualify(session, pane.PaneID)
	if err := c.StartAgent(name, body.Kind, pane.PaneID, startTimeout(body.TimeoutMS)); err != nil {
		msg := fmt.Sprintf("agent %s failed to start in %s: %v", body.Kind, qualified, err)
		if created {
			msg += " (the pane was created and is still open)"
		}
		log.Error("agent start failed", "pane", qualified, "kind", body.Kind, "created", created, "err", err)
		http.Error(w, msg, http.StatusBadGateway)
		return
	}

	// Do not hand back a pane the client cannot safely open. Until the agent
	// reports its session id the transcript for this pane resolves by working
	// directory, which in a directory that already hosts an agent serves someone
	// else's conversation. See herdr.WaitForAgentSession.
	sessionID := c.WaitForAgentSession(pane.PaneID, herdr.SessionSettleWait)
	if sessionID == "" {
		log.Warn("agent started but never reported a session id; its transcript may resolve by cwd",
			"pane", qualified, "kind", body.Kind)
	}

	promptSent, promptErr := sendOpeningPrompt(c, name, qualified, body.Prompt)
	log.Info("started agent", "pane", qualified, "kind", body.Kind, "name", name, "prompt", promptSent)
	s.publish(events.TypeAgentStarted, map[string]any{
		"pane_id": qualified, "kind": body.Kind, "name": name, "created_pane": created,
	})
	res := map[string]any{
		"pane_id":      qualified,
		"tab_id":       herdr.Qualify(session, pane.TabID),
		"workspace_id": herdr.Qualify(session, pane.Workspace),
		"kind":         body.Kind,
		"name":         name,
		"created_pane": created,
		"prompt_sent":  promptSent,
	}
	// Only present when an opening prompt was asked for and did not land. The
	// agent is running either way, so this stays a 200 — but the caller must be
	// able to tell "started, instructed" from "started, empty".
	if promptErr != "" {
		res["prompt_error"] = promptErr
	}
	writeJSON(w, res)
}

// startMode is which of the three targeting forms a start request used.
type startMode int

const (
	targetExistingPane startMode = iota
	targetSplit
	targetNewTab
)

// startTarget picks the single target id out of the body, rejecting a request
// that names none or more than one. Ambiguity is an error rather than a
// precedence rule (unlike /pane/new, where split_from silently wins): starting
// an agent somewhere other than where the caller meant is not recoverable by
// retrying.
func startTarget(body agentStartRequest) (id string, mode startMode, err error) {
	named := 0
	for _, t := range []struct {
		id   string
		mode startMode
	}{
		{body.PaneID, targetExistingPane},
		{body.SplitFrom, targetSplit},
		{body.WorkspaceID, targetNewTab},
	} {
		if t.id != "" {
			named++
			id, mode = t.id, t.mode
		}
	}
	switch named {
	case 1:
		return id, mode, nil
	case 0:
		return "", 0, errors.New("want exactly one of {pane_id, split_from, workspace_id}")
	default:
		return "", 0, errors.New("want exactly one of {pane_id, split_from, workspace_id}, not several")
	}
}

// startTimeout clamps a caller's requested startup budget into Herdr's accepted
// range, defaulting when unset.
func startTimeout(ms int) time.Duration {
	if ms <= 0 {
		return startTimeoutDefault
	}
	d := time.Duration(ms) * time.Millisecond
	return min(max(d, startTimeoutMin), startTimeoutMax)
}

// checkKindInstalled rejects a kind this host cannot actually run, separating
// "Herdr has never heard of it" (400 — the client sent a typo or a kind from a
// newer Herdr) from "Herdr knows it, it just isn't installed here" (409 — a real
// host state the operator can fix).
//
// Asked of the default session's client even when the target lives elsewhere:
// the catalog is a property of the herdr binary, and every session runs the same
// one. Routing it per-session would put a `--session <name>` in front of a help
// invocation for no gain.
func (s *Server) checkKindInstalled(kind string) (int, error) {
	kinds, err := s.sessions.Default().AgentKinds()
	if err != nil {
		return http.StatusBadGateway, err
	}
	known := false
	for _, k := range kinds {
		if k == kind {
			known = true
			break
		}
	}
	if !known {
		return http.StatusBadRequest, fmt.Errorf("unknown agent kind %q; herdr supports: %s", kind, strings.Join(kinds, ", "))
	}
	if _, err := exec.LookPath(kind); err != nil {
		return http.StatusConflict, fmt.Errorf("agent kind %q is not installed on this host (no %q on the bridge's PATH)", kind, kind)
	}
	return 0, nil
}

// resolveStartPane returns the pane the agent will be started in, creating it
// for the split / new-tab forms, and guarantees it is at an interactive shell
// prompt — Herdr's precondition for agent.start. created reports whether this
// call brought the pane into existence, which is what lets the caller tell an
// operator about a pane left behind by a later failure.
func (s *Server) resolveStartPane(c *herdr.Client, mode startMode, bareTarget string, body agentStartRequest) (pane herdr.Pane, created bool, status int, err error) {
	switch mode {
	case targetExistingPane:
		pane, err = c.GetPane(bareTarget)
		if err != nil {
			return herdr.Pane{}, false, herdrStatus(err), err
		}
		// A pane that already hosts an agent is a restart, not a start — saying so
		// is more useful than letting Herdr reject the duplicate.
		if pane.IsAgent() {
			return herdr.Pane{}, false, http.StatusConflict,
				fmt.Errorf("pane already hosts a %s agent — use /agent/restart to replace it", pane.Agent)
		}
	case targetSplit:
		pane, err = c.SplitPane(bareTarget, body.Direction, body.CWD)
		if err != nil {
			return herdr.Pane{}, false, herdrStatus(err), err
		}
		created = true
	case targetNewTab:
		pane, err = c.CreateTab(bareTarget, body.CWD, body.Label)
		if err != nil {
			return herdr.Pane{}, false, herdrStatus(err), err
		}
		created = true
	}

	info, ready := c.WaitForShellPrompt(pane.PaneID, shellSettleWindow)
	if !ready {
		if created {
			return herdr.Pane{}, true, http.StatusBadGateway,
				fmt.Errorf("new pane %s did not reach a shell prompt in %s; it is still open", pane.PaneID, shellSettleWindow)
		}
		busy := info.ForegroundCommand()
		if busy == "" {
			busy = "something other than its shell"
		}
		return herdr.Pane{}, false, http.StatusConflict,
			fmt.Errorf("pane %s is busy running %s — an agent can only start at an idle shell prompt", bareTarget, busy)
	}
	return pane, created, 0, nil
}

// sendOpeningPrompt submits the caller's first message, if there is one, and
// reports whether it landed plus why it did not.
//
// A failure here is never fatal: the agent is up and addressable at that point,
// and losing the whole start over an unsent opening line would be a far worse
// outcome than a prompt the operator retypes. It must not be SILENT either —
// the caller asked for an agent carrying a first instruction, and an
// undifferentiated 200 would have the app navigate to an idle agent as if the
// instruction had been delivered. The reason travels back in the response so it
// can be shown.
//
// The wait is the whole reason this used to fail: the agent is addressable by
// PANE the moment start returns, but by NAME only once Herdr's registry catches
// up, and this addresses it by name.
func sendOpeningPrompt(c *herdr.Client, name, qualifiedPane, prompt string) (bool, string) {
	if prompt == "" {
		return false, ""
	}
	if err := c.PromptAgentWhenReady(name, prompt, herdr.PromptReadyBudget); err != nil {
		log.Error("agent start: opening prompt failed", "pane", qualifiedPane, "agent", name, "err", err)
		return false, fmt.Sprintf("the agent started but your opening prompt was not delivered: %v", err)
	}
	return true, ""
}

// ---- POST /agent/stop ----

// POST /agent/stop {"pane_id":"wN:p7"} — quit the agent running in a pane,
// leaving the pane open at its shell prompt.
//
// This KILLS RUNNING WORK: whatever the agent was doing is interrupted and it
// exits. The app gates it behind a confirm for that reason.
//
// The response only says stopped when the pane has been observed back at its
// shell prompt. Herdr has no stop method, so the mechanism is repeated terminal
// interrupts (see herdr.StopAgent) and there is no acknowledgement to trust —
// an agent that swallowed the interrupts is still alive and still holds the
// pane. Reporting that as a 409 rather than a success is the whole point: a
// false "stopped" would have the app navigate away from an agent that is still
// running, possibly mid-turn.
func (s *Server) handleAgentStop(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "use POST", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		PaneID string `json:"pane_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.PaneID == "" {
		http.Error(w, "want {pane_id}", http.StatusBadRequest)
		return
	}

	c, _, bare, err := s.target(body.PaneID)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}
	agent, err := c.Get(bare)
	if err != nil {
		if errors.Is(err, herdr.ErrAgentNotFound) {
			http.Error(w, "no such agent", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	stopped, err := c.StopAgent(bare, stopWindow)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if !stopped {
		http.Error(w, fmt.Sprintf("the %s agent in %s did not exit within %s and is still running", agent.Kind, body.PaneID, stopWindow), http.StatusConflict)
		return
	}

	log.Info("stopped agent", "pane", body.PaneID, "kind", agent.Kind)
	s.publish(events.TypeAgentStopped, map[string]any{"pane_id": body.PaneID, "kind": agent.Kind})
	writeJSON(w, map[string]any{"stopped": true, "pane_id": body.PaneID, "kind": agent.Kind})
}

// ---- POST /agent/restart ----

// POST /agent/restart {"pane_id":"wN:p7", "prompt"?:"…"} — stop the agent in a
// pane and start the same kind again in the same place.
//
// What survives: the pane, its id (so anything holding it stays valid), its
// scrollback, its working directory, and the agent's Herdr name. The directory
// survives for free rather than by being restored — the agent ran as a child of
// the pane's shell and a child cannot move its parent, so the shell is still
// exactly where it was when the replacement launches.
//
// What does NOT survive, and this is the whole reason a restart is a destructive
// action rather than a refresh:
//
//   - the conversation. The new agent gets a NEW session — no history, no
//     memory of what was discussed, no awareness that it is a replacement. It
//     will not resume the previous task; it has never heard of it.
//   - the in-flight turn. Whatever the agent was doing is interrupted and lost,
//     including any partially written file the tool call had not finished.
//   - queued input, permission mode, plan mode, and every other piece of TUI
//     state the agent held in memory.
//
// Only the pane is preserved. Callers must confirm with the operator first, and
// the optional prompt exists precisely because the replacement needs to be told
// what to do from scratch.
func (s *Server) handleAgentRestart(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "use POST", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		PaneID    string `json:"pane_id"`
		Prompt    string `json:"prompt"`
		TimeoutMS int    `json:"timeout_ms"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.PaneID == "" {
		http.Error(w, "want {pane_id}", http.StatusBadRequest)
		return
	}

	c, session, bare, err := s.target(body.PaneID)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}
	agent, err := c.Get(bare)
	if err != nil {
		if errors.Is(err, herdr.ErrAgentNotFound) {
			http.Error(w, "no such agent", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}

	// The name is read (and the replacement started under it) before the stop, so
	// an operator's own label for the pane survives the swap. Herdr frees the name
	// when the old agent exits, so reusing it cannot collide.
	name, err := agentName(agent.Name, agent.Kind, bare)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	stopped, err := c.StopAgent(bare, stopWindow)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if !stopped {
		http.Error(w, fmt.Sprintf("the %s agent in %s did not exit within %s, so it was not restarted", agent.Kind, body.PaneID, stopWindow), http.StatusConflict)
		return
	}

	if err := c.StartAgent(name, agent.Kind, bare, startTimeout(body.TimeoutMS)); err != nil {
		// The old agent is already gone at this point; say so, so the operator
		// knows the pane is now an empty shell rather than a running agent.
		log.Error("agent restart failed after stop", "pane", body.PaneID, "kind", agent.Kind, "err", err)
		http.Error(w, fmt.Sprintf("the old %s agent was stopped but the replacement failed to start in %s: %v (the pane is now an idle shell)", agent.Kind, body.PaneID, err), http.StatusBadGateway)
		return
	}

	// Worse here than on a start: until the REPLACEMENT reports its session id,
	// the pane still resolves to the transcript of the agent this call just
	// discarded — so the client would render the very history the response
	// declares gone (history_kept:false), and it would look plausible.
	if sessionID := c.WaitForAgentSession(bare, herdr.SessionSettleWait); sessionID == "" {
		log.Warn("agent restarted but never reported a session id; its transcript may resolve to the old session",
			"pane", body.PaneID, "kind", agent.Kind)
	}

	promptSent, promptErr := sendOpeningPrompt(c, name, body.PaneID, body.Prompt)
	log.Info("restarted agent", "pane", body.PaneID, "kind", agent.Kind, "name", name, "prompt", promptSent)
	s.publish(events.TypeAgentRestarted, map[string]any{
		"pane_id": body.PaneID, "kind": agent.Kind, "name": name,
	})
	res := map[string]any{
		"restarted":    true,
		"pane_id":      herdr.Qualify(session, bare),
		"kind":         agent.Kind,
		"name":         name,
		"cwd":          agent.Cwd,
		"prompt_sent":  promptSent,
		"history_kept": false,
	}
	if promptErr != "" {
		res["prompt_error"] = promptErr
	}
	writeJSON(w, res)
}
