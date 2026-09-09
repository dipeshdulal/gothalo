package server

import (
	"net/http"
	"strings"

	"github.com/dipeshdulal/gothalo/internal/config"
)

// corsMaxAge caps how long a browser may cache a preflight. Ten minutes keeps
// the OPTIONS round-trip off the hot path without pinning a stale policy for
// long after the operator edits AllowedOrigins.
const corsMaxAge = "600"

// withCORS answers cross-origin preflights and tags allowed responses.
//
// Two things make this necessary rather than decorative. Every real endpoint
// authenticates with a bearer token, and a custom Authorization header forces
// the browser to preflight; a preflight deliberately carries no credentials, so
// the handler's own auth check answers 401 and the browser reports a failed
// request instead of the response the app was asking for. So OPTIONS has to be
// terminated HERE, ahead of the mux, and never reach a handler.
//
// The allowlist is exact-match on purpose. This API can start processes and
// read repositories, so "which sites may script it" is a decision worth making
// explicitly — no wildcard. The project's own published UI is permitted by
// default (config.DefaultAllowedOrigin) and transport.allowed_origins extends
// that set rather than replacing it.
//
// Access-Control-Allow-Credentials is deliberately never sent: auth here is an
// explicit Authorization header, not an ambient cookie, so there is nothing for
// the browser to attach on its own and granting credentialed access would widen
// the blast radius of an allowed origin for no benefit.
func (s *Server) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Any response may differ by Origin, so it is not safe for a shared
		// cache to reuse one origin's response for another — announce that even
		// when the origin is rejected and no other CORS header is set.
		w.Header().Add("Vary", "Origin")

		origin := r.Header.Get("Origin")
		allowed := origin != "" && s.originAllowed(origin)
		if allowed {
			w.Header().Set("Access-Control-Allow-Origin", origin)
		}

		// A preflight is OPTIONS *plus* Access-Control-Request-Method. A bare
		// OPTIONS is an ordinary request and still belongs to the mux.
		if r.Method == http.MethodOptions && r.Header.Get("Access-Control-Request-Method") != "" {
			if !allowed {
				// 403 rather than a silent 204: without the allow headers the
				// browser blocks the call regardless, and the status is the only
				// part an operator can see in a proxy log while working out why.
				w.WriteHeader(http.StatusForbidden)
				return
			}
			h := w.Header()
			// Only what handlers actually serve. Advertising a method no route
			// implements (DELETE was here once) buys nothing and misleads
			// anyone reading a preflight to learn the surface.
			h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			h.Set("Access-Control-Max-Age", corsMaxAge)
			h.Add("Vary", "Access-Control-Request-Headers")
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// originAllowed reports whether origin is configured, comparing scheme and host
// case-insensitively (a browser lowercases both, but a hand-edited config file
// is not obliged to) and ignoring a trailing slash, which is easy to paste in
// from a browser bar and never appears in a real Origin header.
//
// Normalizing the CONFIGURED value on every comparison, not just the incoming
// one, is what lets the two config paths stay honest about whitespace: the env
// var is split and trimmed up front, while a JSON array is taken as written.
// Both end up compared the same way, and a blank entry can never match because
// callers only reach here with a non-empty Origin.
func (s *Server) originAllowed(origin string) bool {
	got := normalizeOrigin(origin)
	if got == normalizeOrigin(config.DefaultAllowedOrigin) {
		return true
	}
	for _, want := range s.cfg.Transport.AllowedOrigins {
		if got == normalizeOrigin(want) {
			return true
		}
	}
	return false
}

func normalizeOrigin(v string) string {
	return strings.ToLower(strings.TrimRight(strings.TrimSpace(v), "/"))
}
