// Package ports discovers HTTP servers running on the Herdr host and attributes
// each one to the pane that spawned it, for GET /ports.
//
// Two things the phone cannot work out for itself. First, *which* ports are
// serving: `lsof` lists every TCP listener, most of which are databases, the
// bridge itself, and OS daemons — so a listener only counts once it has
// answered a probe with an HTTP status line. Second, *whose* it is: with agents
// working in parallel worktrees there may be three dev servers up at once, and
// a bare port number says nothing about which agent owns it. Herdr knows each
// pane's shell pid, so walking a listener's parent chain until it reaches a
// known shell pid names the owner.
//
// It shells out to lsof and ps rather than reading /proc — this is a macOS host,
// and the bridge already reads local state directly elsewhere (internal/gitdiff,
// internal/transcript). No elevation is needed: the agents' dev servers run as
// the same user as the bridge.
package ports

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Listener is one HTTP server found on the host.
type Listener struct {
	Port int `json:"port"`
	// Bind is the address the socket is bound to, verbatim from lsof: "*" for
	// all interfaces, otherwise a literal address ("127.0.0.1", "100.84.12.3").
	Bind string `json:"bind"`
	PID  int    `json:"pid"`
	// Proc is the executable name ("node", "python3"), for labelling the chip.
	Proc string `json:"proc"`
	// Loopback reports a bind that only the host itself can connect to. These
	// are the servers a phone on the tailnet cannot reach no matter what — the
	// app shows them as present-but-unreachable rather than hiding them, since
	// "vite is up, it's just bound to localhost" is the useful thing to know.
	Loopback bool `json:"loopback"`
	// Pane is the session-qualified pane that owns this listener, empty when the
	// parent chain reached init without crossing a known pane. Unattributed
	// listeners are still returned: a dev server started in a terminal outside
	// Herdr is a real server, just not one gothalo can label.
	Pane  string `json:"pane,omitempty"`
	Agent string `json:"agent,omitempty"`
	// URL is where the phone should point, filled in by the caller that knows
	// the bridge's own reachable host. Empty for a loopback bind: there is no
	// URL that works until something relays it.
	URL string `json:"url,omitempty"`
}

// scan is the raw host state before attribution: what is listening and what is
// parented to what.
type scan struct {
	listeners []Listener
	parent    map[int]int // pid -> ppid
}

// Collect discovers the host's HTTP listeners. Panes maps a pane's shell pid to
// its session-qualified pane id; pass nil to skip attribution entirely.
//
// A host with no lsof, or no listeners at all, returns an empty slice and no
// error — "nothing is serving" is a normal state, the same way an empty diff is.
func Collect(ctx context.Context, panes map[int]PaneRef) ([]Listener, error) {
	s, err := hostScan(ctx)
	if err != nil {
		return nil, err
	}
	found := probeHTTP(ctx, s.listeners)
	Attribute(found, panes, s.parent)
	sort.Slice(found, func(i, j int) bool { return found[i].Port < found[j].Port })
	return found, nil
}

// PaneRef is what attribution stamps onto a listener once its parent chain
// reaches a pane.
type PaneRef struct {
	Pane  string
	Agent string
}

// hostScan runs lsof and ps. Both are cheap enough to run on every uncached
// call; the caching that keeps a polling list page honest lives in Cache.
func hostScan(ctx context.Context) (scan, error) {
	// -n/-P skip DNS and service-name lookups, which otherwise dominate the
	// runtime. -F is the stable machine format; the column layout is not.
	raw, err := output(ctx, "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP")
	if err != nil {
		return scan{}, err
	}
	ps, err := output(ctx, "ps", "-axo", "pid=,ppid=")
	if err != nil {
		return scan{}, err
	}
	return scan{listeners: parseLSOF(raw), parent: parsePS(ps)}, nil
}

// output runs a command and returns stdout. A non-zero exit with output still
// counts: lsof exits 1 when some descriptors were unreadable, which is routine
// on a multi-user machine and not a reason to fail the whole scan.
func output(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.Output()
	if err != nil && len(out) == 0 {
		return nil, err
	}
	return out, nil
}

// parseLSOF reads `lsof -F` output. Fields arrive as one letter + value per
// line, grouped: a `p` line opens a process (with `c` naming it) and every
// following `n` line is one of its sockets, until the next `p`.
func parseLSOF(raw []byte) []Listener {
	var (
		out  []Listener
		pid  int
		proc string
		seen = map[string]bool{} // pid:bind:port — IPv4 and IPv6 rows collapse
	)
	sc := bufio.NewScanner(bytes.NewReader(raw))
	for sc.Scan() {
		line := sc.Text()
		if len(line) < 2 {
			continue
		}
		tag, val := line[0], line[1:]
		switch tag {
		case 'p':
			pid, _ = strconv.Atoi(val)
			proc = ""
		case 'c':
			proc = val
		case 'n':
			bind, port, ok := splitListen(val)
			if !ok || pid == 0 {
				continue
			}
			key := strconv.Itoa(pid) + ":" + bind + ":" + strconv.Itoa(port)
			if seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, Listener{
				Port: port, Bind: bind, PID: pid, Proc: proc,
				Loopback: isLoopback(bind),
			})
		}
	}
	return out
}

// splitListen parses an lsof socket name: "*:5173", "127.0.0.1:5173",
// "[::1]:5173". Anything with an arrow is an established connection, not a
// listener, and is skipped.
func splitListen(name string) (bind string, port int, ok bool) {
	if strings.Contains(name, "->") {
		return "", 0, false
	}
	i := strings.LastIndex(name, ":")
	if i < 0 {
		return "", 0, false
	}
	host, portStr := name[:i], name[i+1:]
	p, err := strconv.Atoi(portStr)
	if err != nil || p <= 0 || p > 65535 {
		return "", 0, false
	}
	host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	if host == "" {
		host = "*"
	}
	return host, p, true
}

// isLoopback reports a bind only the host can reach. "*" is every interface,
// which includes the tailnet one, so it is explicitly not loopback.
func isLoopback(bind string) bool {
	if bind == "*" {
		return false
	}
	ip := net.ParseIP(bind)
	return ip != nil && ip.IsLoopback()
}

// parsePS builds the pid -> ppid map from `ps -axo pid=,ppid=`.
func parsePS(raw []byte) map[int]int {
	parent := map[int]int{}
	sc := bufio.NewScanner(bytes.NewReader(raw))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) != 2 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		parent[pid] = ppid
	}
	return parent
}

// Attribute stamps each listener with the pane that owns it, by walking the
// listener's parent chain until it hits a pid Herdr named as a pane's shell.
// It mutates in place; listeners whose chain reaches init unmatched are left
// unattributed rather than dropped.
func Attribute(ls []Listener, panes map[int]PaneRef, parent map[int]int) {
	if len(panes) == 0 {
		return
	}
	for i := range ls {
		// Bounded rather than while-true: a corrupt ps table could otherwise
		// describe a cycle, and this runs on every list-page poll.
		for pid, hops := ls[i].PID, 0; pid > 1 && hops < 64; hops++ {
			if ref, ok := panes[pid]; ok {
				ls[i].Pane, ls[i].Agent = ref.Pane, ref.Agent
				break
			}
			next, ok := parent[pid]
			if !ok || next == pid {
				break
			}
			pid = next
		}
	}
}

// probeTimeout bounds one connect+read. Dev servers are local, so anything
// slower than this is not something worth showing a chip for.
const probeTimeout = 400 * time.Millisecond

// probeHTTP keeps only the listeners that answer with an HTTP status line. This
// is what separates a dev server from Postgres, and it is why the chip list
// stays short enough to be useful. Probes run concurrently — a dozen listeners
// resolve in about one timeout, not a dozen.
func probeHTTP(ctx context.Context, ls []Listener) []Listener {
	results := make([]bool, len(ls))
	var wg sync.WaitGroup
	for i := range ls {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = speaksHTTP(ctx, ls[i])
		}(i)
	}
	wg.Wait()

	out := make([]Listener, 0, len(ls))
	for i, ok := range results {
		if ok {
			out = append(out, ls[i])
		}
	}
	return out
}

// speaksHTTP sends a minimal request and reports whether the reply starts with
// an HTTP status line. Any status counts — a dev server answering 404 on / is
// still a dev server.
func speaksHTTP(ctx context.Context, l Listener) bool {
	// The probe always dials from the host, so a loopback-bound server is
	// reachable here even though the phone cannot reach it. "*" has no literal
	// address to dial; loopback stands in for it.
	host := l.Bind
	if host == "*" {
		host = "127.0.0.1"
	}
	d := net.Dialer{Timeout: probeTimeout}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(l.Port)))
	if err != nil {
		return false
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(probeTimeout))
	if _, err := conn.Write([]byte("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")); err != nil {
		return false
	}
	buf := make([]byte, 5)
	if _, err := conn.Read(buf); err != nil {
		return false
	}
	return string(buf) == "HTTP/"
}
