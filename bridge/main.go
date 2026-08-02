// herdr-bridge: a tiny bridge between the Herdr socket API and your phone.
//
// It does three things, each independently testable with curl — no mobile app:
//   1. GET  /snapshot        -> current agent/pane/workspace state (herdr api snapshot)
//   2. POST /send            -> type text into an agent   {"pane":"wM:p2","text":"yes\n"}
//   3. background watchers    -> herdr agent wait --until blocked done -> notify()
//
// Auth: every request needs  Authorization: Bearer <TOKEN>  (env BRIDGE_TOKEN).
// Bind: BRIDGE_ADDR (default 0.0.0.0:8787 — set to your Tailscale IP in prod).
//
// notify() currently just logs. Swap the body for an FCM POST when you're ready
// (see the comment). You can prove the whole wait->notify path with zero FCM setup.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

func herdr(args ...string) ([]byte, error) {
	out, err := exec.Command("herdr", args...).CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("herdr %s: %w: %s", strings.Join(args, " "), err, out)
	}
	return out, nil
}

func token() string {
	if t := os.Getenv("BRIDGE_TOKEN"); t != "" {
		return t
	}
	return "dev-token" // fine for localhost testing; set a real one for the tailnet
}

func auth(next http.HandlerFunc) http.HandlerFunc {
	tok := token()
	want := "Bearer " + tok
	return func(w http.ResponseWriter, r *http.Request) {
		// Header is the normal path. ?token= is a convenience for a bare browser
		// URL bar (which can't set headers) on the tailnet-only tool.
		if r.Header.Get("Authorization") != want && r.URL.Query().Get("token") != tok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// GET /snapshot -> raw herdr snapshot JSON (agents, panes, tabs, workspaces).
func handleSnapshot(w http.ResponseWriter, r *http.Request) {
	out, err := herdr("api", "snapshot")
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(out)
}

// POST /send  {"pane":"wM:p2","text":"yes\n"} -> types into that pane.
func handleSend(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Pane string `json:"pane"`
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Pane == "" {
		http.Error(w, "want {pane,text}", http.StatusBadRequest)
		return
	}
	if _, err := herdr("pane", "send-text", body.Pane, body.Text); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	w.Write([]byte(`{"ok":true}`))
}

// FCM push config, initialized in main(). If fcm is nil (no/invalid service
// account) or the device token is empty, notify() just logs — the wait->trigger
// path still works with zero Firebase setup.
//
// The device token is hot-swappable: the receiver page registers it via
// POST /register-token (see handleRegisterToken), so you never restart the
// bridge or copy a token by hand. It's guarded by fcmMu (watcher reads it,
// the HTTP handler writes it) and persisted to tokenFile so it survives restarts.
var (
	fcm       *fcmClient
	fcmMu     sync.RWMutex
	fcmToken  string
	tokenFile = "fcm_token.txt"
)

func getFCMToken() string {
	fcmMu.RLock()
	defer fcmMu.RUnlock()
	return fcmToken
}

func setFCMToken(t string) {
	fcmMu.Lock()
	fcmToken = t
	fcmMu.Unlock()
}

// POST /register-token  {"token":"<fcm device token>"} -> stores it (in memory
// + on disk) so notify() pushes to this device. The receiver page calls this
// itself, so registering a phone is one tap — no copy-paste.
func handleRegisterToken(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Token == "" {
		http.Error(w, "want {token}", http.StatusBadRequest)
		return
	}
	setFCMToken(body.Token)
	if err := os.WriteFile(tokenFile, []byte(body.Token), 0600); err != nil {
		log.Printf("persist token: %v", err)
	}
	log.Printf("registered device token (%d chars) from %s", len(body.Token), r.RemoteAddr)
	w.Write([]byte(`{"ok":true}`))
}

// POST /testpush -> fires notify() with sample values so you can prove the FCM
// delivery leg on its own (independent of the watcher). Remove once rung ⑤ passes.
func handleTestPush(w http.ResponseWriter, r *http.Request) {
	notify("test-agent", "blocked", "gothalo test push — if you see this, FCM works")
	w.Write([]byte(`{"ok":true,"sent":true}`))
}

// notify fires on a transition into blocked/done. It always logs; if FCM is
// configured it also sends a real push to the registered device token. The
// agent id + status ride along in data{} for later idempotent approvals (D8).
func notify(agentID, status, title string) {
	log.Printf("NOTIFY  agent=%s  status=%s  title=%q", agentID, status, title)
	devToken := getFCMToken()
	if fcm == nil || devToken == "" {
		return
	}
	pushTitle := fmt.Sprintf("Herdr agent %s", status)
	body := title
	if body == "" {
		body = agentID
	}
	if err := fcm.send(devToken, pushTitle, body, map[string]string{
		"agent":  agentID,
		"status": status,
	}); err != nil {
		log.Printf("fcm send failed: %v", err)
		return
	}
	log.Printf("fcm push sent  agent=%s  status=%s", agentID, status)
}

// snapshot shape we care about for the watchers.
type snapshot struct {
	Result struct {
		Snapshot struct {
			Agents []struct {
				Session struct {
					Value string `json:"value"`
				} `json:"agent_session"`
				Status string `json:"agent_status"`
				PaneID string `json:"pane_id"`
				Title  string `json:"terminal_title_stripped"`
			} `json:"agents"`
		} `json:"snapshot"`
	} `json:"result"`
}

// watchers polls the snapshot every few seconds and fires notify() on any
// transition INTO blocked/done. (A per-agent `herdr agent wait` is more elegant
// and event-driven — this poll version is the dead-simple thing to prove the
// pipeline first. Swap to `wait` once you like the shape.)
func watchers() {
	seen := map[string]string{} // paneID -> last status
	for {
		out, err := herdr("api", "snapshot")
		if err != nil {
			log.Printf("watch: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}
		var s snapshot
		if err := json.Unmarshal(out, &s); err != nil {
			log.Printf("watch parse: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}
		for _, a := range s.Result.Snapshot.Agents {
			prev := seen[a.PaneID]
			if a.Status != prev && (a.Status == "blocked" || a.Status == "done") {
				notify(a.PaneID, a.Status, a.Title)
			}
			seen[a.PaneID] = a.Status
		}
		time.Sleep(3 * time.Second)
	}
}

func main() {
	addr := os.Getenv("BRIDGE_ADDR")
	if addr == "" {
		addr = "0.0.0.0:8787"
	}

	// FCM is optional: without it, notify() logs only (proves wait->trigger).
	// FCM_SERVICE_ACCOUNT: path to the Firebase service-account JSON (default serviceAccount.json)
	// FCM_TOKEN:           optional initial device token; normally the receiver
	//                      page registers it at runtime via POST /register-token,
	//                      and it's persisted to tokenFile across restarts.
	if t := os.Getenv("FCM_TOKEN"); t != "" {
		fcmToken = t
	} else if b, err := os.ReadFile(tokenFile); err == nil {
		fcmToken = strings.TrimSpace(string(b))
	}
	saPath := os.Getenv("FCM_SERVICE_ACCOUNT")
	if saPath == "" {
		saPath = "serviceAccount.json"
	}
	if saBytes, err := os.ReadFile(saPath); err != nil {
		log.Printf("FCM disabled: %v (notify will log only)", err)
	} else if c, err := loadServiceAccount(saBytes); err != nil {
		log.Printf("FCM disabled: %v (notify will log only)", err)
	} else {
		fcm = c
		hasTok := "no device token (set FCM_TOKEN)"
		if fcmToken != "" {
			hasTok = fmt.Sprintf("device token set (%d chars)", len(fcmToken))
		}
		log.Printf("FCM enabled: project=%s, %s", c.sa.ProjectID, hasTok)
	}

	go watchers()

	// API routes (authenticated). More specific patterns than "/", so the
	// ServeMux routes these before falling through to the static file server.
	http.HandleFunc("/snapshot", auth(handleSnapshot))
	http.HandleFunc("/send", auth(handleSend))
	http.HandleFunc("/testpush", auth(handleTestPush))
	http.HandleFunc("/register-token", auth(handleRegisterToken))

	// Static receiver page (unauthenticated — it's public client code, and the
	// browser can't send an auth header on a navigation). Served from the same
	// origin as the API so the HTTPS page can POST /register-token without a
	// mixed-content block. WEB_ROOT defaults to the sibling webpush/ dir.
	webRoot := os.Getenv("WEB_ROOT")
	if webRoot == "" {
		webRoot = "../webpush"
	}
	http.Handle("/", http.FileServer(http.Dir(webRoot)))

	log.Printf("herdr-bridge listening on %s (token=%q, web_root=%q)", addr, token(), webRoot)
	log.Fatal(http.ListenAndServe(addr, nil))
}
