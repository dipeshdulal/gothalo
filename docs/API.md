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
| GET  | `/agent-state` | — (query: `pane`) | parsed agent state JSON | compact card for an **agent** pane (below) |
| GET  | `/attach` | — (query: `pane`, `token`) | **WebSocket** | live terminal stream (below) |
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

## GET /agent-state — parsed agent card
A compact, **parsed, plain-text** state for a single **agent** pane — the phone
alternative to WS /attach's raw terminal. Instead of a full PTY you get one JSON
struct: what the agent is doing, its last message, and — when blocked — the exact
question and choices it's waiting on (which pair with `POST /approve`). Use it for
agent panes; keep raw `/attach` for non-agent panes.
```
GET /agent-state?pane=<pane_id>
Authorization: Bearer <bearer>          // same auth as everything; ?token= also works
```
Response `200` — the **stable contract** (kind-agnostic; the same shape for every
agent kind):
```jsonc
{
  "pane_id": "wQ:p2",
  "agent_kind": "claude",               // herdr agent kind
  "agent_status": "idle|working|blocked|done|unknown",
  "headline": "…",                      // one line: what it's doing / last step (the question when blocked)
  "detail": "…",                        // short plain-text body, ANSI/box-drawing already stripped
  "blocked": {                          // present ONLY when agent_status == "blocked"
    "question": "Do you want to proceed?",
    "options": [                        // may be empty for free-form prompts
      { "index": 1, "label": "Yes", "selected": true },
      { "index": 2, "label": "Yes, and always allow…", "selected": false },
      { "index": 3, "label": "No", "selected": false }
    ]
  },
  "transcript": [ "…recent plain-text lines…" ],   // optional, best-effort
  "parsed": true                        // false => unrecognised kind, raw text fallback
}
```
Field notes for the app:
- **`headline`** is always safe to render alone. When blocked it is the question.
- **`detail`** is phone-ready plain text (may contain `\n`); when blocked it's the
  context being approved (e.g. the command).
- **`blocked.options`** are tap targets. `selected:true` marks the default that a
  bare Enter accepts — so one-tap "Yes" is `POST /approve {agent, seq}` (Enter).
  To pick a *non-default* option, type its number then Enter via
  `POST /send {pane, text:"2\n"}`. `index` is that number (0 if unnumbered).
- **`parsed:false`** means the agent kind has no dedicated parser yet, so
  `detail`/`transcript` are a best-effort raw recent-text dump. The card still
  renders; just don't rely on `blocked`. (claude is parsed today; codex and
  opencode are next behind the same contract.)
- `agent_status` is authoritative (straight from herdr). Pair it with the same
  `state_change_seq` from `/snapshot` for `/approve`.

Parsing never fails the request: an unrecognised layout degrades to `parsed:false`
rather than erroring. Errors: `400` missing `pane` · `401` bad bearer · `404` no
agent in that pane · `502` herdr command failed.

## WS /attach — live terminal
`GET /attach?pane=<pane_id>&token=<bearer>` upgraded to a **WebSocket**. Auth is
via `?token=` (WS clients can't always set an `Authorization` header); the same
bearer/admin token works. The bridge runs `herdr agent attach <pane>` under a PTY
and bridges it to the socket:
- **pty stdout → WS**: server sends **binary** frames — raw terminal bytes; feed
  them straight into your terminal emulator (`xterm.dart`).
- **WS → pty stdin**: send **binary** frames — raw keystrokes and control bytes
  (the accessory key row writes Esc `0x1b`, Ctrl-C `0x03`, arrows `\e[A`… here).

Frames MUST be binary; a text frame closes the connection (`1003`). The attach
subprocess is killed when the socket closes (either side). Reconnect + re-fetch
`/snapshot` is the resilience story (no mosh-style state sync). Resize is not yet
wired — the PTY starts at 80×24 and Herdr repaints on attach.

## Errors
`401` missing/invalid bearer · `403` invalid pairing code · `400` bad body ·
`404` no agent in that pane (`/agent-state`) · `502` herdr command failed.
