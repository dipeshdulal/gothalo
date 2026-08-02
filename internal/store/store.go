// Package store is the paired-device registry, persisted to a JSON file
// (0600). Each device has its own bearer token (for auth) and FCM token (for
// push), so a single device can be revoked without touching the others.
package store

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Device is one paired mobile client.
type Device struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Bearer   string    `json:"bearer"`
	FCMToken string    `json:"fcm_token"`
	PairedAt time.Time `json:"paired_at"`
	LastSeen time.Time `json:"last_seen,omitempty"`
}

// Store is an in-memory registry backed by a JSON file. All methods are safe
// for concurrent use.
type Store struct {
	path string
	mu   sync.RWMutex
	byID map[string]*Device
}

// Open loads the registry from path, creating an empty one if the file is absent.
func Open(path string) (*Store, error) {
	s := &Store{path: path, byID: map[string]*Device{}}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return s, nil
		}
		return nil, fmt.Errorf("read devices %s: %w", path, err)
	}
	var list []*Device
	if err := json.Unmarshal(b, &list); err != nil {
		return nil, fmt.Errorf("parse devices %s: %w", path, err)
	}
	for _, d := range list {
		s.byID[d.ID] = d
	}
	return s, nil
}

func randHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Add registers a new device with the given name and FCM token, minting an id
// and a bearer. now is passed in so callers control time (and tests stay
// deterministic).
func (s *Store) Add(name, fcmToken string, now time.Time) (*Device, error) {
	id, err := randHex(4) // 8 hex chars
	if err != nil {
		return nil, err
	}
	bearer, err := randHex(32) // 64 hex chars
	if err != nil {
		return nil, err
	}
	d := &Device{ID: id, Name: name, Bearer: bearer, FCMToken: fcmToken, PairedAt: now, LastSeen: now}

	s.mu.Lock()
	s.byID[id] = d
	err = s.saveLocked()
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return d, nil
}

// List returns all devices, newest first.
func (s *Store) List() []Device {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Device, 0, len(s.byID))
	for _, d := range s.byID {
		out = append(out, *d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].PairedAt.After(out[j].PairedAt) })
	return out
}

// Revoke deletes a device by id. Returns the removed device name and true if it
// existed.
func (s *Store) Revoke(id string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.byID[id]
	if !ok {
		return "", false
	}
	delete(s.byID, id)
	_ = s.saveLocked()
	return d.Name, true
}

// ByBearer returns the device whose bearer matches, for auth.
func (s *Store) ByBearer(bearer string) (Device, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, d := range s.byID {
		if d.Bearer == bearer {
			return *d, true
		}
	}
	return Device{}, false
}

// FCMTokens returns the push tokens of all devices (deduped, non-empty), the
// fan-out target for notifications.
func (s *Store) FCMTokens() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	seen := map[string]bool{}
	var out []string
	for _, d := range s.byID {
		if d.FCMToken != "" && !seen[d.FCMToken] {
			seen[d.FCMToken] = true
			out = append(out, d.FCMToken)
		}
	}
	return out
}

// SetFCMToken updates a device's push token (they rotate). Returns true if the
// device exists.
func (s *Store) SetFCMToken(id, token string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.byID[id]
	if !ok {
		return false
	}
	d.FCMToken = token
	d.LastSeen = now
	_ = s.saveLocked()
	return true
}

// UpsertByName sets the FCM token on the device with the given name, creating a
// device (with a fresh id + bearer) if none exists. Used by the operator/web
// test path where there is no full pairing handshake.
func (s *Store) UpsertByName(name, token string, now time.Time) (*Device, error) {
	s.mu.Lock()
	for _, d := range s.byID {
		if d.Name == name {
			d.FCMToken = token
			d.LastSeen = now
			err := s.saveLocked()
			cp := *d
			s.mu.Unlock()
			return &cp, err
		}
	}
	s.mu.Unlock()
	return s.Add(name, token, now)
}

// Touch updates a device's last-seen timestamp.
func (s *Store) Touch(id string, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d, ok := s.byID[id]; ok {
		d.LastSeen = now
		_ = s.saveLocked()
	}
}

// saveLocked writes the registry atomically. Callers must hold s.mu.
func (s *Store) saveLocked() error {
	list := make([]*Device, 0, len(s.byID))
	for _, d := range s.byID {
		list = append(list, d)
	}
	b, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return fmt.Errorf("write devices: %w", err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return fmt.Errorf("replace devices: %w", err)
	}
	return nil
}

// EnsureDir makes sure the parent directory of the registry exists (0700).
func (s *Store) EnsureDir() error {
	return os.MkdirAll(filepath.Dir(s.path), 0o700)
}
