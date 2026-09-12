// Package opencode talks to OpenCode v2's local managed service — the
// per-machine HTTP server an OpenCode TUI registers with. It is the supported
// interface for what gothalo needs beyond the raw terminal: reading a session's
// transcript, and reading and answering the prompt a session is blocked on (the
// question tool's forms). Permission requests use a sibling API and are not
// wired here yet.
//
// The service is local and per-user. It listens on a loopback port it writes,
// with a per-service password, to
// $XDG_STATE_HOME/opencode/service.json (default ~/.local/state/opencode/);
// gothalo authenticates as HTTP Basic opencode:<password>. Nothing here leaves
// the machine.
//
// A pane reaches the service by its session id. Herdr usually reports that via
// its opencode integration (`agent_session.value`); when it has not, SessionForCwd
// picks the newest top-level session whose recorded directory matches the
// pane's cwd — the same rule the transcript reader uses.
package opencode

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// apiTimeout bounds a single call to the service. It is local, so anything
// slower means it is wedged; a read must fall through rather than hang a
// request handler forever.
const apiTimeout = 10 * time.Second

// ErrNotFound is the service's 404: the session (or form/request) does not
// exist, or does not belong to the requested location. Callers treat it as
// "nothing here", never as a hard failure.
var ErrNotFound = errors.New("opencode: not found")

// Service is the on-disk registration written at service.json: where the
// service is listening and the basic-auth password. The password is a
// per-service secret, so the file is mode 0600 and never leaves the host.
type Service struct {
	URL      string `json:"url"`
	Password string `json:"password"`
}

// httpClient is shared by every call. Bounding each request means a stopped
// service fails fast instead of blocking a caller.
var httpClient = &http.Client{Timeout: apiTimeout}

// stateDir mirrors OpenCode's own discovery: $XDG_STATE_HOME/opencode, else
// ~/.local/state/opencode.
func stateDir() string {
	if dir := os.Getenv("XDG_STATE_HOME"); dir != "" {
		return filepath.Join(dir, "opencode")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "state", "opencode")
}

func servicePath() string {
	dir := stateDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, "service.json")
}

// Discover reads the running service's registration. A missing file is
// os.ErrNotExist (the normal "no OpenCode v2 here" case), not a bug.
func Discover() (Service, error) {
	path := servicePath()
	if path == "" {
		return Service{}, os.ErrNotExist
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return Service{}, err
	}
	var svc Service
	if err := json.Unmarshal(b, &svc); err != nil {
		return Service{}, err
	}
	if svc.URL == "" || svc.Password == "" {
		return Service{}, errors.New("opencode service credentials incomplete")
	}
	return svc, nil
}

// do runs one authenticated request. body is marshalled as JSON when non-nil.
// A 404 becomes ErrNotFound; any other non-2xx is an error carrying the status.
func (s Service) do(method, path string, body any) ([]byte, error) {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, strings.TrimRight(s.URL, "/")+path, reader)
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth("opencode", s.Password)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrNotFound
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("opencode service %s %s: %s", method, path, resp.Status)
	}
	return io.ReadAll(resp.Body)
}

// Get fetches a path.
func (s Service) Get(path string) ([]byte, error) { return s.do(http.MethodGet, path, nil) }

// Post sends a JSON body to a path.
func (s Service) Post(path string, body any) ([]byte, error) {
	return s.do(http.MethodPost, path, body)
}

// Verify confirms the service owns this session at this cwd. Session ids are
// global, but a pane's cwd is part of the session's identity: without the check
// a rotated or spoofed id could read a different project's state. A mismatch
// reads as ErrNotFound.
func (s Service) Verify(sessionID, cwd string) error {
	body, err := s.Get("/api/session/" + url.PathEscape(sessionID))
	if err != nil {
		return err
	}
	var out struct {
		Data struct {
			Location struct {
				Directory string `json:"directory"`
			} `json:"location"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return err
	}
	if cwd != "" && out.Data.Location.Directory != "" &&
		filepath.Clean(cwd) != filepath.Clean(out.Data.Location.Directory) {
		return ErrNotFound
	}
	return nil
}

// SessionForCwd resolves the pane's session when herdr reported no session id.
// The service lists sessions newest-updated first, so the first top-level
// session whose recorded directory equals the pane's cwd is the one the pane is
// most likely showing. Child sessions (subagents) are skipped so a delegated
// conversation is never mistaken for the pane's own.
func (s Service) SessionForCwd(cwd string) (string, error) {
	if cwd == "" {
		return "", ErrNotFound
	}
	body, err := s.Get("/api/session")
	if err != nil {
		return "", err
	}
	var out struct {
		Data []struct {
			ID       string `json:"id"`
			ParentID string `json:"parentID"`
			Location struct {
				Directory string `json:"directory"`
			} `json:"location"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", err
	}
	want := filepath.Clean(cwd)
	for _, sess := range out.Data {
		if sess.ParentID != "" || sess.Location.Directory == "" {
			continue
		}
		if filepath.Clean(sess.Location.Directory) == want {
			return sess.ID, nil
		}
	}
	return "", ErrNotFound
}
