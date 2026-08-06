# Design — how the bridge learns Herdr state

Status: **decided**. Steps 1-4 shipped. The `PaneStore` this document was
originally written to propose was **not built**, and should not be — see
[Decision: no PaneStore](#decision-no-panestore) at the end for the numbers.

The short version: the bridge reads state from Herdr directly, over the control
socket, and caches nothing.

## Why

Three bugs found in one session, all the same shape: **no component owns "what is
true right now."**

1. **The clearer dismisses live notifications.** `arm()` compares a status
   recorded by the *ingester* against a status announced by the *watcher*. Those
   are two independent observers of Herdr with no ordering relation between them,
   so "my record disagrees with the push" cannot distinguish *the agent moved on*
   from *my record is stale*. On a pane created after the bridge connected, the
   watcher wins systematically and every blocked push is dismissed within the
   same second.
2. **Post-connect panes go dark on the bus.** Herdr's `pane.agent_status_changed`
   is a *targeted* subscription requiring `pane_id`, and a connection's
   subscription set is frozen at connect. Panes created later have no targeted
   subscription, and the global structural events do **not** fire on agent status
   changes — measured: 57s of total silence across all 24 global kinds while an
   agent went idle → working → blocked.
3. **Everything is a subprocess.** `agent wait`, `agent list` (every 10s for
   discovery), and the three enrichment reads per notification each `exec` the
   `herdr` binary. Each spawned process just opens a unix socket we can open
   ourselves — confirmed with `lsof`: one `unix` fd per `herdr agent wait`.

These aren't independent defects. They are what happens when two pipelines each
hold a partial view and a third component tries to reconcile them.

## What Herdr actually offers

Established by reading `herdr` 0.8.0 (Apache-2.0) and testing against the live
socket. This is the ground truth the design rests on.

| Fact | Source |
| --- | --- |
| 27 subscription kinds; only `pane.output_matched`, `pane.agent_status_changed`, `pane.scroll_changed` require a `pane_id` | `api/schema.rs` |
| One `events.subscribe` per connection — `handle_connection` calls `read_initial_request_line` and never parses another request | `api/server.rs:150` |
| Writing **anything** to a live subscription connection kills it: the liveness probe treats any inbound byte as peer-closed (`Ok(_) => Ok(true)`) | `ipc.rs:158` |
| `PaneAgentStatusChanged` events exist **globally** on the internal `EventHub`; the targeted subscription just filters by `pane_id` | `api/subscriptions.rs:389` |
| The targeted subscription is **self-healing** — on no hub event it falls back to a `pane_get` and diffs, guarded against torn reads | `api/subscriptions.rs:454` |
| It supports a server-side `agent_status` filter, and an `initial_event` that fires immediately if the pane is already in that state | `api/subscriptions.rs:255` |
| It also fires on **presentation** changes (title), not only status — so it can re-emit the same status | `api/subscriptions.rs:484` |
| The wire envelope is `{event, data}` only. The hub's `u64` sequence is **server-side**, never transmitted | `api/schema/events.rs:378` |
| `state_change_seq` comes from a single app-wide counter — a **global total order** over every agent transition, comparable across panes | `app/actions.rs:2973` |
| `agent.wait`, `agent.get`, `agent.list`, `agent.read`, `agent.explain` are all socket methods; `agent.wait` returns the transition **and** its seq in one response | `api/schema.rs:128`, verified live |

Two consequences worth stating plainly:

- **`state_change_seq` is the only cross-component ordering token that exists.**
  The event stream gives implicit ordering *within one connection* and nothing
  else. Any comparison between facts from different connections must use seq.
- **Nothing requires a subprocess.** The CLI is a convenience wrapper over the
  same socket.

## Target architecture

```
herdr.sock ─ conn 0: global structural subs        ─┐
herdr.sock ─ conn N: per-pane agent_status         ─┼→  Ingest ──→  PaneStore
             (opened on pane.agent_detected,        ┘              (single writer,
              closed on pane.closed/exited)                         seq-stamped)
                                                                        │
                        ┌──────────────┬────────────────────────────────┼───────────┐
                        ▼              ▼                                ▼           ▼
                    /snapshot       /events                          Notifier    Clearer
                  (materialized)  (deltas + seq)                   (blocked/done) (seq cmp)
```

**One writer.** `Ingest` is the only thing that mutates `PaneStore`. Notifier and
Clearer are *readers*. There is no second opinion for them to disagree with, so
bug #1 becomes unrepresentable rather than fixed.

### Where seq comes from

The per-pane subscription does not carry `state_change_seq`, so the writer has to
attach one. The options, and why the third wins:

1. **`agent.wait` per pane as the input.** Returns status + seq atomically. But
   it's one-shot per connection and returns *immediately* if the pane is already
   in a target state, so tracking every transition means waiting on the
   complement of the current status and re-dialling each time — which is the
   current watcher's two-phase loop, minus exec. Workable, but it can miss
   intermediate states on a rapid flip and it re-dials constantly.
2. **Subscription + a separate seq lookup, stored independently.** Reintroduces a
   window between learning *what* changed and learning *when* — the same
   stale-read hazard, relocated.
3. **Subscription as the change signal; `agent.get` as the read.** ✅
   The subscription is precise, never misses (snapshot fallback), and covers any
   pane. On each event the writer issues one `agent.get`, whose response carries
   **status and seq from the same consistent read**. There is no torn
   status/seq pair, because they arrive in one message.

Option 3 also means the store never depends on the *payload* of the subscription
event — only on the fact that something changed. That is deliberately the same
discipline the Flutter app already follows, and the reason it has been immune to
the coarse-payload problems that bit the clearer.

Cost: one socket round-trip per transition. Compare to today's three `exec`s per
notification plus an `exec` every 10s for discovery.

### What the store holds

Per pane: identity (pane/tab/workspace, session-qualified), agent identity and
status, `state_change_seq`, presentation (title, labels), and the derived
`attention_rank` recomputed on write. Plus the structural tree (workspaces, tabs,
layout) from conn 0.

`/snapshot` becomes a materialization of this — no Herdr round-trip. That is what
lets the app keep its self-correcting refetch model at negligible cost, which is
the decision recorded below.

### Event structure

Envelope stays `{source, type, seq, ts, payload}`. Three changes:

1. **Agent events carry `state_change_seq`.** Herdr's global order, distinct from
   our bus `seq`. This is what makes any future cross-component comparison sound
   by construction.
2. **Deltas vs signals are explicit.** *Deltas* describe state and carry the
   derived fields needed to apply them (`attention_rank`). *Signals*
   (`herdr_resync`, `push_sent`, `notification_cleared`, `heartbeat`) are nudges
   and must never be applied. Today they share one stream and only the app's
   "refetch on everything" policy hides the distinction.
3. ~~The stream is versioned.~~ **Deferred.** Capability negotiation exists to
   let old clients meet new bridges. With two known users who upgrade both sides
   together, it buys nothing today and is speculative structure. The existing
   `BridgeVersion` + `/info` already covers "is this bridge too old", which is
   the one case we actually hit. Revisit if the app is ever distributed.

Deltas carrying enough to be applied does **not** oblige the app to apply them —
see the decision below. It removes the blocker so the choice stays open.

## Decisions

- **App keeps the debounced `/snapshot` refetch.** It is self-correcting: a
  missed event, a coarse payload, a 512-entry hub rollover, or a reconnect all
  converge, because it refetches truth. Delta application would make gap
  detection load-bearing. Once `/snapshot` is materialized the refetch is
  in-memory, so the cost that motivated changing it largely disappears. Revisit
  only with measurements.
- **Do not put a bridge-fetched seq into the app-facing status event as a
  substitute for `/snapshot`.** `API.md` currently tells clients to pair
  `pane_id` with the snapshot to get the seq for `/approve`, and that is correct:
  the snapshot is one consistent read. A seq attached to an event out-of-band
  could already be wrong by the time the client uses it, and `/approve` would
  fail. The store's seq is for the *bridge's* internal comparisons.
- **Keep the per-pane subscription rather than a global one.** A global
  `pane.agent_status_changed` would be an upstream change to Herdr (drop the
  `pane_id` filter). Worth filing, not worth blocking on — and the targeted
  subscription's snapshot fallback makes it more reliable than a raw global feed.

## Audience

Two users (both developers), who upgrade bridge and app together. So:

- **Contract changes may be breaking.** No deprecation windows, no dual-read
  paths, no version negotiation — ship both sides in the same stack.
- **Steps need to be reviewable, not independently shippable.** Stacked PRs for
  sanity, with the whole stack landing together where that is simpler.
- The one real compatibility case — *a bridge that hasn't been upgraded yet* —
  is already handled by `BridgeVersion` and the servers-list warning.

## Staging

Stacked, each reviewable on its own. Step 1 stands alone and should land first
regardless, because it fixes something broken right now.

| # | Step | Contract change | Notes |
| --- | --- | --- | --- |
| 1 | Clearer decides from an authoritative read + sweep | none | **Done.** Fixes a live bug. Independent of everything else; correct under both old and new architecture. |
| 2 | Document the `heartbeat` frame and `done` semantics | docs only | **Done.** Both were undocumented; see below. |
| 3 | Socket transport for the hot paths (Wait/Agents/Get) | none | **Done.** 9 processes -> 0. Remaining cold paths (SnapshotRaw, ReadText, Explain, pane ops) still on the CLI. |
| 4 | Per-pane subscriptions, opened on `pane.agent_detected` | none | **Done.** Fixes post-connect panes going dark. |
| 5 | Introduce `PaneStore` as single writer; `/snapshot` materialized | none | The structural change. Notifier and Clearer become readers. |
| 6 | Event structure: `state_change_seq`, delta/signal split | **breaking OK** | Ship with the app side in the same stack. |

Steps 1-4 leave the mobile contract untouched, so the app needs no change until
step 6 — and step 6 can break freely since both sides ship together.

## Documentation gaps found (independent of this design)

- **The `heartbeat` frame is documented nowhere.** The bridge sends
  `{"type":"heartbeat","ts":…}` every 20s (`internal/server/events.go:53`) and the
  app depends on it (50s silence ⇒ reconnect). A client built from `API.md` would
  meet an unknown frame, and the natural reading — "a frame arrived, therefore
  something changed" — would trigger a pointless full re-snapshot every 20s.
- **`done` is not a state an agent enters.** Herdr projects it as
  `AgentState::Idle` + `seen == false` (`app/api_helpers.rs`). So *looking at the
  pane in Herdr on the desktop* flips `done` → `idle`, which is a transition,
  which dismisses the notification — with the agent doing nothing. Correct, but
  it reads as a bug until documented.

## Open questions

- Should `PaneStore` be a single owning goroutine with a command channel, or a
  mutex-guarded struct? The former makes "one writer" structural; the latter is
  less code. Leaning goroutine, since the whole point is to make the invariant
  hard to break.
- How many concurrent per-pane connections is comfortable? Each costs a thread in
  Herdr polling at 100ms (`CONNECTION_POLL_INTERVAL`). Fine at 6 agents; worth
  measuring before assuming it is fine at 50.
- Does the store need to persist across bridge restarts, or is a cold rebuild
  from `agent.list` + structural snapshot sufficient? Currently assuming the
  latter.

## Decision: no PaneStore

This document opened by proposing an authoritative in-bridge store as the single
writer. After steps 1-4 shipped, that no longer earns its complexity. Recording
why, so the case is not rebuilt from scratch.

### The original justification is gone

The store's headline argument was *"the clearer bug becomes unrepresentable"* —
no second opinion to disagree with. But step 1 fixed that a different way: the
clearer asks Herdr and compares against a fresh read.

A store is a **cache**. Pointing the clearer at one would reintroduce precisely
the shape that caused the bug. `lastStatus` *was* a cache of agent state, and it
dismissed live notifications on every post-connect pane.

### The performance argument does not survive measurement

Measured against the live socket after step 3:

| call | median | payload |
| --- | --- | --- |
| `session.snapshot` | **1.18 ms** | 19 KB |
| `agent.list` | 0.33 ms | 3 KB |
| `agent.get` | 0.15 ms | — |
| `herdr api snapshot` (the CLI path we replaced) | ~7 ms | + a process spawn |

A store would take a snapshot read from 1.18 ms to perhaps 0.05 ms. The app
refetches at most ~4×/s (250 ms debounce), so the saving is single-digit
milliseconds of CPU per second. Caching exists to hide a slow or remote source;
this source is a local Unix socket in the same machine's memory.

### Herdr already caches, and better than we would

Its targeted `pane.agent_status_changed` subscriptions fall back to polling the
pane and diffing when the event hub had nothing (`api/subscriptions.rs:454`),
guarded against torn reads. A store in front of that would be a second,
less-correct copy of a mechanism that already works.

### What remains true from this document

The Herdr API constraints table is the durable part — it was established by
reading `herdr` 0.8.0 and testing against the live socket, and it is what the
shipped design rests on. Also still true:

- `state_change_seq` is the only cross-component ordering token that exists, and
  anything comparing facts from two sources must use it.
- The event bus is a **change signal**, not a state feed. Consumers must treat a
  payload as a nudge and read truth themselves. That is the single rule that
  would have prevented every bug found in this work.
- The app's debounced-refetch model is self-correcting and should stay that way
  until measurements say otherwise.

### If this is ever revisited

The two things that would change the answer: an app that applies deltas instead
of refetching (needs enriched deltas, which needs a writer that owns derived
state), or agent counts high enough that two socket connections per agent
becomes a real cost. Neither is true at present.
