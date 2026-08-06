# CONTRACT — `GET /diff` (working-tree changes)

The "Changes" review screen's contract: an agent pane's pending git changes —
branch, and one unified diff per changed file — without dropping to the raw
terminal and running `git diff` by hand. Pairs naturally with the approval
bar: review what an agent actually did before approving its next action.

Captured live against **gothalo itself mid-development** (the `feat/diff-endpoint`
branch, diffing its own new files) — a real multi-file capture, not a toy
example.

---

## Request

```
GET /diff?pane=<pane_id>
Authorization: Bearer <bearer>
```

| Part | Value |
|---|---|
| Method | `GET` |
| Path | `/diff` |
| Query | `pane` — the Herdr `pane_id` (e.g. `wN:p1`), from `/snapshot`. **Required.** |
| Body | none |
| Auth header | `Authorization: Bearer <bearer>` — the per-device bearer from `/pair`, or the admin token (dev). |

Stateless per request: the bridge resolves the pane's agent (`herdr agent
get`) for its `cwd`, then shells out to `git` directly against that
directory. No Herdr socket call does this — git isn't part of Herdr's model,
it's a plain local process the bridge already has filesystem access to (same
model as `internal/transcript` reading Claude's session files directly).

**Scoped to agent panes.** A non-agent pane (plain shell) has no `cwd` this
endpoint can resolve → `404`. Use `/agent-state` first to confirm the pane
hosts an agent.

---

## Response `200` — schema

| Field | Type | Notes |
|---|---|---|
| `branch` | string | Best-effort (`git rev-parse --abbrev-ref HEAD`); `""` on a detached HEAD or if git fails — never fails the whole request. |
| `files` | array | One entry per changed file, in `git status` order. Empty (not absent) when the tree is clean or `cwd` isn't a git repo — "nothing to review" is a normal state, not an error. |
| `files[].path` | string | The file's current path (its new path for a rename). |
| `files[].old_path` | string \| absent | Set **only** for a rename/copy — the path it moved from. |
| `files[].status` | string | `"modified"` \| `"added"` \| `"deleted"` \| `"renamed"` \| `"untracked"`. |
| `files[].additions` | int | Lines added, counted from the diff itself. |
| `files[].deletions` | int | Lines removed. Always `0` for `"untracked"` — see below. |
| `files[].diff` | string | A **unified diff for this file alone** (one `diff --git …` section, not the whole tree's combined diff). May contain `\n`. |

### The `"untracked"` diff is synthetic, not `git diff` output

A brand-new file isn't in the index or `HEAD`, so plain `git diff` has
nothing to say about it. Rather than give the app a second shape to render
("new file, show its raw content" vs. "existing file, show its diff"),
`/diff` synthesizes a unified diff for it — `--- /dev/null` / `+++ b/<path>`,
every line prefixed `+` — so **every** `files[]` entry is a diff the same
renderer can show. Capped at 64KB of source (a `… (truncated)` marker line is
appended past the cap); a binary file's `diff` is the literal string
`"Binary file, not shown."` instead of raw bytes.

---

## Live example — real capture

Captured against the running daemon while this very endpoint was being
built — `wN:p1` was the pane writing `internal/server/diff.go`, so this is
gothalo diffing its own in-progress source. Two of the five real files from
that capture, shown in full (the other three are the same shape):

```json
{
  "branch": "feat/diff-endpoint",
  "files": [
    {
      "path": "internal/server/server.go",
      "status": "modified",
      "additions": 1,
      "deletions": 0,
      "diff": "diff --git a/internal/server/server.go b/internal/server/server.go\nindex 36dd2cd..4c341f8 100644\n--- a/internal/server/server.go\n+++ b/internal/server/server.go\n@@ -78,6 +78,7 @@ func (s *Server) Handler() http.Handler {\n \tmux.HandleFunc(\"/send\", s.handleSend)\n \tmux.HandleFunc(\"/approve\", s.handleApprove)\n \tmux.HandleFunc(\"/agent-state\", s.handleAgentState)\n+\tmux.HandleFunc(\"/diff\", s.handleDiff)\n \tmux.HandleFunc(\"/agent-mode/cycle\", s.handleAgentModeCycle)\n \tmux.HandleFunc(\"/agent-transcript\", s.handleAgentTranscript)\n \tmux.HandleFunc(\"/attach\", s.handleAttach)"
    },
    {
      "path": "internal/server/diff_test.go",
      "status": "untracked",
      "additions": 47,
      "deletions": 0,
      "diff": "--- /dev/null\n+++ b/internal/server/diff_test.go\n+package server\n+\n+import (\n+\t\"net/http\"\n+\t\"net/http/httptest\"\n+\t\"testing\"\n+)\n+\n+// TestDiffAuth asserts the endpoint rejects unauthenticated callers before it\n+// ever touches herdr — same auth model as every other endpoint.\n+func TestDiffAuth(t *testing.T) {\n+\ts := newTestServer(t)\n+\tcases := []struct {\n+\t\tname   string\n+\t\theader string\n+\t}{\n+\t\t{\"no-token\", \"\"},\n+\t\t{\"bad-token\", \"Bearer nope\"},\n+\t}\n+\tfor _, c := range cases {\n+\t\tt.Run(c.name, func(t *testing.T) {\n+\t\t\treq := httptest.NewRequest(http.MethodGet, \"/diff?pane=wN:p1\", nil)\n+\t\t\tif c.header != \"\" {\n+\t\t\t\treq.Header.Set(\"Authorization\", c.header)\n+\t\t\t}\n+\t\t\trec := httptest.NewRecorder()\n+\t\t\ts.handleDiff(rec, req)\n+\t\t\tif rec.Code != http.StatusUnauthorized {\n+\t\t\t\tt.Errorf(\"status = %d, want 401\", rec.Code)\n+\t\t\t}\n+\t\t})\n+\t}\n+}\n+\n+// TestDiffMissingPane covers the request-shape guard that runs after auth but\n+// before any herdr call.\n+func TestDiffMissingPane(t *testing.T) {\n+\ts := newTestServer(t)\n+\treq := httptest.NewRequest(http.MethodGet, \"/diff\", nil)\n+\treq.Header.Set(\"Authorization\", \"Bearer admin-tok\")\n+\trec := httptest.NewRecorder()\n+\ts.handleDiff(rec, req)\n+\tif rec.Code != http.StatusBadRequest {\n+\t\tt.Errorf(\"status = %d, want 400\", rec.Code)\n+\t}\n+}\n+"
    }
  ]
}
```

> A rename shows `old_path` set and `status: "renamed"`; its `diff` is keyed
> and rendered against the **new** path, same as any modified file.

---

## Errors

Error bodies are plain text (not JSON), matching the other endpoints.

| Status | When | Body (example) |
|---|---|---|
| `400` | `pane` query param missing | `want ?pane=<pane_id>` |
| `401` | missing/invalid bearer | `unauthorized` |
| `404` | no agent in that pane (or unknown pane) | `no such agent` |
| `502` | the underlying `git` invocation failed outright (not just "not a repo" — that degrades to an empty `files[]`, see above) | `git status …: <stderr>` |

---

## Implementation notes (for maintainers)

- Handler: `internal/server/diff.go` (`handleDiff`), registered at
  `mux.HandleFunc("/diff", …)` in `internal/server/server.go`.
- Core logic: `internal/gitdiff` (`gitdiff.Collect(cwd)`) — pure Go, unit- and
  integration-tested (`internal/gitdiff/gitdiff_test.go`) against a real
  temp git repo covering modify/add/delete/rename/untracked, independent of
  the HTTP layer.
- One `git diff HEAD` invocation covers every tracked file (staged,
  unstaged, or both) in a single process spawn; it's split back into
  per-file diffs client-side in Go rather than shelling out once per file.
- `git status --porcelain=v1 -z --untracked-files=all` — the `-z`
  NUL-delimits records so paths with spaces parse correctly, and
  `--untracked-files=all` expands an untracked *directory* into its
  individual files (git's default collapses a new directory to one opaque
  entry, which isn't what "here's what changed" should show).
