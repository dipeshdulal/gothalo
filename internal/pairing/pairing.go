// Package pairing issues short-lived, one-time pairing codes and renders the QR
// a phone scans to connect. The QR encodes a **deep-link URL**
// (<base>/pair?code=<code>) rather than a JSON blob: it's the idiomatic mobile
// shape (the app can register it as a deep link), it's human-openable, and the
// app derives the bridge base URL from the URL's origin — so nothing about the
// transport (tailnet URL now, relay URL later) is hardcoded.
package pairing

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net/url"
	"strings"
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

// URL builds the deep-link a phone scans: <base>/pair?code=<code>. The app POSTs
// to <base>/pair and uses <base> as the bridge URL thereafter.
func URL(base, code string) string {
	return strings.TrimRight(base, "/") + "/pair?code=" + url.QueryEscape(code)
}

// RenderQR prints the QR for the pairing URL to w, with the URL beneath it for
// debugging / manual entry.
func RenderQR(pairURL string, w io.Writer) error {
	qrterminal.Generate(pairURL, qrterminal.M, w)
	fmt.Fprintf(w, "\n%s\n", pairURL)
	return nil
}
