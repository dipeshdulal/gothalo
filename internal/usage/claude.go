// Package usage reads provider quota information on the host running gothalo.
// Credentials never leave this process; the mobile client receives normalized,
// non-secret usage windows only.
package usage

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"

const (
	// defaultCacheTTL keeps a served answer at most a minute old — the app's own
	// poll cadence — while collapsing bursts of concurrent /usage requests into
	// a single Anthropic call.
	defaultCacheTTL = time.Minute

	// defaultRetryAfter applies when a 429 arrives without a usable Retry-After
	// header (or with one this build cannot parse).
	defaultRetryAfter = time.Minute

	// maxRetryAfter caps how long one 429 can silence the card. A pathological
	// header (say, a day) would otherwise hide usage for as long; hitting the
	// endpoint again after the cap is self-correcting, because another 429 just
	// re-arms the cooldown.
	maxRetryAfter = 15 * time.Minute
)

// Window is one provider quota window. Utilization is a percentage in [0, 100].
type Window struct {
	Utilization float64 `json:"utilization"`
	ResetsAt    string  `json:"resets_at,omitempty"`
}

// ClaudeUsage is deliberately small: the app needs the live windows and reset
// times, not the OAuth token or the provider's entire response.
type ClaudeUsage struct {
	Available      bool    `json:"available"`
	Reason         string  `json:"reason,omitempty"`
	Subscription   string  `json:"subscription_type,omitempty"`
	FiveHour       *Window `json:"five_hour,omitempty"`
	SevenDay       *Window `json:"seven_day,omitempty"`
	SevenDaySonnet *Window `json:"seven_day_sonnet,omitempty"`
	SevenDayOpus   *Window `json:"seven_day_opus,omitempty"`
}

// Client fetches Claude Code's OAuth usage endpoint. A client is cheap and has
// no mutable credential state; Claude Code refreshes the credential file itself.
type Client struct {
	httpClient *http.Client
	home       string
	endpoint   string

	// Last-known-good usage plus rate-limit state, guarded by mu.
	//
	// Anthropic rate-limits this endpoint (HTTP 429 + Retry-After). The app
	// polls /usage every minute, and each request shares the same token and
	// User-Agent as Claude Code's own usage checks on this host, so a live call
	// on every poll trips the limiter. Keeping the last good answer in memory
	// means a rate-limit window (or any transient failure) serves
	// stale-but-true data instead of vanishing the card, and honoring
	// Retry-After means the window gets to clear instead of being extended by
	// our own retries.
	mu       sync.Mutex
	cached   *ClaudeUsage
	cachedAt time.Time
	cooldown time.Time

	// cacheTTL overrides defaultCacheTTL; tests shorten it to force refetches.
	cacheTTL time.Duration
}

func (c *Client) ttl() time.Duration {
	if c.cacheTTL != 0 {
		return c.cacheTTL
	}
	return defaultCacheTTL
}

func NewClient() *Client {
	home, _ := os.UserHomeDir()
	return &Client{
		httpClient: &http.Client{Timeout: 10 * time.Second},
		home:       home,
		endpoint:   claudeUsageURL,
	}
}

// FetchClaude returns unavailable rather than an error when Claude is not
// installed or authenticated. That lets the app omit the card cleanly.
func (c *Client) FetchClaude(ctx context.Context) ClaudeUsage {
	now := time.Now()

	c.mu.Lock()
	cached := c.cached
	inCooldown := now.Before(c.cooldown)
	fresh := cached != nil && now.Sub(c.cachedAt) < c.ttl()
	c.mu.Unlock()

	// Serve the last good answer while the endpoint cools down, and skip the
	// network entirely while the cached answer is still fresh.
	if cached != nil && (inCooldown || fresh) {
		return *cached
	}
	// Cold start inside a rate-limit window: nothing to serve, and hitting the
	// endpoint again only extends the 429. Say so plainly instead.
	if inCooldown {
		return ClaudeUsage{Reason: "Claude usage is rate-limited; retrying after the cooldown"}
	}

	token, subscription, err := c.accessToken()
	if err != nil {
		return ClaudeUsage{Reason: err.Error()}
	}

	endpoint := c.endpoint
	if endpoint == "" {
		endpoint = claudeUsageURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return ClaudeUsage{Reason: "could not create Claude usage request"}
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "claude-code/2.1.80")
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")

	httpClient := c.httpClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return c.staleOr(cached, "Claude usage is unreachable")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return c.staleOr(cached, "could not read Claude usage response")
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		// The credential is bad or expired. Last-known-good data is no longer
		// trustworthy — and Claude Code refreshes its own credential, so this
		// clears itself — so let the card disappear rather than show a quota
		// that can never refresh.
		return ClaudeUsage{Reason: "Claude authentication expired"}
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		// Rate-limited: remember the Retry-After cooldown and keep the last good
		// answer visible while it passes.
		c.mu.Lock()
		c.cooldown = time.Now().Add(parseRetryAfter(resp.Header.Get("Retry-After"), time.Now()))
		c.mu.Unlock()
		return c.staleOr(cached, "Claude usage returned HTTP 429")
	}
	if resp.StatusCode != http.StatusOK {
		return c.staleOr(cached, fmt.Sprintf("Claude usage returned HTTP %d", resp.StatusCode))
	}

	var raw claudeResponse
	if err := json.Unmarshal(body, &raw); err != nil {
		return c.staleOr(cached, "Claude usage response was not valid JSON")
	}
	result := ClaudeUsage{
		Available:      raw.FiveHour != nil || raw.SevenDay != nil,
		Subscription:   subscription,
		FiveHour:       raw.FiveHour,
		SevenDay:       raw.SevenDay,
		SevenDaySonnet: raw.SevenDaySonnet,
		SevenDayOpus:   raw.SevenDayOpus,
	}
	c.mu.Lock()
	c.cached = &result
	c.cachedAt = time.Now()
	c.mu.Unlock()
	return result
}

// staleOr serves the last known good answer when one exists — a transient
// failure should not blink the usage card off — or a reason-only answer when
// there is nothing cached yet.
func (c *Client) staleOr(cached *ClaudeUsage, reason string) ClaudeUsage {
	if cached != nil {
		return *cached
	}
	return ClaudeUsage{Reason: reason}
}

// parseRetryAfter reads a Retry-After header: a bare number of seconds
// ("223") or an HTTP-date. Anything unparseable or absent falls back to
// defaultRetryAfter, and the result is capped at maxRetryAfter so one odd
// header cannot silence the card for hours.
func parseRetryAfter(v string, now time.Time) time.Duration {
	after := defaultRetryAfter
	if v != "" {
		if secs, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
			after = time.Duration(secs) * time.Second
		} else if when, err := http.ParseTime(v); err == nil {
			if d := when.Sub(now); d > 0 {
				after = d
			}
		}
	}
	if after > maxRetryAfter {
		return maxRetryAfter
	}
	return after
}

type claudeResponse struct {
	FiveHour       *Window `json:"five_hour"`
	SevenDay       *Window `json:"seven_day"`
	SevenDaySonnet *Window `json:"seven_day_sonnet"`
	SevenDayOpus   *Window `json:"seven_day_opus"`
}

type credentialsFile struct {
	ClaudeAiOauth struct {
		AccessToken      string `json:"accessToken"`
		SubscriptionType string `json:"subscriptionType"`
	} `json:"claudeAiOauth"`
}

func (c *Client) accessToken() (string, string, error) {
	if c.home == "" {
		return "", "", fmt.Errorf("home directory unavailable")
	}
	path := filepath.Join(c.home, ".claude", ".credentials.json")
	if data, err := os.ReadFile(path); err == nil {
		var f credentialsFile
		if json.Unmarshal(data, &f) == nil && f.ClaudeAiOauth.AccessToken != "" {
			return f.ClaudeAiOauth.AccessToken, f.ClaudeAiOauth.SubscriptionType, nil
		}
	}

	// Claude Code and its VS Code integration may keep the same credential in the
	// macOS Keychain instead of ~/.claude/.credentials.json.
	if runtime.GOOS == "darwin" {
		if token, err := keychainToken(); err == nil && token != "" {
			return token, "", nil
		}
	}
	return "", "", fmt.Errorf("Claude is not configured")
}

func keychainToken() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	out, err := exec.Command("security", "find-generic-password", "-s", "Claude Code-credentials", "-a", u.Username, "-w").Output()
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(out))
	// Keychain values are normally the full JSON credentials object.
	var f credentialsFile
	if json.Unmarshal([]byte(value), &f) == nil && f.ClaudeAiOauth.AccessToken != "" {
		return f.ClaudeAiOauth.AccessToken, nil
	}
	return "", fmt.Errorf("keychain credential is not Claude JSON")
}
