# gothalo bridge — API contract (for the mobile app)

This is the contract the app codes against. The backend was rebuilt into a
`gothalo` CLI + bridge with **QR pairing** and **per-device bearer tokens**.

## Base URL
```
https://my-mac.tailnet.ts.net:5338
```
The gothalo bridge, reachable over the tailnet (valid TLS) on port **5338**. The
base URL is not hardcoded in the real flow — the app derives it from the pairing
QR's origin (a tailnet URL today, a relay URL later).

## Auth model
- **Per-device bearer** (normal): every request sends
  `Authorization: Bearer <bearer>`, where `<bearer>` is returned by `/pair`.
- **Dev shortcut** (until the pairing UI exists): you may use the **admin token**
  as the bearer for manual testing. Get its value from the operator, or from
  `~/.gothalo/config.json` (`admin_token`) / the `gothalo serve` startup log —
  it is not committed. It also unlocks the admin endpoints below (so you can mint
  your own pairing codes for testing). Treat it as dev-only.

## Pairing flow (the real onboarding)
1. Operator runs `gothalo pair` on the host; it prints a QR encoding a small JSON
   payload:
   ```json
   { "url": "https://my-mac.tailnet.ts.net:5338", "code": "<8-hex one-time code>" }
   ```
2. App scans the QR and parses the JSON — `url` is the bridge base URL, `code` is
   the one-time code — then:
   ```
   POST <url>/pair
   Content-Type: application/json
   { "code": "<code>", "device_name": "Dipesh S22", "fcm_token": "<this device's FCM token>" }
   ```
   The device names itself via `device_name` (defaults to "device" if omitted).
3. Response `200`:
   ```json
   { "id": "92787cfa", "bearer": "<64-hex per-device bearer>", "name": "Dipesh S22" }
   ```
   Store `{ baseUrl: url, bearer }` in secure storage; use `bearer` for all calls.
   Errors: `403` invalid/expired/already-used code · `400` bad body.

   Codes are **one-time** and expire in ~5 min.

To mint a code yourself for testing (admin token):
```
POST /admin/pairing?token=<admin>   ->  { "code", "url" }
```

## Endpoints (per-device bearer)
| Method | Path | Body | Response | Notes |
|---|---|---|---|---|
| GET  | `/snapshot` | — | raw Herdr snapshot JSON | live agent state (shape below) |
| POST | `/send` | `{pane, text}` | `{ok:true}` | types text into a pane |
| POST | `/approve` | `{agent, seq}` | `{ok:true,applied:bool,reason?}` | idempotent one-tap approval (below) |
| GET  | `/agent-state` | — (query: `pane`) | parsed agent state JSON | compact card for an **agent** pane (below); carries `permission_mode` for Claude |
| GET  | `/diff` | — (query: `pane`) | `{branch, files[]}` | an **agent** pane's working-tree changes — branch + one unified diff per file (see [`CONTRACT-diff.md`](CONTRACT-diff.md)) |
| POST | `/agent-mode/cycle` | `{pane}` | `{ok:true,cycled:true,permission_mode?}` | advance a **Claude** pane's Shift+Tab permission mode by one (below) |
| GET  | `/agent-transcript` | — (query: `pane`, `token`) | **WebSocket** | streamed structured chat transcript for an **agent** pane (below) |
| GET  | `/attach` | — (query: `pane`, `token`) | **WebSocket** | live terminal for **any** pane (below) |
| GET  | `/events` | — (query: `token`) | **WebSocket** | unified push event stream: snapshot-on-connect, then deltas (below) |
| POST | `/pane/new` | `{split_from\|workspace_id, …}` | `{pane_id,tab_id,workspace_id}` | create a terminal, attach to it (below) |
| POST | `/pane/close` | `{pane_id}` | `{closed:true,pane_id}` | close a pane (below) |
| POST | `/herdr` | `{method, params}` | `{result}` or `{error}` | allowlisted generic proxy onto Herdr's command surface (below) |
| POST | `/register-token` | `{token}` | `{ok:true}` | call on FCM token refresh to update THIS device |
| POST | `/testpush` | — | `{ok:true,sent:true}` | fan a sample push to all devices (test your FCM handler) |

### /snapshot shape (what to render in the inbox)
```json
{ "result": { "snapshot": { "agents": [
  { "agent": "claude",
    "agent_status": "idle|working|blocked|done|unknown",
    "attention_rank": 0,
    "pane_id": "wN:p2",
    "state_change_seq": 42,
    "terminal_title_stripped": "…",
    "workspace_id": "wN",
    "branch": "feat/x",
    "cwd": "/…" }
] } } }
```
Group by `workspace_id`; badge on `agent_status`; title = `terminal_title_stripped`;
`pane_id` is the id used for `/send`, `/approve`, and `/attach`.
`state_change_seq` is a per-agent monotonic counter Herdr bumps on every state
transition — pass it to `/approve` as the idempotency token (see below).

**`attention_rank`** is the bridge's authoritative priority ordering — sort the
inbox on it ascending: `blocked` 0, `done` 1, `working` 2, `idle` 3, `unknown` 4
(an unrecognised status also ranks 4, so it sorts last). It is added by gothalo,
not herdr, and is always present. Sorting every surface on this one field is
what keeps list order and the counts derived from it consistent — don't
re-derive priority per screen. `branch` is likewise gothalo-added; both are
described in full in [`CONTRACT.md`](../CONTRACT.md).

## Push messages (what your FCM handler receives)
Messages are **data-only** (no `notification` block) so your handler always runs
and renders the notification itself (reliable on locked Android). Data keys:
```
title             e.g. "Herdr agent blocked"
body              the agent's terminal title
agent             the pane_id (e.g. "wN:p2")  -> deep-link target
status            "blocked" | "done"
state_change_seq  the agent's seq at this transition (string int) -> pass to /approve
```
Render a local notification from `title`/`body`; tapping it should deep-link to
the agent identified by `agent` (== `pane_id`). Carry `state_change_seq` into any
lock-screen/banner **Approve** action so `/approve` can no-op a stale tap (D8).

### `dismiss` — auto-clear a stale "blocked" notification
A **second, data-only** message shape the bridge sends when a `blocked` agent is
**resolved from anywhere** (this phone, another device, the desktop Herdr app, or
the agent just moving on). It tells every device to cancel the tray notification
it raised for that pane, so a handled block doesn't linger on other phones.
```
type    "dismiss"           <- the discriminator; normal pushes have NO type key
agent   the pane_id (e.g. "wN:p2")  <- cancel the notification keyed to this pane
```
There is **no** `title`/`body`/`status` (data-only, so your background handler
runs and cancels silently). Match on `data["type"] == "dismiss"`; if absent, treat
it as a normal push (above). It targets the **same** device set as the blocked
push (all registered devices). Triggered when the bus shows the pane leaving
`blocked` (`pane_agent_status_changed` with `agent_status != "blocked"`) or the
pane closing (`pane_closed` / `pane_exited`) — full contract in
[`CONTRACT-notif-clear.md`](CONTRACT-notif-clear.md).

### Native FCM setup
Add an **Android app** to Firebase project **YOUR_PROJECT_ID** → download
`google-services.json` into `android/app/`. Get the device token via
`firebase_messaging`, pass it as `fcm_token` during `/pair`, and
`POST /register-token {token}` whenever it refreshes.

## POST /approve — idempotent one-tap approval (D8)
One-tap "yes" for a **blocked** agent, safe to fire from a stale lock-screen
banner. The bridge sends the agent's confirm keystroke **only if** the agent is
still blocked at the `seq` you carried; otherwise it no-ops and tells you why.
```
POST /approve
{ "agent": "wN:p2", "seq": 42 }        // seq == the agent's state_change_seq
```
Response `200` (always `200` — `applied` tells you what happened):
```json
{ "ok": true, "applied": true }                                  // confirm keystroke sent
{ "ok": true, "applied": false, "reason": "agent is working, not blocked" }
{ "ok": true, "applied": false, "reason": "stale seq: approve carried 42, agent now at 45" }
{ "ok": true, "applied": false, "reason": "no such agent" }
```
The confirm keystroke is chosen per agent **kind** (`claude`, `codex`, …) from a
small server-side map, defaulting to **Enter** for unknown kinds — so the guard
and the key selection both live in the bridge and every approval surface inherits
them. `400` if the body lacks `agent`.

## GET /agent-state — parsed agent card
A compact, **parsed, plain-text** state for a single **agent** pane — the phone
alternative to WS /attach's raw terminal. Instead of a full PTY you get one JSON
struct: what the agent is doing, its last message, and — when blocked — the exact
question and choices it's waiting on (which pair with `POST /approve`). Use it for
agent panes; keep raw `/attach` for non-agent panes.
```
GET /agent-state?pane=<pane_id>[&recent=1]
Authorization: Bearer <bearer>          // same auth as everything; ?token= also works
```
The card is built from the pane's **current screen**. `?recent=1` additionally
reads the pane's **scrollback** for a richer `detail`/`transcript` — but Herdr can
only capture an alternate-screen pane's history by physically **scrolling the
pane**, which whoever is watching it on the desktop sees as a jump, once per
call. It is therefore **off by default** and should only be requested by a caller
that has no other source of history and has accepted that trade. `blocked`
(question + options) comes from the current screen and is identical either way.
Response `200` — the **stable contract** (kind-agnostic; the same shape for every
agent kind):
```jsonc
{
  "pane_id": "wQ:p2",
  "agent_kind": "claude",               // herdr agent kind
  "agent_status": "idle|working|blocked|done|unknown",
  "permission_mode": "auto",            // Claude ONLY: Shift+Tab mode; OMITTED for other kinds / when unknown
  "headline": "…",                      // one line: what it's doing / last step (the question when blocked)
  "detail": "…",                        // short plain-text body, ANSI/box-drawing already stripped
  "blocked": {                          // present ONLY when agent_status == "blocked"
    "question": "Do you want to proceed?",
    "options": [                        // may be empty for free-form prompts
      { "index": 1, "label": "Yes", "selected": true },
      { "index": 2, "label": "Yes, and always allow…", "selected": false },
      { "index": 3, "label": "No", "selected": false }
    ]
  },
  "transcript": [ "…recent plain-text lines…" ],   // optional, best-effort
  "parsed": true                        // false => unrecognised kind, raw text fallback
}
```
Field notes for the app:
- **`headline`** is always safe to render alone. When blocked it is the question.
- **`detail`** is phone-ready plain text (may contain `\n`); when blocked it's the
  context being approved (e.g. the command).
- **`blocked.options`** are tap targets. `selected:true` marks the default that a
  bare Enter accepts — so one-tap "Yes" is `POST /approve {agent, seq}` (Enter).
  To pick a *non-default* numbered option, type its number then Enter via
  `POST /send {pane, text:"2\n"}`. `index` is that number (0 if unnumbered — see
  `key`). An option with no `index` but a `key` (e.g. `"esc"`) has no menu number
  at all — it's Claude's single-choice approval form, where decline is only
  reachable via a keystroke; dispatch it with `POST /send {pane, key:"esc"}`.
- **`parsed:false`** means the agent kind has no dedicated parser yet, so
  `detail`/`transcript` are a best-effort raw recent-text dump. The card still
  renders; just don't rely on `blocked`. (claude is parsed today; codex and
  opencode are next behind the same contract.)
- `agent_status` is authoritative (straight from herdr). Pair it with the same
  `state_change_seq` from `/snapshot` for `/approve`.
- **`permission_mode`** is **Claude-specific** and **optional**: present only for
  `agent_kind == "claude"` and only when the mode could be read; it is **omitted**
  for every other kind and when unknown, so the field's absence is normal — never
  treat it as an error. Values: `"default"` · `"acceptEdits"` · `"plan"` ·
  `"auto"` · `"bypassPermissions"` (a build that names a mode differently passes
  its raw lowercased label through). It pairs with `POST /agent-mode/cycle`: cycle,
  then re-fetch `/agent-state` to show the new mode. See
  [`CONTRACT-agent-mode.md`](./CONTRACT-agent-mode.md).

Parsing never fails the request: an unrecognised layout degrades to `parsed:false`
rather than erroring. Errors: `400` missing `pane` · `401` bad bearer · `404` no
agent in that pane · `502` herdr command failed.

## POST /agent-mode/cycle — change a Claude agent's permission mode
The mobile remote for Claude's **Shift+Tab** key: it advances a Claude pane's
permission mode by one step around its ring
(`default → acceptEdits → plan → auto → …`, the exact set/order is whatever the
running Claude build cycles through). This is **Claude-specific** — the concept
only exists for Claude's TUI — so a non-Claude pane is rejected, never silently
keystroked.
```
POST /agent-mode/cycle
Authorization: Bearer <bearer>          // same auth as everything; ?token= also works
{ "pane": "wN:p2" }
```
Response `200`:
```json
{ "ok": true, "cycled": true, "permission_mode": "plan" }   // new mode, best-effort read-back
{ "ok": true, "cycled": true }                              // sent, but read-back didn't settle in time
```
`permission_mode` is a **convenience**: after sending the keystroke the bridge
polls the live mode for ~1 s and echoes the new value **if** it observed the
change. It may be absent even on success (the TUI hadn't redrawn yet). **The
authoritative flow is: cycle → re-fetch `GET /agent-state`** and read
`permission_mode` there. Setting a *specific* target mode is not a primitive —
cycle and read back until it matches.

Errors: `400` missing `pane` (or bad JSON) · `401` no/invalid bearer · `404` no
agent in that pane · `405` non-POST · **`409` "mode switching not supported for
this agent kind: <kind>"** (a non-Claude pane) · `502` herdr command failed. A
`409` is the documented, expected response for codex/opencode/etc — the app should
just hide the mode control for those kinds (their `/agent-state` omits
`permission_mode` too).

## WS /agent-transcript — streamed structured chat (agent panes)
`GET /agent-transcript?pane=<pane_id>&token=<bearer>` upgraded to a **WebSocket**.
This is the *chat view* data source: instead of scraping the terminal (like
`/agent-state`) or streaming raw PTY bytes (like `/attach`), the bridge reads the
agent's **own transcript file** (Claude Code writes JSONL at
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`) and streams it **normalized**
into a kind-agnostic chat schema — messages, thinking, tool calls (command + diff),
and tool results.

Frames are **text JSON**, one entry per frame (contrast `/attach`'s binary raw
bytes). On connect it sends a `hello`, replays the **newest page** (`entry` frames,
`live:false`, oldest→newest, ~150 newest — `has_older`/`has_more` flag older
elided, `oldest_loaded_seq` is the paging cursor), a `backlog_complete` marker,
then **tails** the file and pushes each new normalized `entry` (`live:true`) as the
agent appends it (250 ms poll). Correlate a tool call with its result via
`tool.id == result.for_id`; `seq` is the **absolute 1-based position** in the whole
file (stable cursor across pages and the tail — order/de-dupe on it).

**Paginated (protocol `2`).** To read older history the client sends a control
frame `{"type":"load_older","before_seq":<int>,"limit":<int≤500, default 150>}`
over the same socket; the server replies with that page (`entry` frames,
`live:false`, oldest→newest, `seq < before_seq`) then
`{"type":"page_complete","requested_before_seq","oldest_loaded_seq","has_older"}`.
The live tail keeps running while a page loads. Any other/garbage inbound frame
closes the socket cleanly (`1000`). Every page is read with a bounded ring buffer —
the whole file is never held in memory.

The transcript is resolved per agent kind from the pane's `cwd` +
`agent_session.value`. **Where** it lives varies by agent and the wire protocol
does not change with it: `claude` appends a JSONL file
(`~/.claude/projects/<encoded-cwd>/<session>.jsonl`, session id == the filename);
`hermes` keeps every session in a SQLite database (`~/.hermes/state.db`, resolved
by session id alone — Hermes sessions are not keyed by cwd).

For the file-backed kinds the newest-matching-`cwd` fallback applies **only when
`agent_session.value` is absent** — a known session id with no file on disk yet
returns `404` rather than falling back, since the fallback would return a
neighbouring pane's transcript. Install the Herdr agent integration (see the
README) so that id is always present; for `hermes` it is required, as there is no
cwd fallback to resolve with.

`opencode` likewise keeps sessions in SQLite (`~/.local/share/opencode/opencode.db`),
with content split across `message` rows and their child `part` rows.

This is READ-ONLY — prompts/approvals still go through `POST /send` /
`POST /approve`. `claude`, `hermes` and `opencode` are implemented; `codex` is
recognized but not yet wired (→ `404`). Errors before the upgrade: `400` missing `pane` · `401` bad token · `404`
no agent / no transcript / unsupported kind · `500` read failed · `502` herdr
failed. Close code `1000` on normal teardown.

**The full wire protocol, the normalized entry schema (every field), captured
examples of each kind, the resolution rule, and all limits live in
[`CONTRACT.md`](../CONTRACT.md).**

## WS /attach — live terminal (any pane)
`GET /attach?pane=<pane_id>&token=<bearer>` upgraded to a **WebSocket**. Auth is
via `?token=` (WS clients can't always set an `Authorization` header); the same
bearer/admin token works. **It attaches to ANY pane** — agent panes, plain
shells, dev-servers, logs — not just agent ones.
- **terminal → WS**: server sends **binary** frames — raw terminal bytes; feed
  them straight into your terminal emulator (`xterm.dart`).
- **WS → terminal**: send **binary** frames — raw keystrokes and control bytes
  (the accessory key row writes Esc `0x1b`, Ctrl-C `0x03`, arrows `\e[A`… here).
- **WS → resize** (control): send a **text** frame `{"type":"resize","cols":C,"rows":R}`
  to set the PTY geometry — send it on connect and on every viewport change, so
  the agent's line-editing (autocomplete, wrapping, history) redraws at your
  actual width. Agent panes apply it with `pty.Setsize`; plain panes own their
  geometry via Herdr and ignore it. Unknown/malformed text frames are ignored.

Two backends behind the one contract, picked automatically by pane kind — the
client can't tell them apart:
- **Agent panes**: unchanged — `herdr agent attach <pane>` under a PTY, copied
  byte-for-byte both ways (identical to before).
- **Plain panes**: the bridge polls `herdr pane read` (~5×/s) and repaints the
  socket (cursor-home + clear-screen + frame), and forwards inbound bytes to
  `herdr pane send-text`, which delivers raw bytes — Enter, arrows, Ctrl-C —
  straight to the pane's PTY. This is a full-frame repaint stream, so a plain
  pane refreshes on a short interval rather than character-by-character.

Binary frames are raw terminal bytes; **text** frames are out-of-band control
messages (today: `resize`). The backend (PTY process or poller) is stopped when
the socket closes (either side). Reconnect + re-fetch `/snapshot` is the
resilience story (no mosh-style state sync). The PTY starts at 80×24 and is
resized to the client's geometry by the first `resize` frame. Errors before the
upgrade: `404` if `pane` doesn't exist, `401` no/invalid token, `400` missing
`pane`.

## WS /events — unified push event stream
`GET /events?token=<bearer>` upgraded to a **WebSocket** carrying a single
unified event stream, so the app can stop refetching `/snapshot` after every
action. Auth is via `?token=` (like `/attach`). The stream is **text JSON**:

1. **On connect**, one **snapshot** frame — the full `/snapshot` payload plus the
   bus `seq` it's consistent with:
   ```json
   { "type":"snapshot", "source":"gothalo", "seq":420, "ts":<ms>,
     "snapshot": { "result": { "snapshot": { … } } } }   // same JSON as GET /snapshot
   ```
2. Then a stream of **delta** frames — the unified envelope:
   ```json
   { "source":"herdr"|"gothalo", "type":"<type>", "seq":<uint>, "ts":<ms>, "payload":{…} }
   ```

`seq` is process-monotonic (shared across sources + the snapshot baseline); every
delta is `> baseline`. Track the last `seq` — a gap (`seq > last+1`) means
reconnect (which re-snapshots). The stream carries **both** Herdr's normalized
events (`source:"herdr"` — `pane_agent_status_changed`, `pane_created`,
`tab_*`, `workspace_*`, `layout_updated`, …) and gothalo's own system events
(`source:"gothalo"` — `approve_applied`, `pane_created`/`pane_closed`,
`device_paired`, `push_sent`, `notification_cleared`,
`herdr_connected`/`herdr_disconnected`/`herdr_resync`).

`gothalo.notification_cleared` (payload `{pane}`) fires whenever the bridge
dismisses a stale `blocked` push (see the `dismiss` push above). It's a
consistency signal: a **foreground** app can clear its own UI from this event
without waiting for the FCM `dismiss`.

The bridge holds **one** Herdr socket subscription for the whole process and fans
it out; every client is just another in-process subscriber (never one Herdr
connection per client). A slow client is dropped with close code **`4000`** and
must reconnect + re-snapshot. Re-snapshot on: socket close, a `4000`, a
`gothalo.herdr_resync`, or a seq gap. `/events` is **server→client only** — any
inbound frame ends the connection. Errors before upgrade: `401` no/invalid token.

The **full envelope, the complete 25-type Herdr catalog + every gothalo type with
real captured examples, the reverse-engineered Herdr socket framing, and the
resync/reconnect rules** live in [`CONTRACT.md`](../CONTRACT.md) at the repo root
— that's what the app-side `HerdrStore` is built against.

`pane_agent_status_changed` payload is `{pane_id, workspace_id, agent,
agent_status}`; it does **not** carry `state_change_seq` (Herdr's event omits
it), so pair `pane_id` with the snapshot to get the seq for `/approve`.

## POST /pane/new — create a terminal from mobile
Creates a pane and returns its identity so the app can immediately `/attach` to
it. Two modes, chosen by the body:

**Split an existing pane** (adds a pane to that pane's tab):
```
POST /pane/new
{ "split_from": "w4:p1", "direction": "down", "cwd": "/opt/app", "command": "npm run dev" }
```
- `split_from` (**required for this mode**): pane id to split.
- `direction` (optional): `"right"` | `"down"` — defaults to `"down"`.

**New tab in a workspace** (opens the tab's root pane):
```
POST /pane/new
{ "workspace_id": "w4", "cwd": "/opt/app", "label": "logs", "command": "tail -f log" }
```
- `workspace_id` (**required for this mode**): workspace to add the tab to.
- `label` (optional): the new tab's label.

Common optional fields: `cwd` (working directory for the new shell), `command`
(a command line typed and run in the new pane once created). `split_from` wins if
both it and `workspace_id` are present.

Response `200`:
```json
{ "pane_id": "w4:p7", "tab_id": "w4:t5", "workspace_id": "w4" }
```
`pane_id` is what you pass to `/attach`, `/send`, and `/pane/close`. Errors:
`400` neither `split_from` nor `workspace_id` given (or bad JSON) · `404` unknown
pane/workspace · `401` no/invalid token · `502` herdr failed. Note: if `command`
fails to run the pane is still created and returned `200` (it's logged
server-side) — the app can attach regardless.

## POST /pane/close — close a pane
```
POST /pane/close
{ "pane_id": "w4:p7" }
```
Response `200`: `{ "closed": true, "pane_id": "w4:p7" }`. Closing a tab's last
pane closes the tab too. Errors: `400` missing `pane_id` · `404` unknown pane ·
`401` no/invalid token · `502` herdr failed.

## POST /herdr — allowlisted generic proxy (Herdr command parity)
One authenticated endpoint that forwards a **Herdr socket method** straight to
Herdr and returns its result — so the app gets parity with Herdr's command
surface (new worktree, new tab, split/close pane, close tab, plus reads) without
a bespoke bridge endpoint per operation. New Herdr methods become available with
no bridge change, as long as they are added to the allowlist.
```
POST /herdr
{ "method": "pane.split", "params": { "target_pane_id": "w4:p1", "direction": "down" } }
```
- `method` is a Herdr socket method id (from `herdr api schema --json`,
  `schemas.request`) — dotted, e.g. `tab.create`, NOT the CLI subcommand.
- `params` is forwarded verbatim; use the shapes from the schema. Omit or `{}`
  for reads that take no params.
- Success `200`: `{ "result": <herdr result, verbatim> }`.
- Failure: `{ "error": "<message>" }` with a status (see below).

**Only allowlisted methods are proxied; everything else is `403`.** The
authoritative allowlist, each method's params, and real captured examples live in
[`docs/CONTRACT-herdr-proxy.md`](CONTRACT-herdr-proxy.md) — the contract the
worktree/tab/pane controls are built against. Currently allowed: reads
(`session.snapshot`, `workspace.list/get`, `worktree.list`, `tab.list/get`,
`pane.list/get`, `agent.list/get`) and mutations (`worktree.create/open/remove`,
`workspace.create`, `tab.create/close/focus`, `pane.split/close/focus`,
`agent.focus`).

Status codes: `200` ok · `400` malformed body / missing `method` · `401`
no/invalid token · `403` method not on the allowlist · `404` Herdr
target-not-found (e.g. `pane_not_found`) · `502` socket/herdr unreachable or
other Herdr error.

## Errors
`401` missing/invalid bearer · `403` invalid pairing code / method not allowlisted
(`/herdr`) · `400` bad body ·
`404` unknown pane/tab/workspace, no agent in that pane (`/agent-state`,
`/agent-mode/cycle`, `/agent-transcript`), or no transcript file / unsupported
kind (`/agent-transcript`) · `405` wrong method (`/agent-mode/cycle` non-POST) ·
`409` mode switching not supported for the agent kind (`/agent-mode/cycle` on a
non-Claude pane) · `500` transcript read failed (`/agent-transcript`) · `502`
herdr command failed.
