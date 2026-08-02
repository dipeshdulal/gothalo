# gothalo pane-control contract (for the Flutter app)

What `feat/pane-control` adds/changes for the mobile side. Two things:

1. **`GET /attach` now works for ANY pane** — plain shells, dev-servers, logs, not
   just agent panes. The WS frame contract is **unchanged**.
2. **New endpoints to create/close a terminal from mobile** — `POST /pane/new`
   returns a usable `pane_id` you then `/attach` to; `POST /pane/close`.

Everything below was captured against a running bridge (`gothalo serve`) driving a
live Herdr session. Auth is identical to the rest of the API.

## Auth (unchanged)
- **Header**: `Authorization: Bearer <bearer>` on every request.
- **Query fallback**: `?token=<bearer>` — required for the WebSocket (`/attach`),
  accepted everywhere. The admin token also works (dev/testing).
- Missing/invalid token → **401**.

---

## 1. `GET /attach` — live terminal for ANY pane  (CHANGED)

```
GET /attach?pane=<pane_id>&token=<bearer>        → WebSocket upgrade
```

**It now accepts any `pane_id`** (agent OR plain shell/dev-server/logs). The
bridge picks the backend by pane kind automatically; the client cannot tell them
apart and does not need to.

### WS frame contract — UNCHANGED (binary, raw bytes both ways)
- **terminal → WS**: server sends **binary** frames of **raw terminal bytes**.
  Feed them straight into your terminal emulator (`xterm.dart`).
- **WS → terminal**: send **binary** frames of **raw keystrokes/control bytes**
  (Enter `0x0d`, Esc `0x1b`, Ctrl-C `0x03`, arrows `\e[A`…). Forwarded verbatim to
  the pane's PTY.
- A **non-binary** frame tears the connection down (`1003`). Same as before.
- Backend is stopped when the socket closes (either side). Reconnect + re-fetch
  `/snapshot` is the resilience story. Resize not yet wired (starts 80×24).

Backends (informational — no client impact):
- **Agent pane**: `herdr agent attach` under a PTY, copied byte-for-byte. This is
  the *exact* prior behavior, untouched.
- **Plain pane**: bridge polls `herdr pane read` (~5×/s) and repaints
  (cursor-home + clear + frame); inbound bytes go to `herdr pane send-text`. So a
  plain pane is a full-frame repaint stream that refreshes on a short interval
  (not per-character), but bytes both directions are still raw terminal bytes.

### Verified
Attached to a **plain shell pane** `w4:p7` over the WebSocket:
- received the initial repaint as a **binary** frame (164 bytes),
- sent `echo WS_ATTACH_MARKER_42\r` as one binary frame → the shell ran it and the
  output streamed back in subsequent frames.
Attaching to an **agent pane** `w5:p18` still streams (binary frame received),
unchanged.

### Errors (returned as HTTP status *before* the WS upgrade)
| Status | When |
|---|---|
| `400` | missing `pane` (`want ?pane=<pane_id>`) |
| `401` | missing/invalid token |
| `404` | `pane` does not exist |
| `500` | (agent path) PTY failed to start |

---

## 2. `POST /pane/new` — create a terminal, get its `pane_id`  (NEW)

Creates a pane and returns its identity so the app can immediately `/attach` to
it. Two modes, chosen by the body. **`split_from` wins if both are present.**

**Headers**: `Authorization: Bearer <bearer>` · `Content-Type: application/json`

### Body schema
| Field | Type | Notes |
|---|---|---|
| `split_from` | string | pane id to split — **mode A** |
| `workspace_id` | string | workspace to add a new tab to — **mode B** |
| `direction` | string | `"right"` \| `"down"`, split only, defaults to `"down"` |
| `cwd` | string | optional working dir for the new shell |
| `label` | string | optional new-tab label (mode B) |
| `command` | string | optional command line, typed + run in the new pane |
| `tab_id` | string | reserved/ignored today — use `split_from` to target a tab |

### Mode A — split an existing pane
Request:
```json
{ "split_from": "w4:p1", "direction": "down" }
```
Response `200` (captured):
```json
{ "pane_id": "w4:p9", "tab_id": "w4:t1", "workspace_id": "w4" }
```

### Mode B — new tab in a workspace (with a command)
Request:
```json
{ "workspace_id": "w4", "command": "echo HELLO_FROM_MOBILE" }
```
Response `200` (captured):
```json
{ "pane_id": "w4:p7", "tab_id": "w4:t5", "workspace_id": "w4" }
```
(The command was typed and run in the new pane; verified via `herdr pane read`.)

Then attach: `GET /attach?pane=w4:p7&token=<bearer>`.

### Errors
| Status | When | Example body |
|---|---|---|
| `400` | neither `split_from` nor `workspace_id` (or bad JSON) | `want {split_from} or {workspace_id}` |
| `401` | missing/invalid token | `unauthorized` |
| `404` | unknown pane/workspace | `herdr pane split zz:p9 …: {"error":{"code":"pane_not_found",…}}` |
| `502` | herdr command failed | herdr stderr |

Note: if `command` is set but fails to run, the pane is **still created and
returned `200`** (the failure is logged server-side) — the app can attach anyway.

---

## 3. `POST /pane/close` — close a pane  (NEW, optional)

**Headers**: `Authorization: Bearer <bearer>` · `Content-Type: application/json`

Request:
```json
{ "pane_id": "w4:p9" }
```
Response `200` (captured):
```json
{ "closed": true, "pane_id": "w4:p9" }
```
Closing a tab's last pane closes the tab too (Herdr's own behavior).

### Errors
| Status | When | Example body |
|---|---|---|
| `400` | missing `pane_id` (or bad JSON) | `want {pane_id}` |
| `401` | missing/invalid token | `unauthorized` |
| `404` | unknown pane | `herdr pane close zz:p9: {"error":{"code":"pane_not_found",…}}` |
| `502` | herdr command failed | herdr stderr |

---

## Typical mobile flow
1. `POST /pane/new { "workspace_id": "w4", "command": "npm run dev" }`
   → `{ "pane_id": "w4:p7", … }`
2. Open WS `GET /attach?pane=w4:p7&token=<bearer>` → render binary frames, send
   keystrokes as binary frames.
3. When done, `POST /pane/close { "pane_id": "w4:p7" }`.
