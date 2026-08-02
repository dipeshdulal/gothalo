// Package transport decouples "how a phone reaches the bridge" from the HTTP
// handlers. The same http.Handler runs under any transport:
//
//   - direct: the bridge listens; the phone connects directly (tailnet/LAN).
//   - relay (later): the bridge dials OUT to a hosted broker and the phone
//     reaches it through the relay — works behind NAT with no inbound ports
//     and no Tailscale.
package transport

import "net/http"

// Transport runs the bridge's HTTP handler over some carrier. Serve blocks.
type Transport interface {
	// Name is the mode identifier ("direct", "relay").
	Name() string
	// Serve delivers requests to handler until it errors. Blocks.
	Serve(handler http.Handler) error
}
