// Package pairing issues short-lived, one-time pairing codes and renders the
// QR a phone scans to connect. The QR carries a transport-agnostic connect
// payload so the app never hardcodes Tailscale: today a direct URL, later a
// relay URL + bridge id.
package pairing

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/mdp/qrterminal/v3"
)

// DefaultTTL is how long a pairing code stays valid.
const DefaultTTL = 5 * time.Minute

// ConnectPayload is what the QR encodes. The app scans it, then calls
// POST <URL>/pair {code, device_name, fcm_token} to receive a per-device bearer.
type ConnectPayload struct {
	V    int    `json:"v"`    // payload version
	URL  string `json:"url"`  // bridge base URL (direct mode)
	Code string `json:"code"` // one-time pairing code
	// BridgeID string `json:"bridge_id,omitempty"` // reserved for relay mode
}

type pending struct {
	name    string
	expires time.Time
}

// Manager tracks outstanding pairing codes in memory (they are cheap and
// short-lived, so they need not survive a restart).
type Manager struct {
	mu    sync.Mutex
	codes map[string]pending
	ttl   time.Duration
}

// NewManager returns a pairing manager with DefaultTTL.
func NewManager() *Manager {
	return &Manager{codes: map[string]pending{}, ttl: DefaultTTL}
}

func newCode() (string, error) {
	b := make([]byte, 4) // 8 hex chars — enough entropy for a 5-min window
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Issue creates a new one-time code labelled name, valid until now+ttl.
func (m *Manager) Issue(name string, now time.Time) (string, error) {
	code, err := newCode()
	if err != nil {
		return "", err
	}
	m.mu.Lock()
	m.pruneLocked(now)
	m.codes[code] = pending{name: name, expires: now.Add(m.ttl)}
	m.mu.Unlock()
	return code, nil
}

// Consume validates and removes a code (one-time). Returns the device name it
// was issued for and true if the code was valid and unexpired.
func (m *Manager) Consume(code string, now time.Time) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneLocked(now)
	p, ok := m.codes[code]
	if !ok || now.After(p.expires) {
		return "", false
	}
	delete(m.codes, code)
	return p.name, true
}

func (m *Manager) pruneLocked(now time.Time) {
	for c, p := range m.codes {
		if now.After(p.expires) {
			delete(m.codes, c)
		}
	}
}

// RenderQR prints the QR for payload to w (e.g. os.Stdout), plus the raw payload
// beneath it for debugging / manual entry.
func RenderQR(payload ConnectPayload, w io.Writer) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	qrterminal.Generate(string(b), qrterminal.M, w)
	fmt.Fprintf(w, "\n%s\n", b)
	return nil
}
