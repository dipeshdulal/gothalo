// Package server holds the transport-agnostic HTTP surface: an http.Handler set
// plus per-device auth. The same handlers run under any transport (direct today,
// relay later). It ties together herdr (read/control), push (FCM fan-out),
// store (devices), and pairing (QR onboarding).
package server

import (
	"encoding/json"
	"io/fs"
	"net/http"
	"strings"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/pairing"
	"github.com/dipeshdulal/gothalo/internal/push"
	"github.com/dipeshdulal/gothalo/internal/store"
	"github.com/dipeshdulal/gothalo/internal/timeline"
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
	cfg      *config.Config
	sessions *herdr.Manager // one client per running Herdr session
	push     *push.Client   // may be nil (FCM disabled -> notify logs only)
	store    *store.Store
	pairing  *pairing.Manager
	web      fs.FS       // static receiver page assets
	bus      *events.Bus // unified event bus; may be nil (WS /events disabled)
	// timeline is the recorded agent-activity ring behind GET /timeline. May be
	// nil (recording disabled), in which case the endpoint reports 503 rather
	// than an empty history — "no recorder running" and "nothing happened yet"
	// are different answers and a client should be able to tell them apart.
	timeline *timeline.Log
	// requester backs POST /herdr in tests; nil in production (routed per session).
	requester herdrRequester
	// agents backs the pane -> cwd resolution (paneCwd) in tests; nil in
	// production, where the agent is fetched from the pane's own session client.
	agents agentGetter
}

// New constructs a Server. push, bus and tl may be nil.
func New(cfg *config.Config, mgr *herdr.Manager, p *push.Client, st *store.Store, pm *pairing.Manager, web fs.FS, bus *events.Bus, tl *timeline.Log) *Server {
	return &Server{cfg: cfg, sessions: mgr, push: p, store: st, pairing: pm, web: web, bus: bus, timeline: tl}
}

// target resolves a possibly session-qualified id ("acme/w1:p2") to its
// session's client and the bare id Herdr understands. An unknown session's
// error satisfies herdr.IsNotFound, so call sites map it to a 404.
func (s *Server) target(id string) (c *herdr.Client, session, bare string, err error) {
	session, bare = herdr.SplitTarget(id)
	c, err = s.sessions.Client(session)
	return c, session, bare, err
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
	mux.HandleFunc("/info", s.handleInfo)
	mux.HandleFunc("/snapshot", s.handleSnapshot)
	mux.HandleFunc("/send", s.handleSend)
	mux.HandleFunc("/approve", s.handleApprove)
	mux.HandleFunc("/agent-state", s.handleAgentState)
	mux.HandleFunc("/diff", s.handleDiff)
	mux.HandleFunc("/image", s.handleImage)
	mux.HandleFunc("/agent-mode/cycle", s.handleAgentModeCycle)
	mux.HandleFunc("/agent-transcript", s.handleAgentTranscript)
	mux.HandleFunc("/commands", s.handleCommands)
	mux.HandleFunc("/agents/available", s.handleAgentsAvailable)
	mux.HandleFunc("/agent/start", s.handleAgentStart)
	mux.HandleFunc("/agent/restart", s.handleAgentRestart)
	mux.HandleFunc("/agent/stop", s.handleAgentStop)
	mux.HandleFunc("/attach", s.handleAttach)
	mux.HandleFunc("/events", s.handleEvents)
	mux.HandleFunc("/timeline", s.handleTimeline)
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

// GET /snapshot -> herdr snapshot JSON, merged across all running sessions.
func (s *Server) handleSnapshot(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	out, err := s.sessions.MergedSnapshotRaw()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(out)
}

// POST /send {"pane":"wN:p2","text":"yes\n"} -> types into that pane.
// POST /send {"pane":"wN:p2","key":"esc"} -> sends a raw keystroke instead of
// typing text — for a Blocked.Options[] entry that has no numbered index and
// is only reachable via a keystroke (e.g. Claude's single-choice approval
// form, where "No" is only reachable via Esc). Mutually exclusive with text;
// key wins if both are set.
func (s *Server) handleSend(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	var body struct {
		Pane string `json:"pane"`
		Text string `json:"text"`
		Key  string `json:"key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Pane == "" {
		http.Error(w, "want {pane,text}", http.StatusBadRequest)
		return
	}
	c, _, pane, err := s.target(body.Pane)
	if err != nil {
		http.Error(w, err.Error(), herdrStatus(err))
		return
	}
	if body.Key != "" {
		if err := c.SendKeys(pane, body.Key); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
		return
	}
	// Split a trailing newline/CR "submit" off the text. The body is typed as a
	// paste-safe send-text, but the Enter is delivered as a real key event:
	// Claude enables bracketed-paste mode, which swallows a \r embedded in
	// pasted text — leaving the message sitting unsubmitted in the input box
	// (the "have to press Enter twice" bug). A key event submits regardless of
	// paste mode, and only when the caller actually asked to submit.
	text := body.Text
	submit := strings.HasSuffix(text, "\r") || strings.HasSuffix(text, "\n")
	content := strings.TrimRight(text, "\r\n")
	if content != "" {
		if err := c.Send(pane, content); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
	}
	if submit {
		if err := c.SendKeys(pane, "Enter"); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
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
	// The bridge identity goes back with the pairing result: it is what lets the
	// phone attribute an incoming push to this server rather than one of the
	// others it is paired with.
	writeJSON(w, map[string]string{
		"id": d.ID, "bearer": d.Bearer, "name": d.Name,
		"server_id": s.cfg.ServerID, "server_name": s.cfg.ServerName,
	})
}

// BridgeVersion is what this bridge can do, as one number the app can compare
// against. Hand-maintained: bump it when the surface the app depends on gains
// something the app would want to branch on, and leave it alone otherwise.
//
// Deliberately NOT derived from the build or from git. A version that changes
// with every commit tells a client nothing about capability — it would have to
// be mapped back to features somewhere, which is the job this number exists to
// do directly.
//
// History:
//
//	1 — server identity (/info), notification rework, /events heartbeat.
//	2 — POST /image: attach a screenshot to a prompt.
//	3 — agent lifecycle: /agents/available, /agent/start, /agent/restart,
//	    /agent/stop. The app still gates its launch UI on /agents/available
//	    answering with kinds rather than on this number — a bridge can be v3 and
//	    still have nothing installed to launch — so this records the capability
//	    without being the thing that unlocks it.
//	4 — GET /timeline (recorded agent-activity history).
//	5 — GET /commands: the slash commands a pane's agent accepts, for the
//	    composer typeahead. The app gates the typeahead on the endpoint
//	    answering rather than on this number — an older bridge 404s and the
//	    composer stays a plain text field — so this records the capability
//	    without being what unlocks it.
const BridgeVersion = 5

// GET /info -> this bridge's identity and capability level.
//
// Small on purpose: every push carries a server_id, and the app needs a way to
// learn which of its saved servers that id belongs to — including for servers
// paired before identity existed, which is why this is a standalone endpoint and
// not only part of the pairing response.
//
// Its absence is itself informative: a bridge that 404s here predates identity
// entirely, and the app treats it as unidentified.
func (s *Server) handleInfo(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	writeJSON(w, map[string]any{
		"server_id":   s.cfg.ServerID,
		"server_name": s.cfg.ServerName,
		"version":     BridgeVersion,
	})
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
func principal(id string) string {
	if id == "" {
		return "admin/web"
	}
	return "device " + id
}
