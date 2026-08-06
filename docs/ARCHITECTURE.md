# Architecture — the `gothalo` binary

`gothalo` is one Go binary: a Herdr **bridge** plus a **CLI** to run and manage it.
Standard module layout; the HTTP surface is transport-agnostic so it can run over
Tailscale today and a hosted relay later (see DECISIONS D10–D12).

```
cmd/
└── gothalo/            thin entrypoint -> internal/cli
internal/
├── cli/                cobra tree: serve · pair · devices (+ daemon client)
├── config/             ~/.gothalo config (JSON), admin token, transport mode
├── herdr/              typed herdr CLI wrapper + multi-session Manager (all sessions)
├── watcher/            event-driven agent watcher (herdr agent wait) + poll fallback
├── push/              FCM v1 sender (stdlib JWT->OAuth->messages:send, data-only)
├── store/              paired-device registry -> ~/.gothalo/devices.json
├── pairing/            one-time codes + QR (transport-agnostic connect payload)
├── server/             http.Handler routes + per-device/admin auth  ← the heart
├── transport/          Transport interface
│   ├── direct/         http.Server (tailnet / LAN / localhost)  [active]
│   └── relay/          outbound-WS broker client                [stub, later]
├── events/             in-process pub/sub bus (fan-out; drops slow subscribers)
├── agentstate/         parse `herdr agent read` -> compact per-agent state (per-kind)
├── transcript/         tail the agent's on-disk transcript -> kind-agnostic chat
├── imagedrop/          land an uploaded image in the agent's cwd -> a path it can read
├── notify/             bus consumer: dismiss stale "blocked" pushes
└── web/                embedded web-push receiver page (go:embed)
```

## Request path
```
phone / browser ─▶ transport (direct: listen; relay: dial-out) ─▶ server.Handler
                                                                      │
                       herdr CLI ◀── herdr.Client ──┐                 │
                       FCM       ◀── push.Client ────┼── handlers ─────┤
                       devices.json ◀ store.Store ───┤                 │
                       codes/QR  ◀── pairing.Manager ┘                 │
```
The **same handlers** run under any transport. `serve` picks the transport from
config; `pair`/`devices` are localhost clients of the running daemon's admin API.

## HTTP surface
| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET  | `/snapshot` | device bearer or admin | live Herdr state |
| POST | `/send` | device bearer or admin | type into a pane |
| POST | `/approve` | device bearer or admin | idempotent one-tap approval (D8) |
| GET  | `/attach` | device bearer or admin (`?token=`) | WS live terminal (PTY-streamed) |
| GET  | `/agent-state` | device bearer or admin | parsed compact state for one agent pane |
| GET  | `/agent-transcript` | device bearer or admin (`?token=`) | WS normalized transcript chat + backlog |
| GET  | `/events` | device bearer or admin (`?token=`) | WS unified event bus (state changes, push lifecycle) |
| POST | `/herdr` | device bearer or admin | allowlisted Herdr CLI proxy (worktree/tab/pane parity) |
| POST | `/register-token` | device bearer or admin | (re)register a push token |
| POST | `/testpush` | device bearer or admin | fan a sample push to all devices |
| POST | `/pair` | one-time code | issue a per-device bearer |
| POST | `/admin/pairing` | admin | mint a code + connect URL (for the QR) |
| GET  | `/admin/devices` | admin | list paired devices |
| POST | `/admin/devices/revoke` | admin | revoke a device |
| GET  | `/` `…` | none | embedded web-push receiver page |

## Auth model
- **Admin token** — auto-generated into `~/.gothalo/config.json`; gates the CLI,
  admin endpoints, and the browser test page.
- **Per-device bearer** — minted by `/pair`, stored per device; revocable one at a
  time. Push fans out to every device's FCM token.

## Notifications
The watcher fires `server.Notify(pane, status, title, seq)` on each transition
into `blocked`/`done`; Notify pushes a **data-only, high-urgency** FCM message to
every registered device (reliable lock-screen delivery). The message carries the
agent's `state_change_seq` so an **Approve** action tapped later can echo it back
to `POST /approve`, which no-ops if the agent has moved past that seq (D8). A
pre-existing blocked/done state at watcher start is not replayed.

## Live terminal (`WS /attach`)
`GET /attach` upgrades to a WebSocket (`github.com/coder/websocket`) and runs
`herdr agent attach <pane>` under a PTY (`github.com/creack/pty`). Two `io.Copy`
loops bridge the PTY and the socket (via `websocket.NetConn`, binary frames):
pty stdout → WS and WS → pty stdin. Whichever side ends first tears down the
other and the subprocess is killed. Auth accepts `?token=` since WS clients can't
always set headers.
