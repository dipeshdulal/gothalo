package server

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/gitdiff"
)

// GET /diff?pane=<pane_id> -> the agent's working-tree changes: branch, and
// one entry per changed file with a per-file unified diff. The "Changes"
// review screen — reviewing what an agent has actually done — without
// dropping to the raw terminal and running `git diff` by hand.
//
// Scoped to agent panes: the agent's `cwd` (from `herdr agent get`) is the
// tree gothalo diffs. A pane with no agent, or an agent pane whose cwd isn't
// a git repository, both degrade to an empty file list rather than erroring —
// "nothing to review" is a normal state, not a failure.
func (s *Server) handleDiff(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	pane := r.URL.Query().Get("pane")
	if pane == "" {
		http.Error(w, "want ?pane=<pane_id>", http.StatusBadRequest)
		return
	}
	cwd, status, err := s.paneCwd(pane)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}

	result, err := gitdiff.Collect(cwd)
	if err != nil {
		log.Warn("diff: collect failed", "pane", pane, "cwd", cwd, "err", err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	writeJSON(w, result)
}

// GET /diff/expand?pane=<pane_id>&path=<file>&start=<n>&count=<n> -> `count`
// lines of that file's current content from line `start`.
//
// Serves exactly one thing: the "show the unchanged lines between these two
// hunks" affordance in the diff viewer. `git diff` ships three lines of context
// around each change, so everything else in the file is simply absent from the
// /diff payload — the app cannot fill a gap client-side no matter how it parses
// what it was given. Rather than inflate EVERY diff with more context (paying
// for it on every file, on a phone, to serve a tap most files never get), the
// app asks for a gap's lines when the gap is actually tapped.
func (s *Server) handleDiffExpand(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	q := r.URL.Query()
	pane, path := q.Get("pane"), q.Get("path")
	if pane == "" || path == "" {
		http.Error(w, "want ?pane=<pane_id>&path=<file>&start=<n>&count=<n>", http.StatusBadRequest)
		return
	}
	start, _ := strconv.Atoi(q.Get("start"))
	count, _ := strconv.Atoi(q.Get("count"))

	cwd, status, err := s.paneCwd(pane)
	if err != nil {
		http.Error(w, err.Error(), status)
		return
	}

	exp, err := gitdiff.ExpandContext(cwd, path, start, count)
	switch {
	case errors.Is(err, gitdiff.ErrBadPath):
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	case errors.Is(err, gitdiff.ErrNoSuchFile):
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	case errors.Is(err, gitdiff.ErrNotText):
		http.Error(w, err.Error(), http.StatusUnsupportedMediaType)
		return
	case err != nil:
		log.Warn("diff: expand failed", "pane", pane, "path", path, "err", err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	writeJSON(w, exp)
}
