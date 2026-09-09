package server

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/config"
)

const pagesOrigin = config.DefaultAllowedOrigin

func corsServer(origins ...string) *Server {
	return &Server{cfg: &config.Config{
		Transport: config.Transport{AllowedOrigins: origins},
	}}
}

// reached records whether the preflight was terminated by the middleware or
// leaked through to the routes behind it.
func corsHandler(t *testing.T, srv *Server, reached *bool) http.Handler {
	t.Helper()
	return srv.withCORS(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		*reached = true
		w.WriteHeader(http.StatusUnauthorized)
	}))
}

func preflight(origin string) *http.Request {
	req := httptest.NewRequest(http.MethodOptions, "/snapshot", nil)
	req.Header.Set("Origin", origin)
	req.Header.Set("Access-Control-Request-Method", "GET")
	req.Header.Set("Access-Control-Request-Headers", "authorization")
	return req
}

// The bug this pins: every endpoint authenticates, a preflight carries no
// credentials, so an unterminated OPTIONS reaches the handler and 401s. The
// browser then blocks the real request and the app calls the server unreachable.
func TestPreflightAnsweredWithoutReachingHandler(t *testing.T) {
	var reached bool
	rec := httptest.NewRecorder()
	corsHandler(t, corsServer(pagesOrigin), &reached).ServeHTTP(rec, preflight(pagesOrigin))

	if reached {
		t.Fatal("preflight reached the authenticated handler; it must be answered by the middleware")
	}
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != pagesOrigin {
		t.Fatalf("allow-origin = %q, want %q", got, pagesOrigin)
	}
	// Without this the browser discards the response: the app's bearer is a
	// custom header and must be named explicitly.
	if got := rec.Header().Get("Access-Control-Allow-Headers"); got != "Authorization, Content-Type" {
		t.Fatalf("allow-headers = %q, want Authorization to be permitted", got)
	}
}

func TestActualRequestCarriesAllowOrigin(t *testing.T) {
	var reached bool
	req := httptest.NewRequest(http.MethodGet, "/snapshot", nil)
	req.Header.Set("Origin", pagesOrigin)
	rec := httptest.NewRecorder()
	corsHandler(t, corsServer(pagesOrigin), &reached).ServeHTTP(rec, req)

	if !reached {
		t.Fatal("a non-preflight request must still be routed")
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != pagesOrigin {
		t.Fatalf("allow-origin = %q, want %q", got, pagesOrigin)
	}
}

// An origin the operator never named gets no allow header, so the browser
// blocks it — this API can start processes, so the list is the whole point.
func TestUnlistedOriginRefused(t *testing.T) {
	var reached bool
	rec := httptest.NewRecorder()
	corsHandler(t, corsServer(pagesOrigin), &reached).ServeHTTP(rec, preflight("https://evil.example"))

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("allow-origin = %q, want none for an unlisted origin", got)
	}
}

// Same-origin traffic carries no Origin header and must be untouched, however
// the allowlist is configured.
func TestSameOriginRequestUntouched(t *testing.T) {
	var reached bool
	req := httptest.NewRequest(http.MethodGet, "/snapshot", nil)
	rec := httptest.NewRecorder()
	corsHandler(t, corsServer(), &reached).ServeHTTP(rec, req)

	if !reached {
		t.Fatal("same-origin traffic must route normally")
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("allow-origin = %q, want none", got)
	}
}

// The published UI works against a stock install: no allowed_origins, no env
// var, nothing pasted into a config file.
func TestPublishedUIAllowedWithoutConfiguration(t *testing.T) {
	var reached bool
	rec := httptest.NewRecorder()
	corsHandler(t, corsServer(), &reached).ServeHTTP(rec, preflight(pagesOrigin))

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204 for the default origin with no config", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != pagesOrigin {
		t.Fatalf("allow-origin = %q, want %q", got, pagesOrigin)
	}
}

// Configuring an extra origin extends the set. The footgun this prevents:
// adding a dev server silently cutting off the hosted app.
func TestConfiguredOriginsExtendRatherThanReplaceDefault(t *testing.T) {
	var reached bool
	srv := corsServer("http://localhost:5173")

	rec := httptest.NewRecorder()
	corsHandler(t, srv, &reached).ServeHTTP(rec, preflight("http://localhost:5173"))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("configured origin status = %d, want 204", rec.Code)
	}

	rec = httptest.NewRecorder()
	corsHandler(t, srv, &reached).ServeHTTP(rec, preflight(pagesOrigin))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("default origin status = %d, want 204 — it must survive configuration", rec.Code)
	}
}

// The list is a list: several origins coexist, and each is matched
// independently of the others and of the built-in default.
func TestMultipleConfiguredOrigins(t *testing.T) {
	srv := corsServer(
		"http://localhost:5173",
		"https://staging.example.com",
		"https://fork.github.io",
	)
	for _, origin := range []string{
		"http://localhost:5173",
		"https://staging.example.com",
		"https://fork.github.io",
		pagesOrigin,
	} {
		if !srv.originAllowed(origin) {
			t.Errorf("originAllowed(%q) = false, want true", origin)
		}
	}
	if srv.originAllowed("https://other.example.com") {
		t.Error("an origin outside the list must stay refused")
	}
}

// A bare OPTIONS is not a preflight and must not be swallowed.
func TestPlainOptionsIsRouted(t *testing.T) {
	var reached bool
	req := httptest.NewRequest(http.MethodOptions, "/snapshot", nil)
	req.Header.Set("Origin", pagesOrigin)
	rec := httptest.NewRecorder()
	corsHandler(t, corsServer(pagesOrigin), &reached).ServeHTTP(rec, req)

	if !reached {
		t.Fatal("OPTIONS without Access-Control-Request-Method must reach the mux")
	}
}

// A config file may carry a pasted trailing slash or odd case; a real Origin
// header never does. Matching must not hinge on that.
func TestOriginMatchIgnoresTrailingSlashAndCase(t *testing.T) {
	srv := corsServer("http://LocalHost:5173/")
	if !srv.originAllowed("http://localhost:5173") {
		t.Fatal("origin should match despite trailing slash and case")
	}
	if srv.originAllowed(pagesOrigin + ".evil.example") {
		t.Fatal("a suffix-extended origin must not match")
	}
}
