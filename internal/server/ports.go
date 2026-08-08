package server

import (
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/ports"
)

// GET /ports -> the HTTP servers currently running on the host, each attributed
// to the pane that spawned it. Optional ?pane=<pane_id> narrows to one pane.
//
// **The raw feed, not the app-facing surface.** The app asks GET /suggestions,
// which turns this pane's listeners into chips alongside everything else it can
// offer (see D29 and docs/CONTRACT-suggestions.md). This endpoint stays because
// it answers the HOST question — what is serving on this machine and whose is
// it — which a per-pane read cannot, and because it is the layer that knows
// about lsof, HTTP probes and process trees. It is also the honest way to poke
// the scan by hand.
//
// Deliberately not folded into /snapshot. Snapshot is the hottest read in the
// bridge and stays a passthrough; a port scan probes every listener and belongs
// on its own cadence.
//
// A listener with an empty url is bound to loopback: it is serving, but nothing
// on the tailnet can reach it. That is reported rather than hidden, because
// "vite is up, it's just on 127.0.0.1" is the answer you actually want when the
// preview chip is missing.
func (s *Server) handlePorts(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}

	found, err := s.portsCache.Get(r.Context(), s.paneShellPIDs)
	if err != nil {
		log.Warn("ports: scan failed", "err", err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	ports.FillURLs(found, s.reachableHost(r))

	if pane := r.URL.Query().Get("pane"); pane != "" {
		filtered := make([]ports.Listener, 0, len(found))
		for _, l := range found {
			if l.Pane == pane {
				filtered = append(filtered, l)
			}
		}
		found = filtered
	}

	writeJSON(w, map[string]any{"ports": found})
}

// paneMapTTL is how long the pane -> shell-pid map stays good. Much longer than
// the port scan's own TTL on purpose: a pane's shell pid is fixed for the pane's
// whole life, so this only goes stale when a pane is created or closed, which is
// rare next to the poll rate. Rebuilding it costs a snapshot plus one
// `pane.process_info` round-trip per pane, and that is the expensive half of
// /ports — the scan itself is two local commands.
const paneMapTTL = 30 * time.Second

// paneMapCache memoises the pane -> shell-pid map across scans.
type paneMapCache struct {
	mu   sync.Mutex
	at   time.Time
	last map[int]ports.PaneRef
}

// paneShellPIDs maps every pane's shell pid to the pane it belongs to, which is
// what turns a listening pid into "claude on feat/checkout". It is the join side
// of attribution; the walk itself is ports.Attribute.
//
// Covers plain panes, not just agent panes, and that is the point: a dev server
// normally runs in a pane split off *beside* the agent rather than in the
// agent's own pane, so an agent-only map would miss the common case entirely.
// Plain panes come back with an empty Agent and the app labels them by process
// name.
//
// Errors are swallowed per pane: a pane that goes away between the snapshot and
// the process read just does not contribute an entry, which costs one
// attribution rather than the whole endpoint.
func (s *Server) paneShellPIDs() map[int]ports.PaneRef {
	s.paneMap.mu.Lock()
	defer s.paneMap.mu.Unlock()

	if s.paneMap.last != nil && time.Since(s.paneMap.at) < paneMapTTL {
		return s.paneMap.last
	}

	out := map[int]ports.PaneRef{}
	for _, session := range s.sessions.Names() {
		c, err := s.sessions.Client(session)
		if err != nil {
			continue
		}
		panes, err := c.PaneIDs()
		if err != nil {
			log.Warn("ports: pane list failed", "session", session, "err", err)
			continue
		}
		// One agent.list per session labels the agent panes; every other pane is
		// a plain one and keeps an empty kind.
		kinds := map[string]string{}
		if agents, err := c.Agents(); err == nil {
			for _, a := range agents {
				kinds[a.PaneID] = a.Kind
			}
		}
		for _, pane := range panes {
			info, err := c.PaneProcessInfo(pane)
			if err != nil || info.ShellPID == 0 {
				continue
			}
			out[info.ShellPID] = ports.PaneRef{
				Pane:  herdr.Qualify(session, pane),
				Agent: kinds[pane],
			}
		}
	}

	s.paneMap.last, s.paneMap.at = out, time.Now()
	return out
}

// reachableHost returns a bare host (no port) that THIS caller can dial to
// reach another port on the Herdr host — the host part of every dev-server
// preview URL.
//
// The bug this exists to prevent: the bridge's own bind address is not it.
// Behind `tailscale serve` (the documented deployment) the bridge binds
// 127.0.0.1:8787 while the tailnet front-end answers on
// <host>.<tailnet>.ts.net:5338, so deriving a preview URL from the bind address
// handed every phone http://127.0.0.1:<port> — the phone's own loopback.
// Verified on a real device: the chip rendered, the browser opened, the
// connection was refused.
//
// Three sources, in this order:
//
//  1. **The request's own Host.** Authoritative because it is a fact about a
//     connection that just succeeded rather than a configuration that might be
//     stale: whatever the caller dialled to get here, they can dial again. It is
//     also per-caller correct — a phone on the tailnet and a laptop on the LAN
//     each get an answer that works for them, which no single configured value
//     can do.
//  2. **transport.public_url**, when the Host header is unusable. That happens
//     when a reverse proxy rewrites Host to its own upstream address — the very
//     `tailscale serve` case above, if it ever stops passing Host through. The
//     operator's declared public URL is exactly the right answer there, and it
//     is already the address the pairing QR hands out.
//  3. **The bind address**, when it is a literal non-loopback address. This is
//     the `GOTHALO_ADDR=$(tailscale ip -4):8787` setup from the README, where
//     the bridge really is reachable at the address it binds.
//
// Every candidate is filtered through the same loopback test the URL builder
// uses, so a stage that can only offer "localhost" falls through to the next
// rather than producing a link that cannot connect. When all three fall through
// the caller gets no URL at all and the app renders the honest
// "up, but not reachable from here" state.
//
// Deliberately does NOT consult X-Forwarded-Host. It would help only in the
// proxy-rewrites-Host case that public_url already covers, and it would add a
// spoofable input to a URL the user is invited to open.
func (s *Server) reachableHost(r *http.Request) string {
	for _, candidate := range []string{
		hostOnly(r.Host),
		hostOnly(s.cfg.Transport.PublicURL),
		hostOnly(s.cfg.Transport.Addr),
	} {
		if candidate != "" && !ports.IsLoopbackHost(candidate) {
			return candidate
		}
	}
	return ""
}

// hostOnly reduces whatever shape an address arrives in — "example.ts.net:5338",
// "https://example.ts.net:5338/", a bare host, an IPv6 literal — to its host.
func hostOnly(addr string) string {
	v := strings.TrimSpace(addr)
	if v == "" {
		return ""
	}
	if strings.Contains(v, "://") {
		u, err := url.Parse(v)
		if err != nil || u.Hostname() == "" {
			return ""
		}
		return u.Hostname()
	}
	if host, _, err := net.SplitHostPort(v); err == nil {
		return host
	}
	return strings.TrimSuffix(strings.TrimPrefix(v, "["), "]")
}
