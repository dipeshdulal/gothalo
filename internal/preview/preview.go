// Package preview relays a loopback-bound dev server to the tailnet, so a
// server the phone cannot reach becomes a link it can open.
//
// The bridge runs ON the Herdr host, so it can dial 127.0.0.1 when the phone
// cannot. That is the entire idea — `ssh -L` semantics without the SSH — and it
// is what turns the "…is local-only" chip from an explanation into a link.
//
// Named `preview`, not `relay`, because config.Transport already has a
// `"relay"` mode meaning something unrelated (an outbound broker, see
// internal/transport/relay). Two different things called relay in one binary is
// a bug waiting to be written.
//
// # Why a listener per previewed port, and not a path prefix on the bridge
//
// A path-prefixed proxy (`/preview/8124/…` on the bridge's own port) is the
// cheaper-looking design and it does not work:
//
//   - **Absolute asset paths escape the prefix.** Vite serves `/@vite/client`
//     and `/src/main.tsx`; Next serves `/_next/static/…`; Flutter web serves
//     `/main.dart.js` and `/flutter_service_worker.js`. All root-absolute. The
//     document loads from under the prefix, then every subresource requests the
//     bridge's own root and 404s.
//   - **HMR computes its own socket URL** from `location` in the browser, so it
//     dials the origin's root, not the prefix.
//   - **Redirects to `/`** (every framework that bounces an unauthenticated or
//     trailing-slash request) leave the prefix entirely.
//
// Fixing that means rewriting HTML, CSS `url()`, JS string literals and
// `Location` headers — an arms race against every framework's output, which
// fails silently and differently for each one.
//
// A dedicated listener gives the previewed app a **real origin**. Absolute
// paths, redirects, cookies, HMR sockets and service workers all just work,
// because from the app's point of view nothing is unusual. The cost is an open
// port, which is exactly what the auth below is for.
//
// # Host header
//
// The proxied request carries `Host: 127.0.0.1:<port>` — the target's own
// authority, not the relay's. Dev servers increasingly reject unknown Hosts
// (Vite's `server.allowedHosts` since the 5.4.12/6.0.9 fix, Django's
// ALLOWED_HOSTS, Rails' host authorization), and the whole point of this proxy
// is to look to the dev server exactly like the local request it already
// serves happily. The original authority is preserved in `X-Forwarded-Host`
// for an app that wants it.
//
// The known cost, stated rather than discovered later: an app that builds
// absolute self-URLs out of `Host` will emit `127.0.0.1:<port>` links, which
// the phone cannot follow. That is rare in dev servers (root-relative is the
// norm) and strictly less common than a host check rejecting the request
// outright.
package preview

import (
	"crypto/rand"
	"encoding/hex"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/log"
)

// TokenParam carries the grant on the FIRST navigation. A browser is the client
// here — the phone opens this in its own browser, not in the app — so there is
// no way to set an Authorization header, and no way to attach a query parameter
// to the subresource requests the page then makes on its own. The token is
// therefore exchanged for a cookie and stripped from the URL.
const TokenParam = "gothalo_preview"

// CookieName holds the grant for everything after that first navigation:
// subresources, XHR, and the HMR WebSocket handshake (which sends cookies for
// its origin like any other request).
const CookieName = "gothalo_preview"

// idleTimeout is how long a relay survives with no traffic.
//
// This is the whole lifecycle answer, and it is deliberately the only one: a
// dev server that dies stops being connected to, so its relay goes idle and is
// reaped. Tying reaping to the port scan instead would couple two caches and
// still need this as a backstop, since a scan that stops running would leak
// every listener it had ever opened.
//
// It also bounds the one genuinely unpleasant failure: a relay outliving its
// dev server, and a DIFFERENT process later binding that port and inheriting
// the tunnel. Five minutes keeps a preview alive across reading a page and
// coming back, and keeps that window short.
const idleTimeout = 5 * time.Minute

// sweepInterval is how often idle relays are looked for. Coarse on purpose:
// this is housekeeping, not a deadline.
const sweepInterval = time.Minute

// Manager owns the live relays. The zero value is not usable; call New.
type Manager struct {
	mu sync.Mutex
	// relays is keyed by listenAddr|port — the two things a relay is specific
	// to. Keyed by listen address as well as target port because two callers
	// reaching the bridge by different routes (tailnet, LAN) need the relay
	// exposed where each of them can see it.
	relays map[string]*relay
	token  string
	closed bool
	// listen, now and sweepEvery are swappable in tests. sweepEvery of 0 means
	// no background sweeper — the reaping tests drive reapIdle directly, which
	// keeps the clock stub free of a goroutine racing it.
	listen     func(network, addr string) (net.Listener, error)
	now        func() time.Time
	sweepEvery time.Duration
	sweeping   sync.Once
	stop       chan struct{}
}

type relay struct {
	target   int // the loopback port being relayed
	listener net.Listener
	url      string

	mu       sync.Mutex
	lastUsed time.Time
}

func (r *relay) touch(now time.Time) {
	r.mu.Lock()
	r.lastUsed = now
	r.mu.Unlock()
}

func (r *relay) idleSince() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastUsed
}

// New returns a Manager. Nothing runs until a relay is actually wanted: the
// sweeper starts with the first listener, so a bridge whose panes never serve
// anything — and every test that constructs a Server — costs no goroutine.
func New() *Manager {
	return &Manager{
		relays:     map[string]*relay{},
		token:      newToken(),
		listen:     net.Listen,
		now:        time.Now,
		sweepEvery: sweepInterval,
		stop:       make(chan struct{}),
	}
}

// newToken mints the grant this process hands out.
//
// One token for the bridge's lifetime, not one per device, and the consequence
// is worth naming: revoking a paired device does not close a preview session it
// already opened — that waits for the bridge to restart. It is a deliberate
// trade against a per-device grant registry, and it is bounded by what the
// token can actually do (reach a dev server on this host, nothing else) and by
// idleTimeout.
func newToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand does not fail in practice, and a preview is not worth
		// crashing the bridge over. A manager with no token refuses every
		// request, which is the safe direction.
		log.Error("preview: could not mint a relay token", "err", err)
		return ""
	}
	return hex.EncodeToString(b)
}

// URLFor returns a URL the caller can open for a loopback server on port,
// starting a relay if there is not one already. "" means no relay is available
// — the caller should fall back to explaining the loopback bind rather than
// offering a link.
//
// listenAddr is the address to bind (a literal IP), publicHost is what goes in
// the URL. They differ because the caller reaches the bridge by a NAME whose
// address is what we can actually bind: exposing the relay exactly where the
// bridge is already reachable, and no wider, is the point of taking both.
func (m *Manager) URLFor(listenAddr, publicHost string, port int) string {
	if m == nil || port <= 0 || listenAddr == "" || publicHost == "" || m.token == "" {
		return ""
	}
	key := listenAddr + "|" + strconv.Itoa(port)

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return ""
	}
	if r, ok := m.relays[key]; ok {
		r.touch(m.now())
		return r.url
	}

	// Port 0: let the OS pick. Binding the dev server's own port on another
	// interface would give a prettier URL, but it collides the moment anything
	// else has claimed it and buys nothing — the chip's LABEL already names the
	// real port; the relay's port is plumbing.
	ln, err := m.listen("tcp", net.JoinHostPort(listenAddr, "0"))
	if err != nil {
		log.Warn("preview: could not open a relay listener", "addr", listenAddr, "port", port, "err", err)
		return ""
	}
	relayPort := ln.Addr().(*net.TCPAddr).Port

	u := url.URL{
		Scheme:   "http",
		Host:     net.JoinHostPort(publicHost, strconv.Itoa(relayPort)),
		Path:     "/",
		RawQuery: url.Values{TokenParam: {m.token}}.Encode(),
	}
	r := &relay{target: port, listener: ln, url: u.String(), lastUsed: m.now()}
	m.relays[key] = r
	if m.sweepEvery > 0 {
		m.sweeping.Do(func() { go m.sweep(m.sweepEvery) })
	}

	srv := &http.Server{Handler: m.handler(r)}
	go func() {
		if err := srv.Serve(ln); err != nil && !strings.Contains(err.Error(), "use of closed") {
			log.Warn("preview: relay stopped", "port", port, "err", err)
		}
	}()
	log.Info("preview: relaying", "listen", ln.Addr().String(), "target", port)
	return r.url
}

// handler is the auth gate in front of the reverse proxy.
//
// The honest framing of what this gate is worth, which the contract repeats:
// a paired device already has POST /send — arbitrary typing into any pane — so
// reaching a loopback port is not an escalation of what that bearer can do. The
// gate exists so the relay is not a hole that is WIDER than the rest of the
// API, not because it is the only thing standing between the tailnet and this
// host.
func (m *Manager) handler(r *relay) http.Handler {
	target := &url.URL{Scheme: "http", Host: net.JoinHostPort("127.0.0.1", strconv.Itoa(r.target))}
	proxy := httputil.NewSingleHostReverseProxy(target)

	director := proxy.Director
	proxy.Director = func(req *http.Request) {
		director(req)
		// Preserve where the request really came from before overwriting Host —
		// an app that wants the outside authority can find it here.
		req.Header.Set("X-Forwarded-Host", req.Host)
		req.Header.Set("X-Forwarded-Proto", "http")
		// Present as the local request the dev server already serves happily.
		// See the package comment: host checks are the common failure, absolute
		// self-URLs the rare one.
		req.Host = target.Host
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		// The dev server went away, or never answered. Say so plainly: this
		// page is the only feedback the phone gets.
		log.Warn("preview: upstream failed", "target", r.target, "err", err)
		http.Error(w, "the dev server on port "+strconv.Itoa(r.target)+
			" is not answering — it may have stopped", http.StatusBadGateway)
	}

	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if !m.authorize(w, req) {
			return
		}
		r.touch(m.now())
		// ReverseProxy handles a 101 by hijacking and splicing both ways, so
		// WebSockets (every framework's hot reload) pass through end to end.
		// This is the part most likely to be quietly broken, so it is tested
		// against a real WebSocket server rather than assumed.
		proxy.ServeHTTP(w, req)
	})
}

// authorize accepts the grant from the cookie, or from the query parameter on a
// first navigation — in which case it sets the cookie and redirects to the same
// URL without the token, so the grant does not linger in history, the address
// bar, or a Referer header sent to the dev server.
func (m *Manager) authorize(w http.ResponseWriter, req *http.Request) bool {
	if c, err := req.Cookie(CookieName); err == nil && c.Value != "" && c.Value == m.token {
		return true
	}
	q := req.URL.Query()
	if q.Get(TokenParam) == m.token && m.token != "" {
		http.SetCookie(w, &http.Cookie{
			Name:  CookieName,
			Value: m.token,
			// Path "/" and no Domain: the cookie is confined to this host, and
			// browsers ignore ports for cookies, so it is also sent to anything
			// else on this host the browser talks to. That is harmless here —
			// anything ON this host can already dial 127.0.0.1 directly, so the
			// token grants it nothing it did not have.
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
		})
		q.Del(TokenParam)
		to := *req.URL
		to.RawQuery = q.Encode()
		http.Redirect(w, req, to.RequestURI(), http.StatusFound)
		return false
	}
	http.Error(w, "unauthorized", http.StatusUnauthorized)
	return false
}

// sweep closes relays nothing has used for idleTimeout.
func (m *Manager) sweep(every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-m.stop:
			return
		case <-t.C:
			m.reapIdle()
		}
	}
}

func (m *Manager) reapIdle() {
	m.mu.Lock()
	defer m.mu.Unlock()
	cutoff := m.now().Add(-idleTimeout)
	for key, r := range m.relays {
		if r.idleSince().Before(cutoff) {
			log.Info("preview: closing idle relay", "target", r.target)
			_ = r.listener.Close()
			delete(m.relays, key)
		}
	}
}

// Close stops the sweeper and every live relay.
func (m *Manager) Close() {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return
	}
	m.closed = true
	close(m.stop)
	for key, r := range m.relays {
		_ = r.listener.Close()
		delete(m.relays, key)
	}
}

// Count reports how many relays are live, for tests and for a future status
// surface.
func (m *Manager) Count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.relays)
}
