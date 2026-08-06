package ports

import (
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
	FillURLs(ls, "100.84.12.3:8787")

	if want := "http://100.84.12.3:5173"; ls[0].URL != want {
		t.Errorf("reachable url = %q, want %q", ls[0].URL, want)
	}
	// The empty URL is load-bearing: it is what the app renders as the dimmed
	// "localhost-only" state, so a loopback bind must never get one.
	if ls[1].URL != "" {
		t.Errorf("loopback url = %q, want empty", ls[1].URL)
	}
}

// Bound to every interface, the bridge has no single address to advertise —
// guessing one would hand the app a URL that may not route.
func TestFillURLsSkipsWildcardBridgeAddr(t *testing.T) {
	ls := []Listener{{Port: 5173, Bind: "*"}}
	FillURLs(ls, "0.0.0.0:8787")
	if ls[0].URL != "" {
		t.Errorf("url = %q, want empty for a wildcard bridge bind", ls[0].URL)
	}
}
