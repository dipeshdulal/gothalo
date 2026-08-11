package usage

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
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
