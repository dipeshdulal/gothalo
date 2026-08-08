package server

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/ports"
)

// reachableHost is where the dev-server preview bug actually lived, so this is
// where it is pinned. Found on a real phone: every preview URL came back as
// http://127.0.0.1:<port> because the host was taken from the bridge's own BIND
// address — 127.0.0.1:8787 behind `tailscale serve` — which says where this
// process listens and never what someone else should dial.
func TestReachableHost(t *testing.T) {
	cases := []struct {
		name      string
		reqHost   string
		publicURL string
		bindAddr  string
		want      string
	}{
		{
			// The deployment that broke. The bridge binds loopback; the phone
			// reached the tailnet front-end, and that is the answer.
			name:      "tailscale serve, host header preserved",
			reqHost:   "my-mac.tailnet.ts.net:5338",
			publicURL: "https://my-mac.tailnet.ts.net:5338",
			bindAddr:  "127.0.0.1:8787",
			want:      "my-mac.tailnet.ts.net",
		},
		{
			// Same deployment, but the proxy rewrote Host to its upstream. The
			// configured public URL is exactly the right fallback.
			name:      "proxy rewrote Host to the upstream",
			reqHost:   "127.0.0.1:8787",
			publicURL: "https://my-mac.tailnet.ts.net:5338",
			bindAddr:  "127.0.0.1:8787",
			want:      "my-mac.tailnet.ts.net",
		},
		{
			// The README's direct-bind setup: no proxy, no public_url, the
			// bridge really is reachable where it binds.
			name:     "bound straight to the tailnet address",
			reqHost:  "",
			bindAddr: "100.88.0.122:8787",
			want:     "100.88.0.122",
		},
		{
			// A caller on the LAN gets the LAN answer, which no single
			// configured value could have given them.
			name:      "per-caller, not per-config",
			reqHost:   "192.168.1.7:8787",
			publicURL: "https://my-mac.tailnet.ts.net:5338",
			bindAddr:  "0.0.0.0:8787",
			want:      "192.168.1.7",
		},
		{
			// Everything loopback or unset: no host to name. The caller gets no
			// URL rather than one that points at their own machine.
			name:     "nothing reachable to offer",
			reqHost:  "localhost:8787",
			bindAddr: "127.0.0.1:8787",
			want:     "",
		},
		{
			// A public_url someone left as localhost must not be trusted just
			// because it is configured.
			name:      "a loopback public_url falls through",
			reqHost:   "127.0.0.1:8787",
			publicURL: "http://localhost:8787",
			bindAddr:  "0.0.0.0:8787",
			want:      "",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newTestServer(t)
			s.cfg.Transport = config.Transport{Addr: c.bindAddr, PublicURL: c.publicURL}
			req := httptest.NewRequest(http.MethodGet, "/ports", nil)
			req.Host = c.reqHost
			if got := s.reachableHost(req); got != c.want {
				t.Errorf("reachableHost = %q, want %q", got, c.want)
			}
		})
	}
}

// TestReachableHostIsNeverLoopback is the invariant at the layer that chooses
// the host, mirroring the one ports.FillURLs holds at the layer that builds the
// URL. Two guards rather than one because either alone could be bypassed by a
// future caller.
func TestReachableHostIsNeverLoopback(t *testing.T) {
	loopbacks := []string{"127.0.0.1:8787", "localhost:8787", "[::1]:8787", "0.0.0.0:8787", ""}
	for _, reqHost := range loopbacks {
		for _, pub := range []string{"", "http://127.0.0.1:9", "https://localhost", "http://[::1]:1"} {
			for _, bind := range loopbacks {
				s := newTestServer(t)
				s.cfg.Transport = config.Transport{Addr: bind, PublicURL: pub}
				req := httptest.NewRequest(http.MethodGet, "/ports", nil)
				req.Host = reqHost
				if got := s.reachableHost(req); got != "" && ports.IsLoopbackHost(got) {
					t.Errorf("host=%q public=%q bind=%q -> %q, a loopback address",
						reqHost, pub, bind, got)
				}
			}
		}
	}
}

func TestHostOnly(t *testing.T) {
	cases := map[string]string{
		"example.ts.net:5338":         "example.ts.net",
		"https://example.ts.net:5338": "example.ts.net",
		"https://example.ts.net/":     "example.ts.net",
		"example.ts.net":              "example.ts.net",
		"100.88.0.122:8787":           "100.88.0.122",
		"[::1]:8787":                  "::1",
		"[::1]":                       "::1",
		"":                            "",
		"  ":                          "",
	}
	for in, want := range cases {
		if got := hostOnly(in); got != want {
			t.Errorf("hostOnly(%q) = %q, want %q", in, got, want)
		}
	}
}
