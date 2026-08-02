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
