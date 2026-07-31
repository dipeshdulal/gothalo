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
	want := "Bearer " + token()
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != want {
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

// notify is where a push would go. For now it just logs so you can see the
// wait->trigger path fire. To make it a real push, POST to FCM here:
//
//   POST https://fcm.googleapis.com/v1/projects/<proj>/messages:send
//   Authorization: Bearer <oauth token from service account>
//   {"message":{"token":"<device token>","notification":{"title":..,"body":..}}}
func notify(agentID, status, title string) {
	log.Printf("NOTIFY  agent=%s  status=%s  title=%q", agentID, status, title)
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
	go watchers()
	http.HandleFunc("/snapshot", auth(handleSnapshot))
	http.HandleFunc("/send", auth(handleSend))
	log.Printf("herdr-bridge listening on %s (token=%q)", addr, token())
	log.Fatal(http.ListenAndServe(addr, nil))
}
