# CONTRACT — agent permission mode (read + change)

The mobile-side contract for **seeing and changing a Claude agent's permission
mode** — the Shift+Tab mode an operator cycles at the keyboard
(`default → acceptEdits → plan → auto → …`). Two touchpoints:

- **Read** — `GET /agent-state` now carries an optional `permission_mode` string.
- **Change** — `POST /agent-mode/cycle {pane}` advances it by one Shift+Tab.

This is **Claude-specific by design**: only Claude's TUI has the concept. Every
other kind (`codex`, `opencode`, …) **omits** `permission_mode` from
`/agent-state` and gets a **`409`** from `/agent-mode/cycle` — the contract stays
kind-agnostic (a generic field name, absent when unsupported), never leaking a
Claude-only *shape*.

All examples below were captured from **live Claude Code panes** through the
running bridge (see [Verification](#verification)).

---

## The modes

Claude cycles a small ring of permission modes with **Shift+Tab**; its TUI shows
the active one in a footer bar. The mode values gothalo reports (canonical tokens,
mirroring Claude's own `permissionMode` vocabulary):

| `permission_mode` | Claude TUI footer         | Meaning                                             |
|-------------------|---------------------------|-----------------------------------------------------|
| `default`         | `⏸ manual mode on`        | Asks permission before edits / commands (safest).   |
| `acceptEdits`     | `⏵⏵ accept edits on`      | Auto-accepts file edits; still prompts for the rest.|
| `plan`            | `⏸ plan mode on`          | Plans only; makes no changes.                        |
| `auto`            | `⏵⏵ auto mode on`         | Full-auto (this build's fourth mode).                |
| `bypassPermissions` | `⏵⏵ bypass permissions on` | Skips all permission prompts (when the build offers it). |

The **exact set and order are whatever the running Claude build cycles through** —
treat the ring as opaque and don't hard-code it. A build that names a mode
differently passes its **raw lowercased label** through unchanged, so an unknown
value is still meaningful, never an error. The app should render `permission_mode`
as a label/badge and offer a single "cycle" action, not a fixed 4-way switch.

---

## Read — `GET /agent-state` → `permission_mode`

`permission_mode` is an **optional** field on the existing `/agent-state` card
(full card contract: [`CONTRACT-agent-state.md`](./CONTRACT-agent-state.md)).

```
GET /agent-state?pane=<pane_id>
Authorization: Bearer <bearer>          // ?token=<bearer> also works
```
```jsonc
{
  "pane_id": "wN:p1",
  "agent_kind": "claude",
  "agent_status": "idle",
  "permission_mode": "auto",            // Claude only; OMITTED for other kinds / when unknown
  "headline": "…",
  "detail": "…",
  "parsed": true
}
```

Rules the app codes against:
- **Present** only when `agent_kind == "claude"` **and** the mode could be read.
- **Absent** for every other kind and when unknown — **absence is normal**, never
  an error. Hide the mode control when the field is missing.
- **Live**: it reflects the mode *right now*, so after a cycle you re-fetch and see
  the new value immediately (see the source note below — this is why it's read from
  the live screen, not the transcript).

---

## Change — `POST /agent-mode/cycle`

The mobile remote for Shift+Tab: advance a Claude pane's mode by one step.

```
POST /agent-mode/cycle
Authorization: Bearer <bearer>          // ?token=<bearer> also works
{ "pane": "wN:p1" }
```

Response `200`:
```json
{ "ok": true, "cycled": true, "permission_mode": "plan" }   // new mode, best-effort read-back
{ "ok": true, "cycled": true }                              // sent; read-back didn't settle in time
```

- `cycled: true` means the Shift+Tab keystroke was sent to the pane.
- `permission_mode` is a **convenience** echo: after sending the keystroke the
  bridge polls the live footer for ≈1 s and includes the new value **only if** it
  observed the change. It may be **absent even on success** (the TUI hadn't
  redrawn yet). Do not treat its absence as failure.

### The flow the app implements

> **cycle → re-fetch `GET /agent-state` → show `permission_mode`.**

`/agent-state` is the **authoritative** read. The echo on the cycle response is
only to save a round-trip when it settles in time.

**Setting a *specific* target mode** is not a primitive. Because the mode only
cycles one-way, reach a target by **cycling and reading back until it matches**
(the ring is short, ≤ a handful of steps). Example (pseudo):
```
loop up to N times:
  mode = GET /agent-state.permission_mode
  if mode == target: done
  POST /agent-mode/cycle
```

### Errors

| Status | When |
|---|---|
| `400` | missing `pane` (or bad JSON body) |
| `401` | missing / invalid bearer |
| `404` | no agent in that pane |
| `405` | non-`POST` method |
| **`409`** | **mode switching not supported for this agent kind** — a non-Claude pane. Body: `mode switching not supported for this agent kind: <kind>`. Expected & documented: hide the control for that kind. |
| `502` | herdr command failed |

Same auth as every endpoint. Emits a `gothalo.mode_cycled` event on `WS /events`
(payload `{pane, permission_mode}`; `permission_mode` may be `""` when the
read-back didn't settle).

---

## How it works (and why not the transcript)

Two findings, **verified against a live Claude pane**, shaped the design:

1. **Reading — the live footer bar, not the transcript.** Claude Code's transcript
   JSONL *does* record a `permissionMode` (on `type:"permission-mode"` entries and
   per-message). **But it goes stale for an idle pane**: cycling the mode with
   Shift+Tab while idle appends **no** new transcript line, so the file keeps
   showing the old mode. Since the app's flow is *cycle → re-fetch* on a pane
   that's still idle, a transcript read would show **no change** — wrong. gothalo
   therefore reads the mode from the **live `detection` frame** (the TUI footer
   bar, e.g. `⏵⏵ auto mode on (shift+tab to cycle)`), which the `/agent-state`
   parser already receives — zero extra I/O and always current. Parsing lives in
   `internal/agentstate/mode.go`; the last footer bar on screen wins.

2. **Changing — `send-text ESC[Z`, not `send-keys shift+tab`.** Shift+Tab is the
   terminal control sequence **CSI Z** (`\x1b[Z`, "backtab"). gothalo sends it over
   the **existing send-text path** (`herdr pane send-text <pane> $'\x1b[Z'`, wrapped
   as `herdr.Client.CyclePermissionMode`). Note: `herdr pane send-keys <pane>
   shift+tab` is *accepted* by herdr but does **not** emit CSI Z, so the TUI never
   cycles — verified. That's why the raw sequence over send-text is used.

The kind guard is a single predicate (`agentstate.ModeSupported`, claude-only), so
adding a future kind that has the concept is one line, and everything else keeps
degrading gracefully.

---

## Verification

Verified end-to-end through the real HTTP handlers against a live Claude pane
(read the mode, cycle it, confirm the change, walk the whole ring):

```
GET  /agent-state?pane=wT:p1        -> permission_mode: "auto"
POST /agent-mode/cycle {pane:wT:p1} -> { ok, cycled, permission_mode: "default" }
GET  /agent-state?pane=wT:p1        -> permission_mode: "default"     (confirmed changed)
… cycling continues: default → acceptEdits → plan → auto             (full ring)
```
Error paths confirmed: `401` (no token), `400` (missing pane), `405` (GET),
`404` (unknown pane). The `409` kind guard is covered by unit tests
(`agentstate.ModeSupported` + the handler test) since every live pane is Claude.

Go tests: `internal/agentstate/mode_test.go` (mode parse from captured footer
bars, kind gating, `Build` integration) and `internal/server/agentmode_test.go`
(handler auth + request-shape guards).
