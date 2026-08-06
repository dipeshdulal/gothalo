package server

import (
	"net/http"
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/suggest"
)

// suggestionsResponse is the GET /suggestions payload. Pane is echoed so a
// client holding several in flight (the list page opening two panes at once)
// can tell which one answered.
type suggestionsResponse struct {
	Pane        string               `json:"pane"`
	Suggestions []suggest.Suggestion `json:"suggestions"`
}

// GET /suggestions?pane=<pane_id> -> a short, ordered list of one-tap actions
// that make sense for what is running in that pane right now.
//
// The generalisation of GET /ports. Where that endpoint answers one question
// from one signal (a dev server is up in this pane, here is its URL), this one
// takes the same bar — every suggestion returned is one the app can actually
// act on — and applies it to whatever else is cheap to observe: what Herdr says
// holds the pane's foreground, whether an agent lives there, and a few stat()s
// on the pane's working directory.
//
// **/ports is deliberately not routed through this.** The two should converge,
// but not by folding a port scan into a per-pane read: a scan costs an `lsof`, a
// `ps` and a probe per listener, and it is inherently a HOST question that the
// pane filter narrows afterwards. Convergence belongs on the app side first
// (one chip row fed by two endpoints), and only then, if it earns it, as a
// suggestion source that reads the already-cached scan. See
// docs/CONTRACT-suggestions.md.
//
// Costs at most two Herdr round-trips and one `git status`, all behind a short
// per-pane cache — see suggestTTL.
func (s *Server) handleSuggestions(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}

	found, status, err := s.suggestions.get(pane, s.observePane)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}
	writeJSON(w, suggestionsResponse{Pane: pane, Suggestions: found})
}

// processInfoGetter is the one Herdr call the observation needs beyond the agent
// lookup. *herdr.Client satisfies it; tests substitute a fake, the same seam
// shape as Server.agents for paneCwd and Server.requester for /herdr.
type processInfoGetter interface {
	PaneProcessInfo(pane string) (herdr.PaneProcessInfo, error)
}

// observePane collects everything the suggestion sources are allowed to read.
//
// Two lookups, and both are tolerant in a specific direction:
//
//   - `pane.process_info` is the authoritative "does this pane exist", so its
//     not-found is the endpoint's 404 and any other failure is a 502. Without it
//     there is no cwd for a plain pane and no idea whether the shell is free,
//     which is most of the input.
//   - `agent.get` failing is NOT an error. A plain shell pane is the ordinary
//     case for half these sources, and Herdr reports that as agent_not_found —
//     so a missing agent narrows which sources fire rather than failing the read.
//
// Cwd prefers the agent's own, which Herdr already knows, and falls back to the
// foreground process's for a pane with no agent. Those are the same directory
// when both exist; the fallback is what makes plain panes work at all.
func (s *Server) observePane(pane string) (suggest.Pane, int, error) {
	session, bare := herdr.SplitTarget(pane)

	var pg processInfoGetter = s.processInfo
	if pg == nil {
		c, err := s.sessions.Client(session)
		if err != nil {
			return suggest.Pane{}, herdrStatus(err), err
		}
		pg = c
	}
	info, err := pg.PaneProcessInfo(bare)
	if err != nil {
		return suggest.Pane{}, herdrStatus(err), err
	}

	out := suggest.Pane{
		ID:            pane,
		AtShellPrompt: info.AtShellPrompt(),
		Foreground:    info.ForegroundCommand(),
		Cwd:           foregroundCwd(info),
	}
	if agent, _, err := s.paneAgent(pane); err == nil && agent.Kind != "" {
		out.HasAgent = true
		out.AgentKind = agent.Kind
		if agent.Cwd != "" {
			out.Cwd = agent.Cwd
		}
	}
	return out, http.StatusOK, nil
}

// foregroundCwd picks the pane's working directory out of `pane.process_info`.
//
// The process leading the foreground group is preferred over the first entry in
// the list: at a prompt those are the same (the shell), but under a running
// command the list also carries the shell itself, and the shell's cwd is the one
// that is stale — `cd`-ing inside a script does not move it.
func foregroundCwd(info herdr.PaneProcessInfo) string {
	for _, p := range info.ForegroundProcesses {
		if p.PID == info.ForegroundProcessGroupID && p.Cwd != "" {
			return p.Cwd
		}
	}
	for _, p := range info.ForegroundProcesses {
		if p.Cwd != "" {
			return p.Cwd
		}
	}
	return ""
}

// suggestTTL is how long one pane's suggestions stay good.
//
// Sized off what the answers are made of rather than off a refresh rate. Every
// input is something a person changes on a human timescale — an agent starts
// writing files, a rebase stops on a conflict, a shell is left at a prompt —
// so a few seconds of staleness is invisible, while the cache is what keeps a
// screen that refetches on focus, on reconnect and on every agent status change
// from turning into a `git status` per event.
//
// It is also the whole reason this endpoint is safe to call from a poll: the
// app is told it may ask whenever it likes, and the bridge is what decides how
// often that reaches Herdr.
const suggestTTL = 6 * time.Second

// suggestCache memoises suggestions per pane.
//
// Keyed per pane rather than one shared entry, because the observation is
// per-pane: a phone showing one terminal asks about one pane over and over, and
// a shared slot would make two open panes evict each other on every poll.
//
// Unbounded in principle, bounded in practice by the number of panes on the
// host — tens, and each entry is a handful of small structs. A pane that goes
// away leaves one stale entry behind rather than a leak worth a sweeper.
type suggestCache struct {
	mu      sync.Mutex
	entries map[string]suggestEntry
	// now is swappable in tests; nil means time.Now.
	now func() time.Time
}

type suggestEntry struct {
	at   time.Time
	list []suggest.Suggestion
}

func (c *suggestCache) clock() time.Time {
	if c.now != nil {
		return c.now()
	}
	return time.Now()
}

// get returns a pane's suggestions, recomputing when the entry has aged out.
// The lock is held across the observation, so concurrent callers for a pane
// wait for the one in flight and share its result rather than each paying for
// their own round-trips — the same bargain ports.Cache makes.
//
// observe is a func so a cache hit never touches Herdr — which is the point of
// the cache, since the round-trips are the expensive part and the sources
// themselves are microseconds.
//
// A failed observation is returned, never served stale: "this pane is gone" and
// "this pane has nothing to suggest" are different answers, and the 404 is how
// a caller tells them apart.
func (c *suggestCache) get(pane string, observe func(string) (suggest.Pane, int, error)) ([]suggest.Suggestion, int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if e, ok := c.entries[pane]; ok && c.clock().Sub(e.at) < suggestTTL {
		return e.list, http.StatusOK, nil
	}
	observed, status, err := observe(pane)
	if err != nil {
		log.Warn("suggestions: observe failed", "pane", pane, "err", err)
		return nil, status, err
	}
	list := suggest.For(observed)
	if c.entries == nil {
		c.entries = map[string]suggestEntry{}
	}
	c.entries[pane] = suggestEntry{at: c.clock(), list: list}
	return list, http.StatusOK, nil
}
