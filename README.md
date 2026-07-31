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
  │  inbox / approve │                 │  gothalo bridge (Go)        │
  │  live terminal   │  ── WSS/HTTPS ──▶│   GET  /snapshot            │
  │  xterm.dart      │   over tailnet   │   POST /send                │
  │  key row + FCM   │                 │   WS   /attach (planned)    │
  └────────┬─────────┘                 │   watcher: agent wait ──┐   │
           ▲                            └──────────┼─────────────┼───┘
           │                                       │ herdr socket │
           │                                       ▼             │
           │                            ┌────────────────────────┴──┐
           │                            │  Herdr (api/agent/pane)    │
           │                            └────────────────────────────┘
           │  FCM push                             │ outbound
           └──────────── Firebase ◀────────────────┘  (blocked/done)
```

Two independent paths:

- **Interactive** (snapshot / type / terminal): phone → bridge over the
  **tailnet**. No public ports, no SSH on the phone. The tailnet *is* the auth
  boundary; a per-user bearer token lets us revoke a teammate.
- **Push** (notifications): the bridge reaches **outbound** to Firebase/FCM, so
  it works on any network with zero inbound exposure. A phone can't run
  `herdr agent wait` — the bridge does, and calls FCM on `blocked`/`done`.

Because Herdr normalizes ~20 agents *below* the API (`agent:"claude"`,
`agent:"codex"`, …) into a uniform `idle/working/blocked/done` model, the app is
agent-agnostic by construction — multi-agent support is basically free.

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

```
gothalo/
├── bridge/          Go daemon on the Herdr host (the hub everything hangs off)
├── app/             Flutter mobile app (built LAST, once the bridge is proven)
└── docs/
    ├── ROADMAP.md   Phased build order + status
    ├── DECISIONS.md Architecture decisions and their rationale
    └── TESTING.md   How to validate each layer with curl / a browser — no app
```

## Quick start (bridge, on the Herdr host)

```bash
cd bridge
go build -o gothalo-bridge .
BRIDGE_ADDR=$(tailscale ip -4):8787 BRIDGE_TOKEN=<your-token> ./gothalo-bridge

# from anything on the tailnet:
curl -H "Authorization: Bearer <your-token>" http://<tailscale-ip>:8787/snapshot
```

See `docs/TESTING.md` for the full ladder — you validate the whole backend
(including a real push landing on a device) before writing any app code.
