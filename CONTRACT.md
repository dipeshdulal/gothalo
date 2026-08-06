# CONTRACT — `WS /events` (unified event stream)

The mobile-side contract for gothalo's push event stream. This replaces the
app's per-action `/snapshot` refetch (and the timing hacks around it) with a
single reactive stream: the app connects once, seeds its store from a
**snapshot** frame, then applies **delta** frames as they arrive. Every surface
reads from that one store.

The stream is **unified**: it carries both Herdr's own events (normalized,
`source:"herdr"`) and gothalo's own system events (`source:"gothalo"` — things
Herdr doesn't know about: an approval gothalo applied, a pane it created for the
app, pairing, push, and Herdr connectivity).

> The `/agent-state` contract that used to live here moved to
> [`docs/CONTRACT-agent-state.md`](docs/CONTRACT-agent-state.md). It is
> unchanged and still current.

All examples below were **captured live** from the running bridge against Herdr
0.7.5 (protocol 17) unless explicitly marked *(shape from schema)* — those are
the handful of Herdr event types that didn't fire during capture, filled in from
`herdr api schema --json`.

---

## 1. Connect

```
GET /events?token=<bearer>
```

Upgraded to a **WebSocket**. Same auth as `WS /attach`: a `?token=` query
parameter carrying the per-device bearer from `/pair` (or the admin token in
dev). WS clients can't always set an `Authorization` header, so the token rides
in the query — exactly like `/attach`.

| Part | Value |
|---|---|
| Method | `GET` → WebSocket upgrade |
| Path | `/events` |
| Query | `token` — per-device bearer or admin token. **Required.** |
| Frames | **text** JSON, server→client only (see §6 for inbound) |

### Error / close cases before and around the upgrade
| Case | Result |
|---|---|
| No token | `401 unauthorized` (no upgrade) |
| Bad/unknown token | `401 unauthorized` (no upgrade) |
| Valid token but not a WS upgrade (e.g. plain curl) | `426 Upgrade Required` |
| Event bus disabled (shouldn't happen in `serve`) | `503 event bus not enabled` |
| Herdr snapshot fails at connect | socket closed with code `1011` (internal error) |
| Client falls too far behind (slow reader) | socket closed with code **`4000`** "resync: subscriber lagged" → reconnect + re-snapshot |
| Server/herdr teardown | normal close `1000`, or `4000` — either way: reconnect |

---

## 2. Framing: snapshot-on-connect, then deltas

**Frame 1 (always): the snapshot.** The full `/snapshot` payload plus the bus
sequence number it is consistent with:

```json
{
  "type": "snapshot",
  "source": "gothalo",
  "seq": 420,
  "ts": 1785677608858,
  "snapshot": { "id": "cli:api:snapshot", "result": { "snapshot": { "agents": [ … ], "panes": [ … ], "workspaces": [ … ], "tabs": [ … ], "focused_pane_id": "…", … } } }
}
```

- `snapshot` is **byte-for-byte the same JSON** as `GET /snapshot`. Seed your
  store from `snapshot.result.snapshot` (agents, panes, tabs, workspaces, focus).
- `seq` is the **baseline**: every delta that follows has `seq` strictly greater.
- **`branch`** — gothalo adds this string to every agent in `agents[]` (herdr
  does not provide it). It's the **authoritative** git branch, computed by
  running git in the pane's live `foreground_cwd` (falling back to `cwd`), not
  inferred from the path or read from the transcript. It is **`""`** when the
  pane isn't inside a git work tree (e.g. a home dir) or on a detached HEAD, so
  a client can render "no branch" rather than a misleading folder name.
- **`attention_rank`** — gothalo also adds this integer to every agent in
  `agents[]` (herdr does not provide it). It is the **authoritative** "needs a
  human first" ordering, lowest first: `blocked` 0, `done` 1, `working` 2,
  `idle` 3, `unknown` 4. An unrecognised or missing `agent_status` also ranks 4,
  so a status herdr adds later sorts last instead of jumping to the top. It is
  **always present**, so a client can sort on it unconditionally, and because
  every surface sorts on the same field, list order and any counts derived from
  it stay consistent. Herdr's own `agent.view` sort projection is **not** used —
  see [`docs/CONTRACT-herdr-proxy.md`](docs/CONTRACT-herdr-proxy.md) for why.

**Frames 2…N: deltas.** Each is one unified **envelope** (§3). Apply them to the
store in order.

The bus subscription is registered **before** the snapshot is taken, so any
event that occurs while the snapshot is being fetched is queued and delivered as
a delta right after the snapshot frame (its `seq > baseline`) — nothing is lost
in the gap.

### Heartbeat frames

Interleaved with the above, the bridge sends a heartbeat every **20 s**:

```json
{ "type": "heartbeat", "ts": 1785677608858 }
```

It carries **no `seq`**, deliberately. A seq-bearing frame means *something
changed*; a heartbeat means *nothing changed, I am still here*. Treating it as a
change signal would trigger a pointless full re-snapshot every 20 seconds.

**Handle it before your delta path:**

```dart
if (frame['type'] == 'heartbeat') return;   // not a change; do not re-snapshot
```

It exists because a quiet tailnet can go many minutes with no events, and a
connection can die in a way neither end observes — the bridge killed behind
`tailscale serve`, a phone's radio sleeping, a NAT entry expiring. That leaves a
**half-open socket**: the client's stream never ends, so it never reconnects and
serves stale state forever.

It is an application-level frame, not a WebSocket ping, and that distinction is
the whole point: a protocol ping is answered by the client's networking stack and
never surfaces to app code, so it cannot drive a client-side liveness check — and
in a half-open socket the client is exactly the side that learns nothing.

**Clients should time out on silence.** The app treats **50 s** with no frame of
any kind as a dead socket and reconnects (`app/lib/features/inbox/inbox_providers.dart`).
Any threshold comfortably above 20 s works.

---

## 3. The unified envelope

Every delta frame has this stable shape:

```json
{
  "source": "herdr" | "gothalo",
  "type":   "<event type>",
  "seq":    <uint, process-monotonic>,
  "ts":     <unix milliseconds>,
  "payload": { … event-specific … }
}
```

| Field | Meaning |
|---|---|
| `source` | `"herdr"` = forwarded/normalized from Herdr's socket stream. `"gothalo"` = gothalo's own system event. |
| `type` | The event type **within** that source's namespace (so read `(source, type)` together — e.g. `herdr` + `pane_created` vs `gothalo` + `pane_created` are different events). |
| `seq` | Monotonic counter, process-wide, shared across both sources and the snapshot baseline. Strictly increasing by 1 per published event. **Use it for gap detection** (see §5). |
| `ts` | Publish time in unix ms (server clock). |
| `payload` | For `herdr` events, **Herdr's own `data` object verbatim** (it also repeats a `type` field — ignore it, the envelope `type` is authoritative). For `gothalo` events, a small documented object (§4.B). |

### Real captured delta
```json
{"source":"herdr","type":"pane_created","seq":422,"ts":1785677608901,
 "payload":{"pane":{"agent_status":"unknown","cwd":"/Users/…/feat-event-bus","focused":false,"foreground_cwd":"/Users/…/feat-event-bus","pane_id":"wT:p2","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":90},"tab_id":"wT:t2","terminal_id":"term_6581077a5c32331","workspace_id":"wT"},"type":"pane_created"}}
```

---

## 4. Event catalog

### 4.A `source: "herdr"` — the 25 Herdr event types

Payloads are Herdr's `data` object. IDs are Herdr's (`wN` workspace, `wN:t1`
tab, `wN:p2` pane). The **driver** for the inbox is `pane_agent_status_changed`.

| `type` | When | Payload (real capture unless noted) |
|---|---|---|
| `pane_agent_status_changed` | an agent's status changed — **the "which agent needs me" signal** | `{"agent":"claude","agent_status":"idle","pane_id":"wT:p4","workspace_id":"wT"}` |
| `pane_agent_detected` | an agent was detected in a pane | `{"agent":"claude","pane_id":"wT:p4","type":"pane_agent_detected","workspace_id":"wT"}` (also carries `final_status`, `released` when a detection settles) |
| `pane_created` | a pane was created | `{"pane":{"pane_id":"wT:p2","tab_id":"wT:t2","workspace_id":"wT","agent_status":"unknown","cwd":"…","revision":0,"scroll":{…},"terminal_id":"…"},"type":"pane_created"}` |
| `pane_updated` | a pane changed (agent, title, cwd, revision…) | `{"pane":{"pane_id":"wN:pB","workspace_id":"wN","tab_id":"wN:t1","agent":"claude","agent_status":"idle","agent_session":{…},"terminal_title_stripped":"…","revision":6,…},"type":"pane_updated"}` |
| `pane_closed` | a pane closed | `{"pane_id":"wT:p3","workspace_id":"wT","type":"pane_closed"}` |
| `pane_exited` | a pane's process exited | `{"pane_id":"wN:pE","workspace_id":"wN","type":"pane_exited"}` |
| `pane_focused` | focus moved to a pane | `{"pane_id":"wN:pC","workspace_id":"wN","type":"pane_focused"}` |
| `pane_moved` | a pane moved tab/workspace *(shape from schema)* | `{"type":"pane_moved","pane":{…},"previous_pane_id":"…","previous_tab_id":"…","previous_workspace_id":"…","created_tab":{…}?,"created_workspace":{…}?,"closed_tab_id":"…"?,"closed_workspace_id":"…"?}` |
| `pane_output_changed` | pane output revision bumped *(shape from schema; **not delivered** — see §7)* | `{"type":"pane_output_changed","pane_id":"…","workspace_id":"…","revision":<int>}` |
| `tab_created` | a tab was created | `{"tab":{"tab_id":"wT:t2","workspace_id":"wT","label":"evbus-live","number":2,"pane_count":1,"agent_status":"unknown","focused":false},"type":"tab_created"}` |
| `tab_closed` | a tab closed | `{"tab_id":"w4:t2","workspace_id":"w4","type":"tab_closed"}` |
| `tab_focused` | focus moved to a tab | `{"tab_id":"wN:t1","workspace_id":"wN","type":"tab_focused"}` |
| `tab_renamed` | a tab was renamed *(captured on herdr 0.8.0 / protocol 19)* | `{"type":"tab_renamed","tab_id":"wZ:t2","workspace_id":"wZ","label":"api server"}` |
| `tab_moved` | a tab was reordered *(shape from schema)* | `{"type":"tab_moved","tab_id":"…","workspace_id":"…","insert_index":<int>,"tabs":[…]}` |
| `workspace_created` | a workspace opened | `{"workspace":{"workspace_id":"wQ","label":"agent-state","number":10,"active_tab_id":"wQ:t1","agent_status":"unknown","pane_count":1,"tab_count":1,"focused":true,"worktree":{…}},"type":"workspace_created"}` |
| `workspace_updated` | a workspace changed | `{"workspace":{"workspace_id":"wN","label":"gothalo","agent_status":"working",…},"type":"workspace_updated"}` |
| `workspace_closed` | a workspace closed | `{"workspace":{"workspace_id":"wR",…},"workspace_id":"wR","type":"workspace_closed"}` |
| `workspace_focused` | focus moved to a workspace | `{"workspace_id":"wN","type":"workspace_focused"}` |
| `workspace_renamed` | a workspace was renamed *(shape from schema)* | `{"type":"workspace_renamed","workspace_id":"…","label":"…"}` |
| `workspace_moved` | a workspace was reordered *(shape from schema)* | `{"type":"workspace_moved","workspace_id":"…","insert_index":<int>,"workspaces":[…]}` |
| `workspace_metadata_updated` | workspace metadata changed *(shape from schema)* | `{"type":"workspace_metadata_updated","workspace":{…}}` |
| `worktree_created` | a git worktree was created | `{"workspace":{…},"worktree":{"branch":"feat/agent-state","path":"/…/feat-agent-state","label":"gothalo","is_linked_worktree":true,…},"type":"worktree_created"}` |
| `worktree_removed` | a git worktree was removed | `{"workspace":{…},"workspace_id":"wR","worktree":{"branch":"feat/pane-control","path":"/…","…":true},"forced":false,"type":"worktree_removed"}` |
| `worktree_opened` | a git worktree was opened *(shape from schema)* | `{"type":"worktree_opened","workspace":{…},"worktree":{…},"already_open":<bool>}` |
| `layout_updated` | a tab's split layout changed | `{"layout":{"tab_id":"wT:t2","workspace_id":"wT","focused_pane_id":"wT:p2","area":{"x":26,"y":1,"width":219,"height":90},"panes":[{"pane_id":"wT:p2","focused":true,"rect":{…}}],"splits":[…],"zoomed":false},"type":"layout_updated"}` |

**Note on `pane_agent_status_changed`:** Herdr's event does **not** carry
`state_change_seq`. To get the seq you pass to `/approve`, pair the `pane_id`
with `/snapshot` (or the snapshot frame): read that agent's `state_change_seq`
there. `agent_status` in the event is authoritative for the badge; the seq comes
from the snapshot.

### 4.B `source: "gothalo"` — system events

| `type` | Emitted by | Payload (real capture unless noted) |
|---|---|---|
| `approve_applied` | `POST /approve`, on **every** outcome | `{"pane":"w5:p18","seq":179,"applied":false,"reason":"agent is idle, not blocked"}` · applied case: `{"pane":"wN:p2","seq":42,"applied":true,"reason":""}` |
| `pane_created` | `POST /pane/new` (an **app-created** pane; distinct from `herdr.pane_created`) | `{"pane_id":"wT:p3","tab_id":"wT:t2","workspace_id":"wT"}` |
| `pane_closed` | `POST /pane/close` | `{"pane_id":"wT:p3"}` |
| `device_paired` | `POST /pair` | `{"id":"1e55698e","name":"Contract Test Phone"}` |
| `push_sent` | after the FCM fan-out *(shape from code; FCM was disabled during capture)* | `{"agent":"wN:p2","status":"blocked","title":"…","seq":42,"sent":1,"total":1}` |
| `herdr_connected` | ingester connected/re-connected to the Herdr socket | `{"socket":"/Users/…/herdr.sock"}` |
| `herdr_disconnected` | Herdr socket dropped | `{"reason":"socket closed"}` |
| `herdr_resync` | ingester **re**-connected after a drop — **re-snapshot now** | `{"reason":"herdr reconnected"}` |

---

## 5. Sequencing & gap detection

- `seq` is process-monotonic and shared across `herdr`, `gothalo`, and the
  snapshot baseline. Under a single healthy connection it increments by exactly 1
  per delta.
- Track the last `seq` you applied. If a delta arrives with
  `seq > last + 1`, you **missed events** → reconnect (which re-snapshots).
- `seq` resets when the **bridge process** restarts. A new connection always
  begins with a fresh snapshot frame carrying the current baseline, so treat
  "reconnected" as "reseed from the snapshot frame" and start tracking from that
  baseline — don't compare seqs across connections.

---

## 6. Reconnect & resync semantics

Re-snapshot (reconnect the WS; the snapshot frame reseeds you) whenever any of:

1. The socket closes (any code) — reconnect with backoff.
2. You receive **`gothalo.herdr_resync`** — gothalo lost and regained its Herdr
   subscription and may have missed Herdr events during the gap. (You'll also
   see `herdr_disconnected` then `herdr_connected` around it.)
3. You detect a **seq gap** (§5).
4. You're closed with code **`4000`** (you fell behind and were dropped).

The bridge holds **one** Herdr socket subscription for the whole process and
fans it out; every app client is just another in-process subscriber. A slow
client is dropped (code `4000`) rather than being allowed to stall the stream for
everyone — so a client must always be ready to reconnect and reseed. There is no
server-side replay/backfill; the snapshot frame is the recovery mechanism.

**Herdr-down behavior:** if Herdr's socket is unavailable, deltas simply stop and
you'll get `herdr_disconnected`; the ingester retries every ~2s and emits
`herdr_connected` + `herdr_resync` when it's back. If Herdr is down at the moment
you connect, the snapshot fetch fails and the socket closes with `1011`.

### 6.A Inbound frames (client → server)
`/events` is **server→client only**. Any inbound frame (text or binary) is
treated as end-of-stream and ends the connection cleanly. Don't send data on it;
keep it read-only and let WebSocket pings/pongs keep it alive.

---

## 7. Scope notes

- **Multi-session.** The bridge watches every running Herdr session (`herdr
  session list`), one ingester + watcher per session. Ids from non-default
  sessions are qualified as `<session>/<id>` (e.g. `acme/w1:p2`) everywhere
  they leave the bridge — snapshot, event payloads, push data — and every
  endpoint accepts them back (`/send`, `/approve`, `/attach`, …). The default
  session stays unqualified. Every bus payload also carries a `session` label
  ("default" included), and the merged `/snapshot` adds a `sessions` name list
  plus a `session` field on each agent/pane/tab/workspace/layout element.
  `POST /herdr` infers the session from qualified ids in `params` (stripping
  them for Herdr) or takes an explicit top-level `"session"`; result ids come
  back re-qualified.
- `pane_output_changed` is in Herdr's catalog but is **intentionally not
  delivered** on this bus: it's high-volume per-pane output churn. Live terminal
  bytes stay on `WS /attach`; the parsed card stays on `/agent-state`. The bus is
  coarse and global. `/agent-transcript` is likewise **not** routed here.
- Agent status changes for panes created **after** you connect are covered too:
  the ingester derives them from the global `pane_updated` / `pane_agent_detected`
  stream (it can only place a targeted subscription for panes that existed when it
  connected). Either way you get one normalized `herdr.pane_agent_status_changed`
  per real transition (deduped server-side).

---

## 8. How the Herdr socket + wire framing were resolved

Documented so a future maintainer can reproduce it (see also
`internal/herdr/socket.go`).

**Socket path.** Not hardcoded. Resolution order: `HERDR_SOCK` env var, else
`herdr status server --json` → its `socket` field (the authoritative running
value). On this host that's `/Users/alex/.config/herdr/herdr.sock`.

**Wire framing** (reverse-engineered from `herdr api schema --json` +
experimenting against the live socket; herdr 0.7.5, protocol 17):

- **Newline-delimited JSON** (NDJSON), one object per line, both directions.
- A **request** is `{"id","method","params"}` — `id` is **required** (a request
  without it gets `{"id":"","error":{"code":"invalid_request",…}}`).
- To subscribe: `{"id":"gothalo-events","method":"events.subscribe","params":{"subscriptions":[ {"type":"pane.created"}, … ]}}`.
  Subscription `type`s are **dotted** (`pane.created`, `workspace.focused`,
  `layout.updated`, …).
- The server replies once: `{"id":"gothalo-events","result":{"type":"subscription_started"}}`,
  after which the **same connection becomes a one-way event stream** of
  `{"event":"<kind>","data":{…}}` lines until it closes. Event **kinds are
  underscore-cased** (`pane_created`, `pane_agent_status_changed`, …) — note the
  dotted-in / underscore-out asymmetry.
- **One `events.subscribe` per connection.** A second subscribe on an
  already-subscribed connection is silently ignored, so the full subscription set
  must go in the one request. gothalo subscribes to all 23 global structural
  kinds plus a targeted `pane.agent_status_changed` (dotted, needs a `pane_id`)
  for each agent pane present at connect. Targeted agent-status events arrive as
  the **dotted** `pane.agent_status_changed`; gothalo normalizes them (and the
  status carried on `pane_updated`/`pane_agent_detected`) into the single
  underscore `pane_agent_status_changed` envelope.
- Ping check used to confirm framing: send
  `{"id":"1","method":"ping","params":{}}\n` → get
  `{"id":"1","result":{"type":"pong","version":"0.7.5","protocol":17,…}}\n`.

---

*Contract captured against gothalo `feat/event-bus`, Herdr 0.7.5 / protocol 17.*
