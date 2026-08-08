package preview

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// targetServer stands in for a dev server bound to loopback: httptest listens
// on 127.0.0.1, which is exactly the situation this package exists for.
func targetServer(t *testing.T, h http.Handler) int {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}
	return port
}

// client follows no redirects and keeps cookies, like a browser navigating.
func client(t *testing.T) *http.Client {
	t.Helper()
	jar := &cookieJar{}
	return &http.Client{Jar: jar, Timeout: 5 * time.Second}
}

// cookieJar is a one-host jar. net/http/cookiejar would work too, but it needs
// a PSL-shaped host and these tests talk to 127.0.0.1.
type cookieJar struct{ cookies []*http.Cookie }

func (j *cookieJar) SetCookies(_ *url.URL, cs []*http.Cookie) { j.cookies = append(j.cookies, cs...) }
func (j *cookieJar) Cookies(*url.URL) []*http.Cookie          { return j.cookies }

func newTestManager(t *testing.T) *Manager {
	t.Helper()
	m := New()
	// No background sweeper: the reaping tests drive reapIdle directly, and a
	// ticker goroutine reading the stubbed clock would race the test writing it.
	m.sweepEvery = 0
	t.Cleanup(m.Close)
	return m
}

// TestRelayServesTheLoopbackServer is the whole point: a server the phone
// cannot reach becomes one it can, because the bridge dials 127.0.0.1 for it.
func TestRelayServesTheLoopbackServer(t *testing.T) {
	port := targetServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "hello from "+r.Host+r.URL.Path)
	}))
	m := newTestManager(t)

	raw := m.URLFor("127.0.0.1", "127.0.0.1", port)
	if raw == "" {
		t.Fatal("no relay url")
	}
	res, err := client(t).Get(raw)
	if err != nil {
		t.Fatalf("GET %s: %v", raw, err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	body, _ := io.ReadAll(res.Body)
	// The Host the dev server saw is its own authority, not the relay's — see
	// the package comment on host checks.
	if want := "hello from 127.0.0.1:" + strconv.Itoa(port) + "/"; string(body) != want {
		t.Errorf("body = %q, want %q", body, want)
	}
}

// TestRelayCarriesWebSockets is the one that matters most in practice. Vite,
// Next and Flutter web all hot-reload over WS; a proxy that serves the HTML and
// drops the upgrade produces a page that loads and then silently stops
// updating — worse than no link, because it looks like it works.
//
// Tested against a real WebSocket server, not a hand-rolled 101, so this is
// evidence rather than an assumption.
func TestRelayCarriesWebSockets(t *testing.T) {
	port := targetServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		typ, data, err := c.Read(ctx)
		if err != nil {
			return
		}
		_ = c.Write(ctx, typ, append([]byte("echo:"), data...))
	}))
	m := newTestManager(t)

	raw := m.URLFor("127.0.0.1", "127.0.0.1", port)
	if raw == "" {
		t.Fatal("no relay url")
	}
	// Exchange the token for a cookie exactly as a browser navigation would,
	// then hand the cookie to the WebSocket dial — which is what a page's HMR
	// client does, since a WS handshake sends cookies for its origin.
	hc := client(t)
	res, err := hc.Get(raw)
	if err != nil {
		t.Fatalf("first navigation: %v", err)
	}
	res.Body.Close()

	u, _ := url.Parse(raw)
	wsURL := "ws://" + u.Host + "/"
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPClient: hc})
	if err != nil {
		t.Fatalf("websocket dial through the relay: %v — hot reload would be silently dead", err)
	}
	defer conn.CloseNow()

	if err := conn.Write(ctx, websocket.MessageText, []byte("ping")); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, got, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(got) != "echo:ping" {
		t.Errorf("got %q, want %q — the upgrade completed but bytes are not flowing", got, "echo:ping")
	}
}

// TestRelayRequiresTheGrant: the relay is on the tailnet, so it carries the
// same expectation as the rest of the API.
func TestRelayRequiresTheGrant(t *testing.T) {
	port := targetServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "secret")
	}))
	m := newTestManager(t)
	raw := m.URLFor("127.0.0.1", "127.0.0.1", port)
	u, _ := url.Parse(raw)
	bare := "http://" + u.Host + "/"

	// No cookie, no token.
	res, err := (&http.Client{Timeout: 5 * time.Second}).Get(bare)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401 for an ungranted request", res.StatusCode)
	}

	// A wrong token is no better than none.
	res2, err := (&http.Client{Timeout: 5 * time.Second}).Get(bare + "?" + TokenParam + "=nope")
	if err != nil {
		t.Fatal(err)
	}
	defer res2.Body.Close()
	if res2.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401 for a wrong token", res2.StatusCode)
	}
}

// TestRelayStripsTheTokenFromTheURL: the grant is exchanged for a cookie and
// redirected away, so it does not sit in the address bar, in history, or in a
// Referer the dev server receives.
func TestRelayStripsTheTokenFromTheURL(t *testing.T) {
	port := targetServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get(TokenParam) != "" {
			t.Errorf("the dev server received the grant: %s", r.URL.RawQuery)
		}
		_, _ = io.WriteString(w, "ok")
	}))
	m := newTestManager(t)
	raw := m.URLFor("127.0.0.1", "127.0.0.1", port)

	noRedirect := &http.Client{
		Timeout:       5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	res, err := noRedirect.Get(raw)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusFound {
		t.Fatalf("status = %d, want a 302 exchanging the token for a cookie", res.StatusCode)
	}
	loc := res.Header.Get("Location")
	if strings.Contains(loc, TokenParam) {
		t.Errorf("redirect target still carries the grant: %q", loc)
	}
	var found *http.Cookie
	for _, c := range res.Cookies() {
		if c.Name == CookieName {
			found = c
		}
	}
	if found == nil {
		t.Fatal("no cookie set — every subresource request would then be unauthorized")
	}
	if !found.HttpOnly {
		t.Error("cookie is not HttpOnly")
	}

	// And the full flow, following the redirect, reaches the dev server.
	res2, err := client(t).Get(raw)
	if err != nil {
		t.Fatal(err)
	}
	defer res2.Body.Close()
	if res2.StatusCode != http.StatusOK {
		t.Errorf("status = %d after the redirect, want 200", res2.StatusCode)
	}
}

// A second call for the same port reuses the listener rather than opening
// another one — the chip is re-offered on every refresh.
func TestRelayIsReusedPerPort(t *testing.T) {
	port := targetServer(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	m := newTestManager(t)

	first := m.URLFor("127.0.0.1", "127.0.0.1", port)
	second := m.URLFor("127.0.0.1", "127.0.0.1", port)
	if first != second {
		t.Errorf("urls differ across calls: %q vs %q", first, second)
	}
	if m.Count() != 1 {
		t.Errorf("Count = %d, want 1 relay for one port", m.Count())
	}
}

// TestRelayReapsIdleListeners is the lifecycle guarantee: a dev server that
// dies stops being connected to, so its relay goes idle and is closed. Without
// this, a listener outlives its server and a later process binding that port
// inherits the tunnel.
func TestRelayReapsIdleListeners(t *testing.T) {
	port := targetServer(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	m := newTestManager(t)

	now := time.Now()
	m.now = func() time.Time { return now }

	raw := m.URLFor("127.0.0.1", "127.0.0.1", port)
	if m.Count() != 1 {
		t.Fatalf("Count = %d, want 1", m.Count())
	}
	u, _ := url.Parse(raw)

	// Not yet idle.
	now = now.Add(idleTimeout / 2)
	m.reapIdle()
	if m.Count() != 1 {
		t.Fatalf("Count = %d, want the relay kept before the timeout", m.Count())
	}

	now = now.Add(idleTimeout + time.Second)
	m.reapIdle()
	if m.Count() != 0 {
		t.Fatalf("Count = %d, want the idle relay reaped", m.Count())
	}
	// The port is really released, not just forgotten.
	if _, err := (&http.Client{Timeout: time.Second}).Get("http://" + u.Host + "/"); err == nil {
		t.Error("the reaped relay is still answering")
	}
}

// Traffic keeps a relay alive, so reading a page for a while does not have it
// pulled out from under you.
func TestRelayTrafficDefersReaping(t *testing.T) {
	port := targetServer(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	m := newTestManager(t)
	now := time.Now()
	m.now = func() time.Time { return now }

	raw := m.URLFor("127.0.0.1", "127.0.0.1", port)
	hc := client(t)
	if res, err := hc.Get(raw); err == nil {
		res.Body.Close()
	}

	now = now.Add(idleTimeout - time.Second)
	if res, err := hc.Get(raw); err == nil { // a request at the last moment
		res.Body.Close()
	}
	now = now.Add(2 * time.Second)
	m.reapIdle()
	if m.Count() != 1 {
		t.Errorf("Count = %d, want the relay kept alive by traffic", m.Count())
	}
}

// A dead dev server produces a readable page rather than a hung tab — the relay
// is the only feedback the phone gets.
func TestRelayReportsADeadUpstream(t *testing.T) {
	// A port nothing is listening on.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dead := ln.Addr().(*net.TCPAddr).Port
	ln.Close()

	m := newTestManager(t)
	raw := m.URLFor("127.0.0.1", "127.0.0.1", dead)
	res, err := client(t).Get(raw)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusBadGateway {
		t.Errorf("status = %d, want 502 for a dev server that is gone", res.StatusCode)
	}
	body, _ := io.ReadAll(res.Body)
	if !strings.Contains(string(body), strconv.Itoa(dead)) {
		t.Errorf("body = %q, want it to name the port", body)
	}
}

// Guards against handing out a URL for inputs that cannot produce a working one.
func TestURLForRefusesUnusableInputs(t *testing.T) {
	m := newTestManager(t)
	cases := []struct {
		listen, public string
		port           int
	}{
		{"", "host", 8124},
		{"127.0.0.1", "", 8124},
		{"127.0.0.1", "host", 0},
		{"127.0.0.1", "host", -1},
	}
	for _, c := range cases {
		if got := m.URLFor(c.listen, c.public, c.port); got != "" {
			t.Errorf("URLFor(%q,%q,%d) = %q, want no url", c.listen, c.public, c.port, got)
		}
	}
	// An unbindable address fails closed rather than returning a broken URL.
	if got := m.URLFor("203.0.113.1", "host", 8124); got != "" {
		t.Errorf("URLFor on an address this machine does not have = %q, want no url", got)
	}
}

// Close releases every listener; a Manager that has been closed hands out
// nothing further.
func TestCloseReleasesEverything(t *testing.T) {
	port := targetServer(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	m := New()
	m.sweepEvery = 0
	raw := m.URLFor("127.0.0.1", "127.0.0.1", port)
	u, _ := url.Parse(raw)
	m.Close()

	if m.Count() != 0 {
		t.Errorf("Count = %d after Close, want 0", m.Count())
	}
	if _, err := (&http.Client{Timeout: time.Second}).Get("http://" + u.Host + "/"); err == nil {
		t.Error("a closed relay is still answering")
	}
	if got := m.URLFor("127.0.0.1", "127.0.0.1", port); got != "" {
		t.Errorf("URLFor after Close = %q, want none", got)
	}
	m.Close() // idempotent
}
