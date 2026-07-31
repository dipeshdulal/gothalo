# Handoff — conversation context carried over

This project was scoped in a conversation in another Herdr pane. This file carries
that context so the agent working *here* can continue seamlessly. Read this, then
`README.md`, `docs/DECISIONS.md`, `docs/ROADMAP.md`, `docs/TESTING.md`.

## What gothalo is
A self-hosted mobile remote for **Herdr** — a "mini Moshi that I own." It lets me
and a few teammates control coding agents (Claude Code, Codex, Gemini, …) from a
phone: see blocked/working/done state, get pushed when an agent needs input,
approve or type a reply, and open a full terminal — over my own Tailscale network,
built on Herdr's free open socket API instead of paying for Moshi Pro.

## How we got here (the reasoning, condensed)
- Herdr exposes a real JSON socket API: `herdr api snapshot` (full state),
  `agent`/`pane` read+control, and `agent wait --until blocked done` (blocks until
  a state change). That's a complete read + control + event surface — we build on
  it, we don't rebuild a multiplexer.
- **A bridge daemon is mandatory because of push.** A phone can't run
  `herdr agent wait`; something long-lived next to Herdr must watch state and call
  FCM. So "phone SSHes in and runs herdr" (Moshi's model) is rejected.
- **Push is outbound (bridge → Firebase), interactive is tailnet-only.**
  Notifications need zero inbound exposure and work on any network. Only
  snapshot/type/terminal need the phone to reach the bridge — over Tailscale
  (already running), tailnet = auth boundary + per-user bearer token.
- **Flutter**, not React Native: the core screen is a terminal, and `xterm.dart`
  is a *native* terminal widget; RN would embed xterm.js in a WebView (wrong seam).
- Mobile keyboard = an **accessory key row** (Esc/Ctrl/Tab/arrows sending control
  bytes; sticky-Ctrl toggle), not a custom IME.
- **Multi-agent is free** — Herdr normalizes ~20 agents below the API into one
  status model. Only per-agent code is an optional ~12-line keystroke map for
  one-tap approvals.
- Full rationale for each: `docs/DECISIONS.md` (D1–D9).

## Current state (Phase 0 ✅ done)
`bridge/main.go` is a working Go daemon, already tested on localhost:
- `GET /snapshot` → live Herdr state as JSON (returned the real 5 agents)
- Bearer-token auth via `BRIDGE_TOKEN` (401 without it — verified)
- `POST /send {pane,text}` → types into a pane
- A poll-based watcher that detects transitions into `blocked`/`done` and calls
  `notify()` (currently just logs)

Build/run:
```bash
cd bridge && go build -o gothalo-bridge .
BRIDGE_ADDR=127.0.0.1:8787 BRIDGE_TOKEN=test123 ./gothalo-bridge
curl -H "Authorization: Bearer test123" http://127.0.0.1:8787/snapshot
```

## The immediate next milestone (Phase 1 — de-risks everything)
Prove a **real push lands on a device with NO mobile app yet** (see `TESTING.md`
rung ⑤). Steps:
1. Bind the bridge to the Tailscale IP; hit `/snapshot` from the phone browser.
2. Swap the poll watcher for per-agent `herdr agent wait --until blocked done`
   (keep poll as fallback).
3. Put real FCM in `notify()` (Firebase service-account OAuth → `messages:send`).
4. Add a ~30-line static **web-push receiver** page (Firebase JS SDK) to receive
   the notification in a **browser tab** — no Flutter, no Apple Developer account.
5. Block a live agent → confirm the push actually arrives.

> Do not write Flutter app code until rung ⑤ is green.

## House rules
- No "Generated with Claude Code" / "Co-Authored-By: Claude" in commits or PRs.
- This is a personal project (top-level `~/projects/gothalo`), not acme work.
