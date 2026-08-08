package ports

import (
	"net/url"
	"testing"
)

// A realistic `lsof -nP -iTCP -sTCP:LISTEN -FpcnP` capture: one process holding
// two sockets, a loopback-only dev server, and the IPv4/IPv6 pair a single
// listener usually reports.
const lsofFixture = `p4821
cnode
f23
PTCP
n*:5173
f24
PTCP
n[::1]:5173
p5107
cnode
f19
PTCP
n127.0.0.1:5174
p4402
cpostgres
f7
PTCP
n127.0.0.1:5432
`

func TestParseLSOF(t *testing.T) {
	got := parseLSOF([]byte(lsofFixture))

	want := []Listener{
		{Port: 5173, Bind: "*", PID: 4821, Proc: "node", Loopback: false},
		{Port: 5173, Bind: "::1", PID: 4821, Proc: "node", Loopback: true},
		{Port: 5174, Bind: "127.0.0.1", PID: 5107, Proc: "node", Loopback: true},
		{Port: 5432, Bind: "127.0.0.1", PID: 4402, Proc: "postgres", Loopback: true},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d listeners, want %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("listener %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// A pid holding the same bind+port twice must collapse — otherwise a server
// listening on both stacks shows the user two chips for one dev server.
func TestParseLSOFCollapsesDuplicateRows(t *testing.T) {
	raw := "p900\ncnode\nf3\nPTCP\nn127.0.0.1:3000\nf4\nPTCP\nn127.0.0.1:3000\n"
	if got := parseLSOF([]byte(raw)); len(got) != 1 {
		t.Fatalf("got %d listeners, want 1: %+v", len(got), got)
	}
}

func TestSplitListen(t *testing.T) {
	cases := []struct {
		in       string
		bind     string
		port     int
		ok       bool
		loopback bool
	}{
		{in: "*:5173", bind: "*", port: 5173, ok: true, loopback: false},
		{in: "127.0.0.1:8080", bind: "127.0.0.1", port: 8080, ok: true, loopback: true},
		{in: "[::1]:8080", bind: "::1", port: 8080, ok: true, loopback: true},
		// A tailnet-bound server is reachable, so it must not read as loopback.
		{in: "100.84.12.3:5173", bind: "100.84.12.3", port: 5173, ok: true, loopback: false},
		// Established connections are not listeners.
		{in: "127.0.0.1:5173->127.0.0.1:60122", ok: false},
		{in: "garbage", ok: false},
		{in: "127.0.0.1:notaport", ok: false},
	}
	for _, c := range cases {
		bind, port, ok := splitListen(c.in)
		if ok != c.ok {
			t.Errorf("splitListen(%q) ok = %v, want %v", c.in, ok, c.ok)
			continue
		}
		if !ok {
			continue
		}
		if bind != c.bind || port != c.port {
			t.Errorf("splitListen(%q) = %q,%d want %q,%d", c.in, bind, port, c.bind, c.port)
		}
		if got := isLoopback(bind); got != c.loopback {
			t.Errorf("isLoopback(%q) = %v, want %v", bind, got, c.loopback)
		}
	}
}

func TestParsePS(t *testing.T) {
	parent := parsePS([]byte("  4821  4800\n  4800  1637\n 1637     1\nbad line here\n"))
	want := map[int]int{4821: 4800, 4800: 1637, 1637: 1}
	if len(parent) != len(want) {
		t.Fatalf("got %v, want %v", parent, want)
	}
	for k, v := range want {
		if parent[k] != v {
			t.Errorf("parent[%d] = %d, want %d", k, parent[k], v)
		}
	}
}

// The core of attribution: a dev server is a grandchild of the pane shell (shell
// -> npm -> node), so the walk has to climb, not just check the direct parent.
func TestAttributeWalksParentChain(t *testing.T) {
	ls := []Listener{
		{Port: 5173, PID: 4821}, // node <- npm <- pane shell 1637
		{Port: 5174, PID: 9001}, // parented outside any pane
	}
	parent := map[int]int{4821: 4800, 4800: 1637, 1637: 1, 9001: 1}
	panes := map[int]PaneRef{1637: {Pane: "acme/wN:p2", Agent: "claude"}}

	Attribute(ls, panes, parent)

	if ls[0].Pane != "acme/wN:p2" || ls[0].Agent != "claude" {
		t.Errorf("listener 5173 = %+v, want pane acme/wN:p2 agent claude", ls[0])
	}
	// An unattributed listener is still a real server — it must survive, just
	// without a label.
	if ls[1].Pane != "" {
		t.Errorf("listener 5174 got pane %q, want unattributed", ls[1].Pane)
	}
}

// A corrupt ps table describing a cycle must not hang the scan.
func TestAttributeTerminatesOnCycle(t *testing.T) {
	ls := []Listener{{Port: 3000, PID: 10}}
	parent := map[int]int{10: 11, 11: 10}
	Attribute(ls, map[int]PaneRef{999: {Pane: "p"}}, parent)
	if ls[0].Pane != "" {
		t.Errorf("got pane %q, want unattributed", ls[0].Pane)
	}
}

func TestFillURLs(t *testing.T) {
	ls := []Listener{
		{Port: 5173, Bind: "*"},
		{Port: 5174, Bind: "127.0.0.1", Loopback: true},
	}
	// A bare host the CALLER can reach — not the bridge's bind address, which
	// is what this used to be given and is the bug the tests below pin down.
	FillURLs(ls, "100.84.12.3")

	if want := "http://100.84.12.3:5173"; ls[0].URL != want {
		t.Errorf("reachable url = %q, want %q", ls[0].URL, want)
	}
	// The empty URL is load-bearing: it is what the app renders as the dimmed
	// "localhost-only" state, so a loopback bind must never get one.
	if ls[1].URL != "" {
		t.Errorf("loopback url = %q, want empty", ls[1].URL)
	}
}

// ---- URL construction ----
//
// The regression these guard against was found on a real phone: the chip
// rendered "Open :8123 · Python · serving", the browser opened, and the
// connection was refused — because the URL was http://127.0.0.1:8123, which on
// a phone is the phone's own loopback. The bridge had derived it from its own
// BIND address (127.0.0.1:8787 behind `tailscale serve`), which answers "where
// does this process listen" and never "what should someone else dial".

// TestFillURLsNeverEmitsALoopbackURL is the invariant, stated flatly: whatever
// the inputs, a listener that comes back with a URL must not point the caller
// at their own machine. This is the one that must never silently regress.
func TestFillURLsNeverEmitsALoopbackURL(t *testing.T) {
	binds := []string{"*", "0.0.0.0", "::", "127.0.0.1", "127.0.1.9", "::1", "100.84.12.3", "192.168.1.50"}
	hosts := []string{
		"my-mac.tailnet.ts.net", "100.88.0.122", "192.168.1.7",
		// The dangerous inputs: a caller host that is itself loopback, or absent.
		"127.0.0.1", "localhost", "::1", "0.0.0.0", "",
	}
	for _, bind := range binds {
		for _, host := range hosts {
			ls := []Listener{{Port: 8123, Bind: bind, Loopback: isLoopback(bind)}}
			FillURLs(ls, host)
			if ls[0].URL == "" {
				continue
			}
			u, err := url.Parse(ls[0].URL)
			if err != nil {
				t.Fatalf("bind=%q host=%q: unparseable url %q: %v", bind, host, ls[0].URL, err)
			}
			if IsLoopbackHost(u.Hostname()) {
				t.Errorf("bind=%q host=%q produced %q — a phone opening that reaches ITSELF",
					bind, host, ls[0].URL)
			}
			if u.Port() != "8123" {
				t.Errorf("bind=%q host=%q produced port %q, want the dev server's 8123 (not the bridge's)",
					bind, host, u.Port())
			}
			if u.Scheme != "http" {
				t.Errorf("bind=%q host=%q produced scheme %q, want http — the probe that qualified this listener spoke plain HTTP to it",
					bind, host, u.Scheme)
			}
		}
	}
}

// TestFillURLsWildcardUsesTheCallerHost is the reported case: a server on
// 0.0.0.0 answers on every interface, so the address the caller reached the
// bridge on is the one that works for them.
func TestFillURLsWildcardUsesTheCallerHost(t *testing.T) {
	ls := []Listener{{Port: 8123, Bind: "*"}}
	FillURLs(ls, "my-mac.tailnet.ts.net")
	if got, want := ls[0].URL, "http://my-mac.tailnet.ts.net:8123"; got != want {
		t.Errorf("url = %q, want %q", got, want)
	}
}

// A server bound to one specific interface names its own address rather than
// borrowing the bridge's hostname. It is the address the server actually serves
// on; whether the caller can route there is a network question, and a URL that
// looks right and times out is worse than one that is simply honest.
func TestFillURLsSpecificBindKeepsItsOwnAddress(t *testing.T) {
	ls := []Listener{
		{Port: 8123, Bind: "100.84.12.3"},
		{Port: 9000, Bind: "192.168.1.50"},
	}
	FillURLs(ls, "my-mac.tailnet.ts.net")
	if got, want := ls[0].URL, "http://100.84.12.3:8123"; got != want {
		t.Errorf("tailnet-bound: url = %q, want %q", got, want)
	}
	if got, want := ls[1].URL, "http://192.168.1.50:9000"; got != want {
		t.Errorf("lan-bound: url = %q, want %q", got, want)
	}
}

// A loopback-bound server gets no URL however reachable the caller is — it is
// the app's dimmed "local-only" state, and the note names the fix.
func TestFillURLsLoopbackBindStaysURLLess(t *testing.T) {
	ls := []Listener{{Port: 5174, Bind: "127.0.0.1", Loopback: true}}
	FillURLs(ls, "my-mac.tailnet.ts.net")
	if ls[0].URL != "" {
		t.Errorf("url = %q, want none for a loopback bind", ls[0].URL)
	}
}

// With no reachable caller host, a wildcard-bound server reports no URL rather
// than one built out of a guess.
func TestFillURLsWithoutACallerHost(t *testing.T) {
	ls := []Listener{{Port: 8123, Bind: "*"}}
	FillURLs(ls, "")
	if ls[0].URL != "" {
		t.Errorf("url = %q, want none when there is no host to name", ls[0].URL)
	}
}

func TestIsLoopbackHost(t *testing.T) {
	loop := []string{"127.0.0.1", "127.0.1.9", "::1", "[::1]", "localhost", "LOCALHOST", "0.0.0.0", "::"}
	for _, h := range loop {
		if !IsLoopbackHost(h) {
			t.Errorf("IsLoopbackHost(%q) = false, want true", h)
		}
	}
	fine := []string{"my-mac.tailnet.ts.net", "100.84.12.3", "192.168.1.50", "example.com", ""}
	for _, h := range fine {
		if IsLoopbackHost(h) {
			t.Errorf("IsLoopbackHost(%q) = true, want false", h)
		}
	}
}
