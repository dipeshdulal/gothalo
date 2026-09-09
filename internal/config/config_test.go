package config

import (
	"os"
	"path/filepath"
	"testing"
)

func loadWith(t *testing.T, contents string) *Config {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("GOTHALO_DIR", dir)
	path := filepath.Join(dir, "config.json")
	if contents != "" {
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatalf("write config: %v", err)
		}
	}
	cfg, err := Load("")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	return cfg
}

func TestAllowedOriginsFromFile(t *testing.T) {
	cfg := loadWith(t, `{"transport":{"allowed_origins":[
		"http://localhost:5173","https://staging.example.com"]}}`)

	got := cfg.Transport.AllowedOrigins
	if len(got) != 2 || got[0] != "http://localhost:5173" ||
		got[1] != "https://staging.example.com" {
		t.Fatalf("allowed_origins = %v, want both entries in order", got)
	}
}

// The env override is comma-separated, so a multi-origin setup does not need a
// config file at all.
func TestAllowedOriginsFromEnvSplitsOnComma(t *testing.T) {
	t.Setenv("GOTHALO_ALLOWED_ORIGINS",
		"http://localhost:5173, https://staging.example.com ,,")
	cfg := loadWith(t, "")

	got := cfg.Transport.AllowedOrigins
	if len(got) != 2 {
		t.Fatalf("allowed_origins = %v, want 2 entries (blanks dropped)", got)
	}
	// A blank would normalize to "" and match a request with no Origin header.
	for _, o := range got {
		if o == "" {
			t.Fatal("blank origin must never survive parsing")
		}
	}
	if got[1] != "https://staging.example.com" {
		t.Fatalf("got[1] = %q, want surrounding spaces trimmed", got[1])
	}
}

func TestAllowedOriginsDefaultsEmpty(t *testing.T) {
	// The published origin is allowed by the server as a constant, not by being
	// seeded here — so a stock config stays empty and readable.
	if got := loadWith(t, "").Transport.AllowedOrigins; len(got) != 0 {
		t.Fatalf("allowed_origins = %v, want empty by default", got)
	}
}
