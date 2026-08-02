// Package server holds the transport-agnostic HTTP surface: an http.Handler set
// plus per-device auth. The same handlers run under any transport (direct today,
// relay later). It ties together herdr (read/control), push (FCM fan-out),
// store (devices), and pairing (QR onboarding).
package server

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/pairing"
	"github.com/dipeshdulal/gothalo/internal/push"
	"github.com/dipeshdulal/gothalo/internal/store"
)

// herdrRequester is the one call the generic /herdr proxy needs: an
// id-correlated request/response round-trip to the Herdr socket. *herdr.Client
// satisfies it; tests substitute a fake. Kept as a narrow interface so the proxy
// handler stays testable without a live socket.
type herdrRequester interface {
	Request(method string, params any) (json.RawMessage, error)
}

// Server bundles the dependencies the handlers need.
type Server struct {
	cfg     *config.Config
	herdr   *herdr.Client
	push    *push.Client // may be nil (FCM disabled -> notify logs only)
	store   *store.Store
	pairing *pairing.Manager
	web     fs.FS       // static receiver page assets
	bus     *events.Bus // unified event bus; may be nil (WS /events disabled)
	// requester backs POST /herdr; defaults to herdr but is swappable for tests.
	requester herdrRequester
}

// New constructs a Server. push and bus may be nil.
func New(cfg *config.Config, h *herdr.Client, p *push.Client, st *store.Store, pm *pairing.Manager, web fs.FS, bus *events.Bus) *Server {
	return &Server{cfg: cfg, herdr: h, push: p, store: st, pairing: pm, web: web, bus: bus, requester: h}
}

// publish emits a gothalo.* system event onto the bus, if one is wired. It never
// fails a request: a marshalling error is logged, not surfaced. This is the one
// call every gothalo publisher (approve, pane, pairing, push) uses.
func (s *Server) publish(typ string, payload any) {
	if s.bus == nil {
		return
	}
	if _, err := s.bus.Publish(events.SourceGothalo, typ, payload); err != nil {
		log.Error("event publish failed", "type", typ, "err", err)
	}
}

// Handler returns the routed http.Handler. More specific API routes are matched
// before the catch-all static file server at "/".
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/snapshot", s.handleSnapshot)
	mux.HandleFunc("/send", s.handleSend)
	mux.HandleFunc("/approve", s.handleApprove)
	mux.HandleFunc("/agent-state", s.handleAgentState)
	mux.HandleFunc("/agent-transcript", s.handleAgentTranscript)
	mux.HandleFunc("/attach", s.handleAttach)
	mux.HandleFunc("/events", s.handleEvents)
	mux.HandleFunc("/pane/new", s.handlePaneNew)
	mux.HandleFunc("/pane/close", s.handlePaneClose)
	mux.HandleFunc("/herdr", s.handleHerdrProxy)
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
	log.Info("registered push token", "principal", principal(id), "bytes", len(body.Token))
	writeJSON(w, map[string]bool{"ok": true})
}

// POST /testpush -> fan a sample push out to all registered devices.
func (s *Server) handleTestPush(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	s.Notify("test-agent", "blocked", "gothalo test push — if you see this, FCM works", 0)
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
	if !s.pairing.Consume(body.Code, time.Now()) {
		http.Error(w, "invalid or expired pairing code", http.StatusForbidden)
		return
	}
	name := body.DeviceName
	if name == "" {
		name = "device"
	}
	d, err := s.store.Add(name, body.FCMToken, time.Now())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Info("paired device", "name", d.Name, "id", d.ID)
	s.publish(events.TypeDevicePaired, map[string]any{"id": d.ID, "name": d.Name})
	writeJSON(w, map[string]string{"id": d.ID, "bearer": d.Bearer, "name": d.Name})
}

// POST /admin/pairing -> mint a one-time code + return the deep-link URL the QR
// encodes. Called by the local `gothalo pair` CLI (admin-authed).
func (s *Server) handleAdminPairing(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}
	code, err := s.pairing.Issue(time.Now())
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
	log.Info("revoked device", "name", name, "id", body.ID)
	writeJSON(w, map[string]any{"revoked": true, "name": name})
}

// Notify fans a transition out to every registered device. It is the callback
// the watcher fires. Always logs; pushes only when FCM is configured.
func (s *Server) Notify(paneID, status, title string, seq int) {
	log.Info("notify", "agent", paneID, "status", status, "title", title, "seq", seq)
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
	// state_change_seq rides along so a lock-screen approve can echo it back to
	// POST /approve, which no-ops if the agent has since moved past this seq (D8).
	data := map[string]string{
		"agent":            paneID,
		"status":           status,
		"state_change_seq": strconv.Itoa(seq),
	}
	sent := 0
	for _, t := range tokens {
		if err := s.push.Send(t, pushTitle, body, data); err != nil {
			log.Error("push failed", "token", t[:min(8, len(t))]+"…", "err", err)
			continue
		}
		sent++
	}
	log.Info("pushed", "sent", sent, "total", len(tokens), "agent", paneID, "status", status)
	// The bus mirrors the FCM fan-out as a gothalo.push_sent system event. (Later,
	// FCM can move to being a bus SUBSCRIBER instead of the watcher calling Notify
	// directly; this event keeps app clients aware of what was pushed either way.)
	s.publish(events.TypePushSent, map[string]any{
		"agent": paneID, "status": status, "title": title, "seq": seq, "sent": sent, "total": len(tokens),
	})
}

func principal(id string) string {
	if id == "" {
		return "admin/web"
	}
	return "device " + id
}
