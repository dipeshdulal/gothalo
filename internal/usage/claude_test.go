package usage

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFetchClaudeReadsCredentialAndMapsWindows(t *testing.T) {
	home := t.TempDir()
	claudeDir := filepath.Join(home, ".claude")
	if err := os.MkdirAll(claudeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	credentials := `{"claudeAiOauth":{"accessToken":"secret","subscriptionType":"max"}}`
	if err := os.WriteFile(filepath.Join(claudeDir, ".credentials.json"), []byte(credentials), 0o600); err != nil {
		t.Fatal(err)
	}

	var gotAuth string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		if r.Header.Get("anthropic-beta") != "oauth-2025-04-20" {
			t.Errorf("anthropic-beta = %q", r.Header.Get("anthropic-beta"))
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"five_hour": map[string]any{"utilization": 23.5, "resets_at": "2030-01-02T03:04:05Z"},
			"seven_day": map[string]any{"utilization": 4},
		})
	}))
	defer ts.Close()

	client := &Client{home: home, endpoint: ts.URL, httpClient: ts.Client()}
	got := client.FetchClaude(context.Background())
	if !got.Available || got.Subscription != "max" {
		t.Fatalf("usage = %+v, want available max", got)
	}
	if got.FiveHour == nil || got.FiveHour.Utilization != 23.5 {
		t.Fatalf("five_hour = %+v", got.FiveHour)
	}
	if got.SevenDay == nil || got.SevenDay.Utilization != 4 {
		t.Fatalf("seven_day = %+v", got.SevenDay)
	}
	if gotAuth != "Bearer secret" {
		t.Fatalf("authorization = %q", gotAuth)
	}
}

func TestFetchClaudeWithoutCredentialsIsUnavailable(t *testing.T) {
	got := (&Client{home: t.TempDir(), endpoint: "http://127.0.0.1:1"}).FetchClaude(context.Background())
	if got.Available {
		t.Fatalf("usage = %+v, want unavailable", got)
	}
	if got.Reason == "" {
		t.Fatal("unavailable usage has no reason")
	}
}

// writeCredentials drops a usable Claude credential into home so a client can
// pass accessToken().
func writeCredentials(t *testing.T, home string) {
	t.Helper()
	claudeDir := filepath.Join(home, ".claude")
	if err := os.MkdirAll(claudeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	credentials := `{"claudeAiOauth":{"accessToken":"secret"}}`
	if err := os.WriteFile(filepath.Join(claudeDir, ".credentials.json"), []byte(credentials), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestFetchClaudeServesCacheWithinTTL(t *testing.T) {
	home := t.TempDir()
	writeCredentials(t, home)

	var hits int
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		_ = json.NewEncoder(w).Encode(map[string]any{
			"five_hour": map[string]any{"utilization": 50},
		})
	}))
	defer ts.Close()

	client := &Client{home: home, endpoint: ts.URL, httpClient: ts.Client()}
	first := client.FetchClaude(context.Background())
	second := client.FetchClaude(context.Background())
	if !first.Available || !second.Available {
		t.Fatalf("usage = %+v / %+v, want both available", first, second)
	}
	if first.FiveHour == nil || first.FiveHour.Utilization != second.FiveHour.Utilization {
		t.Fatalf("cached utilization drifted: %+v vs %+v", first.FiveHour, second.FiveHour)
	}
	if hits != 1 {
		t.Fatalf("Anthropic hits = %d, want 1 (second call served from cache)", hits)
	}
}

func TestFetchClaudeHonorsRetryAfterAndServesStale(t *testing.T) {
	home := t.TempDir()
	writeCredentials(t, home)

	var hits int
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if hits == 1 {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"five_hour": map[string]any{"utilization": 50},
			})
			return
		}
		w.Header().Set("Retry-After", "120")
		http.Error(w, `{"error":{"type":"rate_limit_error"}}`, http.StatusTooManyRequests)
	}))
	defer ts.Close()

	// A near-zero TTL forces the second call past the fresh-cache path and into
	// the network, which is what this test is about.
	client := &Client{home: home, endpoint: ts.URL, httpClient: ts.Client(), cacheTTL: time.Nanosecond}
	first := client.FetchClaude(context.Background())
	if !first.Available {
		t.Fatalf("first usage = %+v, want available", first)
	}

	// Second call gets a 429; the last good answer must be served, not lost.
	got := client.FetchClaude(context.Background())
	if !got.Available || got.FiveHour == nil || got.FiveHour.Utilization != 50 {
		t.Fatalf("stale usage = %+v, want cached data during rate limit", got)
	}
	if hits != 2 {
		t.Fatalf("hits = %d, want 2 (one success, one 429)", hits)
	}
	if remaining := time.Until(client.cooldown); remaining < 110*time.Second || remaining > 130*time.Second {
		t.Fatalf("cooldown = %v from now, want ~120s", remaining)
	}

	// Still inside the cooldown: the next call must not touch the network.
	again := client.FetchClaude(context.Background())
	if !again.Available || hits != 2 {
		t.Fatalf("cooldown not honored: usage = %+v, hits = %d", again, hits)
	}
}

func TestFetchClaudeRetriesAfterCooldownExpires(t *testing.T) {
	home := t.TempDir()
	writeCredentials(t, home)

	var hits int
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		_ = json.NewEncoder(w).Encode(map[string]any{
			"seven_day": map[string]any{"utilization": 10},
		})
	}))
	defer ts.Close()

	client := &Client{home: home, endpoint: ts.URL, httpClient: ts.Client(), cacheTTL: time.Nanosecond}
	if first := client.FetchClaude(context.Background()); !first.Available {
		t.Fatalf("first usage = %+v", first)
	}

	// Force the cooldown to have already passed, then the next call refetches.
	client.mu.Lock()
	client.cooldown = time.Now().Add(-time.Second)
	client.mu.Unlock()

	second := client.FetchClaude(context.Background())
	if hits != 2 {
		t.Fatalf("hits = %d, want 2 (cooldown expired → refetch)", hits)
	}
	if !second.Available {
		t.Fatalf("usage = %+v, want available", second)
	}
}

func TestFetchClaudeColdStartInCooldownDoesNotHitNetwork(t *testing.T) {
	home := t.TempDir()
	writeCredentials(t, home)

	var hits int
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Retry-After", "120")
		http.Error(w, `{"error":{"type":"rate_limit_error"}}`, http.StatusTooManyRequests)
	}))
	defer ts.Close()

	client := &Client{home: home, endpoint: ts.URL, httpClient: ts.Client()}
	first := client.FetchClaude(context.Background()) // 429, no cache → reason + cooldown
	if first.Available || first.Reason == "" {
		t.Fatalf("usage = %+v, want unavailable with reason", first)
	}
	second := client.FetchClaude(context.Background()) // cooldown → no network
	if second.Available || second.Reason == "" {
		t.Fatalf("usage = %+v, want unavailable during cooldown", second)
	}
	if hits != 1 {
		t.Fatalf("hits = %d, want 1 (cooldown suppressed the second call)", hits)
	}
}

func TestParseRetryAfter(t *testing.T) {
	now := time.Date(2026, 8, 12, 6, 0, 0, 0, time.UTC)
	in90s := now.Add(90 * time.Second).Format(http.TimeFormat)
	cases := []struct {
		header string
		want   time.Duration
	}{
		{"", defaultRetryAfter},
		{"223", 223 * time.Second},
		{" 45 ", 45 * time.Second},
		{"bogus", defaultRetryAfter},
		{in90s, 90 * time.Second},
		{"86400", maxRetryAfter}, // capped
	}
	for _, tc := range cases {
		if got := parseRetryAfter(tc.header, now); got != tc.want {
			t.Errorf("parseRetryAfter(%q) = %v, want %v", tc.header, got, tc.want)
		}
	}
}
