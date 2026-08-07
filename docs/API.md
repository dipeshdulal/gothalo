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
| GET  | `/info` | — | `{server_id, server_name}` | this bridge's identity — map an incoming push's `server_id` to a saved server |
| GET  | `/snapshot` | — | raw Herdr snapshot JSON | live agent state (shape below) |
| POST | `/send` | `{pane, text}` | `{ok:true}` | types text into a pane |
| POST | `/approve` | `{agent, seq}` | `{ok:true,applied:bool,reason?}` | idempotent one-tap approval (below) |
| GET  | `/agent-state` | — (query: `pane`) | parsed agent state JSON | compact card for an **agent** pane (below); carries `permission_mode` for Claude |
| GET  | `/diff` | — (query: `pane`) | `{branch, files[]}` | an **agent** pane's working-tree changes — branch + one unified diff per file (see [`CONTRACT-diff.md`](CONTRACT-diff.md)) |
| POST | `/image` | raw image bytes (query: `pane`) | `{path, relative_path, content_type, bytes}` | drop a screenshot into **any** pane's tree and get the path back, to paste into a prompt or type into the terminal (see [`CONTRACT-image.md`](CONTRACT-image.md)) |
| GET  | `/timeline` | — (query: `limit?`, `pane?`) | `{entries[], limit}` | recent agent-activity log, newest first — one entry per status transition, each with how long the previous status lasted (below; see [`CONTRACT-timeline.md`](CONTRACT-timeline.md)) |
| GET  | `/commands` | — (query: `pane`) | `{pane, agent_kind, commands[]}` | the slash commands an **agent** pane accepts, for the composer typeahead — discovered from disk plus the agent's built-ins (below; see [`CONTRACT-commands.md`](CONTRACT-commands.md)) |
| POST | `/agent-mode/cycle` | `{pane}` | `{ok:true,cycled:true,permission_mode?}` | advance a **Claude** pane's Shift+Tab permission mode by one (below) |
| GET  | `/agents/available` | — | `{agents[],known_kinds[],discovery}` | which agent kinds this host can actually launch (below) |
| POST | `/agent/start` | `{kind, pane_id\|split_from\|workspace_id, …}` | `{pane_id,tab_id,workspace_id,kind,name,…}` | launch an agent, optionally in a pane it creates (below) |
| POST | `/agent/restart` | `{pane_id, prompt?}` | `{restarted:true,pane_id,kind,…}` | replace the agent in a pane — **loses the conversation** (below) |
| POST | `/agent/stop` | `{pane_id}` | `{stopped:true,pane_id,kind}` | quit the agent, keep the pane (below) |
| GET  | `/agent-transcript` | — (query: `pane`, `token`) | **WebSocket** | streamed structured chat transcript for an **agent** pane (below) |
| GET  | `/attach` | — (query: `pane`, `token`) | **WebSocket** | live terminal for **any** pane (below) |
| GET  | `/events` | — (query: `token`) | **WebSocket** | unified push event stream: snapshot-on-connect, then deltas (below) |
| POST | `/pane/new` | `{split_from\|workspace_id, …}` | `{pane_id,tab_id,workspace_id}` | create a terminal, attach to it (below) |
| POST | `/pane/close` | `{pane_id}` | `{closed:true,pane_id}` | close a pane (below) |
| POST | `/herdr` | `{method, params}` | `{result}` or `{error}` | allowlisted generic proxy onto Herdr's command surface (below) |
| GET  | `/branch-info` | — (query: `workspace_id`) | `{branch, default_branch, merged, deletable, …}` | preflight for "also delete the branch" when removing a worktree (below; see [`CONTRACT-branch-delete.md`](CONTRACT-branch-delete.md)) |
| POST | `/branch-delete` | `{repo_root, branch, force?}` | `{deleted, forced, sha, upstream, …}` | delete a local git branch, after its worktree is gone (below) |
| POST | `/register-token` | `{token}` | `{ok:true}` | call on FCM token refresh to update THIS device |
| POST | `/testpush` | — | `{ok:true,sent:true}` | fan a sample push to all devices (test your FCM handler) |

### /snapshot shape (what to render in the inbox)
```json
{ "result": { "snapshot": { "agents": [
  { "agent": "claude",
    "agent_status": "idle|working|blocked|done|unknown",
    "attention_rank": 0,
    "recency_rank": 3,
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

**`recency_rank`** is the second half of the list order: sort agents on
`(attention_rank, recency_rank)`, both ascending. It is gothalo-added, always
present, unique within a snapshot, and lowest = most recently active — the
tiebreak *within* an attention rank, so what needs a human is unaffected. It is
an index into **this** snapshot on **this** bridge: don't cache it, and don't
compare it across servers (fall through to `last_activity_ts` there). Derivation
and the undated-agent rules are in [`CONTRACT.md`](../CONTRACT.md) §2.A.

**`attention_rank`** is the bridge's authoritative priority ordering — sort the
inbox on it ascending: `blocked` 0, `done` 1, `working` 2, `idle` 3, `unknown` 4
(an unrecognised status also ranks 4, so it sorts last). It is added by gothalo,
not herdr, and is always present. Sorting every surface on this one field is
what keeps list order and the counts derived from it consistent — don't
re-derive priority per screen. A surface that can't show every agent may cut the
**prefix** of that order (the app's Priority section does — D23), but it must
not re-sort, and it must not hide a `blocked` agent to stay short.
`branch` is likewise gothalo-added; both are
described in full in [`CONTRACT.md`](../CONTRACT.md).

## Push messages (what your FCM handler receives)
Each alert arrives as **two** messages, both at `android.priority: "high"` and
sharing one `tag`, told apart by the `render` key:

- `render:"os"` — carries a `notification` block. Android draws it with no app
  process involved, which is what makes it survive the app being killed. Android
  does **not** hand this one to your handler while backgrounded, so it can never
  have buttons.
- `render:"app"` — data-only, so your handler *does* run. Redraw the same tag
  (id `0`) with action buttons; it replaces the one above in place.

**Ignore `render:"os"` in your handler**: rendering it duplicates what Android
drew, and logging it double-counts, since a foreground app receives both.

```
type              "alert"
render            "os" | "app"
agent             the pane_id (e.g. "wN:p2")  -> deep-link target
status            "blocked" | "done"
state_change_seq  the agent's seq at this transition (string int) -> pass to /approve
server_id         which bridge sent this  -> which server the tap should open
server_name       that bridge's name, e.g. "Mac Studio"
agent_title       the pane's terminal title
title, body       the composed notification text
question          (blocked, best-effort) what the agent is actually asking
options           (blocked, best-effort) JSON [{index,label,selected,key}]
category          (blocked, best-effort) e.g. "dangerous_command_approval"
```

`server_id` matters because one phone registers the **same** FCM token with every
bridge it pairs with: without it an alert can't be attributed and its tap can't
be routed. Resolve it against `GET /info`. Carry `state_change_seq` into any
lock-screen **Approve** so `/approve` can no-op a stale tap (D8).

### `dismiss` — auto-clear a stale notification
A **second, data-only** message the bridge sends when a notified agent is
**resolved from anywhere** (this phone, another device, the desktop Herdr app, or
the agent just moving on). It tells every device to cancel the tray notification
it raised for that pane.
```
type       "dismiss"    <- the discriminator; an alert carries "alert"
agent      the pane_id (e.g. "wN:p2")
server_id  the sending bridge; cancel the notification tagged "<server_id>/<pane_id>"
```
There is **no** `title`/`body`/`status` (data-only, so your background handler
runs and cancels silently). Triggered when the bus shows the pane leaving the
state it was notified about, or the pane closing (`pane_closed` / `pane_exited`)
— full contract in [`CONTRACT-notif-clear.md`](CONTRACT-notif-clear.md).

The complete payload, channel, tag, action and routing contract lives in
[`CONTRACT-notifications.md`](CONTRACT-notifications.md).

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
The card is assembled from two sources, deliberately:

| Field | Source |
|---|---|
| `headline`, `detail`, `transcript` | the agent's own **transcript store** (the same one `/agent-transcript` streams) |
| `blocked` (question + options) | the pane's **current screen** |

`blocked` cannot come from a transcript: a permission or question prompt is UI the
agent is drawing *right now* to ask you something, not conversation, so nothing
records it. Everything else is read from structured data — already parsed, not
truncated by the viewport, and with no effect on the operator's screen.

For a kind with **no transcript reader**, `headline`/`detail`/`transcript` fall
back to the current screen. `?recent=1` additionally reads the pane's
**scrollback** for a richer fallback, but Herdr can only capture an
alternate-screen pane's history by physically **scrolling the pane**, which
whoever is watching it sees as a jump, once per call. It is therefore **off by
default** and only worth requesting for a kind with no transcript.
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

## POST /image — attach a screenshot to a prompt
Upload an image from the phone; the bridge writes it into the target pane's
working directory and returns the **absolute path** it wrote. Coding agents read
an image when handed a path, so that path — pasted into the composer, or typed
into the terminal, as ordinary text — is the whole attachment mechanism. No
agent protocol is involved.
```
POST /image?pane=wN:p2
Authorization: Bearer <bearer>
Content-Type: application/octet-stream

<raw image bytes>
```
Response `200`:
```json
{ "path": "/Users/dipesh/projects/gothalo/.gothalo/images/20260805-142530-9f86d081.png",
  "relative_path": ".gothalo/images/20260805-142530-9f86d081.png",
  "content_type": "image/png",
  "bytes": 184320 }
```
The body is **raw bytes, not multipart** — deliberately, because a filename is
the one thing this endpoint must never accept. Nothing about the written file is
client-controlled: the pane picks the directory, the **sniffed** content type
(`http.DetectContentType`, never the declared one) picks the extension, and the
bridge picks the name. `?name=`, `?filename=` and `Content-Disposition` are not
read at all.

Accepts **png/jpeg/gif/webp** only, capped at **10 MiB** inclusive. Files land in
`<pane cwd>/.gothalo/images/`, which is self-gitignored on first write and
pruned on every write (7 days / 40 files). The app inserts `path` where the user
is typing and **does not send** — they write the prompt around it.

**Any pane**: the drop directory is the agent's `cwd` when the pane hosts one and
the pane's own `cwd` when it doesn't, so the terminal screen can type a path into
a plain shell too. (`/diff` stays agent-only — it asks a question a pane without
one can't answer.) Accepts the session-qualified `<session>/<pane>` id form.

Errors: `400` missing `pane` or empty body · `401` bad bearer · `404` unknown
pane, or one Herdr reports no cwd for · `405` non-POST · `413` over the cap ·
`415` not an accepted image type · `500` the drop directory couldn't be written ·
`502` herdr command failed.
Full details in [`CONTRACT-image.md`](./CONTRACT-image.md).

## GET /commands — slash commands for the composer typeahead
What the pane's agent will **actually accept** after a `/`, so the phone offers a
list instead of asking the user to recall and thumb-type `/compact`.

```
GET /commands?pane=w5:p18
```

```json
{
  "pane": "w5:p18",
  "agent_kind": "claude",
  "commands": [
    {"name": "migrations", "description": "…", "source": "skill", "scope": "project"},
    {"name": "compact", "description": "…", "argument_hint": "[instructions]", "source": "builtin"}
  ]
}
```

`source` is `command` (`.claude/commands/**.md`) · `skill`
(`.claude/skills/<name>/SKILL.md`) · `builtin`. The first two are read off disk
per request and are ground truth; `builtin` is a hand-maintained list, because
built-ins live inside the agent's binary with no manifest to read — it is a
separate `source` precisely so the app can badge what it cannot verify. `scope`
is `user`/`project` for discovered commands, absent for built-ins. Sorted
most-specific first: project → user → built-in.

An agent kind with no command surface (codex, opencode) is **`200` with an empty
list, not an error** — "no typeahead here" is a normal state, and a 404 would put
an error in front of a working pane. Errors: `400` missing `pane` · `401` bad
bearer · `404` no such pane, a plain pane, or a bridge predating the endpoint
(the app hides the typeahead for all three). Full details, plus a live capture
and the plugin-commands gap, in [`CONTRACT-commands.md`](./CONTRACT-commands.md).

## GET /timeline — recent agent activity
The only read that describes the **past**. Every other endpoint says what is true
now, which is why none of them can tell you whether an agent blocked fifty
minutes ago or ten seconds ago — the status is the same either way.

```
GET /timeline?limit=100&pane=w4:p2
```
Both query params are optional: `limit` defaults to `100` and is capped at `500`;
`pane` (session-qualified, matched whole) restricts the log to one agent.

Response `200`, **newest first**:
```json
{ "entries": [
  { "ts": 1785681000000, "pane": "w4:p2", "agent": "claude", "session": "default",
    "workspace": "w4", "from": "working", "to": "blocked", "prev_ms": 742000 }
], "limit": 100 }
```
- **`prev_ms`** — how long the agent spent in `from`. This is the whole point of
  the endpoint and the one fact `/snapshot` cannot reconstruct (`state_change_seq`
  is a counter, not a clock). **Absent ≠ `0`**: `0` is a real instantaneous flip,
  absent means the bridge could not see where the span began. Render nothing, not
  "0s".
- **`from` absent** = a first sighting of that pane, not a transition out of an
  unnamed state. **`to: "gone"`** = the pane closed or its process exited.
- Answered from an in-memory ring — **no herdr call** — so it is cheap to poll
  and still answers while herdr is down. The ring is bounded (1500 entries / 72h)
  and persisted, so a bridge restart does not lose the recent past.

Errors: `400` `limit` present but not a positive integer (malformed is rejected,
never silently defaulted) · `401` bad bearer · `503` bridge running without a
recorder (distinct from an empty `entries[]`, which just means nothing has
happened yet). Timeline entries are deliberately **not** carried on `WS /events`
— see [`CONTRACT-timeline.md`](CONTRACT-timeline.md) for why, and for the full
schema and restart semantics.

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
`GET /agent-transcript?pane=<pane_id>&token=<bearer>[&subagent=<agent_id>]` upgraded
to a **WebSocket**.
This is the *chat view* data source: instead of scraping the terminal (like
`/agent-state`) or streaming raw PTY bytes (like `/attach`), the bridge reads the
agent's **own transcript file** (Claude Code writes JSONL at
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`) and streams it **normalized**
into a kind-agnostic chat schema — messages, thinking, tool calls (command + diff),
and tool results.

`hello` also carries `subagents`: the session's flat roster of conversations
delegated via the `Task` tool, joined to their spawning tool call by
`tool_use_id`. Pass one back as `?subagent=<agent_id>` to stream that child
conversation through identical framing. See
[`CONTRACT-agent-transcript.md`](CONTRACT-agent-transcript.md#subagents).

Frames are **text JSON**, one entry per frame (contrast `/attach`'s binary raw
bytes). On connect it sends a `hello`, replays the **newest page** (`entry` frames,
`live:false`, oldest→newest, ~150 newest — `has_older`/`has_more` flag older
elided, `oldest_loaded_seq` is the paging cursor), a `backlog_complete` marker,
then **tails** the file and pushes each new normalized `entry` (`live:true`) as the
agent appends it (250 ms poll). Correlate a tool call with its result via
`tool.id == result.for_id`; `seq` is the **absolute 1-based position** in the whole
file (stable cursor across pages and the tail — order/de-dupe on it).

**Follows the pane across sessions (protocol `4`).** A pane's agent session
rotates on `/clear`, `/new`, `/resume` or a restarted agent, and the old
transcript stops growing. The bridge re-reads `agent_session.value` every 2 s and,
on a change, re-points the socket at the new session and replays the opening
sequence in place: `{"type":"session_changed","pane","from","to"}`, then a fresh
`hello` (new `session_id`) + backlog + `backlog_complete`, then the live tail.
**A client must discard everything it holds on `session_changed`** — `seq` is
absolute *within a session* and restarts at 1, so kept entries collide with the
new ones. A rotation that happens while the socket is down has no
`session_changed`, so also reset whenever `hello.session_id` differs from the one
you hold. `hello.subagents` is re-read for the new session. A `?subagent=` stream
is exempt — a delegated conversation belongs to the session that spawned it.

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
  (the accessory key row and the floating arrow pad write Esc `0x1b`, Ctrl-C
  `0x03`, arrows `\e[A`… here).
- **WS → resize** (control): send a **text** frame `{"type":"resize","cols":C,"rows":R}`
  to set the PTY geometry — send it on connect and on every viewport change, so
  the agent's line-editing (autocomplete, wrapping, history) redraws at your
  actual width. Agent panes apply it with `pty.Setsize`; plain panes own their
  geometry via Herdr and ignore it. Unknown/malformed text frames are ignored.
- **WS → mode** (control): the server sends a **text** frame
  `{"type":"mode","agent":<bool>}` when the pane's occupant changed and the
  backend was swapped underneath this same socket — see below.

Two backends behind the one contract, picked automatically by pane kind — the
client can't tell them apart:
- **Agent panes**: unchanged — `herdr agent attach <pane>` under a PTY, copied
  byte-for-byte both ways (identical to before).
- **Plain panes**: the bridge polls `herdr pane read` (~5×/s) and repaints the
  socket (cursor-home + clear-screen + frame), and splits inbound bytes between
  `herdr pane send-text` (literal text) and `herdr pane send-keys` (Enter, Tab,
  Esc, arrows, Ctrl-*, Backspace). The split is required, not stylistic:
  `send-text` **types** text and silently drops control sequences, so an arrow
  sent as `\e[B` never reaches the pane — verified live against a `less` pane
  that stayed put for `send-text` and scrolled for `send-keys down`. Sequences
  Herdr has no key name for (Home, End, PageUp/Down) fall through as text.
  This is a full-frame repaint stream, so a plain pane refreshes on a short
  interval rather than character-by-character.

  **The first frame is a scrollback seed**, not a repaint: up to 1000 rows of
  `herdr pane read --source recent-unwrapped`, sent **without** the clear-screen
  prefix so it lands in the emulator's scrollback and the user can drag back
  through it. Every later frame is a normal repaint, and its erase-display
  clears only the viewport, leaving the seed intact. A client needs no new code
  — just enough buffer to hold it (`Terminal(maxLines:)`) — but should expect a
  large first frame: 82 KB for a busy `docker compose logs -f` pane.

  1000 rows is Herdr's ceiling, not a choice: `pane read` returns at most that
  many however many are asked for, and there is no offset parameter, so deeper
  history is unreachable and a "load more" is not worth building. Agent panes
  get no seed — they run on the alternate screen, where Herdr holds no
  scrollback at all (see D21).

**A pane's kind is not fixed for the life of the socket.** Type `claude` into a
plain shell and Herdr hosts an agent in it; exit that agent and it is a plain
shell again. The bridge follows both transitions and swaps the backend
underneath the same WebSocket — no reconnect, no new `pane_id`.

On each swap the server sends a **text** frame `{"type":"mode","agent":<bool>}`
**before** the new backend's first byte. A client MUST reset its emulator when
it arrives: exit the alternate screen, clear the buffer, and start a fresh
UTF-8 decoder. The two streams are different shapes of output — an alt-screen
TUI versus whole-frame repaints — and one's leftovers corrupt the other. Resend
your geometry too: a freshly started agent PTY is back at 80×24. Swapping to a
plain pane re-seeds scrollback, so expect another large first frame.

Detecting the transition is the bridge's problem, not the client's, and it is
subtler than it looks: Herdr's `pane.agent_detected` fires on an agent
appearing **and** on one exiting, and the `pane.updated` trailing an exit still
carries the departed agent. Only `pane.agent_status_changed` with `agent:""`
reports the departure. So the bridge treats every signal as "re-resolve" and
lets `herdr pane get` decide.

Binary frames are raw terminal bytes; **text** frames are out-of-band control
messages (`resize` inbound, `mode` outbound). The backend (PTY process or
poller) is stopped when the socket closes (either side). Reconnect + re-fetch
`/snapshot` is the resilience story (no mosh-style state sync). The PTY starts
at 80×24 and is resized to the client's geometry by the first `resize` frame.
Errors before the upgrade: `404` if `pane` doesn't exist, `401` no/invalid
token, `400` missing `pane`.

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
3. Interleaved, a **heartbeat** every 20s — `{"type":"heartbeat","ts":<ms>}`.
   It carries **no `seq`** on purpose: it means "still here", not "something
   changed". **Skip it before your delta handling** — treating it as a change
   signal would re-snapshot every 20 seconds for nothing. It exists so a client
   can detect a half-open socket (one that died without either end noticing);
   time out on silence and reconnect. The app uses 50s. Full rationale in
   [`CONTRACT.md`](../CONTRACT.md) §2.

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

## Agent lifecycle — start / restart / stop
Full contract, live captures and the reasoning behind each rule:
[`docs/CONTRACT-agent-lifecycle.md`](CONTRACT-agent-lifecycle.md). Summary:

**`GET /agents/available`** — the kinds this host can run *right now*. Discovered
on the bridge (Herdr's own `--kind` catalog ∩ what resolves on the daemon's PATH,
since Herdr documents a kind as its canonical executable); nothing is hardcoded.
```json
{ "agents": [{ "kind": "claude", "path": "/opt/homebrew/bin/claude", "state_reporting": true }],
  "known_kinds": ["pi","claude","codex","…"],
  "discovery": "herdr agent kinds + PATH lookup" }
```
`state_reporting:false` means the kind will run but Herdr can't classify it — it
stays `unknown` forever and never raises an approval or a push. **Only offer
kinds from `agents[]`.**

**`POST /agent/start`** — one of three targets, exactly one (naming none or
several is a `400`):
```
{ "kind":"claude", "pane_id":"wN:p7" }                                    // reuse an idle shell pane
{ "kind":"claude", "split_from":"wN:p1", "direction":"down", "cwd":"…" }  // split, agent in the new pane
{ "kind":"claude", "workspace_id":"wN", "label":"review", "cwd":"…" }     // new tab, agent in its root pane
```
Optional: `cwd` (absolute, existing directory — **rejected with `pane_id`**),
`prompt` (the agent's first message), `name` (`[a-z][a-z0-9_-]{0,31}`),
`timeout_ms` (clamped 5 000–300 000, default 60 000). Response `200`:
```json
{ "pane_id":"wN:p7", "tab_id":"wN:t5", "workspace_id":"wN",
  "kind":"claude", "name":"claude-wn-p7", "created_pane":true, "prompt_sent":true }
```
`pane_id` is session-qualified, so it feeds `/attach`, `/transcript` and `/send`
directly. **This call blocks 5–30 s** — Herdr only returns once it has verified
the agent is really up — so raise the client's receive timeout.

`prompt_error` is present only when a `prompt` was asked for and did not land.
The agent is running either way (hence still `200`), but the client must be able
to tell an instructed agent from an empty one — show the reason rather than
navigating to it as if the prompt arrived.

`cwd` is validated server-side: absolute, canonical (every `..`/`.`/`//` form is
rejected, not normalised), must exist, must be a directory.

**`POST /agent/stop`** `{pane_id}` → `{stopped:true,pane_id,kind}`. Kills running
work; the pane survives. Herdr has no stop method, so the bridge sends repeated
`ctrl+c` and returns `200` **only** once it has observed the pane back at its
shell prompt. A `409` means the agent ignored the interrupts and is **still
running** — never treat it as a slow success.

**`POST /agent/restart`** `{pane_id, prompt?}` →
`{restarted:true,pane_id,kind,name,cwd,prompt_sent,history_kept:false}`. Stops the
agent and starts the same kind in the same pane and directory. The pane, its id,
its scrollback, its cwd and the agent's name survive. **The conversation does
not** — the replacement is a new session with no memory of the old one, the
in-flight turn is lost, and so is queued input and permission/plan mode. Confirm
before calling.

Status codes: `400` bad shape / bad `cwd` / unknown kind · `401` · `404` unknown
pane or no agent in it · `405` wrong method · `409` pane busy, pane already hosts
an agent, kind not installed, or the agent would not stop · `502` Herdr failed
(a start that fails after creating a pane says so and names the pane).

These publish `agent_started` / `agent_stopped` / `agent_restarted` on
`WS /events`.

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
`workspace.create`, `tab.create/close/focus/rename`, `pane.split/close/focus`,
`agent.focus`).

Status codes: `200` ok · `400` malformed body / missing `method` · `401`
no/invalid token · `403` method not on the allowlist · `404` Herdr
target-not-found (e.g. `pane_not_found`) · `502` socket/herdr unreachable or
other Herdr error.

## GET /branch-info + POST /branch-delete — delete a worktree's branch
Herdr's `worktree.remove` drops the checkout and closes the workspace, and stops
there: Herdr has **no branch concept**, so the branch is left behind on every
removal. These two endpoints are the only place the bridge drives **git**
directly rather than proxying Herdr — there is no method to proxy.
```
GET  /branch-info?workspace_id=w1F           ← before the confirm
POST /branch-delete
{ "repo_root": "/…/gothalo", "branch": "feat/x", "force": false }   ← after
```
They are split at the moment the user decides, and the order is not optional:
the preflight needs the workspace to still exist (it names the branch and the
repo root); the delete needs the checkout to be gone (git refuses to delete a
checked-out branch). **If the `worktree.remove` between them fails, the branch
delete must not be attempted.**

`/branch-info` answers `200` for every "nothing to offer" case too
(`deletable:false` + `blocked_reason`) — a plain workspace, a detached HEAD, the
repo's main checkout. `deletable:true` with `merged:false` means "possible, but
it costs commits"; clients are expected to make that a distinct confirmation.

The safety rules, enforced on **every** delete regardless of what the client
saw: the repository's **default branch is never deleted** (resolved from
`refs/remotes/<remote>/HEAD`, then a conventional local name — never assumed to
be `main`; unresolvable ⇒ nothing is deletable), a branch **checked out in any
worktree is never deleted**, and unmerged deletion (`git branch -D`) happens
only with `force:true`. `force` overrides that last rule and nothing else.
Deleting locally **never** touches the remote — `upstream` and
`remote_deleted:false` are returned so the UI can say so.

Status codes: `200` ok (including "not deletable, here's why" on
`/branch-info`) · `400` missing/invalid params or `repo_root` · `401`
no/invalid token · `404` no such branch (`/branch-delete`) or unknown session ·
`405` wrong method · `409` a safety rule refused (`/branch-delete`) · `502`
Herdr unreachable (`/branch-info`).

Full schemas, examples and rationale:
[`docs/CONTRACT-branch-delete.md`](CONTRACT-branch-delete.md).

## Errors
`401` missing/invalid bearer · `403` invalid pairing code / method not allowlisted
(`/herdr`) · `400` bad body ·
`404` unknown pane/tab/workspace, no agent in that pane (`/agent-state`,
`/agent-mode/cycle`, `/agent-transcript`, `/agent/stop`, `/agent/restart`), or no
transcript file / unsupported kind (`/agent-transcript`) · `405` wrong method
(`/agent-mode/cycle` non-POST, `/image` non-POST, `/agents/available`,
`/agent/*` non-POST) ·
`409` mode switching not supported for the agent kind (`/agent-mode/cycle` on a
non-Claude pane), pane busy / already hosts an agent / kind not installed /
agent would not stop (`/agent/*`), or a branch-safety rule refused
(`/branch-delete`: default branch, still checked out, unmerged without
`force`) · `413` upload over the 10 MiB cap (`/image`) ·
`415` body is not an accepted image type (`/image`) · `500` transcript read
failed (`/agent-transcript`), drop directory unwritable (`/image`) · `502` herdr
command failed.
