# Architecture decisions

Short record of the choices made and *why*, so future-me doesn't relitigate them.

## D1 — Build on Herdr's socket API, don't rebuild a multiplexer
Herdr exposes `herdr api snapshot` (full state as JSON), `agent`/`pane`
read+control, and `agent wait` (blocks until a state change). That's a complete
read + control + event surface. gothalo consumes it; it invents nothing Herdr
already does.

## D2 — A bridge daemon is required (push forces it)
A phone can't run `herdr agent wait`. Something long-lived next to Herdr must
watch state and reach out to FCM. That daemon is the bridge. Consequence: a
"phone SSHes in and runs herdr" design (Moshi's model) is rejected — SSH is
pull-only and can't push.

## D3 — Push is outbound; interactive is tailnet-only
FCM = bridge → Firebase (outbound), so notifications need **zero inbound
exposure** and work on any network. Only the interactive API (snapshot/type/
terminal) needs the phone to reach the bridge, and that goes over the **tailnet**.
Two separate concerns; don't conflate their networking.

## D4 — Tailscale for exposure, not raw ports or SSH tunnels
Already running Tailscale. Bridge binds to the tailnet IP; the tailnet is the
auth boundary; a per-user bearer token allows revocation. No public ports, no
port-forwarding, no SSH client on the phone. (An SSH tunnel would *replace*
Tailscale as the exposure layer, not sit alongside it — not chosen.)

## D5 — Flutter over React Native
The core screen is a fast-scrolling terminal. Flutter's `xterm.dart` is a
**native** terminal widget; React Native has no native terminal and would embed
`xterm.js` in a WebView (JS-bridge boundary on every keystroke/output chunk —
wrong seam for high-frequency streaming). RN's only edge (team already writes
React/TS) doesn't outweigh the terminal being the product. Revisit only if v1
becomes "status board first, terminal later."

## D6 — The mobile keyboard is an accessory row, not a custom IME
Soft keyboards lack Esc/Ctrl/Tab/arrows. Solution is a toolbar above the system
keyboard whose buttons write control bytes into the same PTY stream (Esc=0x1b,
Ctrl+C=0x03, arrows=`\e[A`…). A **sticky Ctrl** toggle (`letter & 0x1f`) collapses
the whole Ctrl-combo space into one button. ~15 lines of UI, not a keyboard
extension.

## D7 — Multi-agent is free
Herdr detects and normalizes ~20 agents below the API into one status model, so
the app writes multi-agent UI once. The only per-agent code is an optional ~12-
line keystroke map for one-tap approvals (each agent's confirm key differs);
fallback is "open the terminal and let the human type," which needs no per-agent
code at all.

## D8 — Idempotent approvals
An approval push may sit on the lock screen for minutes while the agent's state
moves on. Every approve action carries `agent` + `state_change_seq` (both in the
snapshot); the bridge no-ops if the agent isn't still `blocked` at that seq. This
guard lives in the bridge so *every* approval surface (banner button, Live
Activity, in-app) inherits it.

## D9 — Backend-first, app-last
Validate snapshot → tailnet reach → notify trigger → real push (in a browser tab
via FCM web push) entirely with curl/browser before writing Flutter. The app is
drawn over a backend already trusted. See `TESTING.md`.

## D10 — One `gothalo` binary: bridge + CLI (cobra)
The bridge is now a proper CLI (`gothalo serve | pair | devices`) built on cobra,
laid out as a standard Go module (`cmd/gothalo` + `internal/*`). `pair`/`devices`
are thin clients of the running `serve` daemon over a localhost admin API, so the
daemon stays the single source of truth for state.

## D11 — QR pairing + per-device bearer tokens
Devices onboard by scanning a QR (`gothalo pair` prints it) that encodes a
one-time code + a connect URL. `POST /pair {code, device_name, fcm_token}` issues
a **per-device bearer**, stored in `~/.gothalo/devices.json`. This replaces the
single shared token and finally delivers real revocation (D4): `gothalo devices
revoke <id>` kills one device's bearer *and* stops its pushes without touching
the others. An operator **admin token** (auto-generated, in `config.json`) gates
the CLI/admin endpoints and the web test page.

## D12 — Pluggable transport; Tailscale is one option, not a requirement
The HTTP API is a transport-agnostic `http.Handler`. A `transport.Transport`
seam runs it under **direct** mode (listen locally — behind `tailscale serve`,
or a LAN/tailnet IP) today, and a **relay** mode later: the bridge dials OUT to a
small hosted broker over a persistent WebSocket, so phones reach it through the
relay with no inbound ports and no Tailscale. Both feed the same handlers. Push
stays outbound (D3) and per-device bearers still gate access (D4) in either mode.
The pairing QR carries a generic connect endpoint so the app never hardcodes
Tailscale. Relay is stubbed now (`internal/transport/relay`), wired later.
