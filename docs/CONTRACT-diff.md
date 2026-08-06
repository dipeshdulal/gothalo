# CONTRACT — `GET /diff` (working-tree changes + git context) + `GET /diff/expand`

The "Changes" review screen's contract: an agent pane's pending git changes —
branch, and one unified diff per changed file — without dropping to the raw
terminal and running `git diff` by hand. Pairs naturally with the approval
bar: review what an agent actually did before approving its next action.

It also answers **"what is this pane's git situation?"** — branch, default
branch, remote, ahead/behind, dirty — as a `git` object on the same response,
and `?context=1` asks for that object *alone*. That is the read behind the app's
one-tap "Create PR" action, which must know whether opening a pull request from
this pane is even possible before it offers to. It lives here rather than on an
endpoint of its own because it is the same `git` shell-out against the same
resolved pane cwd; two endpoints would be two answers to one question.

Captured live against **gothalo itself mid-development** (the `feat/diff-endpoint`
branch, diffing its own new files) — a real multi-file capture, not a toy
example.

---

## Request

```
GET /diff?pane=<pane_id>[&context=1]
Authorization: Bearer <bearer>
```

| Part | Value |
|---|---|
| Method | `GET` |
| Path | `/diff` |
| Query | `pane` — the Herdr `pane_id` (e.g. `wN:p1`), from `/snapshot`. **Required.** |
| Query | `context` — `1`/`true` narrows the response to `branch` + `git` with an empty `files[]`. Any other value (or absent) returns the full diff. |
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
| `branch` | string | Best-effort; `""` on a detached HEAD or if git fails — never fails the whole request. The same value as `git.branch`, kept at the top level because the app read it before `git` existed. |
| `git` | object | The pane's git **situation** — see the table below. Always present (a bridge older than this omits it entirely; treat that as "unknown"). |
| `files` | array | One entry per changed file, in `git status` order. Empty (not absent) when the tree is clean or `cwd` isn't a git repo — "nothing to review" is a normal state, not an error. |
| `files[].path` | string | The file's current path (its new path for a rename). |
| `files[].old_path` | string \| absent | Set **only** for a rename/copy — the path it moved from. |
| `files[].status` | string | `"modified"` \| `"added"` \| `"deleted"` \| `"renamed"` \| `"untracked"`. |
| `files[].additions` | int | Lines added, counted from the diff itself. |
| `files[].deletions` | int | Lines removed. Always `0` for `"untracked"` — see below. |
| `files[].diff` | string | A **unified diff for this file alone** (one `diff --git …` section, not the whole tree's combined diff). May contain `\n`. |

### The `git` object

| Field | Type | Notes |
|---|---|---|
| `repo` | bool | The pane's cwd is inside a git work tree (`git rev-parse --is-inside-work-tree`), **detected on the host** — not inferred from the path. False makes every other field meaningless; they are all zero-valued in that case. |
| `branch` | string | The checked-out branch. `""` on a detached HEAD. An *unborn* branch (fresh `git init`, no commits) still names itself — this is `git symbolic-ref --short HEAD`, not `rev-parse --abbrev-ref`, which would answer the literal `"HEAD"` when detached. |
| `default_branch` | string | The repo's trunk — what a PR would target. `""` when git can't name one. |
| `default_ref` | string | The ref `ahead`/`behind` were actually counted against (`refs/remotes/origin/main`, `refs/heads/main`). Reported so a client can say what the comparison meant instead of guessing. |
| `remote` | string | The remote a push would go to: `origin` when it exists, else the first configured remote. `""` means there is nowhere to push. |
| `upstream` | string | The branch's tracking ref (`origin/feat/x`); `""` when it has never been pushed. |
| `ahead` | int | Commits on `HEAD` that `default_ref` doesn't have — the work a PR would contain. `0` when there is no `default_ref` to compare against. |
| `behind` | int | The reverse: commits on `default_ref` that `HEAD` doesn't have. |
| `dirty` | bool | The working tree has uncommitted changes, **untracked files included** (same `git status` read the file list comes from). |

**Everything is best-effort and nothing here is an error.** A repo with no
remote, no commits, or a detached HEAD is an ordinary state; the endpoint
reports it and lets the *client* decide what is disqualifying. The app's
"Create PR" gate, for instance, treats a dirty tree with zero commits ahead as
perfectly openable — committing is the first thing it asks the agent to do —
but refuses a detached HEAD, a missing remote, and the default branch itself.

**How `default_branch` is resolved**, first hit wins:

1. `refs/remotes/<remote>/HEAD` — what the remote itself says its HEAD is.
   Authoritative when present, but it is only set by a clone or an explicit
   `git remote set-head`, so a locally-`init`ed repo that later gained a remote
   has none.
2. The first of `main`, `master` that exists — remote-tracking ref before the
   local branch, since the remote-tracking ref is what a PR is actually opened
   against and a stale local `main` is common on a worktree checkout.

A repo whose trunk is neither reports `""` rather than a wrong guess, and a
client should degrade accordingly (the app drops the explicit base from its
prompt and lets `gh pr create` resolve the repo's own default).

### `?context=1` — the git object without the diff

```
GET /diff?pane=wN:p1&context=1
```
```json
{
  "branch": "feat/one-tap-pr",
  "git": {
    "repo": true,
    "branch": "feat/one-tap-pr",
    "default_branch": "main",
    "default_ref": "refs/remotes/origin/main",
    "remote": "origin",
    "upstream": "origin/main",
    "ahead": 3,
    "behind": 0,
    "dirty": true
  },
  "files": []
}
```

`files` is empty **and present** — the narrowed response is the same shape as
the full one, so one decoder handles both.

The reason it exists: diffing the working tree is the expensive half of this
endpoint, and a client deciding *whether to show a button* has no use for a
single line of diff. The full response carries the identical `git` object, so a
client already fetching the diff never needs a second call.

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
  "git": {
    "repo": true,
    "branch": "feat/diff-endpoint",
    "default_branch": "main",
    "default_ref": "refs/remotes/origin/main",
    "remote": "origin",
    "upstream": "",
    "ahead": 0,
    "behind": 0,
    "dirty": true
  },
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

# `GET /diff/expand` — the unchanged lines around a hunk

`git diff` ships **three** lines of context around each change, so everything
else in a changed file is simply absent from `/diff`. The app's "show the
unchanged lines between these two hunks" affordance therefore cannot be served
client-side no matter how the payload is parsed — the lines were never sent.

Two ways to fix that; this is the second:

- **Inflate every diff** (`git diff -U20`). Pays for context on every file, of
  every request, on a phone, to serve a tap most files never get — and still
  answers "what's the rest of this file?" with a bigger fixed guess.
- **Ask per tap.** One small request, only for the region actually opened,
  bounded and cacheable client-side. `/diff` itself is unchanged, so a client
  that never expands anything sends and receives exactly what it did before.

## Request

```
GET /diff/expand?pane=<pane_id>&path=<file>&start=<n>&count=<n>
Authorization: Bearer <bearer>
```

| Part | Value |
|---|---|
| `pane` | the Herdr `pane_id`, same as `/diff`. **Required.** |
| `path` | repo-relative path, exactly as it appeared in `files[].path`. **Required.** Absolute paths and anything escaping the pane's tree are refused. |
| `start` | 1-based **new-side** line number to start at. Clamped to ≥ 1. |
| `count` | how many lines to return. Clamped to 1…400. |

### It reads the working tree, and that is deliberate

The endpoint only ever fills gaps **between** hunks, and a line no hunk touches
is by definition identical on both sides of the diff — so the working-tree file
is a correct source for it, and the diff's new-side numbering is the right
index. Two consequences the app codes against:

- A **deleted** file has nothing to expand (its content exists only in `HEAD`).
- An **untracked** file's `/diff` entry already contains the whole file, so
  there is no gap to fill in the first place.

The app offers the affordance for neither.

## Response `200`

| Field | Type | Notes |
|---|---|---|
| `path` | string | Echoes the request, so a late response can be matched to the gap that asked for it. |
| `start` | int | 1-based line number of `lines[0]`, after clamping. |
| `lines` | array of string | The requested slice. Empty when `start` is past EOF. |
| `eof` | bool | `lines` runs to the end of the file — nothing further down to reveal. |
| `total` | int | The file's whole line count, so a client can size the region below the last hunk without a second request. |

```json
{ "path": "internal/server/diff.go", "start": 12, "lines": ["", "import (", "\t\"net/http\""], "eof": false, "total": 96 }
```

Out-of-range requests **clamp rather than fail**: asking for 400 lines from line
90 of a 96-line file returns 7 lines with `eof: true`. A client walking down a
file should not have to know where it ends before it asks.

## Errors

| Status | When | Body (example) |
|---|---|---|
| `400` | `pane` or `path` missing, or `path` is absolute / escapes the pane's tree | `bad path: ../../.ssh/id_rsa escapes the pane's tree` |
| `401` | missing/invalid bearer | `unauthorized` |
| `404` | no agent in that pane, or no such file in the working tree | `no such file: gone.go` |
| `415` | the file isn't UTF-8 text, or is over 4 MB | `not a text file: logo.png` |

---

## What consumes the `git` object — and what the bridge will not do

The app's **"Create PR"** action (`app/lib/features/pr/create_pr.dart`, offered
in the transcript composer's actions row) reads `?context=1` to decide whether
to show itself at all — `git.repo` — and then, in its sheet, why it can't
proceed if it can't: detached HEAD, no remote, sitting on the default branch,
nothing ahead and nothing uncommitted.

When it *can* proceed it sends a prompt to the pane's agent over `POST /send`
telling it to commit, `git push -u`, and run `gh pr create`. **The bridge never
runs `git push` or `gh pr create` itself, and this endpoint must not grow a
`POST` that does.** Three reasons, all deliberate:

- **Agent-agnostic.** Any agent Herdr can host has a shell; nothing about this
  is Claude-specific.
- **Credentials and judgement stay with the agent.** It has the `gh` auth, the
  repo's commit conventions, and the context to write a PR body worth reading.
- **It happens in the transcript**, where the user can watch each step and
  interrupt it — rather than inside an opaque HTTP call from a phone.

So `/diff` stays a **read**. It answers "what is the situation here?"; the agent
does the acting.

---

## Implementation notes (for maintainers)

- Handlers: `internal/server/diff.go` (`handleDiff`, `handleDiffExpand`),
  registered at `mux.HandleFunc("/diff", …)` / `("/diff/expand", …)` in
  `internal/server/server.go`.
- Core logic: `internal/gitdiff` (`gitdiff.Collect(cwd)`, and
  `gitdiff.ReadContext(cwd)` for the `?context=1` path) — pure Go, unit- and
  integration-tested (`internal/gitdiff/gitdiff_test.go`) against real temp git
  repos covering modify/add/delete/rename/untracked, detached HEAD, an unborn
  branch, and a cloned repo with a real `origin/main`, independent of the HTTP
  layer.
- `Collect` fills the same `git` object from the status read it is already
  doing, so the full response costs no extra `git status` over the context-only
  one.
- The app does **not** gate on `BridgeVersion` for either of these: an older
  bridge simply omits `git` (which decodes to "not a repo") and 404s
  `/diff/expand` (which degrades to a diff with three lines of context) — the
  endpoint answering is what unlocks each of them.
- One `git diff HEAD` invocation covers every tracked file (staged,
  unstaged, or both) in a single process spawn; it's split back into
  per-file diffs client-side in Go rather than shelling out once per file.
- `git status --porcelain=v1 -z --untracked-files=all` — the `-z`
  NUL-delimits records so paths with spaces parse correctly, and
  `--untracked-files=all` expands an untracked *directory* into its
  individual files (git's default collapses a new directory to one opaque
  entry, which isn't what "here's what changed" should show).
- `gitdiff.ExpandContext(cwd, path, start, count)` backs `/diff/expand`; it
  returns typed sentinels (`ErrBadPath`, `ErrNoSuchFile`, `ErrNotText`) so the
  handler maps each refusal to its own status instead of one catch-all.
  Traversal is rejected by resolving the path against `cwd` and checking the
  result still sits under it — `path` arrives on a query string, so
  `../../.ssh/id_rsa` is a request that will show up eventually.
- **Everything else the viewer knows is derived in the app**, not here: the
  directory tree, the hunk/line structure, and the word-level intra-line
  highlighting are all computed from `files[].diff`
  (`app/lib/features/diff/diff_model.dart`, `diff_tree.dart`). Deriving them
  client-side keeps this contract small and means an older bridge still renders
  correctly in a newer app.
