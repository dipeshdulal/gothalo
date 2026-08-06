# CONTRACT — `GET /timeline` (recent agent activity)

The Activity screen's contract: the recent **past** of every agent the bridge
can see — one entry per status transition, each carrying **how long the agent
spent in the status it just left**.

It exists because every other read surface answers "what is true now".
`/snapshot`, `/agent-state`, the inbox and Priority all say *blocked*; none of
them can say whether that block started fifty minutes ago or ten seconds ago,
and that difference is the entire question you have when you pick your phone up
after an hour. `state_change_seq` is a counter, not a clock, so the elapsed time
is genuinely unreconstructable from live state — which is the bar
`docs/RESEARCH-feature-ideas.md` #8 sets for this feature existing at all.

> **Not captured live.** Every sibling contract in this directory was recorded
> against a running bridge. This one was not: it was written on a machine with
> no Herdr host, so the examples below are constructed from the recorder's own
> types (`internal/timeline`) and the unit tests that pin them, not from real
> agent traffic. The shapes are exact — they are what `encoding/json` emits for
> `timeline.Entry` — but no example here is a capture, and the end-to-end
> behaviour against live Herdr transitions is **unverified**.

---

## Request

```
GET /timeline?limit=<n>&pane=<pane_id>
Authorization: Bearer <bearer>
```

| Part | Value |
|---|---|
| Method | `GET` |
| Path | `/timeline` |
| Query | `limit` — page size, **optional** (default `100`, capped at `500`). `pane` — session-qualified pane id, **optional**; restricts the log to one agent. |
| Body | none |
| Auth header | `Authorization: Bearer <bearer>` — the per-device bearer from `/pair`, or the admin token (dev). Same auth as every other endpoint. |

Answered entirely from an in-memory ring: **no Herdr call**. That makes it cheap
enough to poll, and it still answers while Herdr itself is down — which is
exactly when a client most wants to see what happened before things went quiet.

`pane` matches the **whole** id, not a suffix: `w1:p2` and `acme/w1:p2` are
different panes on different Herdr sessions, and a filter for one must never
return the other.

---

## Response `200` — schema

```json
{ "entries": [ … ], "limit": 100 }
```

| Field | Type | Notes |
|---|---|---|
| `entries` | array | **Newest first.** Empty (never `null`) when nothing has been recorded — a fresh bridge is a normal state, not an error. |
| `limit` | int | The page size actually applied, after defaulting and clamping. A client that asked for 100000 can see it got 500. |
| `entries[].ts` | int | When the bridge **observed** the transition, unix milliseconds. |
| `entries[].pane` | string | Session-qualified pane id (`w1:p2`, `acme/w1:p2`) — the same id `/attach`, `/send` and `/approve` take, so a row can open the agent it describes. |
| `entries[].agent` | string \| absent | Agent kind (`claude`, `codex`, …). Carried on the entry so a row can name its agent without a second lookup — **including for a pane that has since closed** and is in no snapshot any more. |
| `entries[].session` | string \| absent | Herdr session label (`default`, `acme`), matching the bus payloads. |
| `entries[].workspace` | string \| absent | Session-qualified workspace id. There is deliberately **no tab id**: the workspace rides along on the bus payload for free, and resolving a tab would cost a Herdr read per transition. |
| `entries[].from` | string \| absent | The status being left. **Absent means a first sighting** — the bridge had never seen this pane before — not a transition out of an unnamed state. |
| `entries[].to` | string | The status entered: a Herdr agent status (`idle`, `working`, `blocked`, `done`, `unknown`), or the synthetic `gone`. |
| `entries[].prev_ms` | int \| absent | **How long the agent spent in `from`**, milliseconds. See below — absent and `0` are different answers. |

### `to: "gone"` — the pane stopped existing

Herdr has no agent status for "the pane is gone", but for a timeline it is the
most informative transition there is: it says the agent **stopped** rather than
went quiet, and it closes the open span with a real duration ("worked 40m, then
the pane closed") instead of abandoning it mid-flight. It is recorded when a
pane closes or its process exits, from either source — Herdr's own
`pane_closed`/`pane_exited` and gothalo's `POST /pane/close`. A pane the bridge
never saw an agent in is ignored: a plain shell closing is not agent activity.

### `prev_ms` absent is not `prev_ms: 0`

`0` is a real value — an agent that flipped status instantaneously — so the two
must not be conflated, and a client must not render a missing duration as "0s".

It is **absent** when the bridge cannot see where the span began. That happens
in exactly one situation: the first transition after a gap in observation the
bridge could not close (see *Restart & outage semantics*). Show nothing rather
than a number in that case; a duration measured from bridge startup would be a
plausible-looking lie, which on this endpoint is worse than no answer.

---

## Example response

Constructed, not captured — see the note at the top. Four entries, newest first:
one agent that has just blocked, one that blocked and was answered after 50
minutes, one first sighting, and one closed pane.

```json
{
  "entries": [
    {
      "ts": 1785681000000,
      "pane": "w4:p2",
      "agent": "claude",
      "session": "default",
      "workspace": "w4",
      "from": "working",
      "to": "blocked",
      "prev_ms": 742000
    },
    {
      "ts": 1785680100000,
      "pane": "acme/w1:p3",
      "agent": "codex",
      "session": "acme",
      "workspace": "acme/w1",
      "from": "blocked",
      "to": "working",
      "prev_ms": 3012000
    },
    {
      "ts": 1785679000000,
      "pane": "w4:p2",
      "agent": "claude",
      "session": "default",
      "workspace": "w4",
      "to": "working"
    },
    {
      "ts": 1785678000000,
      "pane": "w2:p9",
      "agent": "claude",
      "session": "default",
      "workspace": "w2",
      "from": "done",
      "to": "gone",
      "prev_ms": 61000
    }
  ],
  "limit": 100
}
```

Read the second entry as: *codex stopped being blocked at 14:15, having been
blocked for 50m 12s*. The third has no `from` and no `prev_ms` because it is the
first time the bridge ever saw that pane.

---

## What is recorded (and what deliberately isn't)

**Recorded:** agent status transitions, and pane disappearance. Nothing else.

An alerts log over an `AgentEvents` drift table existed once and was deleted
(schema v4), because storing "agent went blocked" duplicated live state the
bridge already answers. This is not that. The entries here are **not a mirror of
current status** — the app still reads status from `/snapshot` — they are the
transitions themselves plus the one derived fact (`prev_ms`) that no live read
can reconstruct.

**Deduplicated.** A repeat of the status already open is dropped. The ingester
already dedupes, but it dedupes *per ingester*, and a Herdr reconnect re-seeds
that baseline — so the same status can legitimately be re-announced. Recording
it would show a transition that never happened **and** reset the duration that
made the row worth reading.

**Bounded twice over**, so the ring can never grow without limit:

| Bound | Value | Why |
|---|---|---|
| `MaxEntries` | `1500` | ~200 bytes an entry puts a full ring around 300KB — the last day or two of a busy fleet, in a file small enough to rewrite on a timer. Oldest evicted first. |
| `Retention` | `72h` | A glanceable "what happened while I was away", not an audit log. A transition from four days ago answers no question the user is asking and only pushes out one that does. Enforced on the flush timer, not just on append, so a *quiet* bridge sheds stale entries too. |
| `DefaultLimit` | `100` | Deep enough to fill a phone screen several scrolls over. |
| `MaxLimit` | `500` | One request can never be asked to marshal the whole ring. |

---

## Restart & outage semantics

The ring is **persisted** (`<DataDir>/timeline.json`, atomic temp-file+rename,
flushed every 5s while dirty). A bridge restart is precisely when the recent past
is most valuable and an in-memory ring is emptiest, so the entries survive it.

The **durations** need one more step, because a span that was already running
when the bridge stopped has a start time that lived only in memory. On startup —
and again whenever Herdr reconnects — the recorder rebuilds its open spans from
an authoritative read, the same discipline `internal/notify`'s rearm follows
(ask what is true NOW, then decide what the stored record means):

- The newest persisted entry says the pane entered **this** status at time `T`
  → resume the span at `T`. An agent blocked since before the restart keeps its
  real number.
- It says anything else, or there is no entry → the span opens at *now* and is
  marked unknown, so its first transition carries **no** `prev_ms`.
- We already track a span naming the same status → left completely alone. Its
  start is better information than any read can supply.
- We track a span naming a **different** status → a transition happened
  unobserved (the ingester re-seeds its own baseline on reconnect, so a pane
  that moved while the socket was down fires no event when it comes back). The
  span is re-pointed at the truth and marked unknown.

**No entry is ever written by that rebuild.** We know a transition happened but
not when, and every consumer reads `ts` as when the agent actually moved — so a
row stamped "now" would report an agent blocked since before the restart as
having *just* blocked, inverting the one answer this endpoint exists to give. The
record therefore has a hole where the unobserved transition was, and the next
real entry's `from` names the status the agent genuinely left. **A gap in the
history is honest; a well-formed row with a made-up time is not.**

A corrupt or unreadable history file degrades to an empty ring with a warning
rather than failing startup: pairing, approvals and push all depend on the bridge
coming up, and the timeline is a convenience.

---

## Why this is NOT on `WS /events`

It would distort the contract, so the app **polls** this endpoint instead.

`WS /events` is defined (CONTRACT.md §2) as *snapshot-on-connect, then deltas*
seeding a store of **current** state, and its recovery mechanism is re-seeding
from the snapshot frame — there is no replay or backfill. History does not fit
either half of that:

- A `gothalo.timeline_entry` delta would be **lossy exactly when it matters**. A
  client that reconnects, hits a `seq` gap, or is dropped for lagging (close
  `4000`) recovers by re-snapshotting, and the snapshot frame carries no
  history — so the entries published during the gap are simply gone. The client
  would have to fetch `/timeline` anyway, which makes the delta redundant.
- It would **duplicate** `herdr.pane_agent_status_changed`, which is already on
  the stream. Two events per transition, one authoritative for the badge and one
  for the log, is a contract that invites them to disagree.
- Every `source:"gothalo"` event today is a notification that gothalo **did
  something** (applied an approval, created a pane, sent a push). A recorded fact
  about the past is a different kind of thing.

The app gets liveness anyway, without touching the contract: `/events` already
signals *something changed*, and an agent transition is exactly the change that
adds a row. The Activity screen re-reads `/timeline` when the agent statuses in
the snapshot change, and otherwise on a slow timer for the relative clock. One
signal, one authoritative read, no new frame type.

---

## Errors

Error bodies are plain text (not JSON), matching the other endpoints.

| Status | When | Body |
|---|---|---|
| `400` | `limit` present but not a positive integer | `limit must be a positive integer` |
| `401` | missing/invalid bearer | `unauthorized` |
| `503` | the bridge is running without a recorder | `timeline not enabled` |

A malformed `limit` is **rejected rather than silently defaulted**: a client that
asked for something specific and got a different page size back would have no way
to notice. An out-of-range one is clamped instead, and the applied value is
echoed in `limit` so the client can see what it got.

`503` and an empty `entries` array are deliberately different answers — "no
recorder running" and "nothing has happened yet" are different situations and a
client should be able to tell them apart.

---

## Implementation notes (for maintainers)

- Handler: `internal/server/timeline.go` (`handleTimeline`), registered at
  `mux.HandleFunc("/timeline", …)` in `internal/server/server.go`. Bumps
  `BridgeVersion` to **2**.
- Recording: `internal/timeline` — `Log` is the bounded persistent ring,
  `Recorder` is the bus consumer. The Recorder deliberately mirrors
  `internal/notify.Clearer` (subscribe, consume, re-subscribe on drop): it is the
  same kind of thing, a long-lived observer of the unified bus.
- Unlike the Clearer, the Recorder **trusts the bus payload's status**. The
  Clearer must not, because it decides whether to retract a notification a human
  is looking at. Here the bus *is* the subject: the job is to log the transitions
  the bus announced, in the order it announced them. Re-reading Herdr per event
  would cost a socket round-trip per transition and record a different sequence
  of statuses from the one every other client saw.
- Persistence path: `Config.TimelinePath()` → `<DataDir>/timeline.json`, beside
  the device registry.
- Tests: `internal/timeline/timeline_test.go` (ordering, limits, both bounds,
  persistence, corrupt input), `internal/timeline/recorder_test.go` (durations,
  dedup, `gone`, and every reconcile branch, including end-to-end over a real
  bus), `internal/server/timeline_test.go` (auth, limit handling, pane filter,
  empty and disabled).
