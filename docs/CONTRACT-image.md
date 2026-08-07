# CONTRACT — `POST /image` (attach a screenshot to a prompt)

The one feature on the roadmap that only makes sense on a phone: the screenshot
you just took, or the photo of the whiteboard, becomes something the agent can
look at — "why is this button misaligned?" with the misaligned button attached.
Feature #9 in [`RESEARCH-feature-ideas.md`](RESEARCH-feature-ideas.md).

**The whole trick is that no agent protocol is involved.** Coding agents read an
image when you hand them a *path* — Claude Code does, and so do the others. So
the bridge never learns any agent's attachment format and no agent needs a new
capability: the bridge's entire job is to put the bytes somewhere inside the
pane's own tree and answer with the path. The app then inserts that path as
ordinary text — into the transcript composer, or typed straight into the
terminal.

**The app does not send.** The path lands where the user is typing and they
write the prompt around it. Uploading an image is not, by itself, a message.

---

## Request

```
POST /image?pane=<pane_id>
Authorization: Bearer <bearer>
Content-Type: application/octet-stream

<raw image bytes>
```

| Part | Value |
|---|---|
| Method | `POST` |
| Path | `/image` |
| Query | `pane` — the Herdr `pane_id` (e.g. `wN:p1`), from `/snapshot`. Accepts the session-qualified `<session>/<pane>` form. **Required.** Any pane, agent or not — see below. |
| Body | The raw image bytes. Not multipart, not base64, no JSON envelope. |
| `Content-Type` | Ignored. The type is sniffed from the bytes (see below). |
| Auth header | `Authorization: Bearer <bearer>` — the per-device bearer from `/pair`, or the admin token (dev). |

### Why raw bytes and not multipart

Multipart exists to carry field names and filenames, and **a filename is the one
thing this endpoint must never accept**. Nothing about the written file is
client-controlled:

- the **pane** picks the directory (resolved to the agent's `cwd`),
- the **sniffed content type** picks the extension,
- the **bridge** picks the name.

A client that cannot name the file cannot escape the directory — path traversal
isn't defended against here so much as made unrepresentable. `?name=`,
`?filename=`, and `Content-Disposition` are all simply not read.

### Any pane, not only agent panes

The drop directory is resolved from the pane: **the agent's `cwd` when the pane
hosts one, the pane's own `cwd` when it doesn't** (`Server.paneDropCwd`).

Agent panes go first and share `Server.paneCwd` with `GET /diff` — they have to
agree, since an image written somewhere `/diff` wouldn't look is an image the
agent can't read. The agentless fallback is this endpoint's alone, and
deliberately: the app's terminal screen attaches to plain panes too and types
the returned path in as ordinary keystrokes, so a shell, a `vim`, or a program
Herdr doesn't recognise as an agent gets the same affordance. The result is a
path, and a path is just text — nothing here needs an agent to exist. `/diff`
stays agent-only because it asks a different question ("what did the agent
change?") that a pane without one cannot answer.

The pane's `cwd`, not its `foreground_cwd`: the drop directory should stay put
while the shell wanders, so retention keeps sweeping one place.

The one remaining `404` on this path is a pane Herdr reports **no** directory
for. There is nowhere to put the file, and inventing a location (a temp dir, the
bridge's own cwd) would hand back a path that pane cannot use.

### Accepted types

Sniffed with `http.DetectContentType` — the client's declared `Content-Type` is
never consulted, so a shell script uploaded as `image/png` is still a shell
script here, and is rejected.

| Sniffed | Extension |
|---|---|
| `image/png` | `.png` |
| `image/jpeg` | `.jpg` |
| `image/gif` | `.gif` |
| `image/webp` | `.webp` |

Anything else → `415`. SVG in particular is **not** accepted: it is markup, not
a raster image, and no coding agent reads it as a picture.

### Size cap

**10 MiB** (`imagedrop.MaxBytes`), inclusive — exactly 10 MiB is fine, one byte
more is `413`. Phones shoot 4–12 MP stills and a tailnet upload from a phone is
slow enough that anything larger is a mistake rather than a screenshot. The
handler buffers the whole body, so the cap doubles as the per-request memory
bound. A `Content-Length` past the cap is refused **without reading the body**.

---

## Where the file lands

```
<pane cwd>/.gothalo/images/<UTC timestamp>-<content hash>.<ext>
            ^^^^^^^^^^^^^^^ e.g. 20260805-142530-9f86d081.png
```

**Under the pane's own cwd, not a temp dir.** Agents are scoped to their
working directory and decline to read outside it, so `/tmp` would produce a path
the agent refuses. The tree the agent is working in is the tree the image has to
land in.

**Nested under `.gothalo/`** so everything the bridge ever writes into someone's
project shares one hideable, disposable root — and the first write drops a
catch-all `.gothalo/.gitignore` containing `*`. Without it every attached
screenshot shows up as an untracked file in `git status` on the desktop and in
gothalo's own `/diff` review screen, which asks for `--untracked-files=all`. The
`*` ignores the `.gitignore` itself too, so the directory is completely
invisible to the repo it lives in.

**The name is `<timestamp>-<content hash>.<ext>`.** The timestamp has one-second
resolution, so the hash (first 4 bytes of the SHA-256) is what keeps two uploads
within the same second off one name, without a counter or a lock. It also makes
a retried upload idempotent within that second. The clock is injected, not read
from `time.Now()`, so the produced name — and the retention sweep that follows —
are deterministic under test.

The bytes are written to a temp file in the same directory and `rename`d into
place. The app may hand the path to the agent the instant this returns, and an
atomic rename is the only way to guarantee the agent never opens a half-written
image.

### Retention

An image is a scratch artefact of a single prompt — the agent reads it during
that turn and never again — so a repo must not accumulate them. Every write
sweeps the drop directory, bounded both ways: **7 days** by age and **40 files**
by count, so neither a long-running repo nor one busy afternoon leaves junk
behind.

Ages are read back out of the **filename**, not from mtime. That keeps retention
a pure function of the injected clock (deterministic, and immune to a checkout
or a copy rewriting mtimes) and means a file the bridge did not write — a name
that doesn't parse — is counted by neither bound and is **never deleted**. This
code removes files from inside someone's repository; that is a place to be
conservative. Sweep failures are silent by design: retention must never fail the
upload that triggered it.

---

## Response `200` — schema

| Field | Type | Notes |
|---|---|---|
| `path` | string | **Absolute** path to the written file — what the app inserts into the composer and what the agent opens. Absolute rather than relative because the agent's cwd is not necessarily the shell's cwd by the time it reads the file. |
| `relative_path` | string | The same file relative to the agent's cwd (`.gothalo/images/…`), slash-separated. For display only. |
| `content_type` | string | What the bytes were **sniffed** as, not what the client claimed. |
| `bytes` | int | Size of the stored image. |

```json
{
  "path": "/Users/dipesh/projects/gothalo/.gothalo/images/20260805-142530-9f86d081.png",
  "relative_path": ".gothalo/images/20260805-142530-9f86d081.png",
  "content_type": "image/png",
  "bytes": 184320
}
```

---

## Errors

Error bodies are plain text (not JSON), matching the other endpoints.

| Status | When | Body (example) |
|---|---|---|
| `400` | `pane` query param missing | `want ?pane=<pane_id>` |
| `400` | empty body | `empty image body` |
| `401` | missing/invalid bearer | `unauthorized` |
| `404` | unknown pane/session, or a pane Herdr reports no cwd for | `pane has no working directory` |
| `405` | non-POST | `POST only` |
| `413` | body over the cap | `image exceeds the 10 MiB limit` |
| `415` | bytes are not png/jpeg/gif/webp | `unsupported image type: want png, jpeg, gif, or webp` |
| `500` | the drop directory could not be created or written, or the pane reported a relative cwd | `create .gothalo/images: permission denied` |
| `502` | herdr command failed while resolving the pane | *(herdr's error)* |

A bridge predating this endpoint answers `404` with the static file server's
body rather than a message of its own, and one predating agentless panes answers
`404` (`no such agent`) for a plain pane. The app treats any `404` on `/image` as
"this bridge is too old, update it" — which reads correctly in both cases — see
`BridgeVersion` (bumped to **2** for this endpoint) if you want to gate the UI
instead of trying and failing.

---

## Client flow (what the app does)

1. `image_picker` returns a file from the camera roll or camera.
2. Read it to bytes; refuse over the cap **locally** so the common mistake never
   costs a slow tailnet upload (the `413` remains the backstop).
3. `POST /image?pane=…` with a progress callback — a phone on a tailnet is slow
   enough that a silent upload reads as a hang.
4. On `200`, insert `path` where the user is typing, with a trailing space, and
   **do not send**:
   - the **transcript** composer inserts it at the cursor;
   - the **terminal** types it into the PTY over `WS /attach` — the same stream
     as every keystroke — with no carriage return, so whatever is running in the
     pane receives it as typed text.
   Either way a path containing whitespace is quoted, since a shell or an agent
   reading a bare path stops at the first space.
5. On failure, say so inline and leave what the user was typing untouched.

Both screens share one controller (`app/lib/features/attach/image_attach.dart`):
the pick → upload → report half is identical, only the destination differs.

---

## Implementation notes (for maintainers)

- Handler: `internal/server/image.go` (`handleImage`), registered at
  `mux.HandleFunc("/image", …)` in `internal/server/server.go`.
- Core logic: `internal/imagedrop` — `Detect` (validate + sniff) and `Save`
  (write + prune), both pure of HTTP and unit-tested in
  `internal/imagedrop/imagedrop_test.go`.
- `Detect` runs **before** the pane is resolved, so an oversized or non-image
  body is rejected without a Herdr round-trip.
- Pane → cwd is `Server.paneDropCwd` in `internal/server/pane.go`: it tries
  `Server.paneCwd` (the agent resolution shared with `GET /diff`) and falls back
  to `herdr pane get`'s own `cwd` when the pane hosts no agent. Both steps split
  the session-qualified id (`herdr.SplitTarget`) first, so the `<session>/`
  prefix is never forwarded to Herdr as part of the pane id.
- No new Go dependencies: sniffing is `net/http`, hashing is `crypto/sha256`.
