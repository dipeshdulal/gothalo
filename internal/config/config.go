// Package config loads gothalo's configuration from ~/.gothalo (overridable by a
// config file and environment variables). Kept stdlib-only (JSON) to avoid deps.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Config is the resolved runtime configuration.
type Config struct {
	// DataDir holds per-install state: devices.json, the service-account key,
	// the config file itself. Defaults to ~/.gothalo (or $GOTHALO_DIR).
	DataDir string `json:"data_dir"`

	// AdminToken authenticates the operator: the `pair`/`devices` CLI talking to
	// the local daemon, curl testing, and the web test page. Paired mobile
	// devices use their own per-device bearers instead. Generated on first serve
	// if empty.
	AdminToken string `json:"admin_token"`

	// ServerID is this bridge's stable identity. A phone pairs with several
	// bridges and registers the SAME FCM token with each, so every push has to
	// say which machine it came from — otherwise an alert is unattributable and
	// its deep-link can't know which server to open. Generated on first serve.
	ServerID string `json:"server_id"`

	// ServerName is the human label for this machine ("Mac Studio"), shown as the
	// notification title and in the app's server list. Defaults to the hostname.
	ServerName string `json:"server_name"`

	Transport Transport `json:"transport"`
	Push      Push      `json:"push"`
}

// Transport selects how phones reach the bridge. "direct" listens locally
// (tailnet/LAN/localhost); "relay" (later) dials out to a hosted broker.
type Transport struct {
	Mode string `json:"mode"` // "direct" | "relay"
	Addr string `json:"addr"` // direct bind address, e.g. 127.0.0.1:8787
	// PublicURL is the externally reachable base URL a phone uses (e.g. the
	// tailnet HTTPS URL from `tailscale serve`). It is embedded in the pairing
	// QR. Empty means pairing can't hand out a reachable URL.
	PublicURL string `json:"public_url"`
}

// Push holds Firebase Cloud Messaging settings.
type Push struct {
	// ServiceAccountPath is tried first when resolving credentials. It is only
	// the FIRST candidate, not the only one: if the file is absent the push
	// package falls through to Google's Application Default Credentials search
	// order, which is what lets a teammate authenticate with
	// `gothalo push login` instead of being handed a copy of someone's key.
	ServiceAccountPath string `json:"service_account_path"`

	// ProjectID is the Firebase project to send to. A service-account file names
	// its own project, so this is optional there. User credentials identify a
	// PERSON and name no project, so on that path this is required — it is what
	// `gothalo push login` writes into the config.
	ProjectID string `json:"project_id"`
}

// DevicesPath is where the paired-device registry lives.
func (c *Config) DevicesPath() string { return filepath.Join(c.DataDir, "devices.json") }

// TimelinePath is where the recorded agent-activity ring is persisted. It lives
// in DataDir with the rest of the per-install state so a restart — the moment
// the recent past matters most — does not start from an empty history.
func (c *Config) TimelinePath() string { return filepath.Join(c.DataDir, "timeline.json") }

// Load resolves configuration. If path is empty it looks for
// <DataDir>/config.json. Missing config file is fine (defaults apply).
// Environment variables override file values.
func Load(path string) (*Config, error) {
	dir := os.Getenv("GOTHALO_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, fmt.Errorf("resolve home dir: %w", err)
		}
		dir = filepath.Join(home, ".gothalo")
	}

	cfg := &Config{
		DataDir:   dir,
		Transport: Transport{Mode: "direct", Addr: "127.0.0.1:8787"},
		Push:      Push{ServiceAccountPath: filepath.Join(dir, "serviceAccount.json")},
	}

	if path == "" {
		path = filepath.Join(dir, "config.json")
	}
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, cfg); err != nil {
			return nil, fmt.Errorf("parse config %s: %w", path, err)
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	// DataDir may have been set by the file; keep the env default authoritative
	// only when the file left it empty.
	if cfg.DataDir == "" {
		cfg.DataDir = dir
	}

	// Environment overrides.
	if v := os.Getenv("GOTHALO_ADDR"); v != "" {
		cfg.Transport.Addr = v
	}
	if v := os.Getenv("GOTHALO_MODE"); v != "" {
		cfg.Transport.Mode = v
	}
	if v := os.Getenv("GOTHALO_SERVICE_ACCOUNT"); v != "" {
		cfg.Push.ServiceAccountPath = v
	}
	if v := os.Getenv("GOTHALO_FCM_PROJECT"); v != "" {
		cfg.Push.ProjectID = v
	}
	if v := os.Getenv("GOTHALO_ADMIN_TOKEN"); v != "" {
		cfg.AdminToken = v
	}
	if v := os.Getenv("GOTHALO_PUBLIC_URL"); v != "" {
		cfg.Transport.PublicURL = v
	}
	if v := os.Getenv("GOTHALO_SERVER_NAME"); v != "" {
		cfg.ServerName = v
	}
	if cfg.ServerName == "" {
		if h, err := os.Hostname(); err == nil {
			cfg.ServerName = h
		} else {
			cfg.ServerName = "gothalo"
		}
	}

	return cfg, nil
}

// EnsureDataDir creates the data directory (0700) if it does not exist.
func (c *Config) EnsureDataDir() error {
	return os.MkdirAll(c.DataDir, 0o700)
}

// ConfigPath is where the JSON config lives inside DataDir.
func (c *Config) ConfigPath() string { return filepath.Join(c.DataDir, "config.json") }

// EnsureAdminToken generates and persists an admin token if none is set, so the
// serve daemon and the pair/devices CLI share one. Returns whether it saved.
func (c *Config) EnsureAdminToken() (bool, error) {
	if c.AdminToken != "" {
		return false, nil
	}
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return false, err
	}
	c.AdminToken = hex.EncodeToString(b)
	if err := c.Save(); err != nil {
		return false, err
	}
	return true, nil
}

// EnsureServerID generates and persists a stable server id if none is set, so
// this bridge identifies itself the same way across restarts (a phone keys its
// paired servers, alerts and notification deep-links by it). Returns whether it
// saved.
func (c *Config) EnsureServerID() (bool, error) {
	if c.ServerID != "" {
		return false, nil
	}
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return false, err
	}
	c.ServerID = hex.EncodeToString(b)
	if err := c.Save(); err != nil {
		return false, err
	}
	return true, nil
}

// Save writes the config to <DataDir>/config.json (0600).
func (c *Config) Save() error {
	if err := c.EnsureDataDir(); err != nil {
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.ConfigPath(), b, 0o600)
}
