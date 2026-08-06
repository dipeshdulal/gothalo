# CONTRACT — Android home-screen widget

The contract between the Flutter app and the Android `AppWidgetProvider` that
draws the fleet on a home screen. It is **entirely app-internal**: the bridge
knows nothing about the widget and no endpoint or FCM payload changed for it.
The widget is fed from data the app already fetches
([`/snapshot`](API.md)) and woken by pushes the app already receives
([`CONTRACT-notifications.md`](CONTRACT-notifications.md)).

> **Android only.** `home_widget` registers Android and iOS, but there is no iOS
> widget extension in this repo and iOS is not a target (same footing as push).
> Every entry point is guarded by `fleetWidgetSupported`, so on iOS and web the
> whole feature compiles to no-ops.

---

## 1. What it answers

One question — *does anything need me?* — in the three numbers the app already
projects out of Herdr's `agent_status`:

| Number | `agent_status` | Meaning |
|---|---|---|
| **need you** | `blocked` | actively waiting on a human |
| **working** | `working` | busy, nothing to do |
| **done** | `done` | finished and not yet looked at |

`idle` and `unknown` are counted into the total and shown nowhere: an agent
sitting there having been seen is exactly the thing a glance is trying to skip
past. Splitting `blocked` from `done` rather than merging them into the app's
`needsAttention` is deliberate — a block is only resolved by answering it, a
completion is resolved by looking (see
[`CONTRACT-notifications.md`](CONTRACT-notifications.md) §4), so one is an ask
and the other is news.

Below the numbers, up to three attention-worthy agents by title, server-qualified
when more than one server contributes. Tapping anywhere opens **Priority**
(`/priority`) — the in-app screen that answers the same question in full.

## 2. The store

`home_widget` gives both sides one `SharedPreferences` file
(`HomeWidgetPreferences`). Dart writes, Kotlin reads. **A key one side does not
know about renders as its default, silently**, so these change in both places at
once: `fleet_widget_store.dart` and `FleetWidgetProvider.kt`.

| Key | Type | Meaning |
|---|---|---|
| `fleet.needs_you` | int | blocked agents, all servers |
| `fleet.working` | int | working agents, all servers |
| `fleet.done` | int | finished-and-unseen agents, all servers |
| `fleet.total` | int | every agent, including idle — written for later use, not drawn |
| `fleet.servers` | int | how many servers are **paired** |
| `fleet.lines` | String | up to 3 rows, `\n`-separated |
| `fleet.updated_at` | String | unix ms of the freshest server bucket |
| `fleet.buckets` | String | per-server JSON; **Dart only**, Kotlin never reads it |

`updated_at` is a **string** rather than an int on purpose. The platform channel
widens a Dart `int` to a Java `Long` only once it no longer fits an `Int`, so a
millisecond timestamp lands via `putLong` and a zero lands via `putInt` — and
`getLong` on a key written by `putInt` throws `ClassCastException`. A string has
one type on both sides.

`fleet.servers` exists because **"nothing needs you" and "this phone is paired
with no bridges" are the same numbers and opposite meanings.** Zero servers is
worded differently on the widget.

### Per-server buckets

`fleet.buckets` is `{"<profileId>": {name, n, w, d, t, lines, ts}}` and is what
the aggregate is merged from. Buckets rather than one aggregate because **the app
almost never has a live view of every server at once**: the `/events` socket
covers only the active server, and Priority's cross-server poll only runs while
that screen is open. Writing an aggregate from whichever source fired last would
let the active server's update erase every other server's counts.

Consequences, accepted:

- A server the app has not been able to reach contributes its **last known**
  counts, not zeros. `updated_at` is how you tell — it is the freshest bucket,
  and the widget renders it as `now` / `12m` / `3h` / `old`.
- Buckets are pruned to the currently-saved server ids on every write, so
  unpairing a machine takes its agents off the widget immediately.

## 3. When it refreshes

**Never on its own.** `updatePeriodMillis` is `0` and no `WorkManager` job, alarm
or `JobScheduler` entry is registered. The widget is a pure renderer; every
number on it was pushed there by the app. Three triggers:

| Trigger | Scope | Where |
|---|---|---|
| `/events` snapshot | the **active** server only | `fleetWidgetSyncProvider` |
| app start + every resume | **every** saved server | `fleetWidgetSyncProvider` |
| an FCM alert or dismiss | **every** saved server | `firebaseMessagingBackgroundHandler` |

The first is free — that socket is already open for the whole session, so the
widget tracks the active machine exactly as closely as the app does. The other
two are the only places the app asks a bridge it has no socket to; both are
moments something is already known to have changed. There is deliberately **no
timer**: waking N bridges in the background is what FCM exists to avoid, and it
is the same reasoning that confines Priority's own cross-server poll to the
seconds that screen is on screen.

The push path runs in the background isolate and resolves servers exactly the way
`notification_actions.dart` does — its own `AppDatabase`, bearers straight from
secure storage, its own `BridgeClient`. Each server gets a **4s** budget
(shorter than `BridgeClient`'s own 8s, because this runs while a notification is
being drawn) and they run concurrently; one asleep machine keeps its old numbers
instead of blanking the widget or delaying the others. **The tray comes first** —
the notification is rendered before the refresh touches the network.

### The cost when nobody uses it

Every path calls `fleetWidgetInstalled()` first and returns immediately if no
widget is on a home screen. A user who never adds the widget pays one
`getInstalledWidgets` channel hop per 30s of app use and nothing else.

## 4. The tap

`FleetWidgetProvider` sets one `PendingIntent` on the root view:
`HomeWidgetLaunchIntent.getActivity(context, MainActivity::class, gothalo://widget/priority)`.

It is an **explicit** intent to `MainActivity`, so no `<intent-filter>` for that
scheme is declared and nothing else on the phone can fire it. Dart picks it up on
two paths, because Android delivers the two cases differently:

| App state | Path |
|---|---|
| running (`MainActivity` is `singleTop`) | `HomeWidget.widgetClicked` → `onNewIntent` |
| dead | `HomeWidget.initiallyLaunchedFromHomeWidget()` at first frame |

Both route to `/priority` with **no server switching**, unlike a notification tap
— the widget counts the whole fleet and Priority is already cross-server, so
there is nothing to disambiguate.

## 5. Known limits

- **A frozen app process means a stale widget.** When Android never runs our Dart
  handler (swiped away, OEM-frozen) only the `os` half of an alert is drawn
  ([`CONTRACT-notifications.md`](CONTRACT-notifications.md) §2) and no refresh
  happens. The numbers keep their previous values and the age label is how you
  know. This is the deliberate trade against a background poller.
- **No cross-isolate write lock.** Writes are serialized within an isolate; the
  push isolate and the UI isolate are rarely awake together, and the loser of
  that race is corrected by the next refresh.
- **Line ordering across servers is best-effort.** Within a server the rows
  follow `Agent.byAttentionThenRecency` — the same comparator Priority, the
  Flock list and the jump sheet use, so the widget's rows are the head of the
  list its own tap opens. Across servers nothing links the ranks, so servers are
  interleaved a row at a time. Getting the global order right needs the agents
  themselves, which is more than a 2x2 cell can use.
- **One dark card in both system themes**, matching the app's dark-first
  identity, rather than a `values-night` variant.
