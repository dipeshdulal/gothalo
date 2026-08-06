package ports

import (
	"context"
	"net"
	"net/url"
	"strconv"
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

// FillURLs stamps each reachable listener with the address the phone should
// open, derived from the host the bridge itself is reachable on: the phone
// already talks to bridgeAddr, so the same host with the server's port is
// reachable by construction.
//
// Loopback binds are deliberately left with an empty URL. Nothing on the
// network can reach them, and handing the app a URL that cannot connect is
// worse than telling it there isn't one — the empty URL is what the app keys
// its dimmed "localhost-only" state off.
func FillURLs(ls []Listener, bridgeAddr string) {
	host, _, err := net.SplitHostPort(bridgeAddr)
	if err != nil {
		host = bridgeAddr
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		// The bridge is bound to every interface, so it has no single address
		// to hand out. Rather than guess an interface, leave the URLs empty and
		// let the app fall back to the host it already dialled.
		return
	}
	for i := range ls {
		if ls[i].Loopback {
			continue
		}
		u := url.URL{Scheme: "http", Host: net.JoinHostPort(host, strconv.Itoa(ls[i].Port))}
		ls[i].URL = u.String()
	}
}
