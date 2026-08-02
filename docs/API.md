# gothalo bridge — API contract (for the mobile app)

This is the contract the app codes against. The backend was rebuilt into a
`gothalo` CLI + bridge with **QR pairing** and **per-device bearer tokens**.

## Base URL
```
https://my-mac.tailnet.ts.net:5338
```
The gothalo bridge, reachable over the tailnet (valid TLS) on port **5338**. The
base URL is not hardcoded in the real flow — the app derives it from the pairing
QR's origin (a tailnet URL today, a relay URL later).

## Auth model
- **Per-device bearer** (normal): every request sends
  `Authorization: Bearer <bearer>`, where `<bearer>` is returned by `/pair`.
- **Dev shortcut** (until the pairing UI exists): you may use the **admin token**
  as the bearer for manual testing. Get its value from the operator, or from
  `~/.gothalo/config.json` (`admin_token`) / the `gothalo serve` startup log —
  it is not committed. It also unlocks the admin endpoints below (so you can mint
  your own pairing codes for testing). Treat it as dev-only.

## Pairing flow (the real onboarding)
1. Operator runs `gothalo pair` on the host; it prints a QR encoding a small JSON
   payload:
   ```json
   { "url": "https://my-mac.tailnet.ts.net:5338", "code": "<8-hex one-time code>" }
   ```
2. App scans the QR and parses the JSON — `url` is the bridge base URL, `code` is
   the one-time code — then:
   ```
   POST <url>/pair
   Content-Type: application/json
   { "code": "<code>", "device_name": "Dipesh S22", "fcm_token": "<this device's FCM token>" }
   ```
   The device names itself via `device_name` (defaults to "device" if omitted).
3. Response `200`:
   ```json
   { "id": "92787cfa", "bearer": "<64-hex per-device bearer>", "name": "Dipesh S22" }
   ```
   Store `{ baseUrl: url, bearer }` in secure storage; use `bearer` for all calls.
   Errors: `403` invalid/expired/already-used code · `400` bad body.

   Codes are **one-time** and expire in ~5 min.

To mint a code yourself for testing (admin token):
```
POST /admin/pairing?token=<admin>   ->  { "code", "url" }
```

## Endpoints (per-device bearer)
| Method | Path | Body | Response | Notes |
|---|---|---|---|---|
| GET  | `/snapshot` | — | raw Herdr snapshot JSON | live agent state (shape below) |
| POST | `/send` | `{pane, text}` | `{ok:true}` | types text into a pane |
| POST | `/approve` | `{agent, seq}` | `{ok:true,applied:bool,reason?}` | idempotent one-tap approval (below) |
| GET  | `/attach` | — (query: `pane`, `token`) | **WebSocket** | live terminal for **any** pane (below) |
| POST | `/pane/new` | `{split_from\|workspace_id, …}` | `{pane_id,tab_id,workspace_id}` | create a terminal, attach to it (below) |
| POST | `/pane/close` | `{pane_id}` | `{closed:true,pane_id}` | close a pane (below) |
| POST | `/register-token` | `{token}` | `{ok:true}` | call on FCM token refresh to update THIS device |
| POST | `/testpush` | — | `{ok:true,sent:true}` | fan a sample push to all devices (test your FCM handler) |

### /snapshot shape (what to render in the inbox)
```json
{ "result": { "snapshot": { "agents": [
  { "agent": "claude",
    "agent_status": "idle|working|blocked|done|unknown",
    "pane_id": "wN:p2",
    "state_change_seq": 42,
    "terminal_title_stripped": "…",
    "workspace_id": "wN",
    "cwd": "/…" }
] } } }
```
Group by `workspace_id`; badge on `agent_status`; title = `terminal_title_stripped`;
`pane_id` is the id used for `/send`, `/approve`, and `/attach`.
`state_change_seq` is a per-agent monotonic counter Herdr bumps on every state
transition — pass it to `/approve` as the idempotency token (see below).

## Push messages (what your FCM handler receives)
Messages are **data-only** (no `notification` block) so your handler always runs
and renders the notification itself (reliable on locked Android). Data keys:
```
title             e.g. "Herdr agent blocked"
body              the agent's terminal title
agent             the pane_id (e.g. "wN:p2")  -> deep-link target
status            "blocked" | "done"
state_change_seq  the agent's seq at this transition (string int) -> pass to /approve
```
Render a local notification from `title`/`body`; tapping it should deep-link to
the agent identified by `agent` (== `pane_id`). Carry `state_change_seq` into any
lock-screen/banner **Approve** action so `/approve` can no-op a stale tap (D8).

### Native FCM setup
Add an **Android app** to Firebase project **YOUR_PROJECT_ID** → download
`google-services.json` into `android/app/`. Get the device token via
`firebase_messaging`, pass it as `fcm_token` during `/pair`, and
`POST /register-token {token}` whenever it refreshes.

## POST /approve — idempotent one-tap approval (D8)
One-tap "yes" for a **blocked** agent, safe to fire from a stale lock-screen
banner. The bridge sends the agent's confirm keystroke **only if** the agent is
still blocked at the `seq` you carried; otherwise it no-ops and tells you why.
```
POST /approve
{ "agent": "wN:p2", "seq": 42 }        // seq == the agent's state_change_seq
```
Response `200` (always `200` — `applied` tells you what happened):
```json
{ "ok": true, "applied": true }                                  // confirm keystroke sent
{ "ok": true, "applied": false, "reason": "agent is working, not blocked" }
{ "ok": true, "applied": false, "reason": "stale seq: approve carried 42, agent now at 45" }
{ "ok": true, "applied": false, "reason": "no such agent" }
```
The confirm keystroke is chosen per agent **kind** (`claude`, `codex`, …) from a
small server-side map, defaulting to **Enter** for unknown kinds — so the guard
and the key selection both live in the bridge and every approval surface inherits
them. `400` if the body lacks `agent`.

## WS /attach — live terminal (any pane)
`GET /attach?pane=<pane_id>&token=<bearer>` upgraded to a **WebSocket**. Auth is
via `?token=` (WS clients can't always set an `Authorization` header); the same
bearer/admin token works. **It now attaches to ANY pane** — agent panes, plain
shells, dev-servers, logs — not just agent ones. The **WS frame contract is
unchanged**: binary frames of raw terminal bytes in both directions.
- **terminal → WS**: server sends **binary** frames — raw terminal bytes; feed
  them straight into your terminal emulator (`xterm.dart`).
- **WS → terminal**: send **binary** frames — raw keystrokes and control bytes
  (the accessory key row writes Esc `0x1b`, Ctrl-C `0x03`, arrows `\e[A`… here).

Two backends behind the one contract, picked automatically by pane kind — the
client can't tell them apart:
- **Agent panes**: unchanged — `herdr agent attach <pane>` under a PTY, copied
  byte-for-byte both ways (identical to before).
- **Plain panes**: the bridge polls `herdr pane read` (~5×/s) and repaints the
  socket (cursor-home + clear-screen + frame), and forwards inbound bytes to
  `herdr pane send-text`, which delivers raw bytes — Enter, arrows, Ctrl-C —
  straight to the pane's PTY. This is a full-frame repaint stream, so a plain
  pane refreshes on a short interval rather than character-by-character.

Frames MUST be binary; a text frame closes the connection (`1003`). The backend
(PTY process or poller) is stopped when the socket closes (either side).
Reconnect + re-fetch `/snapshot` is the resilience story (no mosh-style state
sync). Resize is not yet wired — the PTY starts at 80×24 and Herdr repaints on
attach. Errors before the upgrade: `404` if `pane` doesn't exist, `401` no/invalid
token, `400` missing `pane`.

## POST /pane/new — create a terminal from mobile
Creates a pane and returns its identity so the app can immediately `/attach` to
it. Two modes, chosen by the body:

**Split an existing pane** (adds a pane to that pane's tab):
```
POST /pane/new
{ "split_from": "w4:p1", "direction": "down", "cwd": "/opt/app", "command": "npm run dev" }
```
- `split_from` (**required for this mode**): pane id to split.
- `direction` (optional): `"right"` | `"down"` — defaults to `"down"`.

**New tab in a workspace** (opens the tab's root pane):
```
POST /pane/new
{ "workspace_id": "w4", "cwd": "/opt/app", "label": "logs", "command": "tail -f log" }
```
- `workspace_id` (**required for this mode**): workspace to add the tab to.
- `label` (optional): the new tab's label.

Common optional fields: `cwd` (working directory for the new shell), `command`
(a command line typed and run in the new pane once created). `split_from` wins if
both it and `workspace_id` are present.

Response `200`:
```json
{ "pane_id": "w4:p7", "tab_id": "w4:t5", "workspace_id": "w4" }
```
`pane_id` is what you pass to `/attach`, `/send`, and `/pane/close`. Errors:
`400` neither `split_from` nor `workspace_id` given (or bad JSON) · `404` unknown
pane/workspace · `401` no/invalid token · `502` herdr failed. Note: if `command`
fails to run the pane is still created and returned `200` (it's logged
server-side) — the app can attach regardless.

## POST /pane/close — close a pane
```
POST /pane/close
{ "pane_id": "w4:p7" }
```
Response `200`: `{ "closed": true, "pane_id": "w4:p7" }`. Closing a tab's last
pane closes the tab too. Errors: `400` missing `pane_id` · `404` unknown pane ·
`401` no/invalid token · `502` herdr failed.

## Errors
`401` missing/invalid bearer · `403` invalid pairing code · `400` bad body ·
`404` unknown pane/tab/workspace · `502` herdr command failed.
