// Package server holds the transport-agnostic HTTP surface: an http.Handler set
// plus per-device auth. The same handlers run under any transport (direct today,
// relay later). It ties together herdr (read/control), push (FCM fan-out),
// store (devices), and pairing (QR onboarding).
package server

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/pairing"
	"github.com/dipeshdulal/gothalo/internal/push"
	"github.com/dipeshdulal/gothalo/internal/store"
)

// Server bundles the dependencies the handlers need.
type Server struct {
	cfg     *config.Config
	herdr   *herdr.Client
	push    *push.Client // may be nil (FCM disabled -> notify logs only)
	store   *store.Store
	pairing *pairing.Manager
	web     fs.FS // static receiver page assets
}

// New constructs a Server. push may be nil.
func New(cfg *config.Config, h *herdr.Client, p *push.Client, st *store.Store, pm *pairing.Manager, web fs.FS) *Server {
	return &Server{cfg: cfg, herdr: h, push: p, store: st, pairing: pm, web: web}
}

// Handler returns the routed http.Handler. More specific API routes are matched
// before the catch-all static file server at "/".
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/snapshot", s.handleSnapshot)
	mux.HandleFunc("/send", s.handleSend)
	mux.HandleFunc("/register-token", s.handleRegisterToken)
	mux.HandleFunc("/testpush", s.handleTestPush)
	mux.HandleFunc("/pair", s.handlePair)
	mux.HandleFunc("/admin/pairing", s.handleAdminPairing)
	mux.HandleFunc("/admin/devices", s.handleAdminDevices)
	mux.HandleFunc("/admin/devices/revoke", s.handleAdminDevicesRevoke)
	if s.web != nil {
		mux.Handle("/", http.FileServer(http.FS(s.web)))
	}
	return mux
}

// ---- auth ----

func bearerOrQuery(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	}
	return r.URL.Query().Get("token")
}

// authorize accepts a per-device bearer (returns that device id) or the admin
// token (returns id ""). ok is false when neither matches.
func (s *Server) authorize(r *http.Request) (deviceID string, ok bool) {
	tok := bearerOrQuery(r)
	if tok == "" {
		return "", false
	}
	if s.cfg.AdminToken != "" && tok == s.cfg.AdminToken {
		return "", true
	}
	if d, found := s.store.ByBearer(tok); found {
		s.store.Touch(d.ID, time.Now())
		return d.ID, true
	}
	return "", false
}

// requireAuth authorizes any principal (device or admin), writing 401 on failure.
func (s *Server) requireAuth(w http.ResponseWriter, r *http.Request) (deviceID string, ok bool) {
	id, ok := s.authorize(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return "", false
	}
	return id, true
}

// requireAdmin authorizes only the admin token.
func (s *Server) requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	tok := bearerOrQuery(r)
	if s.cfg.AdminToken != "" && tok == s.cfg.AdminToken {
		return true
	}
	http.Error(w, "unauthorized", http.StatusUnauthorized)
	return false
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// ---- handlers ----

// GET /snapshot -> raw herdr snapshot JSON.
func (s *Server) handleSnapshot(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	out, err := s.herdr.SnapshotRaw()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(out)
}

// POST /send {"pane":"wN:p2","text":"yes\n"} -> types into that pane.
func (s *Server) handleSend(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	var body struct {
		Pane string `json:"pane"`
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Pane == "" {
		http.Error(w, "want {pane,text}", http.StatusBadRequest)
		return
	}
	if err := s.herdr.Send(body.Pane, body.Text); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// POST /register-token {"token":"..."} -> update the caller's push token.
// A device bearer updates that device; the admin token upserts a "web" device
// (for the browser test page).
func (s *Server) handleRegisterToken(w http.ResponseWriter, r *http.Request) {
	id, ok := s.requireAuth(w, r)
	if !ok {
		return
	}
	var body struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Token == "" {
		http.Error(w, "want {token}", http.StatusBadRequest)
		return
	}
	now := time.Now()
	if id == "" {
		if _, err := s.store.UpsertByName("web", body.Token, now); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	} else {
		s.store.SetFCMToken(id, body.Token, now)
	}
	log.Printf("registered push token (%d chars) for %q", len(body.Token), principal(id))
	writeJSON(w, map[string]bool{"ok": true})
}

// POST /testpush -> fan a sample push out to all registered devices.
func (s *Server) handleTestPush(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	s.Notify("test-agent", "blocked", "gothalo test push — if you see this, FCM works")
	writeJSON(w, map[string]bool{"ok": true, "sent": true})
}

// POST /pair {"code","device_name","fcm_token"} -> consume a one-time code and
// register the device, returning its per-device bearer.
func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code       string `json:"code"`
		DeviceName string `json:"device_name"`
		FCMToken   string `json:"fcm_token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Code == "" {
		http.Error(w, "want {code,device_name,fcm_token}", http.StatusBadRequest)
		return
	}
	name, ok := s.pairing.Consume(body.Code, time.Now())
	if !ok {
		http.Error(w, "invalid or expired pairing code", http.StatusForbidden)
		return
	}
	if body.DeviceName != "" {
		name = body.DeviceName
	}
	d, err := s.store.Add(name, body.FCMToken, time.Now())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("paired device %q (id=%s)", d.Name, d.ID)
	writeJSON(w, map[string]string{"id": d.ID, "bearer": d.Bearer, "name": d.Name})
}

// POST /admin/pairing {"name"} -> mint a one-time code + return the connect URL.
// Called by the local `gothalo pair` CLI (admin-authed) to build the QR.
func (s *Server) handleAdminPairing(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body) // name optional
	code, err := s.pairing.Issue(body.Name, time.Now())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]string{"code": code, "url": s.cfg.Transport.PublicURL})
}

// GET /admin/devices -> list paired devices (admin-authed). Used by
// `gothalo devices list` so the running daemon stays authoritative.
func (s *Server) handleAdminDevices(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	writeJSON(w, map[string]any{"devices": s.store.List()})
}

// POST /admin/devices/revoke {"id"} -> revoke a device (admin-authed).
func (s *Server) handleAdminDevicesRevoke(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	var body struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.ID == "" {
		http.Error(w, "want {id}", http.StatusBadRequest)
		return
	}
	name, ok := s.store.Revoke(body.ID)
	if !ok {
		http.Error(w, "no such device", http.StatusNotFound)
		return
	}
	log.Printf("revoked device %q (id=%s)", name, body.ID)
	writeJSON(w, map[string]any{"revoked": true, "name": name})
}

// Notify fans a transition out to every registered device. It is the callback
// the watcher fires. Always logs; pushes only when FCM is configured.
func (s *Server) Notify(paneID, status, title string) {
	log.Printf("NOTIFY  agent=%s  status=%s  title=%q", paneID, status, title)
	if s.push == nil {
		return
	}
	tokens := s.store.FCMTokens()
	if len(tokens) == 0 {
		return
	}
	pushTitle := fmt.Sprintf("Herdr agent %s", status)
	body := title
	if body == "" {
		body = paneID
	}
	data := map[string]string{"agent": paneID, "status": status}
	sent := 0
	for _, t := range tokens {
		if err := s.push.Send(t, pushTitle, body, data); err != nil {
			log.Printf("push failed (token %s…): %v", t[:min(8, len(t))], err)
			continue
		}
		sent++
	}
	log.Printf("pushed to %d/%d device(s)  agent=%s  status=%s", sent, len(tokens), paneID, status)
}

func principal(id string) string {
	if id == "" {
		return "admin/web"
	}
	return "device " + id
}
