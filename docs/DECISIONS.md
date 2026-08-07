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
the whole Ctrl-combo space into one button — it now lives in the more-sheet
below, but the mechanism is unchanged. ~15 lines of UI, not a keyboard
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

The row itself is **one strip of exactly seven small equal buttons spread
evenly**, and — this is the part that took two goes to get right — **the same
seven every time**:

```
Esc   ^C   ⋯   [pad]   Tab   ⌨   🖼
```

Even spacing is what makes it read as one control surface rather than a huddle
of chips, and seven puts the pad toggle on the exact centre line, directly under
the pad it opens. The **keyboard toggle** lives here rather than in the pad,
both for that count and because it's a screen control, not a keystroke; without
it the soft keyboard only ever appeared as a side effect of tapping the buffer,
which is also how you scroll it. **^C** is the one control byte with a place of
its own: it's the emergency stop and must never cost two taps.

Everything below the buffer is one `AccessoryButton` — same fill, radius, height
and mono type, width the only variable. Two earlier attempts are worth not
repeating: the quick commands as Material chips (outlined, proportional,
stadium) stacked above filled mono key blocks read as two unrelated toolbars;
and packing labelled chips *plus* a pinned toggle *plus* four keys into one row
needs ~470dp of a ~393dp phone, so something always clipped mid-word.

### The row is fixed because a config-shaped row has no centre

An earlier version of this row was seven *by default* and grew from there: it
prepended one button per saved quick command and carried `+` (add one) and a
sticky `Ctrl`. That made its width, and therefore its centre, a function of the
user's config. One saved command was enough to push the pad toggle off the
centre line; adding the image button pushed the strip past the screen entirely,
at which point `spaceEvenly` has no free space to distribute, the row
left-aligns and scrolls, and the toggle sits visibly off-centre under the pad it
opens. Shipped, spotted on a Pixel-class phone within minutes, and correctly
called out: the earlier note here claimed appending "moves nothing", which
confused preserving the *order* with preserving the *centre*. It preserved
neither for long.

So the variable half moved behind `⋯` into a **more-sheet**, and the row became
a constant:

- **Control bytes** — `^C ^D ^Z ^L ^R ^U ^W ^A ^E`. Not every combination: the
  ones that earn a button on a phone. End or detach (`^C ^D ^Z`), redraw a
  garbled repaint (`^L`), search history instead of typing a long command
  (`^R` — arguably the most valuable key here), fix a typo without forty
  backspaces (`^U ^W`), and jump to line start/end (`^A ^E`), which a soft
  keyboard has no Home/End for.
- **Sticky Ctrl** — kept, in the sheet. The nine bytes above are a shortlist,
  not the space; `^K`, `^P`/`^N`, `^B`/`^F`, `^X`, `^G`, `^]` all matter to
  somebody, and a phone keyboard has no Ctrl key of its own, so dropping this
  would make them unreachable rather than merely slower. It arms and closes the
  sheet, and the row's `⋯` **lights while armed** — otherwise the armed state
  would be invisible and the next letter would come out mangled with no warning.
- **Quick commands and `+`** — all of them, none pinned in the row. Pinning even
  one would put the count back under the user's control and the centring would
  drift again. The old "filter out a command that duplicates a row key" rule
  goes with them: it existed because a slot in the strip was scarce, and a sheet
  has room — quietly hiding something the user saved is the worse trade.

Every sheet action closes the sheet, because its result is on the terminal
behind it; multi-key work is what the arrow pad is for.

**Attaching an image is the seventh button.** It belongs below the buffer rather
than up in the app bar for the same reason the composer's paperclip sits inside
the input pill: it acts on what you are typing, not on the session. It types the
uploaded path into the PTY like any other keystrokes, with no carriage return —
same insert-don't-send rule as the composer — so it works for whatever is
running in the pane, and works on a pane with no agent at all. The bridge
resolves that pane's own cwd for the drop (see `CONTRACT-image.md`); a path is
just text, and nothing about typing one needs an agent to exist.

Seven buttons plus their gaps measure ~340dp against a 393–412dp phone, so the
row fits with room to spare and the even spread is real rather than a scroll
view's left edge. The minimum gap is 4dp, not 6dp, precisely because 6dp put it
~2dp over on the narrowest common phone — and 2dp of overflow is all it takes to
lose the property this row exists to hold. Tests pin the count, the toggle's
index, and that neither moves with the number of saved commands.

**The transcript composer follows the same rules** — the two screens are one
tap apart doing the same job, so a different toolbar vocabulary on each read as
an accident. Its actions row is the same evenly-spread `AccessoryButton`s
(mode, quick commands, `+`, jump, terminal); attaching an image moved *inside*
the composer pill, where every messaging app puts it and where it belongs, as
it acts on the message being written rather than on the session; and jump moved
down from the app bar, which is a stretch away at the top of a phone.

The composer's row **keeps its quick commands inline**, and did not follow them
into a sheet. Its width is config-shaped in the same way, but nothing there is
anchored to its centre — no popup opens from it — so a wider row merely scrolls,
which is the behaviour it was drawn for. And the chips are that row's *reason*:
the composer has no key strip, so a sheet would cost a tap on the surface where
quick commands are used most and buy nothing. Same list, same store, same
long-press-to-remove wherever it is shown.

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
