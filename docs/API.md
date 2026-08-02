# gothalo bridge — API contract (for the mobile app)

This is the contract the app codes against. The backend was rebuilt into a
`gothalo` CLI + bridge with **QR pairing** and **per-device bearer tokens**.

## Base URL (use the new backend)
```
https://my-mac.tailnet.ts.net:8443
```
Reachable over the tailnet (valid TLS). **Note the `:8443` port** — that's the new
gothalo daemon. (The old prototype bridge on the default `:443` is being retired;
do not target it.) The base URL is not hardcoded in the real flow — it comes from
the pairing QR (a tailnet URL today, a relay URL later).

## Auth model
- **Per-device bearer** (normal): every request sends
  `Authorization: Bearer <bearer>`, where `<bearer>` is returned by `/pair`.
- **Dev shortcut** (until the pairing UI exists): you may use the **admin token**
  as the bearer for manual testing. Get its value from the operator, or from
  `~/.gothalo/config.json` (`admin_token`) / the `gothalo serve` startup log —
  it is not committed. It also unlocks the admin endpoints below (so you can mint
  your own pairing codes for testing). Treat it as dev-only.

## Pairing flow (the real onboarding)
1. Operator runs `gothalo pair` on the host; it prints a QR encoding this JSON
   (the **ConnectPayload**):
   ```json
   { "v": 1, "url": "https://my-mac.tailnet.ts.net:8443", "code": "<8-hex one-time code>" }
   ```
2. App scans the QR, parses the JSON, then:
   ```
   POST <url>/pair
   Content-Type: application/json
   { "code": "<code>", "device_name": "Dipesh S22", "fcm_token": "<this device's FCM token>" }
   ```
3. Response `200`:
   ```json
   { "id": "92787cfa", "bearer": "<64-hex per-device bearer>", "name": "Dipesh S22" }
   ```
   Store `{ baseUrl: url, bearer }` in secure storage; use `bearer` for all calls.
   Errors: `403` invalid/expired/already-used code · `400` bad body.

   Codes are **one-time** and expire in ~5 min.

To mint a code yourself for testing (admin token):
```
POST /admin/pairing?token=<admin>   { "name": "Test Phone" }   ->  { "code", "url" }
```

## Endpoints (per-device bearer)
| Method | Path | Body | Response | Notes |
|---|---|---|---|---|
| GET  | `/snapshot` | — | raw Herdr snapshot JSON | live agent state (shape below) |
| POST | `/send` | `{pane, text}` | `{ok:true}` | types text into a pane |
| POST | `/register-token` | `{token}` | `{ok:true}` | call on FCM token refresh to update THIS device |
| POST | `/testpush` | — | `{ok:true,sent:true}` | fan a sample push to all devices (test your FCM handler) |

### /snapshot shape (what to render in the inbox)
```json
{ "result": { "snapshot": { "agents": [
  { "agent": "claude",
    "agent_status": "idle|working|blocked|done|unknown",
    "pane_id": "wN:p2",
    "terminal_title_stripped": "…",
    "workspace_id": "wN",
    "cwd": "/…" }
] } } }
```
Group by `workspace_id`; badge on `agent_status`; title = `terminal_title_stripped`;
`pane_id` is the id used for `/send` and (later) approvals.

## Push messages (what your FCM handler receives)
Messages are **data-only** (no `notification` block) so your handler always runs
and renders the notification itself (reliable on locked Android). Data keys:
```
title   e.g. "Herdr agent blocked"
body    the agent's terminal title
agent   the pane_id (e.g. "wN:p2")  -> deep-link target
status  "blocked" | "done"
```
Render a local notification from `title`/`body`; tapping it should deep-link to
the agent identified by `agent` (== `pane_id`).

### Native FCM setup
Add an **Android app** to Firebase project **YOUR_PROJECT_ID** → download
`google-services.json` into `android/app/`. Get the device token via
`firebase_messaging`, pass it as `fcm_token` during `/pair`, and
`POST /register-token {token}` whenever it refreshes.

## Errors
`401` missing/invalid bearer · `403` invalid pairing code · `400` bad body ·
`502` herdr command failed.

## Not built yet (stub in the app, don't block on them)
- `WS /attach` (live terminal stream) — coming in a later backend phase.
- `POST /approve {agent, seq}` (idempotent approvals) — coming; for now "approve"
  = `/send` the agent's confirm keystroke.
