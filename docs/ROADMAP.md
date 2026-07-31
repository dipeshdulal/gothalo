# Roadmap

Build order is deliberately **backend-first**: every risky piece is proven with
`curl` / a browser tab before any mobile code exists. The app is drawn last, over
endpoints already trusted.

Status legend: ✅ done · 🚧 in progress · ⬜ not started

## Phase 0 — Bridge skeleton
- ✅ `GET /snapshot` — serves live Herdr agent/pane/workspace state as JSON
- ✅ Bearer-token auth (`BRIDGE_TOKEN`), 401 without it
- ✅ `POST /send` — type text into a pane (`herdr pane send-text`)
- ✅ Poll-based watcher loop that detects transitions into `blocked`/`done`
      and calls `notify()` (currently logs)
- ✅ Verified on localhost: real agents listed, auth enforced

## Phase 1 — Prove push end-to-end (NO app)
- ⬜ Bind bridge to the Tailscale IP; hit `/snapshot` from phone browser
      → proves the tailnet transport
- ⬜ Swap the poll watcher for per-agent `herdr agent wait --until blocked done`
      (event-driven, near-zero cost) — keep poll as fallback
- ⬜ Real FCM in `notify()` (service-account OAuth → `messages:send`)
- ⬜ Tiny static **web-push receiver** (Firebase JS SDK, ~30 lines) to receive a
      real notification in a **browser tab** — no Flutter, no Apple account yet
- ⬜ Block a live agent → confirm a push actually lands. **This is the milestone
      that de-risks the whole project.**

## Phase 2 — Bridge control surface
- ⬜ `WS /attach` — stream `herdr agent attach` output + accept keystrokes
      (the live terminal feed)
- ⬜ Idempotent approve: `POST /approve {agent, seq}` — no-op if the agent is no
      longer `blocked` at that `state_change_seq` (guards stale lock-screen taps)
- ⬜ `GET /diff?pane=…` — `git diff` in the agent's cwd, for phone review
- ⬜ Navigation passthroughs: `pane focus / zoom / swap`, tab/workspace switch

## Phase 3 — Flutter app (only now)
- ⬜ Inbox screen off `/snapshot` (agent + status badges, grouped by workspace)
- ⬜ FCM registration + push handling → deep-link to the blocked agent
- ⬜ Live terminal via `xterm.dart` fed by `WS /attach`
- ⬜ **Accessory key row** — Esc / Tab / arrows / sticky-Ctrl (sends control bytes)
- ⬜ Tap-to-approve using the per-agent keystroke map (~12 lines; fallback = open
      terminal and let the human type)
- ⬜ Biometric gate (`local_auth`), saved bridge hosts, theme

## Phase 4 — Polish (Moshi-parity, as wanted)
- ⬜ Actionable notification buttons (Approve/Deny on the banner)
- ⬜ iOS Live Activity / Android ongoing-notification approvals
- ⬜ Diff viewer UI
- ⬜ Image paste → temp file in cwd → `send-text` the path
- ⬜ Browser preview (tunnel the agent's dev-server port into a WebView)

## Explicitly out of scope
- **mosh / ET** — WebSocket auto-reconnect + re-fetch snapshot covers "good
  enough" resilience; not reimplementing mosh.
- **Multi-agent normalization** — Herdr already does it upstream of the API.
- **SSH on the phone** — the bridge + tailnet replace it entirely.
