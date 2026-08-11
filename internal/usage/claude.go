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
	"strings"
	"time"
)

const claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"

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
		return ClaudeUsage{Reason: "Claude usage is unreachable"}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return ClaudeUsage{Reason: "could not read Claude usage response"}
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return ClaudeUsage{Reason: "Claude authentication expired"}
	}
	if resp.StatusCode != http.StatusOK {
		return ClaudeUsage{Reason: fmt.Sprintf("Claude usage returned HTTP %d", resp.StatusCode)}
	}

	var raw claudeResponse
	if err := json.Unmarshal(body, &raw); err != nil {
		return ClaudeUsage{Reason: "Claude usage response was not valid JSON"}
	}
	return ClaudeUsage{
		Available:      raw.FiveHour != nil || raw.SevenDay != nil,
		Subscription:   subscription,
		FiveHour:       raw.FiveHour,
		SevenDay:       raw.SevenDay,
		SevenDaySonnet: raw.SevenDaySonnet,
		SevenDayOpus:   raw.SevenDayOpus,
	}
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
