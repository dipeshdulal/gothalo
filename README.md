# gothalo

A self-hosted mobile remote for [Herdr](https://getmoshi.app/docs/herdr) — control your
coding agents (Claude Code, Codex, Gemini, Cursor, …) from your phone: see which
agents are blocked/working/done, get pushed when one needs you, approve or type a
reply, and drop into a full terminal — all over your own Tailscale network.

Think "a mini Moshi that I own," built on Herdr's open socket API instead of a
paid client.

## Why this exists

[Moshi](https://getmoshi.app) is a polished commercial mobile client for Herdr.
Its Pro tier ($7.99/mo · $69.99/yr · $199 lifetime) unlocks mosh, multiplexer
pairing, image paste, diff viewer, etc. But the **data and control all come from
Herdr's open, documented socket API** — which is free. gothalo consumes that API
directly, so the only thing left to build is the client experience, for me + a
few teammates, with no per-seat cost.

## Architecture

```
  Phone app (Flutter)                  Mac Studio (Herdr host)
  ┌──────────────────┐                 ┌────────────────────────────┐
  │  inbox / approve │                 │  gothalo (Go binary)       │
  │  live terminal   │  ── WSS/HTTPS ─▶│   GET  /snapshot           │
  │  xterm.dart      │   over tailnet  │   POST /send /approve      │
  │  key row + FCM   │                 │   WS   /attach  /events    │
  └────────┬─────────┘                 │   watcher: agent wait ──┐  │
           ▲                           └──────────┼─────────────┼───┘
           │                                      │ herdr socket│
           │                                      ▼             │
           │                           ┌────────────────────────┴──┐
           │                           │  Herdr (api/agent/pane)   │
           │                           └───────────────────────────┘
           │  FCM push                            │ outbound
           └──────────── Firebase ◀───────────────┘  (blocked/done)
```

Two independent paths:

- **Interactive** (snapshot / type / terminal): phone → bridge over the
  **tailnet**. No public ports, no SSH on the phone. The tailnet *is* the auth
  boundary; a per-device bearer token lets us revoke a single phone.
- **Push** (notifications): the bridge reaches **outbound** to Firebase/FCM, so
  it works on any network with zero inbound exposure. A phone can't run
  `herdr agent wait` — the bridge does, and calls FCM on `blocked`/`done`.

Because Herdr normalizes ~20 agents *below* the API (`agent:"claude"`,
`agent:"codex"`, …) into a uniform `idle/working/blocked/done` model, the app is
agent-agnostic by construction — multi-agent support is basically free.

The bridge watches **every running Herdr session**, so pane ids that leave the
bridge are session-qualified (`<session>/<pane>`) when they aren't from the
default session.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Bridge | **Go** | Same as my other services; tiny; shells out to `herdr` |
| Transport | **Tailscale** | Already running; no port-forward, no public exposure |
| Push | **Firebase / FCM** | Free for a small team; outbound-only |
| App | **Flutter** | `xterm.dart` is a *native* terminal widget (RN would need xterm.js in a WebView) |
| Terminal | **xterm.dart** | Renders the `attach` stream; themes/fonts for free |

Only recurring cost: **Apple Developer account ($99/yr)** for iOS push. Everything
else (Herdr, Tailscale, FCM, libraries) is free.

## Repo layout

The bridge is one Go binary (`gothalo`) that is both the daemon and the CLI.

```
gothalo/
├── cmd/gothalo/     thin entrypoint -> internal/cli
├── internal/        the bridge: cli · config · herdr · watcher · push · store ·
│                    pairing · server · transport · events · agentstate ·
│                    transcript · gitdiff · notify · web
├── app/             Flutter mobile app (lib/{core,data,features})
├── bruno/           Bruno HTTP collection for poking the API by hand
├── CONTRACT.md      WS /events — the unified event stream the app codes against
└── docs/
    ├── API.md            REST/WS surface the app codes against
    ├── ARCHITECTURE.md   package-by-package map of the binary
    ├── CONTRACT-*.md     per-feature contracts (agent state, diff, transcript, …)
    ├── ROADMAP.md        phased build order + status
    ├── DECISIONS.md      architecture decisions and their rationale
    ├── HANDOFF.md        carried-over scoping context
    └── TESTING.md        how to validate each layer with curl / a browser
```

Runtime state lives **outside** the repo, in `~/.gothalo` (override with
`$GOTHALO_DIR`): `config.json`, `devices.json`, and the FCM `serviceAccount.json`.
Nothing secret is committed.

## Quick start (on the Herdr host)

```bash
go build -o gothalo ./cmd/gothalo
./gothalo serve            # first run generates an admin token into ~/.gothalo/config.json
```

Defaults: `direct` transport bound to `127.0.0.1:8787`. Point it at the tailnet
and give the app a reachable base URL:

```bash
GOTHALO_ADDR=$(tailscale ip -4):8787 \
GOTHALO_PUBLIC_URL=https://<host>.<tailnet>.ts.net:8787 \
./gothalo serve
```

| Env var | Overrides |
|---|---|
| `GOTHALO_DIR` | data dir (default `~/.gothalo`) |
| `GOTHALO_ADDR` | direct bind address |
| `GOTHALO_MODE` | `direct` (active) or `relay` (stub) |
| `GOTHALO_PUBLIC_URL` | base URL embedded in the pairing QR |
| `GOTHALO_SERVICE_ACCOUNT` | path to the FCM service-account JSON |
| `GOTHALO_ADMIN_TOKEN` | admin token (else generated + persisted) |
| `WATCHER=poll` | fall back to the polling watcher |

The same values can live in `~/.gothalo/config.json`; env wins.

### Pair a phone

```bash
./gothalo pair             # prints a QR: {"url":…,"code":…}, one-time, ~5 min TTL
./gothalo devices list
./gothalo devices revoke <id>
```

The app POSTs `{code, device_name, fcm_token}` to `/pair` and gets back a
**per-device bearer** it sends as `Authorization: Bearer …` from then on.

### Poke it by hand

The **admin token** (from `~/.gothalo/config.json`) works as a bearer for every
endpoint plus the `/admin/*` routes — dev-only, but it means no app is needed:

```bash
TOKEN=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.gothalo/config.json")))["admin_token"])')
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/snapshot
```

WebSocket routes (`/attach`, `/events`) take the token as `?token=…` instead,
since WS clients can't always set headers. See `docs/API.md` for the full surface
and `CONTRACT.md` for the event stream.
