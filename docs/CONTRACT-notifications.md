# CONTRACT — notifications

The full push contract between the bridge and the app: what a notification
carries, how it is delivered, how it is rendered, and how it is acted on.

Companion documents: [`CONTRACT-notif-clear.md`](CONTRACT-notif-clear.md) covers
the auto-dismiss consumer; [`API.md`](API.md) covers the HTTP surface a
notification action calls back into.

> **Android only.** iOS is not a target today, so no APNs config is sent and the
> app registers no iOS notification categories.

---

## 1. Why the payload looks the way it does

Three delivery facts drive every design decision here.

**A data-only message can only be drawn by the app.** FCM messages with just a
`data` block never reach the system tray on their own — the client's Dart handler
has to render them. When the process is gone (swiped from recents, OEM-frozen)
that handler never runs, so nothing appears.

**But a message carrying a `notification` block never reaches the app's handler
while the app is backgrounded.** Android displays it and does not deliver it to
`onMessageReceived`. So that shape can never grow action buttons or grouping —
verified on a Galaxy S908E: the notification arrived with `actions=0`.

The two facts are in direct conflict, and no single message satisfies both. So
**every alert is sent twice** (§2).

**A data message defaults to NORMAL priority.** Doze is free to batch normal
messages until the next maintenance window, which reads to a user as "the
notification never arrived". Every gothalo message sets
`android.priority: "high"`.

**A phone is paired with several bridges under one FCM token.** Nothing in the
transport says which machine a push came from, so every payload carries
`server_id` / `server_name`. Without them an alert cannot be attributed, its tap
cannot be routed, and an Approve cannot know which bridge to call.

---

## 2. Alert messages — a pair

One agent transition produces **two** FCM messages per device
(`internal/server/notify.go`), distinguished by the `render` data key:

| `render` | Shape | Role |
|---|---|---|
| `os` | `notification` + `data` | Android draws it unaided. Survives a swiped-away, frozen or killed process. No buttons, no group — Android never hands it to the app. |
| `app` | `data` only | Reaches the app's handler, which **redraws the same tag** with Approve/Reject and the group. Best-effort: a frozen process never sees it. |

Because both carry the same `tag`, the second replaces the first in place. Net
effect: the notification always appears, and upgrades itself to an actionable one
whenever there is a live process to do it.

Client rules that follow from this:

- **Ignore `render:"os"` entirely** — never render it (Android already did) and
  never log it (its twin does). A foreground app receives *both*; without this
  check every alert lands in the history twice.
- Delivery is counted on the `os` message: its failure is the one the user sees.

### Envelope (the `os` half)

```jsonc
{
  "message": {
    "token": "<device token>",
    "notification": { "title": "…", "body": "…" },   // system-rendered fallback
    "data": { /* see below */ },
    "android": {
      "priority": "high",
      "collapse_key": "<server_id>/<pane_id>",
      "notification": {
        "tag": "<server_id>/<pane_id>",
        "channel_id": "gothalo_blocked" | "gothalo_done",
        "notification_priority": "PRIORITY_HIGH",
        "default_sound": true
      }
    },
    "webpush": { "headers": { "Urgency": "high", "TTL": "3600" } }
  }
}
```

### `data` keys

| Key | Meaning |
|---|---|
| `type` | `"alert"`. The discriminator against `"dismiss"`. |
| `render` | `"os"` or `"app"` — which half of the pair this is. See above. |
| `agent` | pane id, session-qualified (`<session>/<pane>`) when not the default session. The deep-link target. |
| `status` | `"blocked"` or `"done"`. |
| `state_change_seq` | the agent's seq at the transition, as a string. Echoed back to `POST /approve`. |
| `server_id` | the sending bridge's id (`GET /info`). |
| `server_name` | that bridge's human name, e.g. `"Mac Studio"`. |
| `agent_title` | the pane's terminal title. |
| `title` / `body` | the composed notification text, mirrored so the app can re-render it. |
| `question` | *(blocked, best-effort)* the prompt the agent is actually asking. |
| `options` | *(blocked, best-effort)* JSON array of `{index,label,selected,key}` — the prompt's choices. |
| `category` | *(blocked, best-effort)* Herdr's detection rule id, e.g. `dangerous_command_approval`. |

`question` / `options` / `category` come from a live `agent-state` read at
notification time and are **omitted** when it fails. An alert always goes out;
only its richness degrades.

### Composed text

```
title:  <server_name> · <agent_title>
body:   Needs you — <question> · 1. Yes / 2. No      (blocked)
        Finished — <headline>                        (done)
```

Title carries *where* (the line a locked phone always shows), body carries *why*.
Bodies are truncated to 240 runes.

---

## 3. Dismiss messages

Data-only and silent — see [`CONTRACT-notif-clear.md`](CONTRACT-notif-clear.md)
for when they fire.

```jsonc
{
  "data": { "type": "dismiss", "agent": "<pane_id>", "server_id": "<server_id>" },
  "android": { "priority": "high", "collapse_key": "<server_id>/<pane_id>" }
}
```

No `notification` block, no title or body: a dismiss exists to make the client
cancel something and must never draw anything itself.

---

## 4. Channels

The bridge names a channel in every alert. **A push naming a channel the app has
not created is dropped silently on Android 8+**, so these ids are a hard
contract.

| Channel id | Importance | Used for |
|---|---|---|
| `gothalo_blocked` | HIGH (sound, heads-up) | an agent is waiting on you |
| `gothalo_done` | DEFAULT (quiet) | an agent finished its turn |

`gothalo_agents` is the pre-split channel; the app deletes it on launch.

### `done` is not a state an agent enters

Worth knowing, because the behaviour it causes reads as a bug otherwise.

Herdr's internal model has **four** agent states — `Idle`, `Working`, `Blocked`,
`Unknown`. The API's five-value `agent_status` is a *projection* of those plus a
"has the user looked at this" flag (`herdr` 0.8.0, `src/app/api_helpers.rs`):

```rust
(AgentState::Idle,    false) => AgentStatus::Done,     // idle + NOT seen
(AgentState::Idle,    true)  => AgentStatus::Idle,     // idle + seen
(AgentState::Working, _)     => AgentStatus::Working,
(AgentState::Blocked, _)     => AgentStatus::Blocked,
```

So **`done` means "idle, and you haven't looked at it yet."**

The consequence: **focusing the pane in Herdr on the desktop flips `done` →
`idle`.** That is a status transition, so the notification-clearer dismisses the
completion notice — with the agent having done nothing at all. Correct
behaviour (you *have* now seen it), but "my completion notification vanished
when I clicked on the terminal" is not what anyone would predict.

It also means a `done` notification is inherently more perishable than a
`blocked` one. A block is only resolved by answering it; a completion is
"resolved" by so much as looking.

---

## 5. Tag and id (replace, don't duplicate)

Firebase's Android SDK posts a `notification` block as `notify(tag, 0, …)`. The
app therefore renders **every** notification with **id 0** and the payload's tag,
so its own rich version *replaces* the system-drawn one instead of stacking a
duplicate beside it. A dismiss cancels `(id: 0, tag)`.

The tag is `<server_id>/<pane_id>` — server-qualified, so the same pane id on two
machines is two notifications, not one that overwrites the other.

Notifications are grouped per server (`gothalo.server.<server_id>`) under a
summary notification whose id is derived from the server id.

---

## 6. Actions

A blocked notification carries up to two buttons, handled in a background isolate
(`notification_actions.dart`) that resolves `server_id` → saved profile → bearer,
and calls the bridge directly.

| Action id | Call | Offered when |
|---|---|---|
| `gothalo.approve` | `POST /approve {agent, seq}` | `state_change_seq` is present |
| `gothalo.reject` | `POST /send {pane, key}` or `{pane, text}` | the prompt has a decline choice |

Approve is safe from a stale lock screen because `/approve` is idempotent: the
bridge no-ops if the agent has moved past that `seq`.

Reject has no dedicated endpoint by design — declining is agent-specific UI, so
it is expressed as the prompt's own decline choice: the `esc` keystroke the
parser found, or the non-default numbered option.

**The receiver must be declared by the app.** `flutter_local_notifications`
ships the `ActionBroadcastReceiver` class but its plugin manifest declares only
permissions, so the app's own `AndroidManifest.xml` must register it:

```xml
<receiver android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"
          android:exported="false" android:enabled="true" />
```

Without it the failure is silent and very convincing: the buttons render, they
animate on tap, `SystemUI` logs `EID_QPNE_NOTI_ACTION_BUTTON`, and Android
resolves the broadcast to no component (`sent=0`). Nothing reaches Dart.

**When the app process is frozen outright**, only the `os` half is on screen, so
there are no buttons. The alert still arrives and still deep-links on tap. In
practice the `app` half gets through more often than expected — measured on a
Galaxy S908E, even after `am kill` the push restarted the process and the
notification upgraded to `actions=2`.

---

## 7. Routing a tap

The notification payload is JSON: `{server_id, pane, seq, options}`.

A tap can arrive through either of two paths, and both are handled:

- **the app's own notification** → `flutter_local_notifications` response, or
  `getNotificationAppLaunchDetails()` on a cold start;
- **the system-drawn one** (app was killed) → `FirebaseMessaging`'s
  `getInitialMessage()` / `onMessageOpenedApp`.

Routing **switches the active server first** when the alert came from a bridge
other than the current one, then opens the agent's transcript. An unrecognised
`server_id` leaves the selection alone rather than refusing to navigate.

---

## 8. Delivery hardening

| Behaviour | Where |
|---|---|
| 15s HTTP timeout on every FCM call | `internal/push` |
| 3 attempts with 250/500ms backoff on network errors, 429 and 5xx | `internal/push` |
| `UNREGISTERED` / `INVALID_ARGUMENT` → token cleared from the device registry | `internal/push`, `internal/store` |
| Fan-out runs concurrently across devices | `internal/server/notify.go` |

A cleared token leaves the paired device row intact — the phone re-registers a
fresh token on next launch.

---

## 9. Counting

**The tray is the count.** The app keeps no alert log and no badge: what is on
screen is exactly what is outstanding, because the clearer dismisses a
notification the moment its block is answered (see
[`CONTRACT-notif-clear.md`](CONTRACT-notif-clear.md)).

There was a bell badge over a persisted `agent_events` table; it was removed in
schema v4. An alert only ever said an agent was `blocked` or `done` — live state
the bridge answers directly, so a stored copy could only be a staler version of
an answer already available. The two surfaces that remain each own a question the
log answered worse:

| Question | Surface |
| --- | --- |
| What needs me right now? | **Priority**, from the live snapshot, across every server |
| What did the agent actually do? | The **transcript**, server-side and complete |

A count derived from stored rows could disagree with both — a resolved block
whose row was never marked kept inflating the badge while Priority correctly
showed nothing.
