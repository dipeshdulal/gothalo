# CONTRACT — `GET /ports` (dev-server discovery)

What the preview chip is built on: the HTTP servers actually running on the host
right now, each labelled with the pane that spawned it. The bar this endpoint has
to clear is that a chip which appears is a chip you can tap — a preview link to a
port that turns out to be Postgres, or to another agent's worktree, costs more
than showing nothing.

Two things the phone cannot work out for itself, and this endpoint exists for
both:

1. **Which ports are serving.** `lsof` finds every TCP listener on the box, and
   most of them are databases, caches, the bridge itself, and OS daemons.
2. **Whose they are.** With agents working in parallel worktrees there are
   routinely three dev servers up at once on 5173/5174/5175, and the port number
   alone says nothing about which agent owns which.

The second is the one no competing client does, and it is only cheap here because
Herdr already hands the bridge each pane's shell pid.

---

## Request

```
GET /ports[?pane=<pane_id>]
Authorization: Bearer <bearer>
```

`pane` is optional and narrows the result to one pane, accepting the
session-qualified form (`acme/w1:p2`) like every other pane-scoped endpoint. It
is a filter over the same shared scan, not a second code path — the list page
fetches unfiltered, the terminal view fetches for its own pane, and both hit one
cached scan.

Read-only. It runs `lsof` and `ps`, then opens a short-lived TCP connection to
each listener; it touches no agent process and writes nothing.

---

## Response `200` — schema

```jsonc
{
  "ports": [
    {
      "port": 5173,
      "bind": "*",                      // verbatim from lsof; "*" = all interfaces
      "pid": 4821,
      "proc": "node",                   // executable name, for the chip label
      "loopback": false,                // true => nothing on the tailnet can reach it
      "pane": "acme/wN:p2",            // absent when unattributed
      "agent": "claude",                // absent when unattributed
      "url": "http://100.84.12.3:5173"  // absent when loopback
    }
  ]
}
```

`ports` is always present and always an array — never `null` — so a client can
render it without a null check. Entries are sorted by port so the list is stable
between polls.

---

## The two states the app renders

`url` is the whole client-side decision, and it is deliberately either a working
URL or absent — never a URL that cannot connect.

| Condition | `url` | App |
|---|---|---|
| `loopback: false` | present | live chip → `url_launcher` → system browser |
| `loopback: true` | absent | dimmed badge, "bound to localhost" |

The dimmed state is not a degraded failure — it is the answer to the question the
user is actually asking. "Vite is up on :5174, it's just bound to 127.0.0.1" is
what you need to know when the preview chip you expected isn't tappable, and it
tells you the fix (`--host`) without dropping to the terminal.

**Why there is no relay yet.** A loopback-bound server could be reached by having
the bridge open a tailnet-side listener and splice bytes to 127.0.0.1 — `ssh -L`
semantics, without the SSH. That is a deliberate later step, not an oversight: it
opens ports that sit outside the bearer-token check (the tailnet is the auth
boundary, as it already is for `WS /attach`), so it should be an explicit
per-port "Expose" tap rather than something the bridge does on its own for every
loopback listener it finds. Discovery is useful without it, and shipping
discovery first is what tells us how often the dimmed state actually comes up.

---

## Why a listener has to answer HTTP

Every listener is probed with a bare `GET / HTTP/1.0` and kept only if the reply
starts with an HTTP status line. Any status counts — a dev server answering `404`
on `/` is still a dev server.

This is what keeps the chip list short enough to be worth glancing at. Without
it, a typical host offers Postgres, Redis, the bridge, and a handful of macOS
daemons alongside the one server you wanted. Probes run concurrently with a
400ms deadline, so a dozen listeners resolve in about one timeout rather than a
dozen.

---

## Attribution

A listener's pid is walked up the `ps` parent chain until it reaches a pid Herdr
named as a pane's shell (`pane.process_info` → `shell_pid`). The walk matters:
a dev server is typically a *grandchild* of the pane shell (`shell → npm → node`),
so checking the direct parent alone finds nothing. It is bounded at 64 hops — a
corrupt process table could otherwise describe a cycle, and this runs on a poll.

**Every pane, not just agent panes.** The pane list comes off the snapshot tree
(`herdr.PaneIDs`) rather than `agent.list`, and that choice is load-bearing: a
dev server normally runs in a pane split off *beside* the agent, precisely so it
isn't competing with the agent for the terminal. An agent-only map would miss
the common case and attribute almost nothing. Plain panes come back with `agent`
absent and are labelled by process name instead.

Unattributed listeners are still returned. A dev server running outside Herdr
entirely is a real server; gothalo just can't label it, and dropping it would
make the list lie about what's up.

---

## Caching, and why this is not part of `/snapshot`

Two caches, with different lifetimes, because the two halves go stale at
different rates.

| Cache | TTL | Rebuilt when |
|---|---|---|
| Port scan (`ports.TTL`) | 5s | A server starts or stops |
| Pane → shell-pid map (`paneMapTTL`) | 30s | A pane is created or closed |

The list page polls this alongside `/snapshot`, and a dev server's port does not
change between two polls seconds apart — the 5s cache turns a per-poll `lsof`
plus a fan of probes into an occasional one, while staying short enough that
starting a dev server shows up while you're still looking at the screen.

The pane map is the expensive half: a snapshot plus one `pane.process_info`
round-trip **per pane**, over a socket that takes one request per connection. It
gets the longer TTL because a pane's shell pid is fixed for the pane's entire
life — it can only go stale when a pane is created or closed, which is rare next
to the poll rate. It is also resolved lazily behind the scan cache, so a `/ports`
call that hits the 5s cache never touches Herdr at all.

A later refinement, not built: the bridge already runs an event bus, so pane
create/close events could invalidate the map directly and retire the 30s TTL.

Folding this into `/snapshot` was considered and rejected. Snapshot is the
hottest read in the bridge and stays a passthrough; a scan that shells out twice
and opens a connection per listener belongs on its own cadence, and the two have
no reason to share one.

---

## Failure modes

| Condition | Result |
|---|---|
| No listeners on the host | `200`, `{"ports": []}` |
| Nothing answers HTTP | `200`, `{"ports": []}` |
| `lsof` missing or fails outright | `502` |
| `lsof` exits non-zero with output | Treated as success — unreadable descriptors are routine on a multi-user box |
| A pane's `process_info` read fails | That pane contributes no attribution; the scan is unaffected |
| A session's pane list fails | That session contributes no attribution; other sessions are unaffected |

No elevation is required: the agents' dev servers run as the same user as the
bridge.

---

## Bridge version

`BridgeVersion` 6. As with `/commands`, the app gates its UI on this endpoint
answering rather than on the number — an older bridge 404s and no chip renders.
