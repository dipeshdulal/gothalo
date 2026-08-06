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

## D13 — Unified in-process event bus, streamed over `WS /events`
One process-wide Herdr subscription feeds an in-process pub/sub bus
(`internal/events`); every phone client is just another subscriber over `WS
/events`. Fan-out is bounded — a subscriber that can't keep up is **dropped**
(channel closed) and expected to reconnect and resync from the snapshot frame —
so one lagging phone can't stall the bus or the others. This is the live-update
backbone the app builds on, and the seam an event/plugin ingestion layer plugs
into (see D19).

## D14 — Multi-session bridge
`herdr.Manager` watches **all** Herdr sessions, not just the default, starting and
stopping per-session workers as sessions appear/disappear. People run more than
one Herdr session; the bridge must not be blind to the others.

## D15 — Three views of an agent, not one
The app consumes an agent at three altitudes: the raw PTY (`WS /attach`, full
terminal), a parsed compact **state** card (`agentstate` — "what is it doing / what
is it asking"), and a normalized **transcript** chat (`transcript`). The phone
usually wants the semantic views; the PTY is the escape hatch / fallback.

## D16 — Transcript from the agent's own on-disk log, normalized
`transcript` tails the agent's structured session file (Claude Code writes JSONL;
codex has its own format) and normalizes every entry — messages, thinking, tool
calls (command/diff), tool results — into one kind-agnostic chat schema, so the app
renders a single chat UI for any agent. Unrecognized entries pass through so the
tail survives schema drift. (Revisited in D19.)

## D17 — Notification lifecycle via the bus
The notify-clearer (`internal/notify`), the bus's first consumer, dismisses stale
"blocked" pushes: it remembers the pane behind each blocked push and, when the bus
shows that pane leaving `blocked`, clears the now-irrelevant notification — keeping
the lock screen honest (complements D8's idempotent approvals).

## D18 — `/herdr` allowlisted CLI proxy
A single `POST /herdr` proxies an **allowlisted** set of Herdr operations
(worktree/tab/pane create+close, focus, …) so the app gets Herdr-parity controls
without a bespoke endpoint per verb, while the allowlist stops it from becoming an
arbitrary command sink.

## D19 — Push-based plugin events supersede live file-tailing (direction)
Each coding agent gains a **gothalo plugin** — its own native hook/plugin config
that `POST`s **normalized** events (message, tool call, approval-needed, done) to
the bridge, which `Publish`es them to the event bus (D13). Push is real-time and
carries **intent** — "approval needed for `Bash: rm -rf …`" *before* the tool runs
— which tailing a transcript after the fact (D16) cannot give the notification /
approval path. It also drops the fragile per-agent file-path resolution.

Scope (deliberately not a hard delete of D16):
- Push becomes the **primary live source**; the app reads history + live from the
  bridge, not from agent files.
- File-reading is **demoted, not removed**: a one-time transcript **import** seeds
  pre-plugin history, and it stays the **fallback** for agents whose hook surface is
  too thin to reconstruct chat content.
- The normalized chat schema (D16) is the **target** every plugin maps into, so
  adding an agent = a plugin adapter, not a new file parser. Mirrors how Herdr
  normalizes status (D1/D7) — here gothalo normalizes *events*.
- Reality check: hook richness varies a lot — Claude Code is rich; opencode is
  event-native (client/server with an event stream); codex and others are thinner.
  **Verify each agent's real surface before writing its adapter.** Where a plugin
  can't carry full content, it fires on events and the bridge reads the transcript
  at that moment (hook-triggered) instead of continuously tailing.

Ingestion lands on a new path (`POST /hook` or similar) since `GET /events` is the
outbound stream. Spike with Claude Code first to prove the "approve with context"
UX, then generalize.

## D20 — Terminal scroll is a wheel report to the application, not scrollback
Dragging the live terminal scrolls the **remote application**, by sending it SGR
mouse-wheel reports on the same PTY stream as every keystroke (D6). There is no
client-side scrollback to scroll, and no host-side one either:

- Every agent pane runs on the **alternate screen** (herdr replays `?1049h` on
  attach), so herdr keeps no scrollback for it — `max_offset_from_bottom` is `0`
  on every agent pane and `pane read --source recent` returns exactly the visible
  frame. A bigger `--lines` cannot recover what left the alt screen.
- Herdr has **no scroll-offset API** (149 socket methods, none of them set
  `scroll`), so the bridge can't ask for a window of history either.
- Claude Code turns on mouse tracking and SGR coordinates (`?1000h ?1002h ?1003h
  ?1006h`), so it consumes wheel reports itself. Verified on a live pane:
  `ESC[<64;20;20M` scrolls it.

Consequence, accepted: the pane's own viewport moves, so a desktop operator
watching that pane sees it scroll too. That is inherent to alt-screen apps —
Moshi has it as well (its docs describe the same drag → wheel forwarding when
attached to a multiplexer).

The shim is `PtyMouseHandler`: xterm.dart encodes wheel-up/down as buttons 68/69
(`64 + 4`, which sets the **shift** bit) instead of 64/65, and applications
ignore shift+wheel. Everything else about xterm's gesture path already worked.

**Not chosen** — the two things the open-source herdr clients do instead, both of
which give up the live terminal: merino re-reads `--source recent` with a growing
line budget (400→2000) and renders it as text, which yields nothing on an
alt-screen agent pane; herdr-mobile-relay snapshots each pane every 4 s and
sequence-merges the diff into a reconstructed 10k-line history, which is lossy
and plain-text. For agent history gothalo already has the transcript (D16), read
from the agent's own log — complete and structured. Plain (non-alt-screen) panes
are the one case where a `recent` read is worth having; that stays open.
