package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"path/filepath"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/gitbranch"
	"github.com/dipeshdulal/gothalo/internal/gitutil"
	"github.com/dipeshdulal/gothalo/internal/herdr"
)

// Branch deletion from the phone: the second half of "remove this worktree".
//
// Herdr removes the checkout and closes the workspace, and stops there — it has
// no branch concept and no socket method that could delete one. So the branch
// the worktree was on survives every removal, and since creating worktrees from
// a phone is a tap, the refs pile up faster than anyone prunes them.
//
// Two endpoints, deliberately split at the moment the user decides:
//
//	GET  /branch-info?workspace_id=wN   — before the confirm: what would be
//	                                      deleted, and is it safe?
//	POST /branch-delete {repo_root,…}   — after the worktree is gone.
//
// They cannot be one call. The preflight has to answer while the workspace
// still exists (it is what names the branch and the repo); the delete has to
// run after it does not (git refuses to delete a checked-out branch). And the
// worktree removal in between can fail, which must NOT be followed by a branch
// delete — so the app owns the ordering and the bridge validates each half
// independently. See docs/CONTRACT-branch-delete.md.
//
// Nothing here trusts the preflight it just served. /branch-delete re-runs
// every rule (see internal/gitbranch), because the client is a phone on a
// tailnet and the preflight it saw may be minutes stale.

// branchInfoResponse is GET /branch-info's payload: the facts the confirm
// dialog needs to name the branch, state whether it is merged, and decide
// whether to offer the option at all.
type branchInfoResponse struct {
	WorkspaceID string `json:"workspace_id"`
	// RepoRoot and Branch are what the caller echoes back to /branch-delete.
	// They come from Herdr's own worktree record, not from parsing the checkout
	// path — a Herdr worktree directory is named after the branch it was
	// created for, and they drift apart the moment anyone switches branches
	// inside it.
	RepoRoot     string `json:"repo_root"`
	CheckoutPath string `json:"checkout_path"`
	Branch       string `json:"branch"`

	DefaultBranch string `json:"default_branch"`
	IsDefault     bool   `json:"is_default"`
	// CheckedOutElsewhere lists worktrees OTHER than this space's own checkout
	// that hold the branch. This space's checkout is excluded on purpose: it is
	// about to be removed, so it is not an obstacle. Anything left here is.
	CheckedOutElsewhere []string `json:"checked_out_elsewhere"`
	Merged              bool     `json:"merged"`
	MergedInto          string   `json:"merged_into"`
	UnmergedCommits     int      `json:"unmerged_commits"`
	Upstream            string   `json:"upstream"`

	// Deletable is whether the branch could be deleted once this worktree is
	// gone — including the unmerged case, which is deletable but only with an
	// explicit force. Clients read Merged to decide how hard to ask.
	Deletable bool `json:"deletable"`
	// BlockedReason is a sentence for the cases Deletable is false. Empty
	// otherwise.
	BlockedReason string `json:"blocked_reason"`
}

// GET /branch-info?workspace_id=<id> — the preflight behind the "also delete
// the branch" checkbox.
//
// Takes the same workspace id the app already passes to `worktree.remove`, so
// nothing is reconstructed from paths on the client. The branch and repo root
// come from Herdr's `worktree.list` for that workspace; everything else is git.
//
// A workspace that is not a linked git worktree is a 200 with
// `deletable:false` and a reason, not an error — "there is no branch to offer
// here" is a normal answer for a plain workspace, and the dialog just omits the
// option.
func (s *Server) handleBranchInfo(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodGet {
		writeProxyError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	wsID := r.URL.Query().Get("workspace_id")
	if wsID == "" {
		writeProxyError(w, http.StatusBadRequest, "want ?workspace_id=<id>")
		return
	}

	session, bare := herdr.SplitTarget(wsID)
	req := s.requester
	if req == nil {
		c, err := s.sessions.Client(session)
		if err != nil {
			writeProxyError(w, http.StatusNotFound, err.Error())
			return
		}
		req = c
	}

	resp := branchInfoResponse{WorkspaceID: wsID}
	raw, err := req.Request("worktree.list", map[string]any{"workspace_id": bare})
	if err != nil {
		// `not_git_worktree` is Herdr saying "this space isn't in a repo" — an
		// answer, not a failure. Anything else is a real problem.
		var serr *herdr.SocketError
		if errors.As(err, &serr) && serr.Code == "not_git_worktree" {
			resp.BlockedReason = "this space is not a git worktree"
			writeJSON(w, resp)
			return
		}
		status, msg := herdrProxyErrorStatus(err)
		log.Error("branch-info: worktree.list failed", "workspace", wsID, "err", err)
		writeProxyError(w, status, msg)
		return
	}

	var list struct {
		Source struct {
			RepoRoot string `json:"repo_root"`
		} `json:"source"`
		Worktrees []struct {
			Path             string `json:"path"`
			Branch           string `json:"branch"`
			IsDetached       bool   `json:"is_detached"`
			IsLinkedWorktree bool   `json:"is_linked_worktree"`
			OpenWorkspaceID  string `json:"open_workspace_id"`
		} `json:"worktrees"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		writeProxyError(w, http.StatusBadGateway, "herdr: unreadable worktree_list: "+err.Error())
		return
	}
	resp.RepoRoot = list.Source.RepoRoot

	// Herdr tags the worktree it has open as each workspace, which is the only
	// join that survives someone switching branches inside the checkout.
	idx := -1
	for i, wt := range list.Worktrees {
		if wt.OpenWorkspaceID == bare {
			idx = i
			break
		}
	}
	if idx < 0 {
		resp.BlockedReason = "this space is not a git worktree"
		writeJSON(w, resp)
		return
	}
	wt := list.Worktrees[idx]
	resp.CheckoutPath = wt.Path
	resp.Branch = wt.Branch

	switch {
	case wt.IsDetached || wt.Branch == "":
		resp.BlockedReason = "this worktree is on a detached HEAD, not a branch"
		writeJSON(w, resp)
		return
	case !wt.IsLinkedWorktree:
		// The repository's own working tree, opened as a space. Removing it is
		// not a worktree removal and its branch is not litter.
		resp.BlockedReason = "this space is the repository's main checkout"
		writeJSON(w, resp)
		return
	case resp.RepoRoot == "":
		resp.BlockedReason = "herdr did not report a repo root for this space"
		writeJSON(w, resp)
		return
	}

	info, err := gitbranch.Inspect(resp.RepoRoot, resp.Branch)
	if err != nil {
		log.Warn("branch-info: inspect failed", "repo", resp.RepoRoot, "branch", resp.Branch, "err", err)
		resp.BlockedReason = err.Error()
		writeJSON(w, resp)
		return
	}

	// Drop this space's own checkout: it is the thing being removed, so it can
	// never be the reason the branch has to stay.
	info.CheckedOutAt = withoutPath(info.CheckedOutAt, wt.Path)

	resp.DefaultBranch = info.DefaultBranch
	resp.IsDefault = info.IsDefault
	resp.CheckedOutElsewhere = info.CheckedOutAt
	resp.Merged = info.Merged
	resp.MergedInto = info.MergedInto
	resp.UnmergedCommits = info.UnmergedCommits
	resp.Upstream = info.Upstream
	// force=true: an unmerged branch IS deletable, it just costs a deliberate
	// second confirm on the client. Merged says which conversation to have.
	resp.Deletable, resp.BlockedReason = info.Deletable(true)

	writeJSON(w, resp)
}

// branchDeleteRequest is POST /branch-delete's body. repo_root and branch are
// the ones GET /branch-info returned; force is the caller's explicit opt-in to
// losing unmerged commits.
type branchDeleteRequest struct {
	RepoRoot string `json:"repo_root"`
	Branch   string `json:"branch"`
	Force    bool   `json:"force"`
}

// POST /branch-delete — delete a local branch, after its worktree is gone.
//
// The caller is responsible for ordering (remove the worktree first, and skip
// this entirely if that failed); the bridge is responsible for never doing
// something unsafe when asked. Every rule from the preflight is re-checked
// here, and `force` buys exactly one of them: the unmerged case. The default
// branch and a branch checked out somewhere are refused with any body.
//
// This never touches the remote. The response carries `upstream` and
// `remote_deleted:false` so the caller can say what it did and did not do.
func (s *Server) handleBranchDelete(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAuth(w, r); !ok {
		return
	}
	if r.Method != http.MethodPost {
		writeProxyError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	var body branchDeleteRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeProxyError(w, http.StatusBadRequest, "want {repo_root, branch, force}")
		return
	}
	if body.RepoRoot == "" || body.Branch == "" {
		writeProxyError(w, http.StatusBadRequest, "want {repo_root, branch, force}")
		return
	}
	// Same guard the agent-start path uses for a caller-supplied directory: a
	// relative or traversal-shaped path means a different place on every install.
	if err := validateCWD(body.RepoRoot); err != nil {
		writeProxyError(w, http.StatusBadRequest, "repo_root: "+err.Error())
		return
	}

	out, err := gitbranch.Delete(body.RepoRoot, body.Branch, body.Force)
	if err != nil {
		status := branchErrorStatus(err)
		log.Warn("branch delete refused", "repo", body.RepoRoot, "branch", body.Branch,
			"force", body.Force, "status", status, "err", err)
		writeProxyError(w, status, err.Error())
		return
	}

	log.Info("branch deleted", "repo", body.RepoRoot, "branch", out.Branch,
		"forced", out.Forced, "was", out.SHA)
	writeJSON(w, out)
}

// branchErrorStatus maps a gitbranch refusal to an HTTP status. The safety
// refusals are all 409: the request was well-formed and understood, the
// repository's state is what says no.
func branchErrorStatus(err error) int {
	switch {
	case errors.Is(err, gitutil.ErrIndexLocked):
		return http.StatusConflict
	case errors.Is(err, gitbranch.ErrNoBranch):
		return http.StatusNotFound
	case errors.Is(err, gitbranch.ErrBadBranch), errors.Is(err, gitbranch.ErrNotARepo):
		return http.StatusBadRequest
	case errors.Is(err, gitbranch.ErrDefaultBranch),
		errors.Is(err, gitbranch.ErrUnknownDefault),
		errors.Is(err, gitbranch.ErrCheckedOut),
		errors.Is(err, gitbranch.ErrUnmerged),
		errors.Is(err, gitbranch.ErrGit):
		return http.StatusConflict
	}
	return http.StatusBadGateway
}

// withoutPath drops one filesystem path from a list, comparing cleaned forms
// and then symlink-resolved forms. The two sources disagree on macOS often
// enough to matter: git reports `/private/var/…` where Herdr reports `/var/…`,
// and a mismatch here would leave a space looking like it blocks its own
// branch.
func withoutPath(paths []string, drop string) []string {
	if len(paths) == 0 || drop == "" {
		return paths
	}
	dropClean := filepath.Clean(drop)
	dropReal, err := filepath.EvalSymlinks(dropClean)
	if err != nil {
		dropReal = dropClean
	}
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		c := filepath.Clean(p)
		if c == dropClean {
			continue
		}
		if real, err := filepath.EvalSymlinks(c); err == nil && real == dropReal {
			continue
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
