# CONTRACT — `GET /browse` (host directory picker)

The contract the **mobile app** builds its "open a project" directory picker
against. `GET /browse` is a **read-only, directories-only** view of the host's
filesystem: enough for the phone to point at a directory and open it as a Herdr
space, and deliberately nothing more.

It exists for one case the rest of the API cannot serve. Every other creating
endpoint needs something already open to hang off — `pane.split` needs a pane,
`tab.create` needs a workspace, `/agent/start` needs one of those. On a Herdr
session with **no workspaces at all** there is nothing to hang off, so the app
has to be able to *name* a directory, and it has no way to know what is on the
host. This endpoint is that knowledge, handed over one directory at a time.

Verified against **herdr 0.8.0, protocol 19**. The captured payloads below are
real output from `internal/browse` running against this host.

---

## Envelope

**Request** — `GET /browse`, auth required (per-device `Authorization: Bearer
<bearer>` or `?token=`; the admin token also works for dev):

| query | meaning |
|---|---|
| `path` | absolute directory on the host. **Omit it** to start at the first root (the operator's home directory). |
| `hidden` | `1` to include dot-directories. Anything else, or absent, excludes them. |

**Success** `200` — one directory's browsable children plus the navigation
context:

```json
{
  "path": "/Users/alex/projects",
  "parent": "/Users/alex",
  "is_repo": false,
  "roots": [
    { "path": "/Users/alex", "label": "Home", "kind": "home" }
  ],
  "entries": [
    { "name": "acme", "path": "/Users/alex/projects/acme",
      "is_repo": false, "is_symlink": false },
    { "name": "eve-test", "path": "/Users/alex/projects/eve-test",
      "is_repo": false, "is_symlink": false, "open_workspace_id": "wQ" },
    { "name": "gothalo", "path": "/Users/alex/projects/gothalo",
      "is_repo": true, "is_symlink": false, "open_workspace_id": "wN" },
    { "name": "vim-herdr-navigation", "path": "/Users/alex/projects/vim-herdr-navigation",
      "is_repo": true, "is_symlink": false }
  ],
  "truncated": false,
  "limit": 500
}
```

| field | meaning |
|---|---|
| `path` | the **resolved** directory being listed. Not necessarily the string you asked for — symlinks and `..` are expanded, so `/tmp/x` comes back as `/private/tmp/x` on macOS. Navigate with what comes back. |
| `parent` | the directory above `path`, or `""` when `path` **is a root**. That empty string is how the app knows to stop offering "up"; it does not have to track the roots itself. |
| `is_repo`, `open_workspace_id` | the same two facts about `path` **itself** as on an entry (below). They are what make "open the directory I am standing in" behave identically to "open that one in the list" — including at a root, which was never an entry anywhere. `open_workspace_id` is omitted when absent. |
| `roots` | every directory this device may browse (see below). Always present, so the picker can offer "start over" without a second call. |
| `entries` | the directories inside `path`. Sorted by name. **Never contains a file.** |
| `truncated` | `true` when the directory held more than `limit` browsable children. |
| `limit` | the cap (`500`). |

Entry fields:

| field | meaning |
|---|---|
| `name` | the directory's own name. |
| `path` | absolute path — pass it straight back as `?path=` to descend. |
| `is_repo` | the directory holds a `.git` (a directory for a normal checkout, a file for a linked worktree). **This decides which Herdr method opens it** — see below. |
| `is_symlink` | the entry is a symlink. Only ever present when the target resolved back inside the roots. |
| `open_workspace_id` | omitted unless a Herdr workspace is **already open** at this directory. Session-qualified (`"acme/w3"`), so it addresses `/overview` and the proxy directly. Offer "go there", not a second space on the same tree. |

**Error** — plain text with an HTTP status, matching the other non-proxy
endpoints:

| status | when | body |
|---|---|---|
| `200` | success | the listing above |
| `400` | `path` is not absolute (relative, `~/…`, empty-but-present) | `path must be absolute` |
| `401` | no / invalid bearer or token | `unauthorized` |
| `403` | `path` resolved outside the allowed roots, **or** is not readable | `path is outside the allowed roots` / `directory is not readable` |
| `404` | `path` is inside the roots but missing, or is a file | `no such directory` |
| `405` | non-GET | `GET only` |
| `503` | the host offered no browsable roots at all (no home directory and no open spaces) | `no browsable directories on this host` |

---

## Roots — what the phone may see

`roots` is derived on the host per request. Nothing is configured and nothing is
sent by the client:

1. the operator's **home directory** (`os.UserHomeDir`), and
2. the **parent** of every directory Herdr already has a workspace open at,
   plus the parent of that workspace's repository root when it is a checkout.

An open space contributes its *parent*, not itself, because the whole point of
the flow is to open a sibling of something already open — "the other repo in
`~/projects`". A root at the space itself could only ever browse into it.

Two rules stop that from quietly widening the boundary:

- a parent that is an **ancestor of the home directory** is dropped. A space
  sitting directly in `~` would otherwise contribute `/Users`, i.e. every
  account on the machine.
- the **filesystem root** is never a root.

What survives is then collapsed, so a root already covered by another does not
appear twice. On a typical host every project lives under `~`, so this reduces
to a single `Home` root — the capture above is exactly that, from a session with
19 workspaces open.

Roots are recomputed on **every** request rather than cached: sessions and
spaces come and go, and a stale root is either a hole in the boundary or a
directory the app cannot reach.

---

## The containment rules (what "read-only" actually means here)

These are the rules the tests in `internal/browse/browse_test.go` exist for.
They are the security story, so they are stated rather than implied:

- **Resolve, then check.** A requested path goes through
  `filepath.EvalSymlinks`, which expands symlinks *and* `..` in the order the
  kernel does, and the **result** is checked for containment. A lexical
  `filepath.Clean` is not enough and is not used for the decision: it resolves
  `..` against a symlink's own path rather than its target, so
  `<root>/link-to-elsewhere/..` reads as inside the root while the kernel walks
  out of it. That exact case is a test.
- **`..` is resolved, not banned.** `<root>/projects/../projects` is fine; it
  lands back inside. `<root>/../..` is not.
- **Containment is separator-terminated.** `/srv/appdata` is not inside
  `/srv/app`.
- **Symlinked entries are followed, then re-checked.** A link out of the roots
  is simply not in the listing — it is not an error and not an escape hatch. A
  link that stays inside is listed and marked `is_symlink`.
- **Files never appear**, are never opened, and listing one is a `404`. There is
  no field anywhere in this contract that carries file contents, sizes or names.
- **Missing does not leak.** A path that fails to resolve is only reported as
  `404` when it is *lexically* inside a root. Outside, the answer is the same
  `403` whether the path exists or not — otherwise "does `/etc/shadow` exist"
  would be answerable by anyone holding a bearer.
- **Dot-directories are excluded** unless `hidden=1`.
- **Results are capped** at 500 per directory and truncation is reported, never
  silent.

### What this is *not* protecting against

A paired device can already run arbitrary commands on the host through `/send`
(it types into a shell), so this endpoint is not the thing standing between a
compromised phone and the filesystem. What it avoids is a **standing disclosure
of the host's filesystem layout** through a plain read endpoint — the kind that
is trivially harvested, needs no agent pane to exist, and survives in a log or a
cache after the device is revoked. Narrow because there is no reason for it to
be wide, not because it is the last line of defence.

For the same reason, `POST /herdr` does **not** restrict `workspace.create`'s
`cwd` to the browse roots. Opening a space starts a shell somewhere; a device
that can type into a shell can already `cd`. Enforcing the roots there would be
theatre, and it would break the legitimate case of opening a path the operator
typed by hand.

---

## Opening the picked directory

`GET /browse` only finds the directory. Opening it is `POST /herdr` (see
[`CONTRACT-herdr-proxy.md`](./CONTRACT-herdr-proxy.md)), and **which method
depends on `is_repo`**:

| `is_repo` | method | params | why |
|---|---|---|---|
| `true` | `worktree.open` | `{ "cwd": <path>, "path": <path> }` | attaches the repo metadata Herdr groups a project and its worktrees by, and is **idempotent** — a second call returns the existing workspace with `already_open: true` instead of opening a duplicate space on the same tree. |
| `false` | `workspace.create` | `{ "cwd": <path>, "label"?: <name> }` | takes *any* directory. A project that is not a git repository still needs a space. |

`worktree.open` needs **both** `cwd` and `path`. With `path` alone Herdr answers
`not_git_worktree` even for a valid checkout — `cwd` is what it resolves the
repository from. Verified on herdr 0.8.0; see the proxy contract for the
captured exchange.

Both return a `workspace` whose `workspace_id` is session-qualified, which is
what the app navigates to.

---

## Multi-session

The filesystem is the same host whatever Herdr session you are in, so `/browse`
is **not** session-scoped: roots are pooled across every running session and
`open_workspace_id` is qualified so the app can tell which session already has a
directory open.

Choosing a session matters at the *opening* step, not the browsing step — see
the `session` field in [`CONTRACT-herdr-proxy.md`](./CONTRACT-herdr-proxy.md).

---

## Implementation notes (for maintainers)

- Rules and listing: `internal/browse` (`Roots.Resolve`, `Roots.List`,
  `NewRoots`). The package holds no HTTP and no Herdr — it is the containment
  logic and nothing else, which is why the traversal tests can be exhaustive.
- Handler: `internal/server/browse.go` (`handleBrowse`), registered at
  `mux.HandleFunc("/browse", …)` in `internal/server/server.go`.
- Open spaces come from `herdr.(*Manager).OpenSpaces()`, which reads one
  `session.snapshot` per running session (no git, no enrichment) and takes each
  workspace's `worktree.checkout_path`, falling back to its first pane's `cwd`.
  A session whose snapshot fails is skipped — losing one session's project
  directories is better than losing the browser.
- `BridgeVersion` 6. The app gates the picker on the endpoint *answering*
  rather than on the number: an older bridge 404s and the sheet says so.
