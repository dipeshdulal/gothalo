# RESEARCH — competitive research & feature ideas (2026-08-03)

Produced by a research-only Herdr pane agent (`apparesearch`), investigating
comparable apps and the existing gothalo codebase to suggest what to build
next. No code was changed as part of this research — see `DECISIONS.md` /
open PRs for what's actually landed. Status of each idea (started, done,
deferred) should be tracked in `ROADMAP.md`, not edited into this file — this
is a point-in-time snapshot, kept for reference.

---

I have everything I need — the codebase inventory plus web research on competitors and dashboard patterns. Here's the report.

---

# gothalo — competitive research & feature ideas

## TL;DR

gothalo already covers the **hard 80%** that most competitors charge for: real-time snapshot sync, cross-server priority, one-tap approvals, live terminal + chat transcript, push alerts, QR pairing, and a fuzzy command palette. The clearest gaps versus paid apps are **(1) usage/rate-limit tracking, (2) a glanceable aggregate status + live "current activity" line, (3) a dedicated diff/working-tree review, and (4) lock-screen Live Activities / a home-screen widget.** Your unfair advantage is being **self-hosted over Tailscale with no cloud relay and no subscription** — lean into things the cloud apps structurally can't do (deep Herdr worktree/space integration, zero data leaving your tailnet).

---

## 1. The competitive landscape

### Direct competitors (mobile companions for AI coding agents)

| App | What it is | Notable features |
|---|---|---|
| **Moshi** ([getmoshi.app](https://getmoshi.app/)) | The app you're replacing. Mobile Mosh/SSH terminal + agent layer. | Unified **Inbox** (one row per session, updates in place vs. piling up), **Chat View** (tool calls/plans/approvals as tappable cards), **Usage tab** (rate-limit rings for Claude 5h/7d, Codex, etc.), **Live Activities**/Dynamic Island, **voice-to-terminal** (on-device Whisper), **image paste** (crop/scribble screenshots), **working-tree view** in the terminal header, **Apple Watch** app. Supports Claude Code, Codex, OpenCode, Gemini, Cursor, Kimi, Qwen. ([hooks/usage/watch article](https://getmoshi.app/articles/agent-hooks-live-activities-usage), [docs](https://getmoshi.app/docs/introduction)) |
| **Omnara** ([App Store](https://apps.apple.com/us/app/omnara-claude-codex-mobile/id6748426727)) | Cloud-synced Claude/Codex mobile control. | **Agent orchestration** (break tasks into parallel sub-agents from one dashboard), **review diffs + approve**, **live localhost previews** (no SSH/VPN), **voice coding**, laptop-downtime session preservation, iPhone/iPad/Watch. |
| **Orca** ([github.com/stablyai/orca](https://github.com/stablyai/orca)) | Open-source (MIT) "ADE" — run many agents in parallel git worktrees. Desktop + mobile companion. | **Parallel worktrees** as first-class, unified **diff review/annotate** dashboard, 30+ CLI agents, GitHub + Linear integration, SSH remote worktrees, Design Mode browser. Closest philosophical match to Herdr/gothalo. |
| **Claude Cowork mobile** (Anthropic) | Anthropic's own agent, now on mobile/web (Jul 2026, Max tier). | Monitor + approve agent tasks running in background; **push when Claude needs permission**. Tellingly, [<10% of Cowork sessions are software dev](https://venturebeat.com/technology/anthropic-brings-claude-cowork-to-mobile-and-web-as-usage-data-shows-most-users-arent-coding) — Anthropic is chasing general office work, which leaves the *developer-focused* multiplexer niche wide open for gothalo. |
| Others | CodeAgent Mobile, AgentsRoom, Junction Panel, CC Pocket | Same core loop: sync desktop sessions → monitor/approve/steer from phone, mostly with E2E encryption and cloud relays. |

**Consistent pattern across all of them:** a single **inbox with one row per agent session**, approvals surfaced to the top and to the lock screen, and increasingly a **usage/quota view**. gothalo matches the first two; the usage view is the standout thing you're missing.

### SSH-client home-screen patterns (Termius / Blink / Prompt)

- **Termius** — polished **host list** that syncs across all platforms, plus a **credential vault** and reusable **snippets**; the interesting bits are Pro-gated. ([comparison](https://termai.sh/blog/blink-shell-vs-termius))
- **Blink Shell** — minimal "shell prompt on your phone," best-in-class **keyboard/toolbar** and native **Mosh** for surviving flaky connections.
- Takeaway for gothalo: **saved-connection list + reusable snippets/quick-commands + a great custom keyboard toolbar** are the table stakes of this genre. You have the server list; snippets and a richer keyboard toolbar are unclaimed.

### Ops-dashboard-on-a-phone patterns (PagerDuty / Vercel / GitHub / Linear)

- **PagerDuty mobile home** ([support doc](https://support.pagerduty.com/main/docs/mobile-home-screen)): **My Open Incidents** (count + top 3), **on-call shifts**, **recently impacted services**, a **status dashboard** of top affected services by priority — and **user-customizable widgets**. The whole design is "3 most-important things per category, minimize taps."
- **Vercel** ([deployments](https://vercel.com/docs/deployments)): real-time **build progress broken into steps** with live logs — the "what is it doing *right now*" view.
- The reusable lesson: **an aggregate status summary + a short "top N that need you" list + a live per-item activity line.** gothalo has "top N need you" (Priority). It's missing the **aggregate summary** and the **live activity line**.

---

## 2. Where gothalo already stands (so we don't reinvent it)

Already built (from `app/lib/`): servers home with cross-server **Priority** (starred/blocked), per-server **Flock inbox** (Agents + Spaces, attention-first), **Overview** (workspace→tab→pane), live **xterm terminal** (`WS /attach`), chat **transcript** with composer + approval bar (`WS /agent-transcript`), one-tap **Approve** everywhere, permission-mode cycling, pane/tab/worktree actions, **Jump** fuzzy command palette, **FCM push** with in-place dismiss, and **QR pairing**. Real-time backbone is `WS /events` as a change-signal → debounced `/snapshot`.

**Notable existing gaps the code itself flags:** no usage/analytics anywhere, transcripts aren't persisted (only alerts are), branch is *inferred from cwd* (bridge doesn't expose it yet), and the server-side `agent.view` sort projection is stubbed pending backend support. *(Both of the latter two are now done — see §4.)*

---

## 3. Ranked feature shortlist

Ranked by (value to you) × (feasibility given the current architecture). Each tagged **Quick win** / **Medium** / **Bigger project**.

### #1 — Usage & rate-limit dashboard  ⭐ *Medium*
The single biggest thing every serious competitor has that gothalo doesn't (Moshi's Usage tab, Omnara/Orca quota views). Show Claude Code's **5-hour and 7-day windows**, Codex windows, and **remaining context** as ring/bar meters per agent account. Hugely useful when juggling multiple agents on one plan — you learn *why* an agent stalled (rate-limited) without opening the terminal.
- *Requires:* a bridge endpoint exposing ccusage-style data (host reads Claude/Codex usage). Client side is a new tab + rings — you already bundle no chart lib, so this is the one place a small meter widget is worth adding.
- *Why it's not #-hardest:* the data exists on the host; it's mostly plumbing + a display tab.

### #2 — Aggregate status header on Home  ⭐ *Quick win*
A single glanceable stat row at the top of the servers screen (and/or inbox): **`3 working · 1 needs you · 5 idle · 9 total`** across all servers, matching the PagerDuty "status dashboard" pattern. All data is already in the per-server snapshots you fetch for `_StatsLine`. Pure client work, no backend. Turns the home screen from "list of servers" into "state of my whole fleet at a glance."

### #3 — Live "current activity" line on agent tiles  *Quick win → Medium*
Vercel's "what's it doing right now" applied to agents: show a one-liner under each working agent — *"running: pytest," "editing router.dart," "waiting 4m."* You already fetch `AgentState.headline`/`detail` in the transcript screen (polled every 1500ms). Surfacing a lightweight version on inbox/priority tiles makes the list feel alive without opening each agent.
- *Quick* if you accept lazy/on-demand fetch for the focused/expanded tile; *Medium* if you want it in `/snapshot` for all tiles (bridge change).

### #4 — Diff / working-tree review screen  *Medium*
Moshi surfaces the working tree in the terminal header; Omnara and Orca make **"review the agent's diff and approve"** a headline feature. gothalo shows tool-call diffs inline in the transcript but has no dedicated "here's everything this agent changed" view. Add a per-agent **Changes** screen: `git status` + per-file diffs, with approve/continue. Natural companion to your existing approval bar.
- *Requires:* a bridge endpoint for `git diff`/`status` scoped to the pane's cwd/worktree. High value given Herdr's worktree-centric model.

### #5 — Lock-screen Live Activity + home-screen widget  *Quick win (widget) / Bigger (Live Activity)*
You already have FCM + `flutter_local_notifications`. Two glanceable upgrades:
- **Home-screen widget** (Quick-ish): "**N agents need you**" count that deep-links into Priority. Modest platform-channel work.
- **iOS Live Activity / Dynamic Island** (Bigger): show the active agent's current turn on the lock screen, updating in place — the thing Moshi/Omnara demo constantly. Bigger because Live Activities need native (Swift/ActivityKit) plumbing, but it's the most *demo-able* feature and directly what a phone monitor is for.

### #6 — Voice-to-text on the composer  *Quick win*
Every competitor ships voice; your composer is text-only. A `speech_to_text` mic button in the transcript composer is a small, self-contained add (on-device Whisper like Moshi is the bigger version — skip for v1). Genuinely useful for dictating a nudge one-handed.

### #7 — Quick-commands / snippets  *Quick win*
The Termius/Blink table-stake gothalo lacks: a small library of **reusable prompts/keystrokes** ("run tests," "continue," "explain the last error," an Escape/Ctrl-C combo) surfaced as chips above the composer and in the keyboard toolbar. Pairs perfectly with your existing `/send` (text + raw key) endpoints — pure client work, secure-storage backed like your starred agents.

### #8 — Recent-activity timeline  *Medium*
A **day-grouped activity timeline**: turn completions, tool errors, agents started/stopped — the PagerDuty "recently impacted" idea. Note the precedent: an alerts log over an `AgentEvents` drift table existed and was deleted (schema v4), because storing "agent went blocked/done" duplicates live state the bridge already answers. A timeline is only worth building if it records things the snapshot *can't* reconstruct — errors, transitions that left no trace — rather than a stale mirror of the current state.

### #9 — Image paste / screenshot into prompt  *Medium*
Moshi's crop/scribble and Omnara's screenshot-to-agent. Attach a screenshot to a prompt for design/bug feedback. *Requires* the bridge + target agent to accept image input (Claude Code supports it), so it's gated on backend/agent support — hence Medium, not quick.

> **Shipped** — `POST /image` + an "Image" chip on the composer. The gating
> assumption above turned out not to hold: **no agent-side image input is
> needed**. Agents read an image when handed a *path*, so the bridge writes the
> upload into the agent's own working directory and returns that path, which the
> app inserts into the composer (without sending) for the user to write around.
> Crop/scribble is the remaining Moshi delta. See
> [`CONTRACT-image.md`](CONTRACT-image.md).

### #10 — "Start a new agent task" flow  *Bigger project*
Omnara/Orca let you *launch* parallel agents, not just watch them. You already have `worktree.create` and `pane/new`; a guided "new task → creates worktree + starts agent with this prompt" flow would close the loop from *monitor* to *dispatch*. Bigger because it needs a start-agent contract on the bridge, but it's the natural next act for a fleet controller.

### #11 — Subagent view in the transcript  *Medium* — added 2026-08-05

Agents increasingly fan work out to **subagents**: Claude Code's Task tool, and
OpenCode's subagents. Today the transcript flattens that — you see the parent
invoke a tool and then, minutes later, a result, with no visibility into what
happened in between. On a phone, where the whole point is answering *"what is it
doing right now?"*, a long-running subagent is exactly the case where the current
view goes dark.

**On-disk layout — verified against live files on 2026-08-05**, not guessed.
Claude Code does *not* inline subagent turns in the session file. It writes each
subagent to a sibling directory named after the session:

```
~/.claude/projects/<encoded-cwd>/
    <session>.jsonl                      main transcript
    <session>/subagents/
        agent-<agentID>.jsonl            subagent transcript, same line format
        agent-<agentID>.meta.json        {agentType, description, toolUseId, spawnDepth}
```

The join is clean and needs no heuristics: `meta.json`'s **`toolUseId` equals the
`tool_use` id of the `Task` call in the main transcript**, which the reader
already captures as `Tool.ID`. `spawnDepth` gives nesting for free, and
`agentType` + `description` are exactly the label a collapsed row wants
("general-purpose · Build mobile Phase-3 control surface").

*(An earlier draft of this entry claimed the mechanism was an `isSidechain` flag
inline in `<session>.jsonl`. That was wrong — `isSidechain` exists as a field but
the subagent bodies live in the separate files above. Recorded so the mistake is
not repeated.)*

Shape: discover the sibling `subagents/` dir when resolving a session, attach a
subagent reference to the `Task` `tool_call` entry via the `toolUseId` join, and
let the app fetch a subagent's transcript on demand rather than inlining it
(these files are large — the sampled one was part of a 1.4 MB session). Render
collapsed-by-default with a live count and status — "3 subagents · 1 working".
`Entry` already carries `KindToolCall`/`KindToolResult` and the WS framing does
not change, so this is reader work plus one nesting level in the transcript
screen.

Worth doing because it compounds the differentiator: no competing Herdr client
reads transcripts at all, and a fleet controller that goes blind precisely when
an agent parallelizes has a hole in it. `opencode.go` needs the equivalent
treatment — check whether its SQLite store models subagents as separate sessions,
which would make the join different from Claude's.

---

### Deliberately deprioritized

- **Apple Watch / Wear companion** — cool, but a large surface for a solo project; revisit after Live Activities.
- **Live localhost preview** (Omnara) — largely redundant for you: over Tailscale you can already hit the dev server in a browser. Low incremental value.
- **Multi-account/team/sync** — that's the *cloud* business model; your self-hosted single-user model is the point. Skip.

---

## 4. Two "already-80%-there" cleanups worth finishing

These aren't new features so much as unlocking ones you've stubbed:

1. **Authoritative branch from the bridge** (today it's inferred from `cwd`). Once the bridge exposes branch, you can add **PR/branch linking** (tie an agent → its branch → GitHub PR), echoing Orca's GitHub integration — a cheap, high-signal addition to tiles.
2. ~~**Finish the server-side `agent.view` sort projection**~~ **Done — but not via `agent.view`.** Inbox ordering is now authoritative rather than client-sorted, delivered as an `attention_rank` the bridge stamps on every agent in `/snapshot`.

   Herdr's `agent.view` projection turned out to be a dead end: it *accepts* `agent.view.set` and reports the view `active`, but as of **herdr 0.8.0 (protocol 19) no read applies it** — `agent.list` and `session.snapshot` both return the unprojected list (verified with a filter that should have cut 8 agents to 6; it returned all 8), and there is no projected read method to forward. Its control socket is also strictly one-request-per-connection, so the bridge's stateless proxy was never the blocker. The `agent.view.*` handshake has been removed from the app and the proxy allowlist; revisit only if Herdr applies the view to a read.

---

## Sources

- Moshi: [getmoshi.app](https://getmoshi.app/) · [docs/introduction](https://getmoshi.app/docs/introduction) · [agent hooks/usage/watch](https://getmoshi.app/articles/agent-hooks-live-activities-usage) · [chat view](https://getmoshi.app/articles/claude-code-codex-chat-view) · [Blink vs Termius](https://getmoshi.app/articles/blink-vs-termius)
- Omnara: [App Store listing](https://apps.apple.com/us/app/omnara-claude-codex-mobile/id6748426727)
- Orca: [GitHub](https://github.com/stablyai/orca) · [App Store](https://apps.apple.com/us/app/orca-ide/id6766130217)
- Claude Cowork mobile: [TechCrunch](https://techcrunch.com/2026/07/07/the-coding-agent-wars-are-spilling-into-the-rest-of-the-office-claude-cowork/) · [VentureBeat (usage data)](https://venturebeat.com/technology/anthropic-brings-claude-cowork-to-mobile-and-web-as-usage-data-shows-most-users-arent-coding)
- Control-CC-from-phone roundups: [explainx.ai (2026 guide)](https://www.explainx.ai/blog/claude-code-mobile-remote-control-phone-guide-2026) · [Nimbalyst best apps](https://nimbalyst.com/blog/best-mobile-apps-for-claude-code-2026/)
- SSH clients: [Termius vs Blink (TermAI)](https://termai.sh/blog/blink-shell-vs-termius)
- Ops dashboards: [PagerDuty mobile home screen](https://support.pagerduty.com/main/docs/mobile-home-screen) · [PagerDuty new home blog](https://www.pagerduty.com/blog/incident-management-response/new-mobile-homescreen/) · [Vercel deployments](https://vercel.com/docs/deployments)

No code was changed — this is research and ideation only.

---

## Status (tracked here, updated as work lands)

- [x] #4 Diff/working-tree review screen — landed (`features/diff`)
- [x] #7 Quick-commands/snippets above composer — landed (`quick_commands_providers.dart`)
- [ ] #9 Image/screenshot into prompt — **in progress**, branch `feat/image-to-agent` (2026-08-05)
- [ ] #8 Recent-activity timeline — **in progress**, branch `feat/activity-timeline` (2026-08-05)
- [ ] #10 Start/restart/stop an agent — **in progress**, branch `feat/agent-lifecycle` (2026-08-05)
- [ ] #11 Subagent view in the transcript — queued (2026-08-05)
- [ ] Slash-command typeahead in the composer — queued (2026-08-05)
- [ ] Copy from the transcript screen — queued, small (2026-08-05)

Decided against / deferred (2026-08-05):

- **Audit log of phone writes** — rejected; won't be used. Both merino and
  herdr-remote ship one, but this is a small trusted team on a private tailnet.
- **Bridge self-update** — deferred until there is release wiring to hang it on.
- **Telegram bot** (herdr-remote) — skipped deliberately: it exists there because
  they could not ship native push. gothalo has FCM/APNs.
- **Codex transcripts** — deferred until there is a Codex subscription and a
  machine with real `~/.codex` rollout files. The format must be read off a live
  machine, not guessed; see the stub comment in `internal/transcript/codex.go`.
- **`GOTHALO_MODE=relay`** — keeping the stub as-is by decision, not oversight.

### Second competitive sweep (2026-08-05) — Herdr-specific clients

Four Herdr-specific projects, none of which existed at the first sweep:

| Project | Shape | Notable |
|---|---|---|
| [herdr-remote](https://github.com/dcolinmorgan/herdr-remote) (186★) | Python relay + native macOS + Telegram | agent timeline, digests, web push w/ auto-clear, 11 themes |
| [herdr-mobile-relay](https://github.com/0cv/herdr-mobile-relay) (27★) | Go+Node PWA, per-machine relay | multi-machine merge, 3 terminal fit modes, screenshots→agent, self-update w/ rollback, E2EE |
| [merino](https://github.com/LoneExile/merino) (5★) | Go+Wails menu bar + phone dashboard | inline Kitty images, slash-command typeahead, launch-agent button, audit log |
| [herdr-tether](https://github.com/moneycaringcoder/herdr-tether) (5★) | Rust plugin, tmux+SSH | durable sessions — orthogonal, potentially complementary |

They converge on the same three primitives gothalo already has: list agents
blocked-first, stream a pane, tap to approve. **None of them reads agent
transcripts** — they all show terminal output only. Combined with native APNs
push and a tailnet-only transport (two of the three route terminal traffic
through Cloudflare), that remains the differentiated core worth protecting.
