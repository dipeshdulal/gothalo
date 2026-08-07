# CONTRACT — `GET /branch-info` + `POST /branch-delete` (delete a worktree's branch)

The contract behind **"also delete the branch"** in the app's *Remove worktree?*
confirm.

Herdr's `worktree.remove` (via [`POST /herdr`](./CONTRACT-herdr-proxy.md))
deletes the checkout and closes the workspace, and stops there. Herdr has **no
notion of branches** — no socket method creates, lists or deletes one — so the
branch the worktree was on survives every removal and nothing else in the system
ever picks it up. Now that creating a worktree from a phone is one tap, those
refs accumulate faster than anyone prunes them, and a phone is the one place
with no way to prune.

So this is the one endpoint pair that reaches **past Herdr and drives git
directly**. That is a deliberate exception, justified by there being no Herdr
method to proxy — the same reasoning as [`/diff`](./CONTRACT-diff.md) reading
the working tree and `internal/transcript` reading agent session files.

Verified against **herdr 0.8.0, protocol 19** for the `worktree.list` half, and
against real git repositories (throwaway repos in
`internal/gitbranch/gitbranch_test.go`, plus a live read of this repo) for
everything else.

---

## Why two endpoints and not one

They answer at two different moments, either side of an operation that can fail:

```
1. GET  /branch-info?workspace_id=wN     ← workspace still exists; names the
                                            branch and its merge state
2. (user confirms)
3. POST /herdr {"method":"worktree.remove", …}
4.    ↳ failed?  STOP. Never attempt the branch.
5. POST /branch-delete {repo_root, branch, force}
                                          ← workspace is gone; git will now
                                            allow the ref to be deleted
```

The preflight **must** run while the workspace exists — it is what names the
branch and the repo root. The delete **must** run after the checkout is gone —
git refuses to delete a branch that is checked out anywhere, and so does this
endpoint. And step 4 is the reason the two cannot be collapsed into one call: a
failed worktree removal must not be followed by a branch delete, and the caller
is the only party that knows whether step 3 succeeded.

`/branch-delete` takes `repo_root` + `branch` rather than a workspace id for the
same reason: by the time it is called, the workspace id no longer resolves.
Both values come from the preflight response, so the client never reconstructs
them from a path.

---

## `GET /branch-info`

```
GET /branch-info?workspace_id=<id>
Authorization: Bearer <bearer>
```

| Part | Value |
|---|---|
| Method | `GET` |
| Query | `workspace_id` — the same Herdr workspace id passed to `worktree.remove`, optionally session-qualified (`acme/w7`). **Required.** |
| Body | none |
| Auth | per-device bearer from `/pair`, or the admin token (dev) |

The bridge resolves the branch by asking Herdr `worktree.list` for that
workspace and taking the entry whose `open_workspace_id` matches — **not** by
parsing the checkout path. A Herdr worktree directory is named after the branch
it was *created* for (`…/worktrees/gothalo/feat-image-to-agent`), and that stops
being true the moment anyone switches branches inside it — observed live on this
very host, where that directory sits on `feat/transcript-session-rotation`.

### Response `200` — schema

| Field | Type | Notes |
|---|---|---|
| `workspace_id` | string | Echoed back, as given. |
| `repo_root` | string | The repository's **main** checkout, from Herdr's `worktree_list.source.repo_root`. Echo into `/branch-delete`. |
| `checkout_path` | string | This space's own worktree directory. |
| `branch` | string | The branch that worktree is on. `""` when there is none to offer. |
| `default_branch` | string | **Resolved, not assumed** — see below. `""` when it could not be determined. |
| `is_default` | bool | The branch IS the default branch. Never deletable. |
| `checked_out_elsewhere` | string[] | Worktrees **other than** `checkout_path` still holding the branch. Non-empty ⇒ not deletable: removing this space does not free the ref. This space's own checkout is excluded on purpose — it is the thing being removed, so it is not an obstacle. |
| `merged` | bool | The branch is an ancestor of the default branch: deleting loses nothing. |
| `merged_into` | string | Which ref proved it — `"main"` or `"origin/main"`. `""` when unmerged. |
| `unmerged_commits` | int | Commits on the branch and not in the default branch. `0` when `merged`. |
| `upstream` | string | Tracking ref (`origin/feat/x`), `""` when none. **Deleting locally never touches it.** |
| `deletable` | bool | Could be deleted once the worktree is gone — *including* the unmerged case, which is possible but requires `force`. |
| `blocked_reason` | string | A sentence, when `deletable` is false. `""` otherwise. |

### `deletable` includes the unmerged case on purpose

`deletable: true, merged: false` means "possible, but it costs commits". The
client is expected to make that a **different** confirmation from the merged
case, not the same tap. The app does: ticking the checkbox for an unmerged
branch opens a second dialog naming the commit count, and the box only becomes
ticked if that is accepted.

### "Not a branch to offer" is a `200`, not an error

A space with nothing on offer answers `200` with `deletable: false`, a
`blocked_reason`, and usually an empty `branch`. Four cases:

| Case | `blocked_reason` |
|---|---|
| Workspace is not in a git repo (Herdr `not_git_worktree`), or Herdr has no worktree open as it | `this space is not a git worktree` |
| The worktree is on a detached HEAD | `this worktree is on a detached HEAD, not a branch` |
| The space is the repository's **main** checkout, not a linked worktree | `this space is the repository's main checkout` |
| Herdr reported no repo root | `herdr did not report a repo root for this space` |

The last two matter: the main checkout's branch is not litter, and "remove
worktree" does not apply to it, so it is never on offer even though it looks
like a worktree from the app's side.

### Example

```json
→ GET /branch-info?workspace_id=w1F

← 200
{
  "workspace_id": "w1F",
  "repo_root": "/Users/…/projects/gothalo",
  "checkout_path": "/Users/…/.herdr/worktrees/gothalo/feat-one-tap-pr",
  "branch": "feat/one-tap-pr",
  "default_branch": "main",
  "is_default": false,
  "checked_out_elsewhere": [],
  "merged": false,
  "merged_into": "",
  "unmerged_commits": 2,
  "upstream": "origin/feat/one-tap-pr",
  "deletable": true,
  "blocked_reason": ""
}
```

---

## `POST /branch-delete`

```
POST /branch-delete
Authorization: Bearer <bearer>

{ "repo_root": "/Users/…/projects/gothalo",
  "branch": "feat/one-tap-pr",
  "force": false }
```

| Field | Type | Notes |
|---|---|---|
| `repo_root` | string | **Required.** Absolute, canonical (no `..`, `.`, `//`), existing directory — the same guard `/agent/start` applies to a caller-supplied path. |
| `branch` | string | **Required.** Rejected if empty or starting with `-`. |
| `force` | bool | Opt-in to losing unmerged commits. Defaults to `false`. **Overrides exactly one rule** — see below. |

### Response `200`

| Field | Type | Notes |
|---|---|---|
| `branch` | string | |
| `deleted` | bool | Always `true` on a `200`. |
| `forced` | bool | Whether `git branch -D` was the command actually run. **Not** an echo of the request: forcing an already-merged branch still deletes with `-d`, and reports `forced: false`, because nothing was dropped. |
| `merged` / `merged_into` | bool / string | State at the moment of deletion. |
| `sha` | string | The commit the branch pointed at, read **before** the delete. The only handle left for `git branch <name> <sha>` afterwards, which is why it is worth an extra `rev-parse`. |
| `upstream` | string | The tracking ref the branch had. |
| `remote_deleted` | bool | **Always `false`.** This never runs `git push --delete`. It is a field rather than a comment so the payload states it and no client has to infer it. |

```json
← 200
{ "branch": "feat/one-tap-pr", "deleted": true, "forced": true,
  "merged": false, "merged_into": "", "sha": "3f1c9ad",
  "upstream": "origin/feat/one-tap-pr", "remote_deleted": false }
```

---

## The safety rules

Implemented in `internal/gitbranch` and re-run on **every** `/branch-delete`,
never trusted from the preflight the client happens to be holding — that
preflight may be minutes stale, and the client is a phone.

1. **The default branch is never deleted, whatever it is called.** Resolved, in
   order: `refs/remotes/<remote>/HEAD` (the remote's own answer, preferring
   `origin`), then the first existing local branch among `main`, `master`,
   `trunk`, `develop`. If neither answers, the default branch is **unknown** and
   *nothing* in that repo is deletable — an unknown default makes both "is this
   the default" and "is this merged" unanswerable, and guessing `main` is the
   one failure mode with no recovery. `force` does not override this.
2. **A branch checked out in any worktree is never deleted** — main working tree
   or linked. Git refuses too, but checking up front means the app does not
   offer an impossible action, and the refusal *names the worktree in the way*,
   which git's own message does only for the main tree. `force` does not
   override this.
3. **Merged and unmerged are different operations.** Merged ⇒ `git branch -d`,
   unmerged ⇒ `git branch -D` and only with `force: true`. The least destructive
   command that can succeed is the one that runs.
4. **Order.** A branch delete is only legal once its worktree is gone; the
   caller owns that ordering and rule 2 enforces it.

`force` therefore buys exactly one thing: rule 3.

### Merged-ness is checked against the remote too

A branch is `merged` if it is an ancestor of the local default branch **or** of
`refs/remotes/<remote>/<default>`, and `merged_into` names which. Both are
consulted because they disagree constantly in this app's own workflow: the PR
was merged on the forge, `origin/main` knows, and the local `main` has not been
pulled in a week. Reporting that branch as unmerged would push the user down the
destructive path for a branch that loses nothing.

One consequence worth knowing: a branch merged **only** into `origin/main` is
reported `merged: true, merged_into: "origin/main"`, but `git branch -d` applies
its own local-only test and may still refuse it. That surfaces as a `409` with
git's own message, and the honest outcome — worktree gone, branch kept — is what
the client shows. Re-run after a `git pull` and it deletes cleanly.

### The remote branch is never touched

Deleting `feat/x` locally leaves `origin/feat/x` exactly where it was. Pushing a
deletion from a phone is a materially different act — it affects everyone, and
no other operation on this bridge reaches outside the host — so it is out of
scope here. `upstream` and `remote_deleted: false` exist so the UI can say what
it did *and did not* do rather than letting the user assume either way.

---

## Errors

Both endpoints use the normalized `{"error": "<message>"}` body (`401` is plain
text `unauthorized`, matching every other endpoint).

### `GET /branch-info`

| status | when |
|---|---|
| `200` | answered — including every "nothing to offer" case, which is `deletable: false` with a reason |
| `400` | missing `workspace_id` |
| `401` | no / invalid bearer |
| `404` | unknown Herdr session in a qualified id |
| `405` | non-GET |
| `502` | Herdr socket unreachable or another Herdr error |

A git failure while inspecting is **not** a `502`: it becomes
`deletable: false` with git's message as `blocked_reason`, because the removal
itself is still perfectly possible and must not be blocked by a side question.

### `POST /branch-delete`

| status | when | example body |
|---|---|---|
| `200` | deleted | see above |
| `400` | malformed body, missing field, bad `repo_root`, option-shaped `branch`, not a git repository | `{"error":"repo_root: cwd must be an absolute path, got \"x\""}` |
| `401` | no / invalid bearer | `unauthorized` |
| `404` | no local branch by that name | `{"error":"branch does not exist: feat/x"}` |
| `405` | non-POST | `{"error":"POST only"}` |
| `409` | **a safety rule said no** — default branch, unresolvable default, checked out somewhere, unmerged without `force`, or git refused | `{"error":"branch is not merged: feat/x has 2 commit(s) not in main"}` |

`409` is the important one: the request was well-formed and understood, and the
**repository's state** is what refused. A client should show its message rather
than treating it as a failure — "worktree removed, branch kept, here's why" is a
normal outcome of this flow, not an error.

---

## What the app does with it

`removeWorktree` in `app/lib/features/herdr_actions.dart`:

- calls `/branch-info` **before** showing the confirm, so the dialog names the
  branch and states its merge status up front;
- offers the delete as a checkbox that is **off by default** — removing a
  worktree is recoverable (`worktree.open` brings it back), deleting a branch is
  much less so, and a phone is where a mis-tap is most likely;
- for an unmerged branch, ticking the box opens a second dialog naming the
  commit count; only accepting that ticks it, and only then is `force: true`
  sent;
- shows a branch it *cannot* delete anyway, with the reason, instead of silently
  leaving it behind;
- states that the upstream survives whenever there is one;
- degrades to exactly the old dialog when `/branch-info` cannot be reached (a
  bridge older than `BridgeVersion` 6 `404`s) — removing a worktree must not get
  harder because a side question went unanswered;
- reports the real outcome, including the partial one:
  `Worktree removed · branch feat/x kept: <reason>`.

---

## Implementation notes (for maintainers)

- Handlers: `internal/server/branch.go` (`handleBranchInfo`,
  `handleBranchDelete`), registered in `internal/server/server.go`.
- Git logic and every safety rule: `internal/gitbranch`. The rules live there,
  not in the handler, so they hold for any caller; `Info.Deletable(force)` is
  the single predicate both endpoints answer from.
- `worktree.list` is reached through the same `herdrRequester` seam the
  `/herdr` proxy uses, so the handler is testable without a live socket.
- Path comparison between Herdr's `checkout_path` and git's `worktree list`
  output goes through `filepath.Clean` **and** `EvalSymlinks`: on macOS git
  reports `/private/var/…` where Herdr reports `/var/…`, and a mismatch would
  leave a space looking like it blocks its own branch.
- Every git invocation is bounded by a 15s timeout, for the same reason as
  `internal/gitdiff`: a held `index.lock` or a stalled filesystem would
  otherwise hang the HTTP handler indefinitely.
- To extend: nothing about this is allowlist-driven. It is a typed endpoint
  pair precisely because "params verbatim" would mean no server-side
  validation, which is the one thing this feature cannot do without.
