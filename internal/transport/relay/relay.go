// Package relay is the (not-yet-implemented) NAT-traversing transport.
//
// Design (for when it lands): the bridge dials OUT to a hosted broker over a
// persistent WebSocket — so it needs no inbound ports and no Tailscale. The
// relay authenticates the bridge (by bridge id + secret) and the phone (by its
// per-device bearer), then forwards request frames to the bridge, which runs
// them through the very same http.Handler used by the direct transport and
// sends responses back over the socket. Streaming (WS /attach) rides multiplexed
// sub-streams over the same connection.
//
// This file is a stub so the transport seam is real now; the broker itself
// (cmd/gothalo-relay) and this client are a later milestone.
//
// Security note (end-to-end encryption): in direct mode we rely on the two
// key-exchange layers we already get for free — WireGuard (Curve25519 ECDH) on
// the tailnet and TLS 1.3 (ECDHE) from `tailscale serve` — so no app-level
// crypto is warranted. A hosted relay is the ONLY place it matters: if the relay
// terminates TLS it can read plaintext. When we build it, keep traffic
// end-to-end by either passing TLS through (relay never terminates it) or
// wrapping the tunnel in a vetted protocol (Noise / libsodium box). Do NOT
// hand-roll a Diffie-Hellman exchange.
package relay

import (
	"errors"
	"net/http"
)

// Transport will dial out to a relay broker and serve handlers over it.
type Transport struct {
	relayURL string
	bridgeID string
	secret   string
}

// New returns a relay transport targeting relayURL as bridgeID.
func New(relayURL, bridgeID, secret string) *Transport {
	return &Transport{relayURL: relayURL, bridgeID: bridgeID, secret: secret}
}

// Name implements transport.Transport.
func (t *Transport) Name() string { return "relay" }

// Serve is not implemented yet.
func (t *Transport) Serve(handler http.Handler) error {
	_ = handler
	return errors.New("relay transport not implemented yet (see package doc for the design)")
}
