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
	"github.com/dipeshdulal/gothalo/internal/transcript"
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

// orderedClients snapshots the client set as a slice, default session first
// then the rest by name — the order every cross-session fan-out uses, so the
// default session's answer is always index 0.
func (m *Manager) orderedClients() []*Client {
	m.mu.Lock()
	defer m.mu.Unlock()
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
	return clients
}

// MergedSnapshotRaw fetches every session's snapshot in parallel and merges
// them into one envelope: array fields (agents, panes, tabs, workspaces,
// layouts) are concatenated with non-default ids qualified and each element
// tagged with its "session"; scalar fields (focused_*) come from the default
// session; a "sessions" list names what was merged. A session whose snapshot
// fails is skipped — the merge fails only when every session does.
func (m *Manager) MergedSnapshotRaw() ([]byte, error) {
	clients := m.orderedClients()

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
			// SnapshotRaw returns the socket's result object — the same
			// {type, snapshot} the CLI printed inside its `result` envelope.
			var env struct {
				Snapshot map[string]any `json:"snapshot"`
			}
			if err := json.Unmarshal(raw, &env); err != nil || env.Snapshot == nil {
				results[i] = result{err: fmt.Errorf("parse snapshot: %w", err)}
				return
			}
			results[i] = result{node: env.Snapshot}
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
	enrichAgentLastActivity(merged["agents"])
	enrichAgentSubagents(merged["agents"])
	// After last-activity: recency ranks the field it stamps.
	enrichAgentRecency(merged["agents"])

	return json.Marshal(map[string]any{
		"id":     "gothalo:snapshot",
		"result": map[string]any{"snapshot": merged},
	})
}

// OpenSpace is where one open Herdr workspace lives on disk. It is what the
// directory browser derives its allowed roots from: the bridge can name the
// operator's project directories without being configured with any, because
// Herdr already has them open.
type OpenSpace struct {
	// WorkspaceID is session-qualified ("acme/w3"), like every id the bridge
	// hands out, so a caller can address the space back directly.
	WorkspaceID string
	// Dir is the space's own directory.
	Dir string
	// RepoRoot is the git repository the space belongs to, or "" when it is not
	// a checkout. For a linked worktree this is the MAIN checkout, which is a
	// different place from Dir and worth having: its parent is where the
	// operator's other repositories live.
	RepoRoot string
}

// OpenSpaces returns one entry per open workspace across every running session.
//
// A space's directory is its worktree `checkout_path` when Herdr reports one —
// the authoritative answer, since individual panes wander into subdirectories
// and linked worktrees — and otherwise the cwd of its first pane, the same
// fallback the app's Spaces list uses.
//
// A session whose snapshot fails is skipped rather than failing the call. This
// is advisory data (it widens a browsing allowlist, it does not answer a
// question), and losing one session's projects is a better outcome than losing
// the browser.
func (m *Manager) OpenSpaces() []OpenSpace {
	clients := m.orderedClients()

	type snapshotShape struct {
		Snapshot struct {
			Workspaces []struct {
				WorkspaceID string `json:"workspace_id"`
				Worktree    *struct {
					CheckoutPath string `json:"checkout_path"`
					RepoRoot     string `json:"repo_root"`
				} `json:"worktree"`
			} `json:"workspaces"`
			Panes []struct {
				WorkspaceID string `json:"workspace_id"`
				Cwd         string `json:"cwd"`
			} `json:"panes"`
		} `json:"snapshot"`
	}

	parsed := make([]snapshotShape, len(clients))
	var wg sync.WaitGroup
	for i, c := range clients {
		wg.Add(1)
		go func(i int, c *Client) {
			defer wg.Done()
			raw, err := c.SnapshotRaw()
			if err != nil {
				log.Warn("open spaces: snapshot failed for session; skipping",
					"session", c.SessionLabel(), "err", err)
				return
			}
			if err := json.Unmarshal(raw, &parsed[i]); err != nil {
				log.Warn("open spaces: parse snapshot failed", "session", c.SessionLabel(), "err", err)
			}
		}(i, c)
	}
	wg.Wait()

	var out []OpenSpace
	for i, c := range clients {
		snap := parsed[i].Snapshot
		firstPaneCwd := map[string]string{}
		for _, p := range snap.Panes {
			if p.Cwd == "" {
				continue
			}
			if _, seen := firstPaneCwd[p.WorkspaceID]; !seen {
				firstPaneCwd[p.WorkspaceID] = p.Cwd
			}
		}
		for _, ws := range snap.Workspaces {
			sp := OpenSpace{WorkspaceID: Qualify(c.Session(), ws.WorkspaceID)}
			if ws.Worktree != nil {
				sp.Dir = ws.Worktree.CheckoutPath
				sp.RepoRoot = ws.Worktree.RepoRoot
			}
			if sp.Dir == "" {
				sp.Dir = firstPaneCwd[ws.WorkspaceID]
			}
			if sp.Dir == "" {
				continue // a space with nowhere on disk tells the browser nothing
			}
			out = append(out, sp)
		}
	}
	return out
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

// enrichAgentLastActivity stamps `last_activity_ts` (unix milliseconds) on every
// agent whose transcript can be found, and leaves it off every agent whose
// cannot.
//
// It is what lets a client show "blocked 50m" instead of "blocked". The snapshot
// is otherwise entirely a statement about NOW: it can say an agent is waiting,
// never for how long, and the difference is the whole question you have when you
// pick your phone up. See [transcript.LastActivity] for why the transcript's
// mtime is the source rather than anything the bridge observes — briefly, it
// survives a restart and knows spans that predate the bridge entirely.
//
// ABSENT means unknown, never "just now". A client must render nothing rather
// than "0s" for an agent whose transcript could not be resolved (a kind that
// keeps sessions in a shared database, or an agent that has not spoken yet).
func enrichAgentLastActivity(agentsNode any) {
	agents, ok := agentsNode.([]any)
	if !ok {
		return
	}
	for _, it := range agents {
		obj, ok := it.(map[string]any)
		if !ok {
			continue
		}
		kind, _ := obj["agent"].(string)
		cwd, _ := obj["cwd"].(string)
		var sessionID string
		if sess, ok := obj["agent_session"].(map[string]any); ok {
			sessionID, _ = sess["value"].(string)
		}
		if at, ok := transcript.LastActivity(kind, cwd, sessionID); ok {
			obj["last_activity_ts"] = at.UnixMilli()
		}
	}
}

// enrichAgentSubagents stamps `subagents` — {total, running} — on every agent
// whose session delegated at least one, and leaves it off every other.
//
// It is what puts "4 running" on a Flock row: a session that parallelises hides
// its delegated work inside a conversation, so the list could say an agent was
// working but never that four more were working underneath it.
//
// ABSENT, not zero. A session that delegated nothing and a kind that cannot be
// counted must render no badge at all, and a client that receives {0,0} for
// both cannot tell either from a session whose agents have all finished.
func enrichAgentSubagents(agentsNode any) {
	agents, ok := agentsNode.([]any)
	if !ok {
		return
	}
	for _, it := range agents {
		obj, ok := it.(map[string]any)
		if !ok {
			continue
		}
		kind, _ := obj["agent"].(string)
		cwd, _ := obj["cwd"].(string)
		var sessionID string
		if sess, ok := obj["agent_session"].(map[string]any); ok {
			sessionID, _ = sess["value"].(string)
		}
		c, ok := transcript.SubagentCounts(kind, cwd, sessionID)
		if !ok || c.Total == 0 {
			continue
		}
		obj["subagents"] = map[string]any{
			"total":   c.Total,
			"running": c.Running,
		}
	}
}

// enrichAgentAttention stamps `attention_rank` on every agent in the snapshot
// from its `agent_status`. Ordering by this field, then by `recency_rank`
// (enrichAgentRecency), is the bridge's full authoritative list order — what
// makes the app's list authoritative rather than client-sorted. The field is
// always set, so a client can sort on it unconditionally.
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

// Recency tiers: which clock (if any) could date an agent's last activity.
// They are tiers rather than one number because the two signals are on
// different scales — unix milliseconds and a herdr counter — and averaging
// incomparable units is how a list starts lying. A tier only ever falls back
// to the next one, never mixes.
const (
	recencyDated      = 0 // last_activity_ts: a real wall clock
	recencyTransition = 1 // state_change_seq: herdr's global transition order
	recencyUndatable  = 2 // nothing at all
)

// recencyKey is one agent's position in the "what did I touch last" order.
// Fields are compared in declaration order; paneID is the last resort and is
// unique, so the comparison is a total order and the resulting rank is stable
// between snapshots for an unchanged set of agents.
type recencyKey struct {
	tier   int
	ts     int64  // unix ms, newest first (tier recencyDated)
	seq    int64  // state_change_seq, highest first (tier recencyTransition)
	paneID string // ascending
}

func (k recencyKey) less(o recencyKey) bool {
	if k.tier != o.tier {
		return k.tier < o.tier
	}
	if k.ts != o.ts {
		return k.ts > o.ts
	}
	if k.seq != o.seq {
		return k.seq > o.seq
	}
	return k.paneID < o.paneID
}

// enrichAgentRecency stamps `recency_rank` on every agent in the snapshot: 0 is
// the most recently active, and every agent gets a distinct rank, so
// (attention_rank, recency_rank) is a *complete* order with nothing left for a
// client to break ties on — and therefore nothing for two surfaces to break
// them on differently.
//
// It is the tiebreak *within* an attention rank, not a rival to it. What needs
// a human still comes first; this only decides the order among agents that need
// you equally, where the snapshot's own order previously decided it — i.e.
// arbitrarily. With a dozen-plus agents that put the one you were just using
// wherever herdr happened to list it, usually well down the page.
//
// Three tiers, in order:
//
//  1. `last_activity_ts` (from enrichAgentLastActivity), newest first. A real
//     clock, and the one that matches what "I was just using it" means.
//  2. `state_change_seq`, highest first — for an agent with no transcript to
//     date: another kind entirely (hermes/opencode share one store, so the
//     bridge refuses to date them), or a claude agent that has not spoken yet.
//     This is herdr's single app-wide counter, a global total order over every
//     agent transition and comparable across panes (`app/actions.rs`, recorded
//     in docs/DESIGN-panestore.md; confirmed live — 25 agents on one host carry
//     interleaved values from one sequence). So it genuinely orders "which of
//     these last did something", just in transitions rather than seconds.
//  3. Whatever is left, by `pane_id`.
//
// Undated agents sort *below* dated ones rather than being guessed into the
// middle, for the same reason enrichAgentLastActivity omits the field instead
// of stamping now(): absent means unknown, never "just now". A just-started
// agent is the case that costs — it has no transcript yet — but tier 2 catches
// it, since starting an agent is itself a fresh transition.
//
// `recency_rank` is positional, not an identity: it is an index into this
// snapshot's list, so it shifts when agents come and go. Compare it, don't
// cache it or diff it across snapshots.
func enrichAgentRecency(agentsNode any) {
	agents, ok := agentsNode.([]any)
	if !ok {
		return
	}
	type entry struct {
		obj map[string]any
		key recencyKey
	}
	ordered := make([]entry, 0, len(agents))
	for _, it := range agents {
		obj, ok := it.(map[string]any)
		if !ok {
			continue
		}
		ordered = append(ordered, entry{obj: obj, key: recencyKeyFor(obj)})
	}
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].key.less(ordered[j].key)
	})
	for i, e := range ordered {
		e.obj["recency_rank"] = i
	}
}

// recencyKeyFor reads one agent's recency signals and picks its tier.
func recencyKeyFor(obj map[string]any) recencyKey {
	paneID, _ := obj["pane_id"].(string)
	if ts, ok := jsonInt(obj["last_activity_ts"]); ok && ts > 0 {
		return recencyKey{tier: recencyDated, ts: ts, paneID: paneID}
	}
	if seq, ok := jsonInt(obj["state_change_seq"]); ok {
		return recencyKey{tier: recencyTransition, seq: seq, paneID: paneID}
	}
	return recencyKey{tier: recencyUndatable, paneID: paneID}
}

// jsonInt reads an integer that may have arrived as any of the shapes a decoded
// snapshot mixes: float64 for anything herdr sent through encoding/json, and a
// native int64 for a field the bridge stamped itself (last_activity_ts).
func jsonInt(v any) (int64, bool) {
	switch n := v.(type) {
	case int64:
		return n, true
	case int:
		return int64(n), true
	case float64:
		return int64(n), true
	case json.Number:
		i, err := n.Int64()
		return i, err == nil
	}
	return 0, false
}
