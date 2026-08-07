package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/store"
)

// worktreeLister stands in for the Herdr socket on the one method
// /branch-info calls. It records the params so the "asks about the right
// workspace" claim is checkable, which fakeRequester (json.RawMessage only)
// cannot do for a map body.
type worktreeLister struct {
	lastMethod string
	lastParams map[string]any
	result     json.RawMessage
	err        error
}

func (f *worktreeLister) Request(method string, params any) (json.RawMessage, error) {
	f.lastMethod = method
	if m, ok := params.(map[string]any); ok {
		f.lastParams = m
	}
	return f.result, f.err
}

func newBranchServer(t *testing.T, fake herdrRequester) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "devices.json"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return &Server{
		cfg:       &config.Config{AdminToken: "admintok"},
		store:     st,
		requester: fake,
	}
}

func branchInfoRequest(t *testing.T, srv *Server, query string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/branch-info?"+query, nil)
	req.Header.Set("Authorization", "Bearer admintok")
	rec := httptest.NewRecorder()
	srv.handleBranchInfo(rec, req)
	return rec
}

func postBranchDelete(t *testing.T, srv *Server, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/branch-delete", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admintok")
	rec := httptest.NewRecorder()
	srv.handleBranchDelete(rec, req)
	return rec
}

func decodeBranchInfo(t *testing.T, rec *httptest.ResponseRecorder) branchInfoResponse {
	t.Helper()
	var got branchInfoResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode branch-info: %v (body: %s)", err, rec.Body.String())
	}
	return got
}

// repoWithWorktree builds a repo on `main` plus a linked worktree on `branch`,
// and returns (repoRoot, worktreePath). Mirrors what Herdr leaves behind.
func repoWithWorktree(t *testing.T, branch string, merged bool) (string, string) {
	t.Helper()
	repo := t.TempDir()
	git(t, repo, "init", "-q", "-b", "main")
	git(t, repo, "config", "user.email", "test@example.com")
	git(t, repo, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(repo, "base.txt"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, repo, "add", ".")
	git(t, repo, "commit", "-q", "-m", "base")

	wt := filepath.Join(t.TempDir(), "wt")
	git(t, repo, "worktree", "add", "-q", "-b", branch, wt)
	if err := os.WriteFile(filepath.Join(wt, "work.txt"), []byte("work\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, wt, "add", ".")
	git(t, wt, "commit", "-q", "-m", "work")
	if merged {
		git(t, repo, "merge", "-q", "--no-ff", "-m", "merge", branch)
	}
	return repo, wt
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

// worktreeListResult is what Herdr answers `worktree.list` with, trimmed to the
// fields the handler reads.
func worktreeListResult(repoRoot, wtPath, branch, workspaceID string) json.RawMessage {
	return json.RawMessage(fmt.Sprintf(`{
	  "type": "worktree_list",
	  "source": {"repo_root": %q, "repo_name": "repo"},
	  "worktrees": [
	    {"path": %q, "branch": "main", "is_detached": false, "is_linked_worktree": false},
	    {"path": %q, "branch": %q, "is_detached": false, "is_linked_worktree": true, "open_workspace_id": %q}
	  ]
	}`, repoRoot, repoRoot, wtPath, branch, workspaceID))
}

func TestBranchInfo_MergedWorktreeBranch(t *testing.T) {
	repo, wt := repoWithWorktree(t, "feat/done", true)
	fake := &worktreeLister{result: worktreeListResult(repo, wt, "feat/done", "w7")}
	srv := newBranchServer(t, fake)

	rec := branchInfoRequest(t, srv, "workspace_id=w7")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if fake.lastMethod != "worktree.list" || fake.lastParams["workspace_id"] != "w7" {
		t.Errorf("asked herdr %q %v, want worktree.list for w7", fake.lastMethod, fake.lastParams)
	}

	got := decodeBranchInfo(t, rec)
	if got.Branch != "feat/done" || got.RepoRoot != repo {
		t.Errorf("branch/repo = %q/%q, want feat/done/%s", got.Branch, got.RepoRoot, repo)
	}
	if got.DefaultBranch != "main" || got.IsDefault {
		t.Errorf("default = %q is_default = %v, want main/false", got.DefaultBranch, got.IsDefault)
	}
	if !got.Merged || got.MergedInto != "main" {
		t.Errorf("merged = %v into %q, want true into main", got.Merged, got.MergedInto)
	}
	if !got.Deletable || got.BlockedReason != "" {
		t.Errorf("deletable = %v (%s), want true", got.Deletable, got.BlockedReason)
	}
	// The space's own checkout holds the branch, but it is what is being
	// removed — it must not read as an obstacle.
	if len(got.CheckedOutElsewhere) != 0 {
		t.Errorf("CheckedOutElsewhere = %v, want empty (only this space holds it)", got.CheckedOutElsewhere)
	}
}

func TestBranchInfo_UnmergedIsStillDeletableButNamedAsUnmerged(t *testing.T) {
	repo, wt := repoWithWorktree(t, "feat/wip", false)
	srv := newBranchServer(t, &worktreeLister{result: worktreeListResult(repo, wt, "feat/wip", "w7")})

	got := decodeBranchInfo(t, branchInfoRequest(t, srv, "workspace_id=w7"))
	if got.Merged {
		t.Error("merged = true for a branch with commits not in main")
	}
	if got.UnmergedCommits != 1 {
		t.Errorf("unmerged_commits = %d, want 1", got.UnmergedCommits)
	}
	if !got.Deletable {
		t.Error("deletable = false; unmerged is a harder confirm, not an impossible one")
	}
}

func TestBranchInfo_RefusesTheDefaultBranch(t *testing.T) {
	repo, wt := repoWithWorktree(t, "feat/x", true)
	// A worktree that is somehow on `main` itself: the default branch is never
	// on offer, whatever the space looks like.
	srv := newBranchServer(t, &worktreeLister{result: worktreeListResult(repo, wt, "main", "w7")})

	got := decodeBranchInfo(t, branchInfoRequest(t, srv, "workspace_id=w7"))
	if !got.IsDefault {
		t.Error("is_default = false for main")
	}
	if got.Deletable {
		t.Error("deletable = true for the default branch")
	}
	if !strings.Contains(got.BlockedReason, "default branch") {
		t.Errorf("blocked_reason = %q, want it to say why", got.BlockedReason)
	}
}

func TestBranchInfo_ReportsAnotherWorktreeHoldingTheBranch(t *testing.T) {
	repo, wt := repoWithWorktree(t, "feat/shared", true)
	// A second worktree on the same branch is the case the app must not offer:
	// removing this space leaves the branch checked out somewhere else. git
	// only allows the state under --force, which is exactly why the bridge
	// checks for it rather than assuming one-checkout-per-branch.
	other := filepath.Join(t.TempDir(), "other")
	git(t, repo, "worktree", "add", "-q", "--force", other, "feat/shared")

	srv := newBranchServer(t, &worktreeLister{result: worktreeListResult(repo, wt, "feat/shared", "w7")})
	got := decodeBranchInfo(t, branchInfoRequest(t, srv, "workspace_id=w7"))

	if len(got.CheckedOutElsewhere) != 1 {
		t.Fatalf("CheckedOutElsewhere = %v, want the other worktree", got.CheckedOutElsewhere)
	}
	if got.Deletable {
		t.Error("deletable = true while another worktree holds the branch")
	}
}

func TestBranchInfo_NonWorktreeSpaceIsAnAnswerNotAnError(t *testing.T) {
	fake := &worktreeLister{err: &herdr.SocketError{Code: "not_git_worktree", Message: "not a git work tree"}}
	srv := newBranchServer(t, fake)

	rec := branchInfoRequest(t, srv, "workspace_id=w4")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 — 'no branch here' is a normal answer", rec.Code)
	}
	got := decodeBranchInfo(t, rec)
	if got.Deletable || got.Branch != "" || got.BlockedReason == "" {
		t.Errorf("got %+v, want deletable=false with a reason and no branch", got)
	}
}

func TestBranchInfo_MainCheckoutSpaceIsNotOnOffer(t *testing.T) {
	repo, _ := repoWithWorktree(t, "feat/x", true)
	// The repo's own working tree opened as a space: its branch is not litter,
	// and "remove worktree" does not apply to it.
	result := json.RawMessage(fmt.Sprintf(`{
	  "type":"worktree_list",
	  "source":{"repo_root":%q},
	  "worktrees":[{"path":%q,"branch":"main","is_linked_worktree":false,"open_workspace_id":"w7"}]
	}`, repo, repo))
	srv := newBranchServer(t, &worktreeLister{result: result})

	got := decodeBranchInfo(t, branchInfoRequest(t, srv, "workspace_id=w7"))
	if got.Deletable {
		t.Error("deletable = true for the repository's main checkout")
	}
	if !strings.Contains(got.BlockedReason, "main checkout") {
		t.Errorf("blocked_reason = %q, want it to name the case", got.BlockedReason)
	}
}

func TestBranchInfo_DetachedHeadWorktree(t *testing.T) {
	repo, wt := repoWithWorktree(t, "feat/x", true)
	result := json.RawMessage(fmt.Sprintf(`{
	  "type":"worktree_list",
	  "source":{"repo_root":%q},
	  "worktrees":[{"path":%q,"branch":"","is_detached":true,"is_linked_worktree":true,"open_workspace_id":"w7"}]
	}`, repo, wt))
	srv := newBranchServer(t, &worktreeLister{result: result})

	got := decodeBranchInfo(t, branchInfoRequest(t, srv, "workspace_id=w7"))
	if got.Deletable {
		t.Error("deletable = true for a detached-HEAD worktree; there is no branch to delete")
	}
}

func TestBranchInfo_RequiresWorkspaceID(t *testing.T) {
	srv := newBranchServer(t, &worktreeLister{})
	if rec := branchInfoRequest(t, srv, ""); rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rec.Code)
	}
}

func TestBranchInfo_Unauthorized(t *testing.T) {
	srv := newBranchServer(t, &worktreeLister{})
	req := httptest.NewRequest(http.MethodGet, "/branch-info?workspace_id=w7", nil)
	rec := httptest.NewRecorder()
	srv.handleBranchInfo(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

func TestBranchDelete_MergedBranch(t *testing.T) {
	repo, wt := repoWithWorktree(t, "feat/done", true)
	git(t, repo, "worktree", "remove", "--force", wt)
	srv := newBranchServer(t, &worktreeLister{})

	rec := postBranchDelete(t, srv, fmt.Sprintf(`{"repo_root":%q,"branch":"feat/done"}`, repo))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	var out struct {
		Deleted       bool   `json:"deleted"`
		Forced        bool   `json:"forced"`
		SHA           string `json:"sha"`
		RemoteDeleted bool   `json:"remote_deleted"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !out.Deleted || out.Forced || out.SHA == "" {
		t.Errorf("outcome = %+v, want deleted, unforced, with a sha", out)
	}
	if out.RemoteDeleted {
		t.Error("remote_deleted = true; this endpoint never pushes")
	}
}

func TestBranchDelete_UnmergedNeeds409ThenForce(t *testing.T) {
	repo, wt := repoWithWorktree(t, "feat/wip", false)
	git(t, repo, "worktree", "remove", "--force", wt)
	srv := newBranchServer(t, &worktreeLister{})

	rec := postBranchDelete(t, srv, fmt.Sprintf(`{"repo_root":%q,"branch":"feat/wip"}`, repo))
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 for an unmerged branch (body: %s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "not merged") {
		t.Errorf("body = %s, want it to say why", rec.Body.String())
	}

	rec = postBranchDelete(t, srv, fmt.Sprintf(`{"repo_root":%q,"branch":"feat/wip","force":true}`, repo))
	if rec.Code != http.StatusOK {
		t.Fatalf("forced status = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"forced":true`) {
		t.Errorf("body = %s, want forced:true", rec.Body.String())
	}
}

func TestBranchDelete_RefusesDefaultAndCheckedOut(t *testing.T) {
	repo, wt := repoWithWorktree(t, "feat/live", true)
	srv := newBranchServer(t, &worktreeLister{})

	// Still checked out in the worktree — force must not override this.
	rec := postBranchDelete(t, srv, fmt.Sprintf(`{"repo_root":%q,"branch":"feat/live","force":true}`, repo))
	if rec.Code != http.StatusConflict {
		t.Errorf("status = %d, want 409 while the worktree still holds the branch", rec.Code)
	}

	// The default branch, with force, is still a refusal.
	rec = postBranchDelete(t, srv, fmt.Sprintf(`{"repo_root":%q,"branch":"main","force":true}`, repo))
	if rec.Code != http.StatusConflict {
		t.Errorf("status = %d, want 409 for the default branch", rec.Code)
	}
	_ = wt
}

func TestBranchDelete_MissingBranchIs404(t *testing.T) {
	repo, _ := repoWithWorktree(t, "feat/x", true)
	srv := newBranchServer(t, &worktreeLister{})
	rec := postBranchDelete(t, srv, fmt.Sprintf(`{"repo_root":%q,"branch":"no/such"}`, repo))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}

func TestBranchDelete_BadRequests(t *testing.T) {
	srv := newBranchServer(t, &worktreeLister{})
	cases := map[string]string{
		"no body fields":  `{}`,
		"no branch":       `{"repo_root":"/tmp"}`,
		"relative root":   `{"repo_root":"relative/path","branch":"x"}`,
		"traversal root":  `{"repo_root":"/tmp/../etc","branch":"x"}`,
		"malformed json":  `{`,
		"dash-led branch": `{"repo_root":"/tmp","branch":"-D"}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if rec := postBranchDelete(t, srv, body); rec.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400 (body: %s)", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestBranchDelete_Unauthorized(t *testing.T) {
	srv := newBranchServer(t, &worktreeLister{})
	req := httptest.NewRequest(http.MethodPost, "/branch-delete", strings.NewReader(`{}`))
	rec := httptest.NewRecorder()
	srv.handleBranchDelete(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}
