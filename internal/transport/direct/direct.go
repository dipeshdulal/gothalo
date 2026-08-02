// Package direct is the listen-locally transport: the bridge binds an address
// (loopback behind `tailscale serve`, or a LAN/tailnet IP) and phones connect
// to it directly.
package direct

import (
	"net/http"
	"time"

	"github.com/charmbracelet/log"
)

// Transport serves HTTP on a bind address.
type Transport struct {
	addr string
}

// New returns a direct transport bound to addr (e.g. 127.0.0.1:8787).
func New(addr string) *Transport { return &Transport{addr: addr} }

// Name implements transport.Transport.
func (t *Transport) Name() string { return "direct" }

// Serve runs an http.Server on the bind address until it errors.
func (t *Transport) Serve(handler http.Handler) error {
	srv := &http.Server{
		Addr:              t.addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Info("direct transport listening", "addr", t.addr)
	return srv.ListenAndServe()
}
