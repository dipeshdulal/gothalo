package server

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/ports"
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
// **This is the one endpoint the app asks "what can I do with this pane".** Dev
// servers used to be a second answer to that question, on GET /ports; they are
// now one source among several here, ranked in the same row as the git-shaped
// ones. /ports survives underneath as the raw host-wide feed the source reads —
// it is the thing that knows about `lsof`, HTTP probes and process trees, and it
// still answers unfiltered for anything that wants the whole list.
//
// The bar every source clears: a suggestion returned is one the app can act on.
// The signals are what Herdr says holds the pane's foreground, whether an agent
// lives there, a few stat()s on its working directory, and the listeners already
// attributed to it.
//
// Costs, all behind a short per-pane cache (see suggestTTL): two Herdr
// round-trips, at most one `git status`, and a read of the port scan — which is
// itself cached host-wide for 5s, so a row of open panes shares one `lsof`
// rather than each paying for one.
func (s *Server) handleSuggestions(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}

	found, status, err := s.suggestions.get(r.Context(), pane, s.observePane)
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
//
// The port scan is a third read and the most tolerant of the three: a host with
// no `lsof` is a host with no dev-server chips, not a broken endpoint. See
// paneServers.
func (s *Server) observePane(ctx context.Context, pane string) (suggest.Pane, int, error) {
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
	if s.serversFor != nil {
		out.Servers = s.serversFor(ctx, pane)
	} else {
		out.Servers = s.paneServers(ctx, pane)
	}
	return out, http.StatusOK, nil
}

// paneServers reads the cached host port scan and returns the listeners this
// pane owns, in the shape the sources consume.
//
// This is the join that made the two mechanisms one. Everything expensive is
// already done and cached by internal/ports: which listeners exist, which of
// them answer HTTP, whose pane each belongs to (a walk up the process tree to a
// pane's shell pid), and whether the phone can reach it. All that happens here
// is a filter and a shape change.
//
// **A scan failure is not an endpoint failure.** /ports answers 502 when `lsof`
// is missing, because there the scan IS the response. Here it is one source of
// several, and losing the dev-server chips must not cost a pane its "resolve
// this conflict" chip — so the error is logged and the pane simply has no
// servers. Same reasoning as `agent.get` failing: a missing input narrows which
// sources fire rather than failing the read.
func (s *Server) paneServers(ctx context.Context, pane string) []suggest.Server {
	found, err := s.portsCache.Get(ctx, s.paneShellPIDs)
	if err != nil {
		log.Warn("suggestions: port scan failed", "pane", pane, "err", err)
		return nil
	}
	ports.FillURLs(found, s.cfg.Transport.Addr)

	var out []suggest.Server
	for _, l := range found {
		if l.Pane != pane {
			continue
		}
		out = append(out, suggest.Server{
			Port: l.Port, Proc: l.Proc, URL: l.URL, Loopback: l.Loopback,
		})
	}
	return out
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
// writing files, a rebase stops on a conflict, a dev server comes up, a shell is
// left at a prompt — so a few seconds of staleness is invisible, while the cache
// is what keeps a screen that refetches on focus, on reconnect and on every
// agent status change from turning into a `git status` per event.
//
// Just past ports.TTL (5s) rather than under it, deliberately: a per-pane entry
// that outlived its scan would keep re-triggering scans it then ignores. This
// way a miss here usually finds the scan already warm, and a dev server that
// starts still shows up within about one refresh.
//
// It is also the whole reason this endpoint is safe to call from a poll: the
// app is told it may ask whenever it likes, and the bridge is what decides how
// often that reaches Herdr and the host.
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
func (c *suggestCache) get(ctx context.Context, pane string, observe func(context.Context, string) (suggest.Pane, int, error)) ([]suggest.Suggestion, int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if e, ok := c.entries[pane]; ok && c.clock().Sub(e.at) < suggestTTL {
		return e.list, http.StatusOK, nil
	}
	observed, status, err := observe(ctx, pane)
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
