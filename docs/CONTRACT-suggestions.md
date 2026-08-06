# CONTRACT — `GET /suggestions` (context actions for a pane)

What the chip row above the terminal is built on: the two or three things that
are worth doing to **this** pane, given what is actually running in it. The bar
this endpoint has to clear is the same one `/ports` set — a chip that appears is
a chip you can tap — with one addition that only matters here: the row has to be
**empty most of the time**. A suggestion surface that always has something to
say is a toolbar, and a toolbar is not worth the vertical space on a phone.

The generalisation of the dev-server work. `/ports` answers one question from one
signal (a server is up in this pane, here is a URL the phone can open). This
answers "what else is knowable about a pane cheaply, and does any of it justify a
button" — from `pane.process_info` plus a handful of `stat()`s on the pane's
working directory.

Verified on **2026-08-06** against the live Herdr host this repo is developed on,
across an agent pane mid-task, a plain shell parked in a worktree, a pane running
`docker compose logs -f`, and a shell sitting in `~`. The last two correctly
produce nothing.

---

## Request

```
GET /suggestions?pane=<pane_id>
Authorization: Bearer <bearer>
```

`pane` is required and accepts the session-qualified form (`acme/w1:p2`) like
every other pane-scoped endpoint. It comes back in the response and in every
suggestion's `params.pane`, so an action is addressed with exactly the id the
app already holds.

Read-only. It reads Herdr, stats a few files, and at most runs one
`git status`; it touches no agent process and writes nothing.

---

## Response `200` — schema

```jsonc
{
  "pane": "acme/w1:p2",
  "suggestions": [
    {
      "kind": "git_dirty",              // WHY it was offered
      "label": "Review changes",        // chip text, rendered verbatim
      "detail": "9 files changed",      // one-line justification
      "action": "open_diff",            // WHAT the app does on tap
      "params": {"pane": "acme/w1:p2"},
      "rank": 20                        // usefulness; already sorted, highest first
    }
  ]
}
```

`suggestions` is always present and always an array — never `null` — so a client
can render it without a null check. It is sorted by `rank` descending and capped
at **three** (`suggest.Max`).

### `kind` vs `action`, and why both

| Field | Answers | Used for |
|---|---|---|
| `kind` | why this pane earned a chip | the icon, and nothing else |
| `action` | what happens on tap | the app's `switch` |

They are separate because several kinds legitimately land on the same screen —
`git_conflict` and `git_dirty` both open the diff — and collapsing them would
throw away the only part a person reads at a glance. It also means the app can
branch on `action` alone: a bridge that grows a new *reason* for an action the
app already handles needs no app release.

`label` and `detail` are written by the bridge and rendered verbatim, because
the bridge is the only side that can count the files. The app never composes
copy from `kind`.

### Actions in this version

| `action` | App does | Requires |
|---|---|---|
| `open_diff` | pushes `/diff/<pane>` | the pane hosts an agent (see below) |
| `start_agent` | opens the start-agent sheet targeting the pane | the pane is free |

**An unknown `action` must be dropped, not rendered.** That rule is the whole
forward-compatibility story: a newer bridge can ship a fourth suggestion source
against an older app and the worst case is a chip that does not appear. The
Flutter client enforces it in `PaneSuggestion.isActionable`, before the list
reaches any widget.

---

## The sources, and what each is really keying off

Three today. Each is a ~15-line pure function of an already-collected
observation (`suggest.Pane`), so the interesting part is the predicate, not the
plumbing.

| `kind` | Fires when | `rank` | `action` |
|---|---|---|---|
| `git_conflict` | the pane's repo has an unfinished merge / rebase / cherry-pick / revert | 30 | `open_diff` |
| `git_dirty` | the pane's repo has uncommitted changes | 20 | `open_diff` |
| `shell_idle` | no agent, shell at its prompt, cwd inside a git work tree | 10 | `start_agent` |

**`git_conflict` outranks everything** because it is the one state where the
agent is stuck on something only a person resolves, and the phone is where you
find out about it. It also **suppresses `git_dirty`**: a conflicted tree is a
dirty tree too, and two chips onto the same screen is precisely the noise this
feature exists not to make.

**`git_conflict` reads marker files, not `git status`.** `MERGE_HEAD`,
`rebase-merge/`, `rebase-apply/`, `CHERRY_PICK_HEAD`, `REVERT_HEAD` — a `stat()`
each. These are the states where a person is needed, so the check has to stay
reliable on a huge repository where a status call would not be.

**`shell_idle`'s work-tree test is what keeps it off every idle shell on the
host.** A pane parked in `~` is not somewhere you want an agent; a pane parked in
a worktree is one someone opened to do work in and then walked away from. On the
development host that is the difference between two chips and eleven.

**Worktrees are handled explicitly.** A `git worktree` checkout has `.git` as a
*file* containing `gitdir: <repo>/.git/worktrees/<name>`, not a directory.
Parallel worktrees are the reason this feature exists, so reading that as "not a
repository" would silence every source in exactly the panes that matter most.

---

## Why the diff-shaped suggestions are agent-panes-only

`GET /diff` resolves its tree through the pane's **agent** (`paneCwd` →
`paneAgent`), so a plain pane taps through to a 404. Rather than ship a chip that
sometimes dead-ends, `git_conflict` and `git_dirty` require an agent in the pane.

The cost is real and worth naming: a conflict in a plain shell pane's worktree is
invisible to this endpoint even though the bridge can see it perfectly well. The
fix is on the `/diff` side, not here — teach it to fall back to the pane's
`process_info` cwd when there is no agent, at which point the `HasAgent` guard in
both sources can simply be deleted.

---

## Cost, and the two things that keep it down

Per **uncached** call: one `pane.process_info`, one `agent.get`, a few `stat()`s,
and — only when the tree is a repository with no operation in flight — one
`git status --porcelain`. Nothing scans the host, nothing walks a process table,
nothing runs on a timer.

| Cache | TTL | Why that size |
|---|---|---|
| Per-pane suggestions (`suggestTTL`) | 6s | Every input changes on a human timescale — an agent finishes a turn, a rebase stops, a shell is left at a prompt. A few seconds of staleness is invisible. |

Keyed **per pane**, not one shared slot: a phone showing one terminal asks about
one pane repeatedly, and two open panes must not evict each other on every
refresh. The lock is held across the observation, so concurrent callers for a
pane share the one in flight — the same bargain `ports.Cache` makes.

**The app never polls this.** It refetches on screen open and when the pane's
agent status changes in the snapshot the bridge already pushes over `WS /events`
— which is also *when the answers change*, since an agent that just finished a
turn is an agent that has just written the files the chip is about. The 6s cache
is what makes that safe even if a future surface is less careful.

`--untracked-files=normal`, deliberately, where `/diff` uses `all`: the count is
only ever rendered as "N files changed", and expanding a fresh `node_modules`
into its members would cost real time to print a number that says nothing.

---

## Failure modes

| Condition | Result |
|---|---|
| Pane has nothing worth suggesting | `200`, `{"suggestions": []}` — the steady state |
| No `?pane=` | `400` |
| Pane does not exist | `404` (from `pane.process_info`) |
| Pane has no agent | **Not an error** — narrows which sources fire |
| Herdr unreachable / misbehaving | `502` |
| cwd is not a git repository | `200`, `[]` |
| `git` missing or `git status` times out (3s) | That source stays quiet; the others still answer |
| Bridge too old to have the endpoint | `404` → the app renders no chip row at all |

The app collapses `404` and transport failures into an empty list. This is a
convenience surface: an error banner in front of it would cost more attention
than the feature gives back, and there is nothing the user could do about either
cause.

---

## Relationship to `GET /ports`, and how the two should converge

They are deliberately **not** merged, and `/ports` is untouched by this work.

A port scan is a **host** question — one `lsof`, one `ps`, and a probe per
listener — that the `?pane=` filter narrows *afterwards*. Folding it into a
per-pane read would make every suggestion refresh pay for a host scan, or make
the suggestion cache and the scan cache fight over one TTL. The two also answer
at different rates: a dev server appears within seconds of being started, a dirty
tree changes when an agent finishes a turn.

The convergence that makes sense, in order:

1. **On the app side first.** One chip row fed by two endpoints — `/ports`
   contributes an "Open :5173" chip, `/suggestions` the rest, merged by `rank`.
   `PaneSuggestion.rank` exists for exactly this and is otherwise redundant,
   since the bridge already sorts. This is cheap and changes no contract.
2. **Then, if it earns it,** a `dev_server` source in `internal/suggest` that
   reads the *already-cached* `ports.Cache` rather than triggering a scan, and
   emits an `open_url` action. At that point `/ports` becomes the raw feed and
   `/suggestions` the curated one, which is the right shape — but it is only
   worth doing once step 1 has shown how the merged row actually reads.

Doing step 2 first would couple a host scan to a per-pane read for no user-facing
gain.

---

## Deliberately not built

- **A "rerun the test runner" source.** `process_info` gives the foreground
  command, so recognising `vitest`/`jest`/`go test` is easy; making the *action*
  work is not. A watcher wants a keystroke (`a` in vitest watch mode), a finished
  run wants the command retyped, and the two are indistinguishable from the
  process list alone. `suggest.Pane.Foreground` is collected and unused, which is
  where that source will hang off when it is worth the flakiness budget.
- **A push/PR source.** "Branch is ahead of origin → open a PR" needs network and
  a real action surface, not a chip.
- **Event-driven cache invalidation.** The bridge runs an event bus, so a pane
  status change could invalidate the entry directly and retire the TTL. The TTL
  is doing the job at this scale; the same note is already open against the
  `/ports` pane map.

---

## Bridge version

`BridgeVersion` 7. As with `/commands` and `/ports`, the app gates its UI on the
endpoint answering rather than on the number — an older bridge 404s and no chip
row renders.
