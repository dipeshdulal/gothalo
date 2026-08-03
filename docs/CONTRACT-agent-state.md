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

Kind-agnostic: **the same shape for every agent kind.** No Claude-specific fields
leak into the contract.

| Field | Type | Notes |
|---|---|---|
| `pane_id` | string | Echoes the requested pane. |
| `agent_kind` | string | Herdr agent kind (`claude`, later `codex`, `opencode`, …). |
| `agent_status` | string | Authoritative status from Herdr: `idle` \| `working` \| `blocked` \| `done` \| `unknown`. |
| `headline` | string | One line: what it's doing / its last step. **The question when blocked.** Always safe to render alone. |
| `detail` | string | Short plain-text body (current activity or last assistant message). ANSI/box-drawing already stripped. May contain `\n`. |
| `blocked` | object \| absent | **Present only when `agent_status == "blocked"`.** See below. |
| `blocked.question` | string | The prompt the agent is waiting on. |
| `blocked.options` | array | Selectable choices in display order. May be empty for a free-form prompt. |
| `blocked.options[].index` | int | The number the user types to pick it (1-based); `0` if unnumbered (see `key`). |
| `blocked.options[].label` | string | Choice text. |
| `blocked.options[].selected` | bool | The highlighted default — the one a bare Enter (`/approve`) accepts. |
| `blocked.options[].key` | string \| absent | Set **instead of** `index` for an option with no menu number, reachable only via a raw keystroke — e.g. `"esc"` for the decline action on Claude's single-choice approval form (`❯ 1. Yes` with no numbered "No", just an "Esc to cancel" footer hint). Omitted for numbered options. Dispatch with `POST /send { "pane": pane_id, "key": "esc" }` (see docs/API.md), not `/approve` or a typed index. |
| `blocked.category` | string \| absent | Coarse semantic class of the block, from Herdr's own detection rule id (e.g. `tool_approval`, `question_panel`, `dangerous_command_approval`, `write_file_approval`, `generic_permission_prompt`). Filled via `agent.explain` — **no per-agent plugin** — and omitted when unavailable. Lets the app style/prioritise (e.g. flag a dangerous command). |
| `transcript` | array\<string\> \| absent | Optional, best-effort recent plain-text lines. |
| `parsed` | bool | `false` ⇒ no dedicated parser for this kind; `detail`/`transcript` are a raw recent-text fallback. |

### How the app uses `blocked` (pairs with `POST /approve` and `POST /send`)
- **One-tap "Yes"** (the `selected` default): `POST /approve { "agent": pane_id, "seq": state_change_seq }` — the bridge presses Enter only if the agent is still blocked at that `seq` (idempotent).
- **Pick a non-default numbered option**: `POST /send { "pane": pane_id, "text": "2\n" }` — type the option's `index` then newline.
- **Pick a `key`-only option** (no `index`): `POST /send { "pane": pane_id, "key": "esc" }` — dispatches the raw keystroke instead of typing.
- `state_change_seq` comes from `/snapshot` (or the push payload), not from this endpoint.

---

## Live examples — one per status

### `idle` (Claude, `w5:p18`)
```json
{
  "pane_id": "w5:p18",
  "agent_kind": "claude",
  "agent_status": "idle",
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
