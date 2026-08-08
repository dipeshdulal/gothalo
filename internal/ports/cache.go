package ports

import (
	"context"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// TTL is how long a scan stays fresh. The list page polls /ports alongside
// /snapshot, and a dev server's port does not change between two polls a few
// seconds apart — so a short cache turns a per-poll `lsof` + a fan of probes
// into an occasional one. Short enough that starting a dev server shows up
// while you are still looking at the screen.
const TTL = 5 * time.Second

// Cache serialises and memoises host scans. Concurrent callers during a scan
// wait for it and share the result rather than each running their own lsof.
type Cache struct {
	mu   sync.Mutex
	at   time.Time
	last []Listener
	// now is swappable in tests; nil means time.Now.
	now func() time.Time
}

func (c *Cache) clock() time.Time {
	if c.now != nil {
		return c.now()
	}
	return time.Now()
}

// Get returns the cached listeners, rescanning when the entry has aged out.
// On a scan failure it returns the error; it does not serve a stale result,
// since a failed scan and an empty host are different answers.
//
// panes is a func rather than a map because resolving it costs one Herdr
// round-trip per pane: on a cache hit it is never called at all, which is the
// common case when the list page is polling.
//
// The result is a copy. Callers stamp URLs onto what they get back, and the
// cached slice has to stay clean for the next caller.
func (c *Cache) Get(ctx context.Context, panes func() map[int]PaneRef) ([]Listener, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if now := c.clock(); c.last != nil && now.Sub(c.at) < TTL {
		return append([]Listener(nil), c.last...), nil
	}
	var refs map[int]PaneRef
	if panes != nil {
		refs = panes()
	}
	found, err := Collect(ctx, refs)
	if err != nil {
		return nil, err
	}
	if found == nil {
		found = []Listener{}
	}
	c.last, c.at = found, c.clock()
	return append([]Listener(nil), found...), nil
}

// FillURLs stamps each reachable listener with a URL **the caller** can open.
//
// clientHost is a bare host (no port) that the caller is known to be able to
// reach — see server.reachableHost, which derives it from the connection the
// caller is already talking on. It is a parameter rather than something this
// package works out because "reachable" is a fact about the client, not about
// the host: the bridge cannot know it by looking at itself.
//
// This used to be derived from the bridge's own BIND address, and that was a
// real bug rather than a rough edge. Behind `tailscale serve` (the documented
// deployment) the bridge binds 127.0.0.1:8787 and the tailnet front-end proxies
// to it, so every listener came back as http://127.0.0.1:<port> — which on a
// phone is the PHONE's loopback. The chip rendered, the browser opened, and the
// connection was refused. The bind address answers "where does this process
// listen", never "what should someone else dial".
//
// Three outcomes, decided by what the LISTENER is bound to:
//
//   - Loopback bind → no URL. Nothing off-box can reach it however it is
//     addressed, and handing the app a URL that cannot connect is worse than
//     telling it there isn't one. The empty URL is what the app keys its dimmed
//     "localhost-only" state off.
//   - Wildcard bind ("*", i.e. 0.0.0.0 / ::) → clientHost. The server answers on
//     every interface the host has, which necessarily includes the one the
//     caller just reached the bridge on.
//   - A specific non-loopback bind (100.84.12.3, 192.168.1.50) → that address
//     verbatim. It is the address the server actually serves on, and it beats
//     substituting the bridge's hostname: a server bound only to the LAN
//     interface is not answering on the tailnet one, and saying so honestly is
//     better than composing a URL that looks right and times out.
//
// The scheme is always http, and that is not a guess. A listener only reaches
// this function after answering a bare `GET / HTTP/1.0` over a plain TCP dial
// (see speaksHTTP) — a server that actually spoke TLS on its port would have
// failed that probe and never been listed. The bridge's own https is a property
// of the bridge's port (where `tailscale serve` terminates TLS), not of the
// machine, and nothing is terminating TLS on a dev server's port.
func FillURLs(ls []Listener, clientHost string) {
	for i := range ls {
		if ls[i].Loopback {
			continue
		}
		host := ls[i].Bind
		if isWildcard(host) {
			host = clientHost
		}
		// No reachable host to name (a wildcard bind and a caller we could not
		// place). Leave it empty rather than invent one: the app renders it as
		// "up, but we cannot give you a link", which is true.
		if host == "" || isLoopbackHost(host) {
			continue
		}
		u := url.URL{Scheme: "http", Host: net.JoinHostPort(host, strconv.Itoa(ls[i].Port))}
		ls[i].URL = u.String()
	}
}

// isWildcard reports a bind that names no particular interface. lsof prints "*"
// for these; the literal spellings are accepted too, since a caller-supplied
// host can arrive in either form.
func isWildcard(bind string) bool {
	switch bind {
	case "*", "0.0.0.0", "::", "[::]":
		return true
	}
	return false
}

// IsLoopbackHost reports whether host names the caller's own machine — the one
// thing a preview URL must never be. It accepts the literal name as well as the
// addresses, because "localhost" is what a person types and what a misconfigured
// public_url is most likely to contain.
//
// Exported so the layer that picks a client host can apply the same test the URL
// builder does, rather than a second one that could drift from it.
func IsLoopbackHost(host string) bool { return isLoopbackHost(host) }

func isLoopbackHost(host string) bool {
	h := strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	if h == "" {
		return false
	}
	if strings.EqualFold(h, "localhost") {
		return true
	}
	if ip := net.ParseIP(h); ip != nil {
		return ip.IsLoopback() || ip.IsUnspecified()
	}
	// A name we cannot resolve here (a tailnet DNS name, a LAN hostname) is not
	// loopback. Resolving it would be a DNS round-trip on a hot path to answer a
	// question the name itself already answers for every realistic case.
	return strings.EqualFold(h, "localhost.localdomain") ||
		strings.HasSuffix(strings.ToLower(h), ".localhost")
}
