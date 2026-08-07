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

Arrows moved out of that row into an **arrow pad**: ↑ over ← ↓ → over ⌫ beside a
double-width Enter, with hold-to-repeat on everything except Enter (a leaned-on
thumb must not resubmit). Arrows are what agent TUIs (menus, history, approval
prompts) ask for most, but four more keys in a scrolling row is a poor way to
offer them.

A popup, not a fixture: it costs nothing while closed, and one tap dismisses it
when it's over something you want to read. An earlier draft floated permanently
over the buffer and was draggable to get it out of the way — dragging is a worse
answer to "it's covering something" than closing is, and having arrows in both
the pad and the row meant two homes for one key.

The row itself is **one strip of seven small equal buttons spread evenly**:
`+`, Esc, Ctrl, pad toggle, Tab, ^C, keyboard. Even spacing is what makes it
read as one control surface rather than a huddle of chips, and seven puts the
pad toggle on the exact centre line — directly under the pad it opens. The
**keyboard toggle** lives here rather than in the pad, both for that count and
because it's a screen control, not a keystroke; without it the soft keyboard
only ever appeared as a side effect of tapping the buffer, which is also how you
scroll it.

Everything below the buffer is one `AccessoryButton` — same fill, radius, height
and mono type, width the only variable. Two earlier attempts are worth not
repeating: the quick commands as Material chips (outlined, proportional,
stadium) stacked above filled mono key blocks read as two unrelated toolbars;
and packing labelled chips *plus* a pinned toggle *plus* four keys into one row
needs ~470dp of a ~393dp phone, so something always clipped mid-word.

Quick commands that merely fire a key this bar already has are **filtered out
here**. The shipped default, "Interrupt", sends `esc` — the same keystroke as
the Esc button three slots over. It earns its place in the transcript composer,
which has no key strip; on the terminal it was the same key twice.

**The transcript composer follows the same rules** — the two screens are one
tap apart doing the same job, so a different toolbar vocabulary on each read as
an accident. Its actions row is the same evenly-spread `AccessoryButton`s
(mode, quick commands, `+`, jump, terminal); attaching an image moved *inside*
the composer pill, where every messaging app puts it and where it belongs, as
it acts on the message being written rather than on the session; and jump moved
down from the app bar, which is a stretch away at the top of a phone.

The agent's "working" state there is now a **bar sweeping the seam** above those
controls, with no `thinking…` label — the motion says it, and the word cost a
line of transcript. Pulsing dots were the wrong borrow: they promise an imminent
message, where this is a machine holding a turn open for anything up to ten
minutes.

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

## D20 — FCM credentials follow ADC; a shared key file is not the only path
`internal/push` accepts **two credential shapes** and finds them by Google's
Application Default Credentials search order (configured path → `$GOOGLE_APPLICATION_CREDENTIALS`
→ gcloud's well-known file → GCE/Cloud Run metadata server).

The motivation is team access, not flexibility. A downloaded service-account key
is a shared bearer secret: everyone holding the file is the *same* identity,
rotation breaks everyone at once, and the audit log can't attribute a send. Adding
`authorized_user` support means a teammate runs `gothalo push login`, authenticates
as themselves via gcloud, and is granted/revoked individually in IAM — nobody
copies a key. This is also what makes the repo publishable: there is no shared
secret that *must* exist for a contributor to run the thing.

Consequences:
- The two shapes mint tokens by different grants (jwt-bearer vs refresh_token),
  so `mintToken` dispatches on shape. Scopes are bound at consent time for the
  refresh grant — hence `push login` passing `--scopes` explicitly, since gcloud's
  default set omits `firebase.messaging` and the resulting 403 reads as a
  permissions bug rather than a scope bug.
- User credentials name a *person*, not a project, so `push.project_id` becomes
  required on that path (`push login` persists it).
- `push status` verifies with FCM's `validate_only` rather than sending, and maps
  403 to a distinct error — "authenticated but never granted access" is the one
  failure a teammate cannot fix by logging in again.
- The metadata-server branch means a future hosted relay (D12) can run with **no**
  key material anywhere. That is a free consequence of following ADC, not a
  commitment to build the relay.

## D21 — Terminal scroll is a wheel report to the application, not scrollback
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
are the one case where a `recent` read is worth having — see D22.

## D22 — A plain pane's scrollback is seeded once, not paged
A plain pane has no application to send a wheel to (D21) and no live byte stream:
the client receives whole frames prefixed with a clear-screen, so its buffer holds
nothing to scroll back through. `WS /attach` therefore sends **one** history frame
before the first repaint — `pane read --source recent-unwrapped`, without the
clear-screen prefix, so it lands in the emulator's own scrollback. Later repaints
erase only the viewport (ED 2 leaves scrollback alone), so the seed survives.

Once, not paged, because **Herdr caps `pane read` at 1000 rows** and exposes no
offset parameter. Measured on two panes holding far more: a `docker compose logs -f`
pane with 10,467 rows and a server log with 1,960 — `--lines` of 1100, 1500 and
20000 all returned exactly 999. So 1000 rows is the entire reachable history and a
merino-style growing window buys nothing (merino's own 2000-line cap is above what
Herdr will return). Deeper history needs an offset method Herdr does not have.

Unwrapped, because the captured rows are folded at the *desktop's* column count;
replaying those folds on a phone double-wraps every long log line. Reading is
side-effect-free for the operator — on a pane sitting 1,254 rows back, a read left
`offset_from_bottom` untouched, so the old warning in `bridge_client.dart` (that
history could only be captured by physically scrolling the pane) no longer holds.

Accepted wart: the seed ends with the current frame, so a few lines can appear both
in scrollback and on screen. Trimming by the pane's row count would risk cutting
past the overlap and leaving a silent gap, and a repeated line beats a lost one.

## D23 — The Priority section is capped, but "needs you" is exempt
Priority is automatic (every `blocked` **and** `done` agent lands in it) plus
whatever you starred, so with a dozen agents live it grew past the viewport and
pushed the servers list off the bottom of the home screen — the one screen that
is supposed to answer "what now" at a glance.

It collapses to **five rows** (`kPriorityVisibleRows`) with a `Show N more`
expander. Five two-line tiles plus the header and the expander leave two or
three server tiles visible on a ~390×780dp phone, which is the point: Priority
is the top of the home surface, not the whole of it.

The cap is **soft in exactly one direction**. An agent that needs you is never
behind the expander: the cut stretches down the list to cover the last `blocked`
row, so ten blocked agents render ten rows. More blocked agents than fit *is*
the case the app exists for, and a screen that hid them to stay tidy would be
tidy and wrong. Nothing stretches it the other way — `done`, `working`, `idle`
and starred rows all sit under the cap, so a starred idle agent can be behind
the expander.

Ordering is untouched. `PriorityOverflow` only ever cuts a **prefix** off the
list the bridge already ranked by `attention_rank` (see `docs/API.md`); it never
sorts, and the exemption is defined on the row ("does this one need
you") rather than on its position, so an older bridge whose ranks arrive via the
local fallback still can't bury a blocked agent. Starred does **not** promote a
row above the bridge's rank — that would be a second, client-side priority
order, which is the thing `attention_rank` exists to prevent.

Collapsed, the footer carries a **tally of the whole section** — `3 need you ·
5 done · 2 idle`, in each status's own badge colours — not of the hidden part.
A collapsed section should still say what it is sitting on; "5 hidden" alone
says only how much you are missing, never whether it matters. Expanded, the
counts go away (the rows say it) and only `Show less` remains — the control
outlives its own use, or the tap that opened the list would delete the only way
to shut it.

Expanded/collapsed is remembered **for the session** (a plain `Notifier`) and
**shared** by both surfaces that render the section — the home screen and the
Priority screen. It is one list drawn twice; open in one place and shut in the
other reads as a bug. A cold start comes back collapsed, which is the state that
fits the screen.

## D24 — Deleting a worktree's branch is the bridge's own endpoint, and the safety rules live there
Removing a worktree from the phone cleaned up the checkout and the workspace and
left the **branch** behind, every time. That is not an oversight in the app:
Herdr has no notion of branches anywhere on its socket, so there was nothing to
proxy and nothing else in the system to pick it up. With worktree creation down
to one tap, the refs pile up faster than anyone prunes them, and a phone is the
one place with no way to prune.

So `GET /branch-info` + `POST /branch-delete` (see
[`CONTRACT-branch-delete.md`](CONTRACT-branch-delete.md)) shell out to **git**
directly — the same exception `/diff` and `internal/transcript` already are, for
the same reason: the thing being read or done is not part of Herdr's model.

They are deliberately **not** on the `/herdr` allowlist (D18). That proxy's whole
design is "params verbatim, no server-side validation", which is exactly wrong
for an operation whose entire substance is what it refuses to do. The rules —
never the default branch, whatever it is called; never a branch checked out in
any worktree; unmerged only on an explicit force — live in `internal/gitbranch`
and re-run on **every** delete, so they hold for any caller and never depend on
the preflight the client happens to be holding.

Two endpoints rather than one, because they answer either side of an operation
that can fail. The preflight needs the workspace to still exist (it is what
names the branch and the repo root); the delete needs the checkout to be gone
(git refuses a checked-out branch). Between them sits `worktree.remove`, and if
that fails the branch delete must not run — which only the caller can know.

**Default off, and unmerged is a second dialog.** Removing a worktree is
recoverable (`worktree.open` brings it back); deleting a branch is much less so,
and a phone is where a mis-tap is most likely. A merged branch is one checkbox.
An unmerged one names the commit count in its own confirm before the box will
tick — the same tap must not mean both things.

**The default branch is resolved, never assumed.** `refs/remotes/<remote>/HEAD`
first, then a conventional local name; if neither answers, nothing in that repo
is deletable. Assuming `main` is the single failure mode here with no recovery,
and a repo on `trunk` is not exotic.

**Partial outcomes are reported as partial.** "Worktree gone, branch kept" is a
normal result — unmerged, refused, or a bridge too old to have the endpoint —
and it says so rather than showing a generic success. Likewise the local delete
never touches the remote, so `upstream` and `remote_deleted:false` come back in
the payload and the UI states it. Pushing a branch deletion from a phone affects
everyone and reaches outside the host; nothing else on this bridge does that, and
this does not either.
