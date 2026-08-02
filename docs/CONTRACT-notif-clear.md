# CONTRACT — notification dismiss (auto-clear stale `blocked` pushes)

The mobile-side contract for auto-clearing a stale "blocked" push. When an agent
**blocks**, the bridge fans a `blocked` push out to every device (the "agent
needs you" notification) and mirrors it as `gothalo.push_sent`. When that block
is later **resolved from anywhere** — this phone, another paired device, the
desktop Herdr app, or the agent simply moving on — the tray notification on
**every** phone clears itself.

The backend half is a single process-wide bus consumer (the
notification-clearer, `internal/notify`). It watches the same unified event bus
that feeds [`WS /events`](../CONTRACT.md), so "from anywhere" works for free: the
Herdr transition reaches the bus regardless of who caused it. There is no new
endpoint — the app only needs to handle the `dismiss` FCM message below (and may
optionally react to the `gothalo.notification_cleared` delta on `WS /events`).

> Base event-stream framing (the envelope, `seq` gap detection, reconnect
> semantics) lives in [`../CONTRACT.md`](../CONTRACT.md). This document covers
> only the dismiss contract.

---

## 1. The `dismiss` FCM message (what the app receives)

A **data-only** FCM message (no `notification` block, so the app's background
handler runs and cancels silently). Exactly two data keys:

```json
{ "type": "dismiss", "agent": "<pane_id>" }
```

| Key | Value |
|---|---|
| `type` | always `"dismiss"` — the **discriminator**. A normal push has **no** `type` key; match on it to tell the two apart. |
| `agent` | the **pane_id** — the same key the `blocked` push carries. The app cancels the notification keyed to that pane. |

There is **no** `title` / `body` / `status` / `state_change_seq` on a dismiss — it
is purely data-only. If `type` is absent, treat the message as a normal push (see
the "Push messages" section of [`API.md`](API.md)).

## 2. Target devices

The **same set as the blocked push**: **all** registered devices (every non-empty
FCM token in the device store, `store.FCMTokens()`), via the **same** FCM client.
There is no second FCM path and no per-device targeting — a block handled on one
device dismisses the notification on all of them.

## 3. The `gothalo.notification_cleared` bus event

Alongside each dismiss, the bridge publishes a `gothalo.notification_cleared`
delta on [`WS /events`](../CONTRACT.md):

```json
{ "source":"gothalo", "type":"notification_cleared", "seq":<uint>, "ts":<ms>,
  "payload": { "pane": "<pane_id>" } }
```

It is a **consistency/bonus** signal: a **foreground** app can clear its own UI
from this event without relying on the FCM `dismiss`. The app's **primary** path
is the FCM `dismiss` (§1); this event is the in-band mirror. It is published
whenever an armed pane resolves — even if FCM is disabled or no devices are
registered (in which case only this event fires).

## 4. Trigger conditions (when a dismiss is sent)

A pane is **armed** the moment a `blocked` push goes out for it
(`gothalo.push_sent` with `status == "blocked"`). An armed pane is **dismissed
exactly once** on the **first** of these bus events:

| Bus event | Condition |
|---|---|
| `herdr.pane_agent_status_changed` | `agent_status != "blocked"` (i.e. `idle` / `working` / `done` / `unknown`) — the agent left blocked |
| `pane_closed` | the pane was closed (either `herdr.pane_closed` or `gothalo.pane_closed`) |
| `pane_exited` | the pane's process exited (`herdr.pane_exited`) |

Guarantees:

- **No double-dismiss.** The pane is removed from the tracker the instant it's
  dismissed, so a burst of resolving events (e.g. a status change *and* a close)
  dismisses only once. A resolution for a pane that was never armed is ignored.
- **Re-arm on a new block.** A pane that flips `blocked → working → blocked` is
  armed again by the new `blocked` push, so the next resolution dismisses again.
- **Only `blocked` arms.** A `done` push (`gothalo.push_sent status:"done"`) does
  **not** arm — done notifications are not auto-cleared.
- **In-memory, resets on restart.** The tracker is a small in-memory set; it's
  cleared on bridge restart. A gap there is acceptable — the app re-snapshots on
  reconnect. If FCM is disabled (no creds) the consumer no-ops cleanly (logs
  only), mirroring how the blocked-push path already degrades.

---

*Backend: `internal/notify` (the clearer) + `gothalo.notification_cleared` on the
unified bus. App side: handle `data["type"] == "dismiss"` in the background FCM
handler.*
