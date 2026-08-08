package server

import (
	"errors"
	"io/fs"
	"net/http"
	"os"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/browse"
	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// spaceLister is the one call the browse roots need: where Herdr's open
// workspaces live on disk. *herdr.Manager satisfies it; tests substitute a fake
// (Server.spaces) so the whole roots-and-containment path is exercisable
// without a live Herdr socket. Same seam shape as Server.requester for /herdr.
type spaceLister interface {
	OpenSpaces() []herdr.OpenSpace
}

// browseRoots builds the allowlist for one request, plus the directory -> open
// workspace map the listing annotates entries with.
//
// Recomputed per request rather than cached: sessions and spaces come and go,
// a stale root is either a hole in the boundary or a directory the app cannot
// reach, and the cost is one socket snapshot per session on a call the user
// made by tapping a folder. If browsing ever gets chatty enough to matter, the
// fix is a short TTL here, not a longer-lived allowlist.
func (s *Server) browseRoots() (browse.Roots, map[string]string) {
	var lister spaceLister = s.spaces
	if lister == nil {
		lister = s.sessions
	}
	spaces := lister.OpenSpaces()

	dirs := make([]string, 0, len(spaces)*2)
	openBy := make(map[string]string, len(spaces))
	for _, sp := range spaces {
		dirs = append(dirs, sp.Dir)
		if sp.RepoRoot != "" {
			dirs = append(dirs, sp.RepoRoot)
		}
		// Keyed by the RESOLVED directory, because that is what a listing
		// compares against — an unresolved key would silently never match on a
		// host where the path crosses a symlink (macOS /tmp, say).
		if real, err := browse.Real(sp.Dir); err == nil {
			openBy[real] = sp.WorkspaceID
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		log.Warn("browse: no home directory; roots come from open spaces only", "err", err)
	}
	return browse.NewRoots(home, dirs), openBy
}

// GET /browse?path=<abs dir>&hidden=1 — the host's directory tree, read-only
// and directories-only, so the phone can point at a project and open it as a
// Herdr space.
//
// This is the one endpoint that exists purely so the app works on a Herdr
// session with NOTHING open: with no workspaces there is no pane to split, no
// cwd to inherit and nothing to navigate from, so the app has to be able to
// name a directory itself.
//
// Scope is deliberately tight (see `internal/browse` for the rules and
// `docs/CONTRACT-browse.md` for the contract): roots are the operator's home
// directory plus the parents of spaces Herdr already has open, symlinks and
// ".." are resolved and re-checked against those roots, only directories are
// ever returned, dot-directories need `hidden=1`, and results are capped.
//
// Omitting `path` starts at the first root. Statuses:
//
//	400 — the path is not absolute
//	403 — the path resolves outside the roots, or is unreadable
//	404 — the path is inside the roots but missing, or is a file
//	503 — the host offered no browsable roots at all
func (s *Server) handleBrowse(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}

	roots, openBy := s.browseRoots()
	q := r.URL.Query()
	listing, err := roots.List(q.Get("path"), q.Get("hidden") == "1", openBy)
	if err != nil {
		status, msg := browseErrorStatus(err)
		log.Warn("browse failed", "path", q.Get("path"), "status", status, "err", err)
		http.Error(w, msg, status)
		return
	}
	writeJSON(w, listing)
}

// browseErrorStatus maps a browse error to a status and the message the client
// sees. The messages are deliberately uninformative about anything outside the
// roots: "outside the allowed roots" is the same answer whether the path exists
// or not, which is the point.
func browseErrorStatus(err error) (int, string) {
	switch {
	case errors.Is(err, browse.ErrNotAbsolute):
		return http.StatusBadRequest, "path must be absolute"
	case errors.Is(err, browse.ErrOutsideRoots):
		return http.StatusForbidden, browse.ErrOutsideRoots.Error()
	case errors.Is(err, browse.ErrNoRoots):
		return http.StatusServiceUnavailable, "no browsable directories on this host"
	case errors.Is(err, browse.ErrNotDirectory), errors.Is(err, fs.ErrNotExist):
		return http.StatusNotFound, "no such directory"
	case errors.Is(err, fs.ErrPermission):
		return http.StatusForbidden, "directory is not readable"
	default:
		return http.StatusInternalServerError, err.Error()
	}
}
