# CONTRACT — gothalo mobile API (agent pane data)

Two mobile-side contracts for reading an **agent** pane. Both are kind-agnostic
(the same shape for `claude`/`pi`/`codex`/`opencode`) and share the bridge's auth
(`Authorization: Bearer <bearer>` or `?token=<bearer>`).

- **`GET /agent-state`** — a compact parsed *state card* (what it's doing now + the
  blocked question). Good for a list row / notification. ↓ next section.
- **`WS /agent-transcript`** — the full *structured conversation*, streamed: backlog
  then a live tail of normalized chat entries. Good for the chat view.
  ↓ [jump to it](#contract--ws-agent-transcript-streamed-chat).

---

# CONTRACT — `GET /agent-state` (parsed agent card)

The mobile-side contract for the parsed agent state. This is the phone-friendly
alternative to the raw PTY stream (`WS /attach`): for an **agent** pane you get a
compact JSON card — what the agent is doing, its last message, and, when blocked,
the exact question + choices it's waiting on (which pair with `POST /approve`).
Non-agent panes keep using raw `/attach`.

All examples below were captured from **live Claude Code panes** through the
running bridge.

---

## Request

```
GET /agent-state?pane=<pane_id>
Authorization: Bearer <bearer>
```

| Part | Value |
|---|---|
| Method | `GET` |
| Path | `/agent-state` |
| Query | `pane` — the Herdr `pane_id` (e.g. `wQ:p2`), from `/snapshot`. **Required.** |
| Body | none |
| Auth header | `Authorization: Bearer <bearer>` — the per-device bearer from `/pair`, or the admin token (dev). `?token=<bearer>` also works, matching `/attach`. |

Stateless per request: the bridge shells out to `herdr` (`agent get` + `agent
read`) and parses; it stores nothing.

---

## Response `200` — schema

Kind-agnostic: **the same shape for every agent kind.** The one kind-specific
field, `permission_mode`, uses a generic name and is **optional** — it is simply
absent for kinds that don't have the concept, so the core contract is unchanged
for them (a Claude-specific *value*, never a Claude-only *shape*).

| Field | Type | Notes |
|---|---|---|
| `pane_id` | string | Echoes the requested pane. |
| `agent_kind` | string | Herdr agent kind (`claude`, later `codex`, `opencode`, …). |
| `agent_status` | string | Authoritative status from Herdr: `idle` \| `working` \| `blocked` \| `done` \| `unknown`. |
| `permission_mode` | string \| absent | **Claude-only, optional.** The current Shift+Tab permission mode: `default` \| `acceptEdits` \| `plan` \| `auto` \| `bypassPermissions` (or a raw lowercased label a build names differently). **Omitted** for kinds without the concept and when unknown — absence is normal, not an error. Change it with `POST /agent-mode/cycle`, then re-fetch. Full contract: [`CONTRACT-agent-mode.md`](./CONTRACT-agent-mode.md). |
| `headline` | string | One line: what it's doing / its last step. **The question when blocked.** Always safe to render alone. |
| `detail` | string | Short plain-text body (current activity or last assistant message). ANSI/box-drawing already stripped. May contain `\n`. |
| `blocked` | object \| absent | **Present only when `agent_status == "blocked"`.** See below. |
| `blocked.question` | string | The prompt the agent is waiting on. |
| `blocked.options` | array | Selectable choices in display order. May be empty for a free-form prompt. |
| `blocked.options[].index` | int | The number the user types to pick it (1-based); `0` if unnumbered. |
| `blocked.options[].label` | string | Choice text. |
| `blocked.options[].selected` | bool | The highlighted default — the one a bare Enter (`/approve`) accepts. |
| `transcript` | array\<string\> \| absent | Optional, best-effort recent plain-text lines. |
| `parsed` | bool | `false` ⇒ no dedicated parser for this kind; `detail`/`transcript` are a raw recent-text fallback. |

### How the app uses `blocked` (pairs with `POST /approve`)
- **One-tap "Yes"** (the `selected` default): `POST /approve { "agent": pane_id, "seq": state_change_seq }` — the bridge presses Enter only if the agent is still blocked at that `seq` (idempotent).
- **Pick a non-default option**: `POST /send { "pane": pane_id, "text": "2\n" }` — type the option's `index` then newline.
- `state_change_seq` comes from `/snapshot` (or the push payload), not from this endpoint.

---

## Live examples — one per status

### `idle` (Claude, `w5:p18`)
```json
{
  "pane_id": "w5:p18",
  "agent_kind": "claude",
  "agent_status": "idle",
  "permission_mode": "auto",
  "headline": "Both PRs are open against develop:",
  "detail": "Both PRs are open against develop:\n\n- #1570 — fix/consolidated-arrangement-earliest — consolidated refresh window uses the earliest per-SKU\narrangement (MIN not MAX), + the cancel-deadline email fix.\nhttps://github.com/example/acme-app/pull/1570\n- #1571 — feat/order-detail-per-sku-shipping — per-SKU shipping-detail collapsible panel, gated to\nmulti-warehouse units.\nhttps://github.com/example/acme-app/pull/1571\n\nBoth are file-disjoint and independent (no stacking), so they can be reviewed and merged in any order.\nNeither commit carries any Claude attribution.\n\nOne thing I did not do: the earlier temp branch feat/per-sku-shipping-detail still exists locally at\ndevelop's HEAD with no commits — harmless, but I can delete it if you want it cleaned up.",
  "transcript": [
    "Both are file-disjoint and independent (no stacking), so they can be reviewed and merged in any order.",
    "Neither commit carries any Claude attribution.",
    "✻ Worked for 2m 43s",
    "※ recap: Goal was surfacing per-SKU shipping data on the order-detail page plus fixing the consolidated",
    "await review, or delete the leftover local branch if you want. (disable recaps in /config)"
  ],
  "parsed": true
}
```

### `working` (Claude, `wN:pB`)
```json
{
  "pane_id": "wN:pB",
  "agent_kind": "claude",
  "agent_status": "working",
  "permission_mode": "default",
  "headline": "Pushed to feat/alerts-liveness…",
  "detail": "Pushed to feat/alerts-liveness…",
  "transcript": [
    "That's the inbox (reload reset navigation). Let me open Alerts via the bell to check the dimming:",
    "Now both done and resolved recede (dimmed, muted title) — the green check is just a quiet success marker…",
    "Pushed to feat/alerts-liveness…"
  ],
  "parsed": true
}
```
> When a working agent has done only tool calls for a while (no fresh prose in the
> visible window), `headline` falls back to the pane's task title and `detail` to
> the current tool step — the card still says something useful.

### `blocked` (Claude, `wQ:p2`) — a Bash-permission prompt
```json
{
  "pane_id": "wQ:p2",
  "agent_kind": "claude",
  "agent_status": "blocked",
  "headline": "Do you want to proceed?",
  "detail": "Bash command\ntouch card_demo.txt\nCreate empty card_demo.txt file",
  "blocked": {
    "question": "Do you want to proceed?",
    "options": [
      { "index": 1, "label": "Yes", "selected": true },
      { "index": 2, "label": "Yes, and always allow access to blocked-demo/ from this project", "selected": false },
      { "index": 3, "label": "No", "selected": false }
    ]
  },
  "transcript": [
    "Running 1 shell command…",
    "Bash command",
    "touch card_demo.txt",
    "Create empty card_demo.txt file",
    "Do you want to proceed?",
    "❯ 1. Yes",
    "2. Yes, and always allow access to blocked-demo/ from this project",
    "3. No"
  ],
  "parsed": true
}
```
> To approve the default (option 1): `POST /approve {"agent":"wQ:p2","seq":<seq>}`.
> To choose "No" (option 3): `POST /send {"pane":"wQ:p2","text":"3\n"}`.

### `done` (Claude, `wQ:p2`)
```json
{
  "pane_id": "wQ:p2",
  "agent_kind": "claude",
  "agent_status": "done",
  "headline": "Done — created card_demo.txt.",
  "detail": "Done — created card_demo.txt.",
  "transcript": [
    "✻ Crunched for 6s",
    "Ran 1 shell command",
    "Done — created approve_me_demo.txt.",
    "Ran 1 shell command",
    "Done — created card_demo.txt."
  ],
  "parsed": true
}
```

---

## Fallback — `parsed: false` (unrecognised agent kind)

For a kind with no dedicated parser yet, the bridge degrades to a best-effort raw
recent-text dump instead of erroring. `blocked` is never populated in this mode
(`agent_status` is still authoritative). Shape is identical; only `parsed` flips
to `false`. (Below: a hypothetical `aider` pane; `claude` is parsed today, `codex`
and `opencode` are next behind this same contract.)
```json
{
  "pane_id": "wZ:p4",
  "agent_kind": "aider",
  "agent_status": "working",
  "headline": "…best-effort last readable line…",
  "detail": "…raw recent readable text, ANSI/rules/box-art removed…",
  "transcript": [ "…up to ~12 recent lines…" ],
  "parsed": false
}
```
App rule: render `headline`/`detail`/`transcript` as usual, but when
`parsed == false` do **not** rely on `blocked` — fall back to raw `/attach` if the
user needs to act.

---

## Errors

Error bodies are plain text (not JSON), matching the other endpoints.

| Status | When | Body (example) |
|---|---|---|
| `400` | `pane` query param missing | `want ?pane=<pane_id>` |
| `401` | missing/invalid bearer (or `?token=`) | `unauthorized` |
| `404` | no agent in that pane / unknown pane | `no such agent` |
| `502` | the underlying `herdr` command failed | `herdr agent get …: <stderr>` |

Notes:
- **Parsing never 500s.** An unrecognised on-screen layout degrades to
  `parsed:false` with raw text — it does not produce an error status.
- A momentary failure to read the terminal text (but the agent still exists) is
  non-fatal: you get a `200` built from whatever was available, possibly with a
  thin `detail`.

---

## Curl (dev)

```bash
BASE=https://my-mac.tailnet.ts.net:5338
TOKEN=<admin-or-device-bearer>

# parsed card for a pane
curl -s "$BASE/agent-state?pane=wQ:p2" -H "Authorization: Bearer $TOKEN"

# ?token= form (parity with /attach)
curl -s "$BASE/agent-state?pane=wQ:p2&token=$TOKEN"
```

---

# CONTRACT — `WS /agent-transcript` (streamed chat)

The full, structured conversation for an agent pane, read from the agent's **own
transcript file** (not the terminal) and streamed live. This is the data source
for a chat view: user/assistant messages, thinking, tool cards (command + diff),
and tool results — normalized into one kind-agnostic schema so the app renders one
UI regardless of agent kind.

All examples below were **captured from live Claude Code panes** through the running
bridge (project transcripts of gothalo itself; no secrets).

---

## Connect

```
GET ws(s)://<host>/agent-transcript?pane=<pane_id>&token=<bearer>
```

| Part | Value |
|---|---|
| Protocol | WebSocket (upgrade of a GET). Use `wss://` in prod. |
| Query | `pane` — the Herdr `pane_id` (e.g. `wN:p1`), from `/snapshot`. **Required.** |
| Auth | `?token=<bearer>` — per-device bearer (from `/pair`) or the admin token. **Required in the query** because WS clients can't set headers (mirrors `/attach`). An `Authorization: Bearer` header also works if your client can send one. |
| Direction | **Mostly server→client**, plus one client control frame: `load_older` (paging up). Prompts/approvals still go through `POST /send` / `POST /approve`. |

Per-connection state is only a byte offset into the file (for the tail), the
running `seq` counter, and the id of the session currently being followed;
closing the socket stops the tail. Auth is re-checked on connect (not per frame).

> **`protocol` is `5`.** The **subagent roster is now live**: a `subagents`
> frame re-sends the whole roster whenever it changes — an agent spawned, or one
> the parent has been told finished. Before this it rode only in `hello`, so a
> chat left open while four agents finished went on reporting them as running
> with their ages climbing, and disagreed with the same session's row in
> `/snapshot`. Re-scanned every 3s (slower than the tail poll: it lists a
> directory and scans the parent, and an agent finishing is human-scale). Age
> alone does not trigger a resend — a working agent's `last_activity_ts`
> advances constantly and the client can already compute the elapsed time.
>
> **`protocol` `4`** made the socket **follow the pane across sessions**:
> when the agent starts a new one (`/clear`, `/new`, `/resume`, a restarted
> agent), the server re-points at it and replays the opening sequence in place —
> `session_changed`, then a fresh `hello` + backlog. `hello` is therefore **no
> longer once per socket**. A `?subagent=` stream is exempt (it never rotates).
> Within `4` the roster gained `done` and `last_activity_ts` (see
> [Subagents](#subagents)), both additive.
>
> **`protocol` `3`** put the session's **subagent roster** in `hello`, and
> `?subagent=<agent_id>` streams a delegated conversation instead of the
> session's own.
>
> **`protocol` `2`** made the backlog **paginated**: connect sends only the
> newest page (~150), reports the cursor in `hello`, and older history is fetched
> on demand with a `load_older` control frame. Inbound frames are no longer
> end-of-stream — a `load_older` is serviced; anything else closes the socket
> cleanly.

### `subagents` — the roster changed

```json
{"type":"subagents","pane":"wN:p1","subagents":[ …same shape as in hello… ]}
```

Sent mid-stream when the roster differs from the one this socket last sent.
**Replace your roster wholesale**; it is not a delta, so a client that misses one
is not left wrong until the next rotation. An empty `subagents` is a real update
(the last agent finished and its files were cleared), not a no-op.

`hello` still carries the roster on connect and after a rotation, so a client
that ignores this frame degrades to the old connect-time behaviour rather than
to nothing.

### Subagents

When an agent delegates with the `Task` tool, the child's conversation is **not**
appended to the parent transcript. Claude Code writes it beside the session:

```
~/.claude/projects/<encoded-cwd>/
    <session>.jsonl                    the parent transcript
    <session>/subagents/
        agent-<agentID>.jsonl          the child transcript, same line format
        agent-<agentID>.meta.json      {agentType, description, toolUseId, spawnDepth}
```

Before this, the app saw a `Task` `tool_call` and then — minutes later — its
result, with nothing in between: the view went dark exactly when the agent
parallelized.

Two properties of the layout, **verified against live files**, define the
contract:

1. **The directory is flat.** A subagent that itself spawns a subagent does not
   nest on disk — the grandchild lands in the same `subagents/` dir carrying
   `spawn_depth: 2`. Observed live: four depth-1 agents beside one depth-2
   `Explore` spawned by one of them.
2. **`tool_use_id` is the join key**, and it points at a `Task` call in whichever
   transcript spawned it — the session's for a depth-1 child, another
   subagent's for a depth-2 one.

Together these mean **one flat roster serves every level**: to find the direct
children of the transcript currently on screen, match `tool_use_id` against the
`tool.id` of its `Task` calls. No depth arithmetic, and drilling down needs no
extra round trip. `hello.subagents` is therefore the whole session's roster, not
just the streamed conversation's children.

The roster is metadata only — enough to render a collapsed row
(`"general-purpose · Build recent-activity timeline"`) without opening anything.
Child transcripts are fetched **on demand**: one live session dir held five
subagents beside a 1.4 MB parent — and, later, 63 beside a 10 MB one — and a
phone should not pay for that to draw a one-line summary.

| Field | Type | Meaning |
|---|---|---|
| `agent_id` | string | Handle to stream this subagent (pass back as `?subagent=`). Unique per session. |
| `tool_use_id` | string | The `tool.id` of the `Task` call that spawned it. The join key. |
| `agent_type` | string | Configured agent that ran (`general-purpose`, `Explore`, …). Primary label. |
| `description` | string | Task description given at spawn time. Secondary label. |
| `spawn_depth` | int | `1` for a child of the session, `2` for a child of a subagent. Display only. |
| `done` | bool | The parent has been told this agent finished. `false` means still working. Always present. |
| `last_activity_ts` | int | When this conversation last wrote, unix ms. **Omitted** when undatable — absent is unknown, never "just now". |

#### `done`, and the two ways an agent's end is recorded

There are two, and reading either one alone is wrong in opposite directions.
Which applies is **stated by the spawning call**, as `run_in_background` — never
inferred from timing.

**Asynchronous (`run_in_background: true`).** The call returns within seconds
("launched successfully") while the child runs on for minutes; measured on a
live session, all 15 calls carried results while 6 children were still
appending. A client deriving "running" from the call would report every agent
finished. Their end arrives later, as a `task-notification`.

**Synchronous (`run_in_background: false`).** No notification is ever sent. The
agent reports by **returning** — its `tool_result` is the completion — so a
client reading notifications alone leaves it running forever. Measured on a
plain parallel fan-out: 4 children, 4 results, the parent idle, and not one
`task-notification` in the whole transcript. This is the common shape of
delegation, and it is why the count must not be derived from notifications
alone.

**Absent `run_in_background` is unknown, and is treated as async** (notify
only). Guessing "synchronous" on an async call reinstates the first error for
every agent at once; guessing "async" on a synchronous one merely leaves it
reading as running.

The spawning tool is named `Task` in some builds and `Agent` in others. The join
is on `tool_use_id` either way, so the name is only used to recognise a spawn.

When both records exist for one agent, **the notification wins**, including when
it says `running`: an agent can be resumed after finishing, and its original
call still carries the result that ended it the first time.

The notification is keyed by the **agent id** — the same id as `agent_id`. Two
shapes on disk make naive parsing wrong, and a client re-deriving this must
handle both:

- One notification can name **several** agents under a single `status` (the "no
  completion record was found for N background agents" notice). Matching one id
  per notification loses the rest — and those are the agents that will never
  report for themselves, so they would read as running forever.
- A notification need not carry a `status` at all (monitor events share the
  envelope), and agent prose quotes these tags verbatim. Pairing an id with a
  status found outside its own block ends the wrong agent.

A terminal status does not latch: an agent can be resumed and report again
(observed: `stopped → killed → failed → completed` for one id), so the last
status wins. The residual is that a **resumed** agent is silent until it next
reports, so it reads as done while `last_activity_ts` keeps advancing — which is
why the timestamp is worth rendering beside the state rather than instead of it.

One further residual, in the synchronous half: the spawning call for a
`spawn_depth` 2 agent lives in **another subagent's** transcript, not the
parent's, and only the parent is scanned. A synchronous grandchild therefore has
no completion record here and reads as running until something notifies. Depth 1
— every child the session itself spawned — is unaffected.

Ordering of the roster is `spawn_depth` then `agent_id`, **for determinism only —
it is not spawn order.** The authoritative order is the position of each matching
`Task` call in the transcript being rendered.

**Degradation is deliberate.** A session that delegated nothing omits
`subagents` entirely (the common case). Discovery failure is logged and the
transcript still streams — losing the roster must never cost the user their
conversation. A metadata file whose JSON is unreadable still yields a row (the
transcript is streamable; it just loses its labels), while metadata with no
matching `.jsonl` is dropped rather than advertising a row that cannot open.

**Security.** `?subagent=` is client input and is **never used to build a path**.
Discovery runs first and the id is matched against what was found, so traversal
(`../../secret`, `/etc/passwd`) resolves to `ErrNoTranscript` → `404` rather than
being filtered. It is unrepresentable by construction, not blocked by a check.

---

## Framing

Every frame is a **text** JSON object (contrast `/attach`, which is binary raw
bytes). **One entry per frame** (never batched), so the app can render
incrementally and back-pressure naturally. Each frame has a `type`:

**Server → client:**

| `type` | When | Payload |
|---|---|---|
| `hello` | first, and again after every `session_changed` | identity + pagination stats |
| `entry` | newest page, older pages, then live | one normalized entry; `live` is `false` for backlog/older pages, `true` for the tail |
| `backlog_complete` | after each newest page (connect and rotation) | boundary marker between the newest page and the live tail |
| `page_complete` | after each `load_older` reply | end-of-page marker + the new cursor |
| `session_changed` | the pane's agent started a new session | `{from, to}` — **discard everything buffered**; a fresh `hello` + backlog follows |

**Client → server** (the only inbound frame the server acts on):

| `type` | When | Payload |
|---|---|---|
| `load_older` | to page up (fetch older history) | `{before_seq, limit}` |

The stream on connect is: **`hello` → `entry`×N (`live:false`, the newest page,
oldest→newest) → `backlog_complete` → `entry`… (`live:true`, forever until
close)**. The **live tail runs continuously** — `load_older` replies are
interleaved with live entries, so an `entry` with `live:false` after
`backlog_complete` belongs to a page you requested, never to the tail.

`seq` is the **absolute 1-based position** of an entry in the whole file's
normalized stream (the newest entry's `seq` == `total`). It is a stable cursor:
the same entry always has the same `seq` across the newest page, any older page,
and the live tail — **within one session**. It restarts at 1 on the other side of
a `session_changed`, which is why that frame requires dropping what you hold.

### `session_changed` — following the pane onto a new session

```json
{"type":"session_changed","pane":"wN:p1","from":"b0651a43-…","to":"7d2c19f0-…"}
```

A pane's agent session is not fixed for the life of the pane: `/clear`, `/new`,
`/resume` and a restarted agent all start a new one, and the old transcript stops
growing. A socket pinned to the file it resolved at connect would simply go quiet
— indistinguishable, from the app, from a hung agent.

So the server re-reads the pane's `agent_session.value` every **2s** and, when it
changes to a session it can open, swaps the stream over and re-sends the opening
sequence on the same socket:

```
session_changed          {from, to}
hello                    now carrying the NEW session_id
entry (live:false) ×N    the new session's newest page, oldest→newest
backlog_complete
entry (live:true) …      the live tail, against the new session
```

Detection is on the **session id**, not on watching for a `/new` being typed, so
it fires however the session started — from the app, from the keyboard at the
machine, or by the agent itself.

Client rules:

- On `session_changed`, **discard all buffered entries, tool results and
  pagination cursors.** `seq` restarts at 1, so retained entries collide with the
  new session's and a `seq`-keyed de-dupe will silently drop the new ones.
- Treat the frames that follow exactly like a fresh connect.
- **Also compare `hello.session_id` to the one you hold** and reset on a change.
  A rotation that happens while the socket is down produces no `session_changed`
  (there is no one to send it to) — the next `hello` is the only signal.
- A rotation the server cannot yet open (an unresolvable or unsupported new
  session) sends nothing; the socket keeps streaming the old session and retries
  on the next tick.
- `hello.subagents` is re-read for the new session, so the roster you hold is
  replaced along with the entries — a fresh session has usually delegated nothing.
- **A `?subagent=` stream never rotates.** A delegated conversation belongs to the
  session that spawned it and is complete in itself; following the pane would swap
  the user onto a different conversation than the one they drilled into. To see
  the new session, reconnect without `?subagent=`.

### `hello`
```json
{"type":"hello","protocol":4,"pane":"wN:p1","agent_kind":"claude","session_id":"b0651a43-38fc-4f8b-8b03-c8611cdb9237","backlog_count":150,"total":1025,"has_more":true,"oldest_loaded_seq":876,"has_older":true,"subagents":[{"agent_id":"aa4832e5ce82b16f0","tool_use_id":"toolu_01F9bssr6JjRZXjvEumqMwuR","agent_type":"general-purpose","description":"Build recent-activity timeline","spawn_depth":1,"done":true,"last_activity_ts":1788601356000},{"agent_id":"a9adcab7329a772ac","tool_use_id":"toolu_013gpQcoGTMVRYdciecEq7rZ","agent_type":"Explore","description":"Explore Flutter app conventions","spawn_depth":2,"done":false,"last_activity_ts":1788601402000}]}
```
| Field | Type | Notes |
|---|---|---|
| `protocol` | int | Wire version. **`4`** (session rotation; subagent roster + `?subagent=`). |
| `subagent` | string | Echoes the `?subagent=` being streamed; absent for the session's own transcript. |
| `subagents` | array | The session's **flat** subagent roster, every depth, **re-read on each rotation**. Absent when nothing was delegated. See [Subagents](#subagents). |
| `pane` | string | Echoes the requested pane. |
| `agent_kind` | string | `claude`, `pi` (later `codex`/`opencode`). |
| `session_id` | string | The resolved transcript session id (see *Resolution*). **Compare it to the one you hold** — a change means the pane moved to a new session and your buffer is stale. |
| `backlog_count` | int | How many `entry` frames the newest page will send (≤ 150). |
| `total` | int | Total normalized entries in the whole file. The newest entry's `seq` == `total`. |
| `has_more` | bool | `true` ⇒ older entries exist before this page. **Equals `has_older`** (kept for back-compat). |
| `oldest_loaded_seq` | int | Absolute `seq` of the oldest entry in this first page (`0` if the file is empty). **Pass it back as `load_older.before_seq`** to page up. |
| `has_older` | bool | `true` ⇒ entries with `seq < oldest_loaded_seq` exist — there is more to page up. |

### `backlog_complete`
```json
{"type":"backlog_complete","count":150,"has_more":true}
```
Use it to hide a loading spinner and jump the scroll to the bottom; entries after
it are live (`live:true`) **or** older-page entries you requested via `load_older`.

### `entry`
```json
{"type":"entry","live":false,"entry": { …normalized entry… }}
```

### `load_older` (client → server) and `page_complete` (reply)

To page up, send a `load_older` control frame with the cursor you currently hold
(the oldest `seq` you have — `hello.oldest_loaded_seq`, or the previous page's
`page_complete.oldest_loaded_seq`):

```json
{"type":"load_older","before_seq":876,"limit":150}
```
| Field | Type | Notes |
|---|---|---|
| `before_seq` | int | Return entries with `seq < before_seq`. Use the oldest `seq` you already have. |
| `limit` | int | Max entries in this page. Optional — omit/`0` ⇒ **150**; capped at **500**. |

The server replies with the page — `entry` frames (`live:false`, **oldest→newest**)
for the `limit` entries immediately older than `before_seq` — then a single
`page_complete`:

```json
{"type":"page_complete","requested_before_seq":876,"oldest_loaded_seq":826,"has_older":true}
```
| Field | Type | Notes |
|---|---|---|
| `requested_before_seq` | int | Echoes the `before_seq` you asked for (correlate the reply). |
| `oldest_loaded_seq` | int | Absolute `seq` of the oldest entry in **this page** (`0` if the page was empty). Your next `load_older.before_seq`. |
| `has_older` | bool | `true` ⇒ still more to page up (`oldest_loaded_seq > 1`). `false` ⇒ you've reached the start of the file; stop. |

Notes:
- Pages are bounded and streamed from disk — the whole file is never held in
  memory, no matter how deep you page.
- The live tail keeps flowing while a page loads; the two never block each other.
- An empty page (`before_seq ≤ 1`, or nothing older) returns just a
  `page_complete` with `oldest_loaded_seq:0`, `has_older:false`.
- Any inbound frame that isn't a well-formed `load_older` (garbage, unknown
  `type`, binary) closes the socket cleanly with `1000` — it does **not** crash
  the stream.

---

## Normalized entry schema

The same shape for every agent kind. Optional/empty fields are omitted.

| Field | Type | Notes |
|---|---|---|
| `id` | string | Unique per entry. One transcript line can expand into several entries (an assistant turn = text + N tool calls), so it's the source line's uuid plus a block index, e.g. `…f117#0`. |
| `parent_id` | string? | The source line's `parentUuid` (threading), when present. |
| `seq` | int | **Absolute 1-based position in the whole file's normalized stream** (the newest entry's `seq` == `hello.total`). Stable across the newest page, older pages, and the live tail, so it's the paging cursor. Order and de-dupe on this; don't rely on `ts`. |
| `ts` | string? | ISO-8601 timestamp of the source line. |
| `role` | string | `user` \| `assistant` \| `system`. |
| `kind` | string | `message` \| `thinking` \| `tool_call` \| `tool_result` \| `attachment`. |
| `text` | string? | Markdown body for `message`/`thinking` (and `[image]` for image attachments). |
| `tool` | object? | Present for `tool_call` (see below). |
| `result` | object? | Present for `tool_result` (see below). |
| `parsed` | bool | `false` ⇒ the reader couldn't place this line and passed it through minimally. Render `role`/`kind`/`text` but expect nothing else. |

### `tool` (on `kind:"tool_call"`)
| Field | Type | Notes |
|---|---|---|
| `id` | string | The agent's tool-use id. **Correlate a call with its result: `tool.id == result.for_id`** (more reliable than uuid threading). |
| `name` | string | Raw tool name (`Bash`, `Edit`, `Read`, `Write`, `WebFetch`, …). |
| `title` | string? | Short label (usually == `name`). |
| `subtitle` | string? | Secondary label — e.g. a Bash command's `description`. |
| `command` | string? | Shell command, for command tools (`Bash`). |
| `file` | string? | Primary file basename, for file tools (`Edit`/`Read`/`Write`). |
| `diff` | string? | **Preview** unified diff for `Edit`/`Write`, built from the tool input. The *applied* diff is authoritative and rides on the paired `tool_result`. |
| `diff_truncated` | bool? | `true` when `diff` was capped. |
| `input_summary` | string? | Compact one-line summary of the raw input — always safe to show, even for tools the reader doesn't specifically model. |

### `result` (on `kind:"tool_result"`)
| Field | Type | Notes |
|---|---|---|
| `for_id` | string | The `tool.id` this result answers. |
| `ok` | bool | `false` on tool error, interruption, or a rejected permission. |
| `output_summary` | string? | Textual output (stdout, `[stderr] …`, or content), capped. |
| `diff` | string? | Applied unified diff for `Edit`/`Write`, from the richer `structuredPatch`. Authoritative over `tool.diff`. |
| `truncated` | bool? | `true` when `output_summary` or `diff` was capped. |

---

## Captured examples — one per kind

### `message` — user
```json
{"id":"e8a10a3c-0c75-43da-a3f8-c95b686df117#0","seq":1,"ts":"2026-07-31T05:58:11.827Z","role":"user","kind":"message","text":"You are picking up the gothalo project mid-stream — it was scoped in another Herdr pane…","parsed":true}
```

### `message` — assistant
```json
{"id":"f23a8018-577c-4c9c-a45b-b272ad36b4a3#0","parent_id":"2055fdc8-9b17-41ae-ac28-5383d8ce3954","seq":2,"ts":"2026-07-31T05:58:14.349Z","role":"assistant","kind":"message","text":"I'll get oriented by reading the handoff doc first, then the other files.","parsed":true}
```

### `message` — system
```json
{"id":"775cb7d6-48b2-4b0f-a597-c889443ecb98#0","parent_id":"1da4d040-444c-4f75-b998-b823d6b0f4cd","seq":92,"ts":"2026-07-31T06:19:22.603Z","role":"system","kind":"message","text":"Goal: prove gothalo's push chain end-to-end. Rung ② is done…","parsed":true}
```

### `thinking`
Assistant reasoning surfaces as `kind:"thinking"` **when the transcript stores the
text**. Note: the observed Claude Code versions persist thinking blocks with an
**empty** text field (only a cryptographic `signature`) — the reasoning is not
written to disk — so in practice `thinking` entries are usually absent from a
Claude backlog. The reader emits them only when real text is present; the shape is:
```json
{"id":"a1b2…#0","seq":7,"ts":"2026-07-31T06:00:00.000Z","role":"assistant","kind":"thinking","text":"They want a health endpoint. I'll register a handler on the mux.","parsed":true}
```

### `tool_call` — Bash
```json
{"id":"5de67b18-b982-43ad-8722-f42ffb13b3fd#0","parent_id":"0e5fc094-25c5-4502-b46c-ca7cc160d90c","seq":31,"ts":"2026-07-31T06:06:19.224Z","role":"assistant","kind":"tool_call","tool":{"id":"toolu_01McJKGxUnpe7A7hJhBGWX1A","name":"Bash","title":"Bash","subtitle":"Check bridge dir, Go, Tailscale IP, herdr CLI","command":"cd /Users/alex/projects/gothalo/bridge && ls -la && echo \"---go---\" && go version …","input_summary":"cd /Users/alex/projects/gothalo/bridge && ls -la && …"},"parsed":true}
```

### `tool_call` — Edit (with preview diff)
```json
{"id":"377ab4c9-c228-4537-8020-c3c3ff3f5406#0","parent_id":"3d39bb0c-5c3b-41f2-abf4-b403e635ba7a","seq":82,"ts":"2026-07-31T06:13:48.103Z","role":"assistant","kind":"tool_call","tool":{"id":"toolu_01E6nzecxr8e4ELXcJ1NfHcV","name":"Edit","title":"Edit","file":"main.go","diff":"@@ -1 +1 @@\n func auth(next http.HandlerFunc) http.HandlerFunc {\n-\twant := \"Bearer \" + token()\n-\treturn func(w http.ResponseWriter, r *http.Request) {\n-\t\tif r.Header.Get(\"Authorization\") != want {\n \t\t\thttp.Error(w, \"unauthorized\", http.StatusUnauthorized)\n \t\t\treturn\n \t\t}\n+\ttok := token()\n+\twant := \"Bearer \" + tok\n …","input_summary":"/Users/alex/projects/gothalo/bridge/main.go"},"parsed":true}
```

### `tool_result` — ok (Bash stdout)
```json
{"id":"01f71a2c-608c-4a00-8f81-f1aa34c0007c#0","parent_id":"a0640b0d-e208-43a1-881c-b41735141208","seq":4,"ts":"2026-07-31T05:58:15.051Z","role":"user","kind":"tool_result","result":{"for_id":"toolu_012s3QgWUuY86vgKSRv41TcM","ok":true,"output_summary":"1\t# Handoff — conversation context carried over\n2\t\n3\tThis project was scoped in a conversation in another Herdr pane…"},"parsed":true}
```

### `tool_result` — ok (Edit applied diff)
```json
{"id":"ed9765de-00bd-4f34-a43b-f053cdf6f616#0","parent_id":"377ab4c9-c228-4537-8020-c3c3ff3f5406","seq":83,"ts":"2026-07-31T06:13:48.133Z","role":"user","kind":"tool_result","result":{"for_id":"toolu_01E6nzecxr8e4ELXcJ1NfHcV","ok":true,"diff":"@@ -39,9 +39,12 @@\n }\n \n func auth(next http.HandlerFunc) http.HandlerFunc {\n-  want := \"Bearer \" + token()\n+  tok := token()\n+  want := \"Bearer \" + tok\n   return func(w http.ResponseWriter, r *http.Request) {\n-    if r.Header.Get(\"Authorization\") != want {\n+    // Header is the normal path. ?token= is a convenience …"}},"parsed":true}
```

### `tool_result` — fail (permission rejected)
```json
{"id":"82f22884-c5ac-491e-a319-b1a4ec829fef#0","parent_id":"1e2d3d82-9287-4753-b3ae-767e2aa4d883","seq":43,"ts":"2026-07-31T06:07:57.498Z","role":"user","kind":"tool_result","result":{"for_id":"toolu_01JxVcjiXDGA9VaqHgGyt3A8","ok":false,"output_summary":"User rejected tool use"}}
```
> A failing Bash surfaces the same way with `ok:false` and the stderr in
> `output_summary` (prefixed `[stderr] …`).

### `entry` (live tail) — a real appended frame
Captured live while the agent ran a command (note `live:true` and `seq` continuing
past the backlog):
```json
{"type":"entry","live":true,"entry":{"id":"82e67515-fa41-41a7-a28a-6ae23ef8189a#0","parent_id":"b7757ea2-8ef0-4822-a092-725ded34ae2d","seq":205,"ts":"2026-08-02T13:25:31.001Z","role":"assistant","kind":"tool_call","tool":{"id":"toolu_01PDuj6NG5sFgp3YregTK8Tx","name":"Bash","title":"Bash","subtitle":"Generate transcript activity","command":"echo \"live-tail activity marker 1 $(date +%s)\"; sleep 3","input_summary":"echo \"live-tail activity marker 1 …"},"parsed":true}}
```

---

## How the transcript file is resolved

Claude Code writes one JSONL per session at
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, where `<encoded-cwd>` is the
absolute project cwd with **every `/` and `.` replaced by `-`** (verified against
live dirs: `/Users/x/.herdr/worktrees/foo` → `-Users-x--herdr-worktrees-foo` — the
`/.` becomes `--`).

From the pane, the bridge reads `cwd` and `agent_session.value` via
`herdr agent get <pane>`, then resolves (documented, in order):

1. **Direct hit** — `<encoded-cwd>/<agent_session.value>.jsonl`. Herdr's
   `agent_session.value` **is** Claude Code's own session id and equals both the
   filename stem and the JSONL's internal `sessionId` field (verified), so this is
   the normal path.
2. **Encoding-drift hardening** — if that misses but the session id is known, glob
   `~/.claude/projects/*/<session-id>.jsonl` (the session id is globally unique),
   finding the file regardless of how the dir name was encoded.
3. **Newest-matching fallback** — if the session id is unknown/unmatched, pick the
   **most-recently-modified** `*.jsonl` in the project dir whose own recorded `cwd`
   equals the pane's cwd (guards against a stale/rotated session id).

OpenCode v2 is resolved through its local managed service API using the
session id and pane cwd. The bridge prefers that supported API when the service
is reachable and falls back to the legacy SQLite store when it is not. `codex`
remains a recognized kind without a transcript source and returns `404` (see
below).

### pi

pi writes one JSONL per session at
`~/.pi/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl`, where `<encoded-cwd>` is
the absolute project cwd with the leading separator stripped, every `/` (and `\`
and `:` on Windows) replaced by `-`, and the result wrapped in `--` on both sides
(verified against pi's own `getDefaultSessionDirPath` and live dirs:
`/Users/x/projects/gothalo` → `--Users-x-projects-gothalo--`). Note this differs
from Claude Code's encoding: `.` is **not** replaced and the name is wrapped.

The line format mirrors Claude Code's JSONL — a `session` header, `message`
records, and metadata records (`model_change`, `thinking_level_change`, `custom`)
that are dropped — with two differences the reader handles:

- Tool calls are `toolCall` blocks inside an assistant message; tool results are
  **their own** message with `role:"toolResult"`, correlated to the call by
  `toolCallId` (the wire `tool.id == result.for_id` key is preserved).
- `isError` on the result message flips `result.ok` to `false`, and edit/write
  results carry the authoritative applied diff in `details.diff` (surfaced as
  `result.diff`).

Resolution is simpler than Claude's because Herdr's pi integration reports
`agent_session.value` as the **full path** to the `.jsonl`:

1. **Direct hit** — the session id *is* the file path; an existing file opens
   directly, a not-yet-written one is served as an empty pending source that
   streams in when pi creates it (pi writes the file lazily, on the first
   message).
2. **Bare-session-id glob** — a session id that is not a path globs
   `~/.pi/agent/sessions/*/*<session-id>.jsonl` (filenames embed the uuid),
   hardening against encoding drift.
3. **Newest-matching fallback** — unknown session id only: newest session in the
   encoded-cwd dir whose recorded `cwd` equals the pane's cwd.

pi has no subagent layout, so `hello.subagents` is absent for pi panes and
`?subagent=` resolution fails cleanly — the roster mechanism is Claude-specific
and discovery finds nothing for kinds that do not use it.

---

## Errors & close

Pre-upgrade failures are plain-text HTTP responses (the socket never opens), so the
client sees a real status:

| Status | When | Body |
|---|---|---|
| `400` | `pane` query param missing | `want ?pane=<pane_id>` |
| `401` | missing/invalid token | `unauthorized` |
| `404` | no agent in that pane | `no such agent` |
| `404` | no transcript resolved, or kind not supported yet (codex) | `no transcript file for pane` / `transcript not supported for this agent kind` |
| `500` | transcript read failed | `read transcript failed` |
| `502` | the underlying `herdr` command failed | `herdr agent get …: <stderr>` |

Once open, the socket closes with WebSocket **`1000` (normal closure)** when the
client goes away, the server shuts the stream down, or the client sends an
**unrecognized inbound frame** (anything that isn't a well-formed `load_older`) —
the last case closes with reason `"unrecognized control frame"`. A transient tail
read error (e.g. the file briefly unavailable during a rotation) is **not** fatal —
the tail logs and keeps polling; likewise a `load_older` read error just yields an
empty page rather than tearing down the socket.

---

## Limits

| Limit | Value | Effect |
|---|---|---|
| Newest page | **150** newest normalized entries on connect | Older entries are elided from the first page; `hello.has_more` / `has_older` / `backlog_complete.has_more` = `true`. Page up with `load_older`. |
| `load_older` page | **150** default, **500** max per request | Omitted/`0` `limit` ⇒ 150; a larger `limit` is clamped to 500. |
| Tool output | **4000 runes** per `output_summary` | Capped; `result.truncated = true`. |
| Diff size | **400 lines / 12000 runes** per diff | Capped; `tool.diff_truncated` or `result.truncated = true`. |
| Message/thinking body | **20000 runes** | Capped. |
| Tail poll | **250 ms** | New appended lines surface within ~one poll. |
| Session poll | **2 s** | A new agent session is picked up within ~one poll (`session_changed` + a fresh `hello`/backlog). |

Backpressure/safety: every page (newest **and** older) is read with a bounded ring
buffer (the whole file is never held in memory, no matter how deep you page); an
older page also stops scanning as soon as it reaches the cursor; transcript content
is only ever sent to the one authorized socket.

---

## Quick test (dev)

```bash
# any WS client; here with websocat
websocat "ws://127.0.0.1:8787/agent-transcript?pane=wN:p1&token=$TOKEN"
# → a hello frame, the backlog, a backlog_complete, then live entries as the agent works
```
