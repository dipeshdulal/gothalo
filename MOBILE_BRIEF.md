# Mobile app brief — gothalo Flutter client

You are building the **Flutter mobile app** for **gothalo**, a self-hosted mobile
remote for **Herdr** (a terminal multiplexer for coding agents). Read the repo docs
first, then build. This worktree is on branch **mobile-app**; work only here, only
under `app/`. Do NOT touch the Go backend (`bridge/`, `cmd/`, `internal/`) — that's
being rewritten in parallel in another worktree.

## Read first (in this order)
- `docs/HANDOFF.md` — full project context and reasoning
- `README.md` — architecture diagram + stack
- `docs/DECISIONS.md` — D5 (Flutter/xterm.dart), D6 (accessory key row), D7
  (multi-agent + per-agent keystroke map), D8 (idempotent approvals)
- `docs/ROADMAP.md` — Phase 3 is your scope
- `docs/TESTING.md` — how the backend was proven

## The bridge API (LIVE right now — test against it)
The backend bridge is running and reachable over the tailnet via HTTPS:

- Base URL: `https://<host>.<tailnet>.ts.net` (your bridge's tailnet URL from `tailscale serve`)
- Auth (temporary): header `Authorization: Bearer test`  — or `?token=test` for
  GET-in-a-browser. **This shared token is temporary**: the backend is moving to
  **per-device bearer tokens issued by QR pairing** (see Coordination below).

Verified endpoints:
- `GET /snapshot` → raw Herdr snapshot JSON. Shape that matters:
  ```
  { "result": { "snapshot": { "agents": [
      { "agent": "claude",
        "agent_session": { "value": "<uuid>" },
        "agent_status": "idle|working|blocked|done|unknown",
        "pane_id": "wN:p2",
        "terminal_title_stripped": "…",
        "cwd": "/…", "focused": false, "workspace_id": "wN" }
  ] } } }
  ```
- `POST /send` `{"pane":"wN:p2","text":"yes\n"}` → types text into that pane.
- `POST /register-token` `{"token":"<fcm token>"}` (with `?token=test`) → registers a
  device push token. (The web receiver used this; your native app registers its own.)
- `POST /testpush` → fires a sample push to the registered token (handy to test FCM).

Confirm you can reach it: `curl -H "Authorization: Bearer test" https://<host>.<tailnet>.ts.net/snapshot`

## Firebase (for native push)
- Create your own Firebase project (Cloud Messaging enabled) — see README
  "Push: bring your own Firebase" or run `scripts/setup-firebase.sh`.
- For **native Android FCM** add an **Android app** in the Firebase console
  under your project, download **google-services.json**, and place it in
  `android/app/`. The whole bridge→FCM→device pipeline is already proven end-to-end,
  so this is just registering the native client and minting its own token.

## Build order (Phase 3)
1. `flutter doctor`; create the app in `app/` (suggest org `com.dipeshdulal`, name
   `gothalo`). Target the **attached adb device** (`flutter devices` to confirm).
2. **Networking layer**: a `BridgeClient(baseUrl, bearer)` with `getSnapshot()` and
   `sendText(pane, text)`. Keep `baseUrl` + `bearer` in a settings/connection model
   so the future QR-pairing flow can populate them — do NOT hardcode.
3. **Inbox screen** off `/snapshot`: list agents grouped by `workspace_id`, with
   status badges (idle/working/blocked/done/unknown), title = `terminal_title_stripped`,
   pull-to-refresh. This is the first thing to get on the device against the LIVE bridge.
4. **FCM registration**: `firebase_core` + `firebase_messaging`; get token, POST it to
   the bridge; handle a push → deep-link to the blocked agent. (Needs google-services.json.)
5. **Live terminal** (`xterm.dart`): stub a `TerminalScreen` now — the backend `WS /attach`
   stream isn't built yet, so wire the widget and leave the socket as a TODO.
6. **Accessory key row** (D6): Esc / Ctrl / Tab / arrows sending control bytes, sticky-Ctrl.
7. **Tap-to-approve** (D7/D8): per-agent keystroke map; approvals will carry
   `agent` + `state_change_seq` (idempotent) once the backend `/approve` lands.

## Coordination with the backend rewrite (important)
The Go backend is being rebuilt in parallel into a **cobra CLI + bridge** with:
- subcommands `serve` / `pair` / `devices`
- **per-device bearer tokens** stored in `~/.gothalo/devices.json`
- **QR pairing**: phone scans a QR encoding a transport-agnostic connect payload
  `{ url (or relay+bridge_id), code }`, then `POST /pair {code, device_name, fcm_token}`
  → the bridge returns a **per-device bearer**. The app stores that bearer + baseUrl.
- **pluggable transport** so it can later work without Tailscale (via a hosted relay).

So: design the **connection model** as `{ baseUrl, bearer }` populated either manually
(a settings screen, for now) or by scanning a QR (later). Plan a `qr_code_scanner`/
`mobile_scanner` screen for pairing. The exact `/pair` contract will be handed to you
when the backend side lands; until then, use the manual `{baseUrl:"https://<host>.<tailnet>.ts.net", bearer:"test"}`
connection to build and test the inbox + FCM.

## Rules
- Use **real** pub.dev packages (`xterm`, `firebase_core`, `firebase_messaging`,
  `http` or `dio`, `mobile_scanner`, `flutter_secure_storage`, …). Run `flutter pub get`
  to verify — **do not invent package names or APIs**; check pub.dev/docs when unsure.
- Commit to the **mobile-app** branch as you go. **No** "Generated with Claude Code"
  or "Co-Authored-By: Claude" — personal project, house rule.
- Keep everything under `app/`. Don't run git operations outside this worktree.

Start now: read the docs above, run `flutter doctor` + `flutter devices`, scaffold the
app, and get the **inbox screen** showing the real agents from the live bridge on the
attached device. Report what you see.
