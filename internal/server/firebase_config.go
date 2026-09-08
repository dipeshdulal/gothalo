package server

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
)

// firebaseWebFileName is the per-install Firebase web config written by
// scripts/setup-firebase.sh into the bridge data dir (~/.gothalo). It holds
// the same values flutterfire puts in the app build: the project's public
// identifiers plus the VAPID public key. The service-account key that
// authorises sends is never in this file and never leaves the bridge.
const firebaseWebFileName = "firebase-web.json"

// GET /firebase-config -> this bridge's Firebase web config as JSON.
//
// A generically-built web client (GitHub Pages, any custom domain) carries no
// Firebase project of its own, so it fetches the active bridge's config here
// and initialises Firebase against it at pair time instead of build time.
// Every bridge keeps serving its own project: bring-your-own-Firebase holds,
// one shared build works everywhere.
//
// Public: every field served is a public identifier — the same values ship
// inside every Firebase web app ever built. 404 when this bridge has no web
// push configured.
func (s *Server) handleFirebaseConfig(w http.ResponseWriter, r *http.Request) {
	raw, err := os.ReadFile(filepath.Join(s.cfg.DataDir, firebaseWebFileName))
	if err != nil {
		if os.IsNotExist(err) {
			http.Error(w, "firebase web push not configured — run scripts/setup-firebase.sh", http.StatusNotFound)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var v map[string]any
	if err := json.Unmarshal(raw, &v); err != nil {
		http.Error(w, "firebase-web.json is not valid JSON", http.StatusInternalServerError)
		return
	}
	writeJSON(w, v)
}
