package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// herdrProxyAllowlist is the explicit set of Herdr socket methods POST /herdr
// will forward. Anything not listed here is rejected with 403 — this is the one
// place to audit and extend what the app can drive. Method names are the socket
// `method` ids from `herdr api schema --json` (schemas.request), NOT the CLI
// subcommands. Reads are safe; the mutating entries (create/split/close/focus)
// are the specific operations the app needs, each allowed deliberately. The
// destructive ones (worktree.remove, tab.close, pane.close) are gated behind an
// in-app confirm and are on the list on purpose.
var herdrProxyAllowlist = map[string]bool{
	// ---- reads (safe; state the app renders) ----
	"session.snapshot": true, // full session tree (workspaces/tabs/panes/agents)
	"workspace.list":   true, // list workspaces
	"workspace.get":    true, // one workspace by id
	"worktree.list":    true, // git worktrees for a workspace/cwd
	"tab.list":         true, // tabs (optionally scoped to a workspace)
	"tab.get":          true, // one tab by id
	"pane.list":        true, // panes (optionally scoped to a workspace)
	"pane.get":         true, // one pane by id
	"agent.list":       true, // hosted agents across the session
	"agent.get":        true, // one agent by target

	// ---- worktree create/remove (the app's primary flow) ----
	"worktree.create": true, // create a git worktree + its workspace
	"worktree.open":   true, // open an existing worktree as a workspace
	"worktree.remove": true, // DESTRUCTIVE: remove a worktree's workspace (in-app confirm)

	// ---- workspace / tab / pane mutations ----
	"workspace.create": true, // new empty workspace
	"tab.create":       true, // new tab (+ root pane) in a workspace
	"tab.close":        true, // DESTRUCTIVE: close a tab (in-app confirm)
	"tab.focus":        true, // focus a tab
	"pane.split":       true, // split a pane (the app's "new pane")
	"pane.close":       true, // DESTRUCTIVE: close a pane (in-app confirm)
	"pane.focus":       true, // focus a pane
	"agent.focus":      true, // focus an agent's pane

	// ---- mobile agent-list projection (Herdr's own filter+sort for the phone) ----
	"agent.view.set":   true, // install a filter+sort projection (e.g. sort by "attention")
	"agent.view.clear": true, // clear the projection
}

// herdrProxyRequest is the POST /herdr body: a Herdr socket method plus its
// params. Params is passed through to the socket verbatim (as raw JSON), so the
// app can use exactly the shapes from `herdr api schema --json` without the
// bridge re-modelling each one. Session picks the Herdr session explicitly;
// when absent it is inferred from session-qualified ids inside params
// ("acme/w1:p2"), which are stripped to the bare ids Herdr understands.
type herdrProxyRequest struct {
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	Session string          `json:"session"`
}

// resolveProxySession strips session prefixes from every id in params and
// returns (session, bareParams). Ids naming different sessions in one call are
// an error; explicit wins over inferred but must not contradict it. Params
// without any qualified id pass through VERBATIM (byte-for-byte).
func resolveProxySession(explicit string, params json.RawMessage) (string, json.RawMessage, error) {
	if explicit == "default" {
		explicit = ""
	}
	var v any
	if err := json.Unmarshal(params, &v); err != nil {
		return explicit, params, nil // not an object we can walk; let Herdr complain
	}
	inferred := ""
	conflict := false
	changed := false
	herdr.RewriteIDs(v, func(id string) string {
		sess, bare := herdr.SplitTarget(id)
		if sess == "" {
			return id
		}
		if inferred != "" && sess != inferred {
			conflict = true
		}
		inferred = sess
		changed = true
		return bare
	})
	if conflict {
		return "", nil, fmt.Errorf("params mix ids from different sessions")
	}
	if explicit != "" && inferred != "" && explicit != inferred {
		return "", nil, fmt.Errorf("session %q contradicts ids qualified with %q", explicit, inferred)
	}
	session := explicit
	if session == "" {
		session = inferred
	}
	if !changed {
		return session, params, nil
	}
	out, err := json.Marshal(v)
	if err != nil {
		return "", nil, err
	}
	return session, out, nil
}

// writeProxyError writes a normalized {"error": msg} body with the given status.
func writeProxyError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// POST /herdr {"method":"<socket method>","params":{…}} — an allowlisted generic
// proxy onto the Herdr control socket, giving the app parity with Herdr's command
// surface through one authenticated endpoint. Auth is the usual per-device bearer
// (or admin token). Only methods on herdrProxyAllowlist are forwarded (403
// otherwise). On success returns {"result": <herdr result>}; on failure a
// normalized {"error": …} with an appropriate status:
//
//	400 — malformed body / missing method
//	403 — method not on the allowlist
//	404 — Herdr resolved-target-not-found (e.g. pane_not_found)
//	502 — socket/herdr unreachable or other Herdr error
func (s *Server) handleHerdrProxy(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodPost {
		writeProxyError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}

	var body herdrProxyRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Method == "" {
		writeProxyError(w, http.StatusBadRequest, "want {method, params}")
		return
	}

	if !herdrProxyAllowlist[body.Method] {
		writeProxyError(w, http.StatusForbidden, "method not allowed: "+body.Method)
		return
	}

	// Default missing/empty params to an empty object — most read methods take
	// EmptyParams and Herdr expects an object, not null.
	params := body.Params
	if len(params) == 0 {
		params = json.RawMessage("{}")
	}

	session, params, err := resolveProxySession(body.Session, params)
	if err != nil {
		writeProxyError(w, http.StatusBadRequest, err.Error())
		return
	}

	// Route to the session's socket; the test seam (s.requester) bypasses routing.
	req := s.requester
	if req == nil {
		c, cerr := s.sessions.Client(session)
		if cerr != nil {
			writeProxyError(w, http.StatusNotFound, cerr.Error())
			return
		}
		req = c
	}

	result, err := req.Request(body.Method, params)
	if err != nil {
		status, msg := herdrProxyErrorStatus(err)
		log.Error("herdr proxy failed", "method", body.Method, "session", session, "status", status, "err", err)
		writeProxyError(w, status, msg)
		return
	}

	log.Info("herdr proxy", "method", body.Method, "session", session)
	// result is already JSON; wrap it in {"result": …} without re-encoding.
	if len(result) == 0 {
		result = json.RawMessage("null")
	}
	// Re-qualify ids in the result so the app can address them back directly.
	if session != "" {
		var v any
		if json.Unmarshal(result, &v) == nil {
			herdr.QualifyIDs(v, session)
			if b, merr := json.Marshal(v); merr == nil {
				result = b
			}
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"result":`))
	_, _ = w.Write(result)
	_, _ = w.Write([]byte("}"))
}

// herdrProxyErrorStatus maps a Request error to an HTTP status + message. A
// Herdr *SocketError with a "*_not_found" code is a 404 (bad target), any other
// Herdr error is surfaced with its code, and a transport failure is a 502.
func herdrProxyErrorStatus(err error) (int, string) {
	var serr *herdr.SocketError
	if errors.As(err, &serr) {
		if strings.HasSuffix(serr.Code, "_not_found") {
			return http.StatusNotFound, serr.Error()
		}
		return http.StatusBadGateway, serr.Error()
	}
	return http.StatusBadGateway, err.Error()
}
