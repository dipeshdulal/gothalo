// Multi-session support: Herdr runs one server (and control socket) per named
// session. The Manager discovers running sessions, keeps one Client per session,
// and merges their snapshots into a single payload. Ids from non-default
// sessions are qualified as "<session>/<id>" so a pane address stays unique
// across sessions; the default session stays unprefixed for compatibility.
package herdr

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/gitdiff"
)

// defaultSessionName is how Herdr names its default session.
const defaultSessionName = "default"

// sessionSyncInterval is how often the Manager re-lists sessions.
const sessionSyncInterval = 15 * time.Second

// SessionInfo is one row of `herdr session list --json`.
type SessionInfo struct {
	Name       string `json:"name"`
	Default    bool   `json:"default"`
	Running    bool   `json:"running"`
	SocketPath string `json:"socket_path"`
}

// Sessions lists Herdr's sessions (`herdr session list --json`).
func (c *Client) Sessions() ([]SessionInfo, error) {
	out, err := c.run("session", "list", "--json")
	if err != nil {
		return nil, err
	}
	var env struct {
		Sessions []SessionInfo `json:"sessions"`
	}
	if err := json.Unmarshal(out, &env); err != nil {
		return nil, fmt.Errorf("parse session list: %w", err)
	}
	return env.Sessions, nil
}

// Qualify prefixes an id with its session ("acme/w1:p2"). The default session
// ("" or "default") stays unprefixed.
func Qualify(session, id string) string {
	if session == "" || session == defaultSessionName || id == "" {
		return id
	}
	return session + "/" + id
}

// SplitTarget parses a possibly session-qualified id back into (session, id).
// "w1:p2" -> ("", "w1:p2"); "acme/w1:p2" -> ("acme", "w1:p2").
func SplitTarget(target string) (session, id string) {
	if s, rest, found := strings.Cut(target, "/"); found {
		if s == defaultSessionName {
			s = ""
		}
		return s, rest
	}
	return "", target
}

// idKeys are the JSON keys whose string values are Herdr ids that must carry
// the session prefix once payloads from several sessions share one stream.
var idKeys = map[string]bool{
	"pane_id": true, "tab_id": true, "workspace_id": true,
	"focused_pane_id": true, "focused_tab_id": true, "focused_workspace_id": true,
	"active_tab_id": true, "split_from": true,
}

// RewriteIDs walks decoded JSON and applies f to every id-keyed string value.
func RewriteIDs(v any, f func(string) string) {
	switch n := v.(type) {
	case map[string]any:
		for k, val := range n {
			if s, ok := val.(string); ok && idKeys[k] {
				n[k] = f(s)
				continue
			}
			RewriteIDs(val, f)
		}
	case []any:
		for _, e := range n {
			RewriteIDs(e, f)
		}
	}
}

// QualifyIDs walks decoded JSON and prefixes every id with the session.
func QualifyIDs(v any, session string) {
	if session == "" || session == defaultSessionName {
		return
	}
	RewriteIDs(v, func(id string) string { return Qualify(session, id) })
}

// StartFunc launches the per-session workers (ingester, watcher, …) for a
// discovered session and returns a stop function called when it goes away.
type StartFunc func(name string, c *Client) (stop func())

// Manager owns one Client per running Herdr session. Discovery (Run) keeps the
// set current and starts/stops per-session workers via the StartFunc.
type Manager struct {
	onStart StartFunc

	mu      sync.Mutex
	clients map[string]*Client // key "" = default session
	stops   map[string]func()
}

// NewManager builds a Manager seeded with the default-session client. onStart
// may be nil (no per-session workers, e.g. in tests).
func NewManager(onStart StartFunc) *Manager {
	return &Manager{
		onStart: onStart,
		clients: map[string]*Client{"": New()},
		stops:   map[string]func(){},
	}
}

// Client returns the client for a session name ("" or "default" = default).
func (m *Manager) Client(session string) (*Client, error) {
	if session == defaultSessionName {
		session = ""
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.clients[session]
	if !ok {
		// "not found" so herdr.IsNotFound (and the HTTP 404 mapping) matches.
		return nil, fmt.Errorf("herdr session %q not found", session)
	}
	return c, nil
}

// Default returns the default-session client (always present).
func (m *Manager) Default() *Client {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.clients[""]
}

// Names returns the known session labels, default first, the rest sorted.
func (m *Manager) Names() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	names := make([]string, 0, len(m.clients))
	for k := range m.clients {
		if k != "" {
			names = append(names, k)
		}
	}
	sort.Strings(names)
	return append([]string{defaultSessionName}, names...)
}

// Run discovers sessions now and then every sessionSyncInterval until ctx ends.
func (m *Manager) Run(ctx context.Context) {
	m.sync()
	t := time.NewTicker(sessionSyncInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			m.stopAll()
			return
		case <-t.C:
			m.sync()
		}
	}
}

// sync reconciles the client set against `herdr session list`. If listing fails
// (older herdr, daemon down) it degrades to the default session only.
func (m *Manager) sync() {
	running := map[string]bool{"": true} // default is always kept
	infos, err := m.Default().Sessions()
	if err != nil {
		log.Warn("session discovery failed; default session only", "err", err)
	}
	for _, in := range infos {
		if !in.Running {
			continue
		}
		key := in.Name
		if in.Default || key == defaultSessionName {
			key = ""
		}
		running[key] = true
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	for key := range running {
		if _, ok := m.clients[key]; !ok {
			m.clients[key] = NewForSession(key)
		}
		if _, started := m.stops[key]; !started && m.onStart != nil {
			c := m.clients[key]
			log.Info("herdr session attached", "session", c.SessionLabel())
			m.stops[key] = m.onStart(c.SessionLabel(), c)
		}
	}
	for key, stop := range m.stops {
		if running[key] {
			continue
		}
		log.Info("herdr session detached", "session", m.clients[key].SessionLabel())
		stop()
		delete(m.stops, key)
		delete(m.clients, key)
	}
}

// stopAll stops every per-session worker (Run teardown).
func (m *Manager) stopAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for key, stop := range m.stops {
		stop()
		delete(m.stops, key)
	}
}

// MergedSnapshotRaw fetches every session's snapshot in parallel and merges
// them into one envelope: array fields (agents, panes, tabs, workspaces,
// layouts) are concatenated with non-default ids qualified and each element
// tagged with its "session"; scalar fields (focused_*) come from the default
// session; a "sessions" list names what was merged. A session whose snapshot
// fails is skipped — the merge fails only when every session does.
func (m *Manager) MergedSnapshotRaw() ([]byte, error) {
	m.mu.Lock()
	clients := make([]*Client, 0, len(m.clients))
	if c, ok := m.clients[""]; ok {
		clients = append(clients, c)
	}
	names := make([]string, 0, len(m.clients))
	for k := range m.clients {
		if k != "" {
			names = append(names, k)
		}
	}
	sort.Strings(names)
	for _, n := range names {
		clients = append(clients, m.clients[n])
	}
	m.mu.Unlock()

	type result struct {
		node map[string]any
		err  error
	}
	results := make([]result, len(clients))
	var wg sync.WaitGroup
	for i, c := range clients {
		wg.Add(1)
		go func(i int, c *Client) {
			defer wg.Done()
			raw, err := c.SnapshotRaw()
			if err != nil {
				results[i] = result{err: err}
				return
			}
			var env struct {
				Result struct {
					Snapshot map[string]any `json:"snapshot"`
				} `json:"result"`
			}
			if err := json.Unmarshal(raw, &env); err != nil || env.Result.Snapshot == nil {
				results[i] = result{err: fmt.Errorf("parse snapshot: %w", err)}
				return
			}
			results[i] = result{node: env.Result.Snapshot}
		}(i, c)
	}
	wg.Wait()

	merged := map[string]any{}
	var sessions []string
	var lastErr error
	arrayKeys := []string{"agents", "panes", "tabs", "workspaces", "layouts"}
	for i, c := range clients {
		r := results[i]
		if r.err != nil {
			log.Warn("snapshot failed for session; skipping", "session", c.SessionLabel(), "err", r.err)
			lastErr = fmt.Errorf("session %s: %w", c.SessionLabel(), r.err)
			continue
		}
		label := c.SessionLabel()
		sessions = append(sessions, label)
		QualifyIDs(r.node, c.Session())
		if c.Session() == "" {
			// Scalars (focused_* etc.) come from the default session.
			maps.Copy(merged, r.node)
			// Its arrays are re-appended below; drop to avoid double-counting.
			for _, k := range arrayKeys {
				delete(merged, k)
			}
		}
		for _, k := range arrayKeys {
			items, ok := r.node[k].([]any)
			if !ok {
				continue
			}
			for _, it := range items {
				if obj, ok := it.(map[string]any); ok {
					obj["session"] = label
				}
			}
			prev, _ := merged[k].([]any)
			merged[k] = append(prev, items...)
		}
	}
	if len(sessions) == 0 {
		if lastErr == nil {
			lastErr = fmt.Errorf("no herdr sessions")
		}
		return nil, lastErr
	}
	merged["sessions"] = sessions

	enrichAgentBranches(merged["agents"])
	enrichAgentAttention(merged["agents"])

	return json.Marshal(map[string]any{
		"id":     "gothalo:snapshot",
		"result": map[string]any{"snapshot": merged},
	})
}

// enrichAgentBranches fills a `branch` field on every agent in the snapshot,
// computed by running git in the pane's live cwd — the authoritative branch,
// not one inferred from the path (which only works for herdr worktrees) or
// read from the transcript (which records the session's start cwd). It prefers
// `foreground_cwd` (the pane's current dir, tracking a shell `cd`) over the
// launch `cwd`. The field is always set — "" when the pane isn't in a git work
// tree (e.g. a home dir) or on a detached HEAD — so the app can render "no
// branch" rather than a misleading folder name.
//
// git runs once per *unique* cwd (agents in the same repo dir share one call)
// and those calls run concurrently, so enrichment costs one git round-trip of
// wall time regardless of agent count.
func enrichAgentBranches(agentsNode any) {
	agents, ok := agentsNode.([]any)
	if !ok || len(agents) == 0 {
		return
	}

	cwdFor := func(obj map[string]any) string {
		if fg, ok := obj["foreground_cwd"].(string); ok && fg != "" {
			return fg
		}
		if cwd, ok := obj["cwd"].(string); ok {
			return cwd
		}
		return ""
	}

	// Unique cwds → resolve each branch once, concurrently.
	seen := map[string]struct{}{}
	var uniq []string
	for _, it := range agents {
		if obj, ok := it.(map[string]any); ok {
			cwd := cwdFor(obj)
			if _, dup := seen[cwd]; !dup {
				seen[cwd] = struct{}{}
				uniq = append(uniq, cwd)
			}
		}
	}

	branches := make(map[string]string, len(uniq))
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, cwd := range uniq {
		wg.Add(1)
		go func(cwd string) {
			defer wg.Done()
			b := gitdiff.Branch(cwd)
			mu.Lock()
			branches[cwd] = b
			mu.Unlock()
		}(cwd)
	}
	wg.Wait()

	for _, it := range agents {
		if obj, ok := it.(map[string]any); ok {
			obj["branch"] = branches[cwdFor(obj)]
		}
	}
}

// attentionRanks is the bridge's canonical "who needs a human first" ordering,
// lowest rank first. It is the one place that priority is defined, so every
// surface that consumes /snapshot (inbox list, priority screen, counts, the
// aggregate header) orders identically instead of each re-deriving it.
//
// This lives here rather than on Herdr's `agent.view` projection deliberately:
// Herdr accepts `agent.view.set` and reports the view active, but as of herdr
// 0.8.0 (protocol 19) no read applies it — `agent.list` and `session.snapshot`
// both return the unprojected list — so there is no projected read for the
// bridge to forward. The bridge is the authority instead.
var attentionRanks = map[string]int{
	"blocked": 0, // waiting on an approval or an answer — the whole point of the app
	"done":    1, // finished a turn; needs you to look at it and continue
	"working": 2, // busy, nothing to do
	"idle":    3, // parked at a prompt
	"unknown": 4, // undetected; sorts last so it never displaces a real signal
}

// unknownAttentionRank is what an unrecognised (or missing) agent_status gets —
// the same slot as "unknown", so a status Herdr adds later degrades to "sorts
// last" instead of jumping to the top of the inbox.
const unknownAttentionRank = 4

// enrichAgentAttention stamps `attention_rank` on every agent in the snapshot
// from its `agent_status`. Ordering by this field (then by whatever tiebreak the
// surface wants) is what makes the app's list authoritative rather than
// client-sorted. The field is always set, so a client can sort on it
// unconditionally.
func enrichAgentAttention(agentsNode any) {
	agents, ok := agentsNode.([]any)
	if !ok {
		return
	}
	for _, it := range agents {
		obj, ok := it.(map[string]any)
		if !ok {
			continue
		}
		rank := unknownAttentionRank
		if status, ok := obj["agent_status"].(string); ok {
			if r, known := attentionRanks[status]; known {
				rank = r
			}
		}
		obj["attention_rank"] = rank
	}
}
