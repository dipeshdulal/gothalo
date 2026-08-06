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
- ✅ `GET /diff?pane=…` + `GET /diff/expand` (`internal/gitdiff`,
      `docs/CONTRACT-diff.md`)
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
- ✅ Diff viewer UI (`features/diff`) — collapsible directory tree with
      per-directory +/− rollups, word-level intra-line highlighting, collapsed
      unchanged regions backed by `/diff/expand`, per-file collapse/expand
- ✅ Notification **auto-clear**: stale `blocked` pushes are dismissed when the
      bus shows the pane leaving blocked, whoever resolved it
      (`internal/notify/clearer.go`, `docs/CONTRACT-notif-clear.md`)
- ✅ Agent transcript reading — the conversation, not just terminal scrollback
      (`internal/transcript`, `docs/CONTRACT-agent-transcript.md`).
      **No competing Herdr client does this.**
- ✅ Image paste → file in the pane's cwd → send the path (#85,
      `docs/CONTRACT-image.md`). On the transcript composer and, since the
      endpoint serves agentless panes too, on the raw terminal — where the path
      is typed into the PTY (`features/attach/image_attach.dart`).
- ✅ Recent-activity timeline (#88, `internal/timeline`,
      `docs/CONTRACT-timeline.md`)
- ✅ Start / restart / stop an agent from the phone (#87,
      `docs/CONTRACT-agent-lifecycle.md`). One-shot launch only — saved launch
      profiles were deliberately left out.
- ✅ Slash-command typeahead in the composer — `/` in the transcript composer
      lists what the agent really accepts, read off the host's disk
      (`internal/commands`, `docs/CONTRACT-commands.md`). Plugin commands are a
      recorded gap, not an omission; see the contract.
- ✅ One-tap **Create PR** — the app asks the pane's own agent to commit, push
      and `gh pr create`, gated on a host-side git read (`GET /diff?context=1`,
      `docs/CONTRACT-diff.md`, D26). Agent-agnostic by construction; the bridge
      runs no git itself. The prompt is editable before it is sent.
- ⬜ iOS Live Activity / Android ongoing-notification approvals. Note
      `core/widgets/live_activity_line.dart` is an **in-app** activity line, not
      ActivityKit — the real Live Activity is still unbuilt and needs Swift.
- ✅ **Pane suggestions (incl. dev-server preview)** — `GET /suggestions` plus a
      chip row above the terminal (`internal/suggest`, `internal/ports`,
      `app/lib/features/suggestions/`, `docs/CONTRACT-suggestions.md`): the two or
      three things worth doing to a pane given what is running in it. Five
      sources — a reachable dev server, a stopped merge/rebase/cherry-pick, an
      agent tree with uncommitted changes, a dev server bound to localhost, and a
      plain shell parked at its prompt inside a worktree.

      **One mechanism, not two.** Dev-server discovery was built first as its own
      endpoint and its own chip; it is now a source inside the suggestion
      mechanism, ranked in the same row as the git-shaped ones. `GET /ports`
      survives underneath as the raw host-wide scan the source reads — it is what
      knows about `lsof`, HTTP probes and process trees — and the app calls only
      `/suggestions`. What made the merge affordable is that the scan is cached
      host-wide for 5s, so a row of open panes shares one `lsof` between them
      rather than each paying for one.

      This supersedes the earlier "browser preview in a WebView — low value over
      a tailnet" note, which was half right and half wrong. Right: the **tunnel**
      is redundant. Tailscale already reaches a server bound to `0.0.0.0`, so
      there is nothing to forward and no WebView is wanted — the chip opens the
      system browser. Wrong on two counts: dev servers **default to
      `127.0.0.1`** (Vite, `next dev`, `rails s`), which no amount of tailnet
      reaches; and with agents in parallel worktrees, **discovery and attribution**
      is the real problem — three servers on 5173/5174/5175 and a bare port
      number tells you nothing about whose is whose.

      Loopback-bound servers come back with no `url` and render as a dimmed chip
      whose tap explains the bind and names `--host`. Relaying them (a bridge-side
      TCP splice, `ssh -L` without the SSH) is deliberately deferred until that
      chip shows how often the case actually comes up — it would open ports
      outside the bearer check, so it should be an explicit per-server "Expose"
      tap. When it lands it is one more `action` on an existing chip, not a new
      mechanism, which is the point of having merged the two.

      The design constraint that mattered most was **restraint**: the row renders
      nothing at all for a pane with nothing to offer, which on the development
      host is most of them, and one source may contribute at most two chips so a
      microservice stack cannot crowd out the chip that needs a person. A
      rerun-the-test-runner source was scoped out on purpose — recognising the
      runner is easy, but a watcher wants a keystroke and a finished run wants the
      command retyped, and the process list cannot tell the two apart.

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
