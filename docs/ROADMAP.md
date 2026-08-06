# Roadmap

Build order was deliberately **backend-first**: every risky piece proven with
`curl` / a browser tab before any mobile code existed. The app was drawn last,
over endpoints already trusted.

Phases 0–3 are complete and Phase 4 is most of the way there. The status below
was re-derived from the tree on 2026-08-05 and corrected again on 2026-08-06 —
it drifts fast, and both times in the same direction: shipped work left marked
unstarted or in-progress. Keep it honest, and re-derive from the tree rather than
trusting the marks: this is the first doc anyone reads.

Status legend: ✅ done · 🚧 in progress · ⬜ not started

## Phase 0 — Bridge skeleton
- ✅ `GET /snapshot` — serves live Herdr agent/pane/workspace state as JSON
- ✅ Bearer-token auth, 401 without it
- ✅ `POST /send` — type text into a pane (`herdr pane send-text`)
- ✅ Watcher loop that detects transitions into `blocked`/`done` and calls `notify()`
- ✅ Verified on localhost: real agents listed, auth enforced

## Phase 1 — Prove push end-to-end (NO app)
- ✅ Bind bridge to the Tailscale IP (`GOTHALO_ADDR`) → tailnet transport proven
- ✅ Event-driven watcher: per-agent `herdr agent wait`, with `WATCHER=poll` as
      the documented fallback (`internal/watcher`)
- ✅ Real FCM in `notify()` — service-account OAuth → `messages:send`
      (`internal/push/fcm.go`)
- ✅ Static web-push receiver for testing without the app (`internal/web`)
- ✅ Push confirmed landing from a live blocked agent

## Phase 2 — Bridge control surface
- ✅ `WS /attach` — streams pane output, accepts keystrokes, and applies
      `{"type":"resize"}` control frames so the agent's TUI redraws at the
      phone's real viewport (`internal/server/attach.go`)
- ✅ Idempotent `POST /approve` guarded on `state_change_seq` (stale
      lock-screen taps are no-ops)
- ✅ `GET /diff?pane=…` (`internal/gitdiff`, `docs/CONTRACT-diff.md`)
- ✅ Navigation passthroughs via `/herdr` proxy, `/pane/new`, `/pane/close`
- ✅ Beyond the original plan: `/agent-state`, `/agent-mode/cycle`,
      `/agent-transcript`, `WS /events`, device pairing (`/pair`, `/admin/*`)

## Phase 3 — Flutter app
- ✅ Inbox + Priority + Overview screens off `/snapshot`
- ✅ FCM registration + push handling → deep-link to the blocked agent
- ✅ Live terminal via `xterm.dart` fed by `WS /attach`
- ✅ Accessory key row — Esc / Tab / arrows / **sticky-Ctrl**
- ✅ Floating arrow pad over the terminal — draggable, hold-to-repeat
- ✅ Tap-to-approve (`features/approvals`)
- ✅ Saved bridge hosts (`features/servers`, multi-bridge since #83)
- ✅ Theme (`ThemeMode.system`; no in-app picker, which is fine)
- ⬜ **Biometric gate** — never built, and **deferred by decision** (2026-08-05):
      not needed yet. Note `local_auth: ^3.0.2` is still declared in
      `app/pubspec.yaml` but imported **nowhere** in `lib/`. The dependency is
      being kept for when the gate is built; until then it implies a protection
      that does not exist, so do not read its presence as auth being handled.

## Phase 4 — Polish
- ✅ Actionable notification buttons (`features/push/notification_actions.dart`)
- ✅ Diff viewer UI (`features/diff`)
- ✅ Notification **auto-clear**: stale `blocked` pushes are dismissed when the
      bus shows the pane leaving blocked, whoever resolved it
      (`internal/notify/clearer.go`, `docs/CONTRACT-notif-clear.md`)
- ✅ Agent transcript reading — the conversation, not just terminal scrollback
      (`internal/transcript`, `docs/CONTRACT-agent-transcript.md`).
      **No competing Herdr client does this.**
- ✅ Image paste → file in the agent's cwd → send the path (#85,
      `docs/CONTRACT-image.md`)
- ✅ Recent-activity timeline (#88, `internal/timeline`,
      `docs/CONTRACT-timeline.md`)
- ✅ Start / restart / stop an agent from the phone (#87,
      `docs/CONTRACT-agent-lifecycle.md`). One-shot launch only — saved launch
      profiles were deliberately left out.
- ✅ Slash-command typeahead in the composer — `/` in the transcript composer
      lists what the agent really accepts, read off the host's disk
      (`internal/commands`, `docs/CONTRACT-commands.md`). Plugin commands are a
      recorded gap, not an omission; see the contract.
- ⬜ iOS Live Activity / Android ongoing-notification approvals. Note
      `core/widgets/live_activity_line.dart` is an **in-app** activity line, not
      ActivityKit — the real Live Activity is still unbuilt and needs Swift.
- ⬜ Browser preview (agent's dev server in a WebView). Low value over a
      tailnet, where the phone browser already reaches it directly.

## Known gaps
- **Codex transcripts** — `internal/transcript/codex.go` is an honest stub that
  defers to the generic reader (`Parsed=false`). Deferred until there is a Codex
  subscription and a machine with real `~/.codex` rollout files: the format must
  be read off a live machine, not guessed. This is the one hole in the transcript
  feature, which is otherwise gothalo's strongest differentiator.
- **Subagent transcripts are readable but not rendered.** The bridge side landed
  (#86): `/agent-transcript`'s hello frame carries the session's full subagent
  roster and `?subagent=<id>` streams a delegated conversation
  (`internal/transcript/subagents.go`). **The app ignores both** — nothing in
  `app/lib` references the roster — so when an agent fans work out the phone
  still goes dark exactly when it should be most useful. The remaining work is
  one nesting level in the transcript screen, against a contract that already
  exists. See #11 in `docs/RESEARCH-feature-ideas.md`.
- `GOTHALO_MODE=relay` stays a stub **by decision** (2026-08-05), not oversight.
- No self-update. Deferred until there is release wiring to hang it on. Bridge/app
  version skew is still the likeliest real-world failure with more than one user.

## Explicitly out of scope
- **mosh / ET** — WebSocket auto-reconnect + re-fetch snapshot covers "good
  enough" resilience; not reimplementing mosh.
- **Multi-agent normalization** — Herdr already does it upstream of the API.
- **SSH on the phone** — the bridge + tailnet replace it entirely.
- **Cloud relay / multi-tenant sync** — that is the competitors' business model;
  self-hosted on your own tailnet is the point of this project.
