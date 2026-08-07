# CONTRACT — `POST /herdr` (allowlisted Herdr command proxy)

The contract the **mobile app** builds its worktree / tab / pane controls
against. `POST /herdr` is one authenticated endpoint that forwards an
**allowlisted** Herdr socket method to the running Herdr multiplexer and returns
its result (or a normalized error). It gives the app parity with Herdr's command
surface without a bespoke bridge endpoint per operation; new Herdr methods become
available by adding them to the allowlist — no other bridge change.

Verified end-to-end against **herdr 0.7.5, protocol 17** on the live socket
(`tab.rename` and the `pane.rename` findings against **0.8.0, protocol 19**).
Every example below is a real captured request/response.

---

## Envelope

**Request** — `POST /herdr`, auth required (per-device `Authorization: Bearer
<bearer>` or `?token=`; the admin token also works for dev):

```json
{ "method": "<herdr socket method>", "params": { … } }
```

- `method` — a Herdr **socket method id** from `herdr api schema --json`
  (`schemas.request`). These are dotted (`tab.create`, `pane.split`), **not** the
  CLI subcommands. Required.
- `params` — forwarded to the socket **verbatim**. Use the exact shapes from the
  schema (documented per method below). Omit it or send `{}` for methods that
  take no params.

**Success** `200`:

```json
{ "result": <herdr result object, passed through verbatim> }
```

The `result` is exactly what Herdr's socket returns for that method (each carries
its own `"type"` discriminator, e.g. `worktree_created`, `pane_info`, `ok`). The
bridge does not reshape it.

**Error** — normalized, with an HTTP status:

```json
{ "error": "<message>" }
```

The bridge auth-reject bodies (`401`) are plain text (`unauthorized`), matching
the other endpoints; all other errors use the JSON `{ "error": … }` shape above.

---

## Allowlist (the full set)

Only these methods are proxied. **Anything else → `403`** (`{"error":"method not
allowed: <method>"}`) without ever touching the socket. Source of truth:
`internal/server/herdr_proxy.go` (`herdrProxyAllowlist`).

### Reads (safe)

| method | params | returns (`result.type`) |
|---|---|---|
| `session.snapshot` | `{}` | full session tree |
| `workspace.list` | `{}` | `workspace_list` |
| `workspace.get` | `{ "workspace_id": "wN" }` | `workspace_info` |
| `worktree.list` | `{ "cwd"?: string, "workspace_id"?: string }` | `worktree_list` |
| `tab.list` | `{ "workspace_id"?: string }` | `tab_list` |
| `tab.get` | `{ "tab_id": "wN:tM" }` | `tab_info` |
| `pane.list` | `{ "workspace_id"?: string }` | `pane_list` |
| `pane.get` | `{ "pane_id": "wN:pM" }` | `pane_info` |
| `agent.list` | `{}` | `agent_list` |
| `agent.get` | `{ "target": "<pane id / agent>" }` | `agent_info` |

### Mutations (deliberately allowed)

| method | params | returns (`result.type`) | notes |
|---|---|---|---|
| `worktree.create` | `{ "cwd"?, "branch"?, "base"?, "path"?, "label"?, "workspace_id"?, "focus"?=false }` | `worktree_created` | creates a git worktree **and** opens it as a workspace |
| `worktree.open` | `{ "cwd"?, "branch"?, "path"?, "label"?, "workspace_id"?, "focus"?=false }` | `worktree_*` | open an existing worktree as a workspace |
| `worktree.remove` | `{ "workspace_id": "wN", "force"?=false }` | `worktree_removed` | **DESTRUCTIVE** — gate behind an in-app confirm |
| `workspace.create` | `{ "cwd"?, "label"?, "env"?, "focus"?=false }` | `workspace_*` | new empty workspace |
| `tab.create` | `{ "workspace_id"?, "cwd"?, "label"?, "env"?, "focus"?=false }` | `tab_created` | new tab + its root pane |
| `tab.close` | `{ "tab_id": "wN:tM" }` | `ok` | **DESTRUCTIVE** — in-app confirm |
| `tab.focus` | `{ "tab_id": "wN:tM" }` | `ok` | |
| `tab.rename` | `{ "tab_id": "wN:tM", "label": string }` | `tab_info` | **the client must validate `label`** — see below |
| `pane.split` | `{ "direction": "down"\|"right"\|"up"\|"left", "target_pane_id"?, "cwd"?, "ratio"?, "env"?, "workspace_id"?, "focus"?=false }` | `pane_info` | the app's "new pane"; `direction` is **required** |
| `pane.close` | `{ "pane_id": "wN:pM" }` | `ok` | **DESTRUCTIVE** — in-app confirm; closing a tab's last pane closes the tab |
| `pane.focus` | `{ "pane_id": "wN:pM" }` | `ok` | |
| `agent.focus` | `{ "target": "<pane id / agent>" }` | `ok` | focus an agent's pane |

> **`tab.rename` validates nothing.** Herdr accepts any string, including `""`,
> which blanks the tab's label — verified on the live socket (`tab.rename` with
> `""` returned `tab_info` with `"label": ""`). Nothing in Herdr or the bridge
> stops a client leaving a nameless tab behind, so **the label rule belongs to
> the client**: the app trims, rejects empty, and caps at 60 characters
> (`normalizeTabLabel` in `app/lib/features/herdr_actions.dart`). An unknown
> `tab_id` is a proper `tab_not_found`, which the bridge maps to `404`.
>
> **`pane.rename` is deliberately not allowlisted (yet).** It exists on the
> socket and works (`{ "pane_id", "label"? }` → `pane_info`; a null `label`
> clears it), but unlike `tab.rename` it emits **no event at all** — measured
> against herdr 0.8.0 / protocol 19 by subscribing to all 23 global kinds the
> ingester uses and renaming a throwaway pane: nothing was delivered. A rename
> driven from the phone would therefore not reach any other client until some
> unrelated change happened to trigger a re-snapshot. The app also does not
> carry a pane `label` in its snapshot model. Revisit together with those two.

> **`agent.view.set` / `agent.view.clear` are deliberately not allowlisted.**
> Herdr accepts the projection and reports it active, but as of herdr 0.8.0
> (protocol 19) **no read applies it** — `agent.list` and `session.snapshot`
> both return the unprojected list, and there is no projected read method — so
> forwarding these only let a client mutate daemon state to no visible effect.
> Attention ordering is served by **`attention_rank`** on every agent in
> `GET /snapshot` instead (see [`API.md`](./API.md)), which the bridge computes
> so every surface orders identically. Revisit if Herdr ever applies the view to
> a read.

`focus` defaults to **`false`** everywhere, so app-created panes/tabs do not steal
the operator's foreground pane on the host. Pass `"focus": true` to override.

> Confirmed **not** allowlisted (→ `403`): `server.stop`, `server.reload_config`,
> `pane.send_text`, `pane.send_keys`, `agent.prompt`, `events.subscribe`,
> `agent.view.set`, `agent.view.clear`, `pane.rename`, and
> every other method not in the table above. The app's existing typed endpoints
> (`/send`, `/approve`, `/attach`, `/events`, …) remain the path for those.

---

## Real captured examples

All captured against the live socket via `POST /herdr` (worktree ops run against
a throwaway git repo).

### `worktree.create`

```json
→ { "method": "worktree.create",
    "params": { "cwd": "/…/repo", "branch": "cc-demo", "label": "cc demo" } }

← 200
{ "result": {
    "type": "worktree_created",
    "workspace": {
      "workspace_id": "wZ", "number": 17, "label": "cc demo",
      "focused": false, "pane_count": 1, "tab_count": 1,
      "active_tab_id": "wZ:t1", "agent_status": "unknown",
      "worktree": {
        "repo_key": "/…/repo/.git", "repo_name": "repo",
        "repo_root": "/…/repo",
        "checkout_path": "/Users/…/.herdr/worktrees/repo/cc-demo",
        "is_linked_worktree": true } },
    "tab": { "tab_id": "wZ:t1", "workspace_id": "wZ", "number": 1,
             "label": "1", "focused": false, "pane_count": 1,
             "agent_status": "unknown" },
    "root_pane": {
      "pane_id": "wZ:p1", "terminal_id": "term_658113d68271e39",
      "workspace_id": "wZ", "tab_id": "wZ:t1", "focused": false,
      "cwd": "/Users/…/.herdr/worktrees/repo/cc-demo",
      "agent_status": "unknown", "revision": 0 },
    "worktree": {
      "path": "/Users/…/.herdr/worktrees/repo/cc-demo",
      "branch": "cc-demo", "is_bare": false, "is_detached": false,
      "is_linked_worktree": true, "open_workspace_id": "wZ",
      "label": "repo" } } }
```

The new workspace is `result.workspace.workspace_id` (`wZ`); its root pane is
`result.root_pane.pane_id` (`wZ:p1`). Keep the `workspace_id` — it is what
`worktree.remove` takes.

### `tab.create`

```json
→ { "method": "tab.create",
    "params": { "workspace_id": "wZ", "label": "demo-tab" } }

← 200
{ "result": {
    "type": "tab_created",
    "tab": { "tab_id": "wZ:t2", "workspace_id": "wZ", "number": 2,
             "label": "demo-tab", "focused": false, "pane_count": 1,
             "agent_status": "unknown" },
    "root_pane": {
      "pane_id": "wZ:p2", "terminal_id": "term_658113dffa5d73a",
      "workspace_id": "wZ", "tab_id": "wZ:t2", "focused": false,
      "cwd": "/Users/…/.herdr/worktrees/repo/cc-demo",
      "agent_status": "unknown", "revision": 0 } } }
```

New tab is `result.tab.tab_id` (`wZ:t2`); its root pane `result.root_pane.pane_id`
(`wZ:p2`).

### `pane.split`

```json
→ { "method": "pane.split",
    "params": { "target_pane_id": "wZ:p1", "direction": "down" } }

← 200
{ "result": {
    "type": "pane_info",
    "pane": {
      "pane_id": "wZ:p3", "terminal_id": "term_658113e0188af3b",
      "workspace_id": "wZ", "tab_id": "wZ:t1", "focused": false,
      "cwd": "/Users/…/.herdr/worktrees/repo/cc-demo",
      "agent_status": "unknown", "revision": 0 } } }
```

The new pane is `result.pane.pane_id` (`wZ:p3`), added to the target pane's tab
(`wZ:t1`).

### `pane.close`

```json
→ { "method": "pane.close", "params": { "pane_id": "wZ:p3" } }

← 200
{ "result": { "type": "ok" } }
```

### `tab.rename`

Captured against herdr 0.8.0 (protocol 19) on a throwaway workspace.

```json
→ { "method": "tab.rename",
    "params": { "tab_id": "wZ:t2", "label": "api server" } }

← 200
{ "result": {
    "type": "tab_info",
    "tab": { "tab_id": "wZ:t2", "workspace_id": "wZ", "number": 2,
             "label": "api server", "focused": false, "pane_count": 1,
             "agent_status": "unknown" } } }
```

The result echoes the whole tab, so a client can read the applied label back
rather than assuming its own string landed. Renaming also emits a
[`tab_renamed`](../CONTRACT.md) event on `WS /events` —
`{"type":"tab_renamed","tab_id":"wZ:t2","workspace_id":"wZ","label":"api server"}`
— so every connected client re-snapshots without being told to.

An unknown tab is a `404`:

```json
→ { "method": "tab.rename", "params": { "tab_id": "w999:t9", "label": "x" } }

← 404
{ "error": "herdr: tab_not_found: tab w999:t9 not found" }
```

### `tab.close`

```json
→ { "method": "tab.close", "params": { "tab_id": "wZ:t2" } }

← 200
{ "result": { "type": "ok" } }
```

### `worktree.remove`

```json
→ { "method": "worktree.remove",
    "params": { "workspace_id": "wZ", "force": true } }

← 200
{ "result": {
    "type": "worktree_removed", "workspace_id": "wZ",
    "path": "/Users/…/.herdr/worktrees/repo/cc-demo", "forced": true } }
```

### Disallowed method → `403`

```json
→ { "method": "server.stop", "params": {} }

← 403
{ "error": "method not allowed: server.stop" }
```

### Herdr target-not-found → `404`

```json
→ { "method": "pane.get", "params": { "pane_id": "wZ:p99" } }

← 404
{ "error": "herdr: pane_not_found: pane wZ:p99 not found" }
```

---

## Error / status table

| status | when | body |
|---|---|---|
| `200` | success | `{ "result": <herdr result> }` |
| `400` | malformed JSON body, or missing/empty `method` | `{ "error": "want {method, params}" }` |
| `401` | no / invalid bearer or token | `unauthorized` (plain text) |
| `403` | `method` is not on the allowlist | `{ "error": "method not allowed: <method>" }` |
| `404` | Herdr rejected with a `*_not_found` code (unknown pane/tab/workspace) | `{ "error": "herdr: <code>: <message>" }` |
| `502` | socket unreachable, or any other Herdr error (e.g. `invalid_params`) | `{ "error": "herdr: <code>: <message>" }` or transport error text |
| `405` | non-POST method | `{ "error": "POST only" }` |

**404 vs 502:** a Herdr error whose `code` ends in `_not_found` maps to `404`
(the target you named does not exist — usually a client bug, safe to surface as
"gone"). Any other Herdr error, or a failure to reach the socket at all, is `502`
(the bridge could not complete the operation).

---

## Implementation notes (for maintainers)

- Handler: `internal/server/herdr_proxy.go` (`handleHerdrProxy`), registered at
  `mux.HandleFunc("/herdr", …)` in `internal/server/server.go`.
- Transport: `herdr.(*Client).Request(method, params)` in
  `internal/herdr/socket.go` opens a **dedicated short-lived** connection per
  call (`SocketConn.Do`), sends `{id, method, params}` with a unique
  `gothalo-req-<n>` id, and returns the `result` for the matching id. It is
  **separate** from the event ingester's long-lived subscription connection, so
  the proxy never disturbs the event stream. Concurrency-safe: each call gets its
  own connection and a monotonically-minted id, so the app can fire several at
  once.
- Timeout: a 15s read/write deadline bounds each round-trip; a wedged socket
  surfaces as `502` rather than hanging the handler.
- To extend: add the method (and a one-line comment) to `herdrProxyAllowlist`.
  Nothing else changes — params pass through verbatim.
