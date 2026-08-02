// Package pairing issues short-lived, one-time pairing codes and renders the QR
// a phone scans to connect. The QR encodes a small JSON payload — the bridge
// base URL + a one-time code — so nothing about the transport (a tailnet URL
// today, a relay URL later) is hardcoded in the app.
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

// Manager tracks outstanding pairing codes in memory (they are cheap and
// short-lived, so they need not survive a restart).
type Manager struct {
	mu    sync.Mutex
	codes map[string]time.Time // code -> expiry
	ttl   time.Duration
}

// NewManager returns a pairing manager with DefaultTTL.
func NewManager() *Manager {
	return &Manager{codes: map[string]time.Time{}, ttl: DefaultTTL}
}

func newCode() (string, error) {
	b := make([]byte, 4) // 8 hex chars — enough entropy for a 5-min window
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Issue creates a new one-time code valid until now+ttl.
func (m *Manager) Issue(now time.Time) (string, error) {
	code, err := newCode()
	if err != nil {
		return "", err
	}
	m.mu.Lock()
	m.pruneLocked(now)
	m.codes[code] = now.Add(m.ttl)
	m.mu.Unlock()
	return code, nil
}

// Consume validates and removes a code (one-time). Returns true if the code was
// valid and unexpired.
func (m *Manager) Consume(code string, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneLocked(now)
	expiry, ok := m.codes[code]
	if !ok || now.After(expiry) {
		return false
	}
	delete(m.codes, code)
	return true
}

func (m *Manager) pruneLocked(now time.Time) {
	for c, expiry := range m.codes {
		if now.After(expiry) {
			delete(m.codes, c)
		}
	}
}

// ConnectPayload is the JSON a pairing QR encodes: the bridge base URL and a
// one-time code. The app parses it and POSTs {code, device_name, fcm_token} to
// <URL>/pair, then uses <URL> as the bridge base thereafter.
type ConnectPayload struct {
	URL  string `json:"url"`
	Code string `json:"code"`
}

// RenderQR prints the QR for the payload to w, with the JSON beneath it for
// debugging / manual entry. Half-block glyphs pack two rows per line (half the
// height) and level L keeps the module count low — compact but still scannable
// at close range.
func RenderQR(p ConnectPayload, w io.Writer) error {
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	qrterminal.GenerateWithConfig(string(b), qrterminal.Config{
		Level:          qrterminal.L,
		Writer:         w,
		HalfBlocks:     true,
		BlackChar:      qrterminal.BLACK_BLACK,
		WhiteChar:      qrterminal.WHITE_WHITE,
		BlackWhiteChar: qrterminal.BLACK_WHITE,
		WhiteBlackChar: qrterminal.WHITE_BLACK,
		QuietZone:      1,
	})
	fmt.Fprintf(w, "\n%s\n", b)
	return nil
}
