# CONTRACT — `POST /herdr` (allowlisted Herdr command proxy)

The contract the **mobile app** builds its worktree / tab / pane controls
against. `POST /herdr` is one authenticated endpoint that forwards an
**allowlisted** Herdr socket method to the running Herdr multiplexer and returns
its result (or a normalized error). It gives the app parity with Herdr's command
surface without a bespoke bridge endpoint per operation; new Herdr methods become
available by adding them to the allowlist — no other bridge change.

Verified end-to-end against **herdr 0.7.5, protocol 17** on the live socket. Every
example below is a real captured request/response.

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
| `pane.split` | `{ "direction": "down"\|"right"\|"up"\|"left", "target_pane_id"?, "cwd"?, "ratio"?, "env"?, "workspace_id"?, "focus"?=false }` | `pane_info` | the app's "new pane"; `direction` is **required** |
| `pane.close` | `{ "pane_id": "wN:pM" }` | `ok` | **DESTRUCTIVE** — in-app confirm; closing a tab's last pane closes the tab |
| `pane.focus` | `{ "pane_id": "wN:pM" }` | `ok` | |
| `agent.focus` | `{ "target": "<pane id / agent>" }` | `ok` | focus an agent's pane |

`focus` defaults to **`false`** everywhere, so app-created panes/tabs do not steal
the operator's foreground pane on the host. Pass `"focus": true` to override.

> Confirmed **not** allowlisted (→ `403`): `server.stop`, `server.reload_config`,
> `pane.send_text`, `pane.send_keys`, `agent.prompt`, `events.subscribe`, and
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
