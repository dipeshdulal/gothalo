# CONTRACT — `GET /suggestions` (context actions for a pane)

What the chip row above the terminal and the transcript is built on: the two or
three things that are worth doing to **this** pane, given what is actually
running in it — a dev server you can open, a rebase that stopped on a conflict,
changes worth reading, work worth opening a pull request for, an empty shell
worth putting an agent in.

**This is the one mechanism for "what can I do with this pane."** Three features
arrived at that question separately and are sources here now, ranked in one row:

| Was | Is now |
|---|---|
| `GET /ports` + a preview chip (`CONTRACT-preview.md`) | the `dev_server` / `dev_server_local` sources |
| `GET /diff?context=1` + a "Create PR" button in the composer | the `create_pr` source |
| — | the `git_conflict` / `git_dirty` / `shell_idle` sources |

The raw feeds survive underneath and each still owns its own reading: `/ports`
knows about `lsof`, HTTP probes and process trees (appendix below); `/diff`
knows how to run git against a pane's cwd (`CONTRACT-diff.md`). **There is
exactly one git read per pane** and one shared host scan; the sources shell out
for nothing.

Two bars this surface has to clear:

1. **A chip that appears is a chip you can tap.** A preview link to a port that
   turns out to be Postgres, or a "Review changes" that dead-ends in a 404, costs
   more than showing nothing.
2. **The row is empty most of the time.** A suggestion surface that always has
   something to say is a toolbar, and a toolbar is not worth the vertical space
   on a phone.

A third bar applies only to the actions the **agent** performs (see below): they
are never fired by the tap alone. The text is always shown and editable first.

Verified on **2026-08-06/07** against the live Herdr host this repo is developed
on: an agent pane mid-task, a plain shell parked in a worktree, a pane running
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

Read-only. It reads Herdr, stats a few files, runs at most one `git status`, and
reads the cached port scan; it touches no agent process and writes nothing.

---

## Response `200` — schema

```jsonc
{
  "pane": "acme/w1:p2",
  "suggestions": [
    {
      "kind": "dev_server",              // WHY it was offered
      "performer": "app",                // WHO carries it out
      "label": "Open :5173",             // chip text, rendered verbatim
      "detail": "node · serving",        // one-line justification
      "action": "open_url",              // WHAT happens on tap
      "params": {"pane": "acme/w1:p2", "url": "http://100.84.12.3:5173", "port": "5173"},
      "rank": 25                         // usefulness; already sorted, highest first
    },
    {
      "kind": "create_pr",
      "performer": "agent",              // the APP does not do this one
      "label": "Create PR",
      "detail": "feat/thing → main · 2 commits ahead",
      "action": "prompt_agent",
      "params": {"pane": "acme/w1:p2", "prompt": "Open a pull request for the work on feat/thing: …"},
      "rank": 18
    }
  ]
}
```

`suggestions` is always present and always an array — never `null` — so a client
can render it without a null check. It is sorted by `rank` descending and capped
at **three** (`suggest.Max`).

### `performer` — who actually does it

**The one field here that is not cosmetic.** Most suggestions are things the app
does: open a screen, open a URL. But the most valuable thing you can do to a
pane from a phone is often something only the *agent* can do — it holds the
shell, the credentials and the context. So the mechanism carries both, and says
which is which, rather than pretending a prompt is a navigation.

| `performer` | Means | Client obligations |
|---|---|---|
| `app` | the app performs the action itself | none beyond doing it |
| `agent` | the app asks the agent in the pane, by sending `params.prompt` | **show the prompt, let it be edited, send only on confirmation** |

An `agent` suggestion is not a command. The agent may do it differently, do part
of it, or refuse — and every step lands in the transcript where it can be
watched and interrupted. That is a feature, not a limitation: it is why the
bridge never runs `git push` or `gh pr create` itself (see D29).

A client that treated an `agent` suggestion as an `app` one would fire an
irreversible, outward-facing action off a single tap. Absent or unrecognised
values must therefore read as `app`, never as `agent` — fail closed.

### `kind` vs `action`, and why both

| Field | Answers | Used for |
|---|---|---|
| `kind` | why this pane earned a chip | the icon and its colour, and nothing else |
| `action` | what happens on tap | the app's `switch` |

They are separate because several kinds legitimately land on the same screen —
`git_conflict` and `git_dirty` both open the diff — and collapsing them would
throw away the only part a person reads at a glance. It also means the app can
branch on `action` alone: a bridge that grows a new *reason* for an action the
app already handles needs no app release.

`label` and `detail` are written by the bridge and rendered verbatim, because
the bridge is the only side that can count the files or name the port. The app
never composes copy from `kind`.

### Actions in this version

| `action` | `performer` | Client does | `params` beyond `pane` |
|---|---|---|---|
| `open_url` | app | hands the URL to the system browser | `url` (required), `port` |
| `open_diff` | app | pushes `/diff/<pane>` | — |
| `show_note` | app | shows `note` in a dialog and nothing else | `note` (required) |
| `start_agent` | app | opens the start-agent sheet targeting the pane | — |
| `prompt_agent` | **agent** | shows `prompt` **editable**, sends it to the pane on confirm | `prompt` (required) |

**An unknown `action` must be dropped, not rendered** — and so must a known one
whose required param is missing. That rule is the whole forward-compatibility
story: a newer bridge can ship a fifth suggestion source against an older app
and the worst case is a chip that does not appear. The Flutter client enforces
both in `PaneSuggestion.isActionable`, before the list reaches any widget.

`prompt_agent` is the only action whose text is a suggestion in the ordinary
English sense. It is composed on the bridge — one wording, reviewable in one
place, identical on every client — but it is a *starting* text, not a message.
The client must not send it unedited-by-default without showing it.

`show_note` deserves its own justification, since an action that only explains
looks like a placeholder. It exists for exactly one state — a dev server bound
to loopback — where something real is true, the phone cannot act on it, and the
*fix* is a sentence. Without it that server would either be hidden (leaving the
user to wonder why there is no preview chip) or shown as a chip that does
nothing when tapped, which breaks bar 1. See "the two states" below.

---

## The sources

Six today. Each is a short pure function of an already-collected observation
(`suggest.Pane`) — no I/O, no git, no `lsof` — so the interesting part is the
predicate, not the plumbing.

| `kind` | Fires when | `rank` | `action` | by |
|---|---|---|---|---|
| `git_conflict` | an unfinished merge / rebase / cherry-pick / revert in the pane's repo | 30 | `open_diff` | app |
| `dev_server` | a reachable HTTP listener attributed to this pane | 25 | `open_url` | app |
| `git_dirty` | uncommitted changes in the pane's repo | 20 | `open_diff` | app |
| `create_pr` | a feature branch with a remote and work on it | 18 | `prompt_agent` | **agent** |
| `dev_server_local` | a listener attributed to this pane, bound to loopback | 15 | `show_note` | app |
| `shell_idle` | no agent, shell at its prompt, cwd inside a git work tree | 10 | `start_agent` | app |

The ranks live in one block in `suggest` on purpose. Now that dev servers and
the git-shaped suggestions share a row, "which of these matters more" is a
single argument rather than one per feature, and it is only reviewable if the
numbers sit next to each other. The order reads: something is **stuck** and
needs a person; something is **serving** that you probably came here to look at;
something **changed** that you probably came here to read; something is
**finished enough to ship**; something is up but **unreachable**, worth knowing
and not urgent; and finally an **empty** pane you could put an agent in.

`create_pr` sits just under `git_dirty` on purpose. When both fire they are the
two halves of one moment — the agent has finished and you are deciding what to
do about it — and reading the diff before opening the pull request is the order
a person actually wants, not the reverse.

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

**Worktrees are handled by asking git.** A `git worktree` checkout has `.git` as
a *file* pointing at `<repo>/.git/worktrees/<name>`, and the operation markers
live in that per-worktree directory rather than in the main clone. The git dir
comes from `git rev-parse --absolute-git-dir` rather than from walking up
looking for a `.git` directory, which delegates the one case that is easy to get
wrong. Parallel worktrees are the reason this feature exists.

**`create_pr` is gated in the order the conditions actually disqualify:** an
agent in the pane (there is nobody to ask otherwise); a git repository, read from
the host and never inferred from the cwd path (a directory called `feat/x` is not
evidence of a branch); a branch, not a detached HEAD; a remote, since there is
otherwise nowhere to push; not the default branch, where a PR means nothing; and
actual work — commits ahead of the trunk, **or** uncommitted changes to make into
one, since committing them is step one of what the agent is asked to do. A tree
mid-rebase is excluded too: "open a PR" during a stopped rebase is the wrong next
step by a wide margin, and `git_conflict` is already saying the right one.

**The dev-server source contributes at most two chips.** A pane running a
frontend and an API is two chips and both are worth a tap; a pane running five is
a microservice stack, and turning the row into a port list would push out the
"resolve this conflict" chip that is the reason the row is worth reading. The
full list is what `GET /ports` is for.

---

## Dev servers: the two states the app renders

Inherited verbatim from the preview design, because it was right: `url` is the
whole client-side decision, and it is deliberately either a working URL or
absent — never a URL that cannot connect.

| Condition | `kind` | `action` | App |
|---|---|---|---|
| reachable | `dev_server` | `open_url` | live chip → `url_launcher` → system browser |
| loopback bind | `dev_server_local` | `show_note` | dimmed chip; tap explains and names `--host` |

The dimmed state is not a degraded failure — it is the answer to the question the
user is actually asking. "Vite is up on :5174, it's just bound to 127.0.0.1" is
what you need to know when the preview chip you expected isn't tappable, and the
note tells you the fix without dropping to the terminal.

### How the `url` is built — and the bug that made this section necessary

**The host is the address the CALLER reached the bridge on, never the address
the bridge binds.** Those are different machines' points of view, and confusing
them shipped a broken chip: behind `tailscale serve` the bridge binds
`127.0.0.1:8787` while the phone talks to `<host>.<tailnet>.ts.net:5338`, so
deriving the URL from the bind address handed every phone
`http://127.0.0.1:8123` — the phone's *own* loopback. Verified on a real device:
the chip rendered "Open :8123 · Python · serving", the browser opened, and the
connection was refused. The bind address answers "where does this process
listen"; it never answers "what should someone else dial".

The host is resolved per request, first non-loopback candidate wins
(`server.reachableHost`):

1. **The request's own `Host`.** Authoritative because it is a fact about a
   connection that just succeeded rather than configuration that might be stale —
   whatever the caller dialled to get here, they can dial again. It is also
   per-caller correct: a phone on the tailnet and a laptop on the LAN each get an
   answer that works for them, which no single configured value can do.
2. **`transport.public_url`**, when `Host` is unusable — a reverse proxy that
   rewrites `Host` to its own upstream. The operator's declared public URL is
   exactly right there, and it is already the address the pairing QR hands out.
3. **The bind address**, when it is a literal non-loopback address — the
   `GOTHALO_ADDR=$(tailscale ip -4):8787` setup, where the bridge really is
   reachable where it binds.

Every candidate goes through the same loopback test the URL builder uses, so a
stage that can only offer `localhost` falls through instead of producing a link
that cannot connect. All three falling through means no `url`, and the chip
degrades to the honest `dev_server_local` state.

**The port is the server's, not the bridge's.** `:5338` is the bridge; the dev
server is on `:8123`.

**The scheme is always `http`, and that is not a guess.** A listener only becomes
a chip after answering a bare `GET / HTTP/1.0` over a plain TCP dial — a server
that actually spoke TLS on its port would have failed that probe and never been
listed. The bridge's own `https` is a property of the bridge's port, where
`tailscale serve` terminates TLS; nothing terminates TLS on a dev server's port.

**A server bound to one specific interface keeps its own address.** `100.84.12.3`
or `192.168.1.50` is what the server actually serves on, so that is the host in
its URL rather than the bridge's hostname substituted in. This needs no third UI
state: it is still `dev_server` with a working-shaped URL. Whether the caller can
route to that particular interface is a network question the bridge should not
pretend to answer, and a URL that names the truth beats one that looks right and
times out. Only the wildcard bind (`*`, i.e. `0.0.0.0`/`::`) borrows the caller's
host — legitimately, since a server on every interface is by definition answering
on the one the caller just used.

Two invariants are tested rather than merely intended, because this is a class of
bug that renders perfectly and fails only on a real device:
`ports.FillURLs` never emits a URL whose host is loopback for **any** combination
of bind and caller host, and `server.reachableHost` never returns one.

**The system browser, not a WebView.** Over a tailnet the phone reaches the
server directly, so a WebView would add nothing and take away the address bar,
devtools, and the tab you want to keep open while you go back to the terminal.

**Why there is no relay yet.** A loopback-bound server could be reached by having
the bridge open a tailnet-side listener and splice bytes to 127.0.0.1 — `ssh -L`
semantics, without the SSH. That is a deliberate later step, not an oversight: it
opens ports that sit outside the bearer-token check (the tailnet is the auth
boundary, as it already is for `WS /attach`), so it should be an explicit
per-server "Expose" tap rather than something the bridge does on its own for
every loopback listener it finds. Shipping the dimmed state first is what tells
us how often the case actually comes up. When it is built it is one more action
(`expose_url`) on an existing chip, not a new mechanism — which is the point of
having merged the two.

---

## Why the diff-shaped suggestions are agent-panes-only

`GET /diff` resolves its tree through the pane's **agent** (`paneCwd` →
`paneAgent`), so a plain pane taps through to a 404. Rather than ship a chip that
sometimes dead-ends, `git_conflict` and `git_dirty` require an agent in the pane.

That is upstream's decision, not a shortcut taken here: `paneDropCwd` was added
for `POST /image` precisely because an image drop makes sense for any pane, and
it says so explicitly — "/diff is a different question: it asks what an agent
changed, and a pane with no agent has no answer."

The cost is worth naming anyway: a conflict in a plain shell pane's worktree is
invisible to this endpoint even though the bridge can see it perfectly well. If
`/diff` ever grows the same agentless fallback, the `HasAgent` guard in both
sources can simply be deleted.

Note that `dev_server` has **no** such restriction, and that asymmetry is
correct: a dev server normally runs in a pane split off *beside* the agent,
precisely so it is not competing for the terminal.

---

## Cost, and the two caches that keep it down

Per **uncached** call: one `pane.process_info`, one `agent.get`, **one git read**
(`gitdiff.ReadContext` — the same call `GET /diff?context=1` answers with), and a
read of the port scan.

That "one git read" is load-bearing. Before the three features were merged, the
suggestion sources ran their own `git status` while the app separately polled
`/diff?context=1` for the PR gate — two implementations of "what is this pane's
git situation", against the same directory, that could disagree. They now share
`internal/gitdiff`, which is why the chip that says "9 files changed" and the
diff screen that lists nine files are reading one number.

| Cache | TTL | Scope | Rebuilt when |
|---|---|---|---|
| Per-pane suggestions (`suggestTTL`) | 6s | one pane | anything about the pane changes |
| Port scan (`ports.TTL`) | 5s | the whole host | a server starts or stops |
| Pane → shell-pid map (`paneMapTTL`) | 30s | the whole host | a pane is created or closed |

Every input changes on a human timescale — an agent finishes a turn, a rebase
stops, a dev server comes up, a shell is left at a prompt — so a few seconds of
staleness is invisible.

`suggestTTL` sits **just past** `ports.TTL` rather than under it, deliberately: a
per-pane entry that outlived its scan would keep re-triggering scans it then
ignores. This way a miss usually finds the scan already warm.

The suggestion cache is keyed **per pane and per client host**, not one shared
slot. Per pane because a phone showing one terminal asks about one pane
repeatedly and two open panes must not evict each other; per client host because
a dev-server URL is only correct for the client it was built for, and a shared
entry would hand a LAN caller a tailnet link. That is the same class of bug as
handing out loopback, just harder to notice. In practice it is one or two hosts.
The lock is held across the observation, so concurrent callers for a pane share
the one in flight — the same bargain `ports.Cache` makes.

The port scan is host-wide and shared, which is what makes folding it in
affordable: a row of open panes costs **one** `lsof` per 5s between them, not one
each. The pane map is the expensive half (a snapshot plus one
`pane.process_info` per pane) and gets the longest TTL because a pane's shell pid
is fixed for the pane's whole life.

**The app never polls this.** It refetches on screen open and when the pane's
agent status changes in the snapshot the bridge already pushes over `WS /events`
— which is also *when the answers change*. The TTLs are what make that safe even
if a future surface is less careful.

There is a second, deliberate git read: the **pre-flight** the app runs when a
`create_pr` chip is tapped. That is not a duplicate gate — the bridge already
decided whether to offer the chip — it is a re-check that the answer has not
changed in the seconds since the chip was drawn, before an action that reaches
outside the host. An agent that opened the PR while you were reading the screen
is exactly the case worth catching, and it is one call, on an explicit user
action, not per render.

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
| `lsof` missing or the scan fails | Logged; the pane has no dev-server chips. **Not** a 502 — see below |
| Bridge too old to have the endpoint | `404` → the app renders no chip row at all |
| A `create_pr` chip tapped after the situation changed | the sheet says why, and the Send button stays disabled |

The scan failure is the one place this endpoint deliberately disagrees with
`/ports`, which answers `502`. There the scan *is* the response; here it is one
source of several, and losing the dev-server chips must not cost a pane its
"resolve this conflict" chip.

The app collapses `404` and transport failures into an empty list. This is a
convenience surface: an error banner in front of it would cost more attention
than the feature gives back, and there is nothing the user could do about either
cause.

---

## What the app lost, and why that is the right trade

The "Create PR" button used to live in the transcript composer, drawn whenever
the pane was in a repository at all, and *disabled with a sentence* for the finer
conditions: "This pane is on main, the default branch. Move the work onto a
feature branch first."

As a chip, it simply does not appear in those states. That is a real loss and it
is named here rather than glossed: standing on `main`, nothing tells you to move
the work to a feature branch.

It is the right trade because the two surfaces have different jobs. A chip row
answers *what should I do now* and has to be quiet — the same rule that keeps it
from showing "no dev server here". A sentence answers *why didn't that work*, and
the place that question is actually asked is **after a tap**, not before one. The
pre-flight keeps every one of those sentences for the case where they matter
most: a chip that has gone stale between being drawn and being tapped.

## Deliberately not built

- **A "rerun the test runner" source.** `process_info` gives the foreground
  command, so recognising `vitest`/`jest`/`go test` is easy; making the *action*
  work is not. A watcher wants a keystroke (`a` in vitest watch mode), a finished
  run wants the command retyped, and the two are indistinguishable from the
  process list alone. `suggest.Pane.Foreground` is collected and unused, which is
  where that source will hang off when it is worth the flakiness budget.
- **The loopback relay.** See above — an action, not a mechanism, and gated on
  evidence the dimmed state actually comes up.
- **Event-driven cache invalidation.** The bridge runs an event bus, so pane
  create/close could invalidate the pane map directly and retire its 30s TTL, and
  a pane status change could do the same for the suggestion entry. The TTLs are
  doing the job at this scale.

---

## Bridge version

`BridgeVersion` 11. As with `/commands`, the app gates its UI on this endpoint
answering rather than on the number — an older bridge 404s and no chip row
renders.

---

# Appendix — `GET /ports`, the raw feed

`/ports` is the host-wide scan the `dev_server` source reads. It is kept as an
endpoint (unchanged from when it was the whole feature) for two reasons: it
answers the *host* question — "what is serving on this machine, and whose is
it" — which a per-pane read cannot; and it is the layer that knows about `lsof`,
HTTP probes and process trees, which is not knowledge the suggestion mechanism
should acquire.

**The app does not call it.** Everything the app renders comes through
`/suggestions`. `/ports` is for a future list-page surface, and for poking the
host by hand.

## Request

```
GET /ports[?pane=<pane_id>]
Authorization: Bearer <bearer>
```

`pane` narrows the result to one pane; it is a filter over the same shared scan,
not a second code path.

`url` is built for **the caller of this request** — see "How the `url` is built"
above; the same rules apply here, since both surfaces stamp URLs through
`ports.FillURLs`.

## Response `200`

```jsonc
{
  "ports": [
    {
      "port": 5173,
      "bind": "*",                      // verbatim from lsof; "*" = all interfaces
      "pid": 4821,
      "proc": "node",
      "loopback": false,                // true => nothing on the tailnet can reach it
      "pane": "acme/wN:p2",            // absent when unattributed
      "agent": "claude",                // absent when unattributed
      "url": "http://100.84.12.3:5173"  // absent when loopback or unreachable
    }
  ]
}
```

Always an array, never `null`. Sorted by port so the list is stable between
polls.

## Why a listener has to answer HTTP

Every listener is probed with a bare `GET / HTTP/1.0` and kept only if the reply
starts with an HTTP status line. Any status counts — a dev server answering `404`
on `/` is still a dev server.

This is what keeps the chip list short enough to be worth glancing at. Without
it, a typical host offers Postgres, Redis, the bridge, and a handful of macOS
daemons alongside the one server you wanted. Probes run concurrently with a
400ms deadline, so a dozen listeners resolve in about one timeout rather than a
dozen.

## Attribution

A listener's pid is walked up the `ps` parent chain until it reaches a pid Herdr
named as a pane's shell (`pane.process_info` → `shell_pid`). The walk matters: a
dev server is typically a *grandchild* of the pane shell (`shell → npm → node`),
so checking the direct parent alone finds nothing. It is bounded at 64 hops — a
corrupt process table could otherwise describe a cycle.

**Every pane, not just agent panes.** The pane list comes off the snapshot tree
(`herdr.PaneIDs`) rather than `agent.list`, and that choice is load-bearing: a
dev server normally runs in a pane split off *beside* the agent, precisely so it
isn't competing with the agent for the terminal. An agent-only map would miss the
common case and attribute almost nothing.

Unattributed listeners are still returned by `/ports`. A dev server running
outside Herdr entirely is a real server; gothalo just can't label it, and
dropping it would make the list lie about what's up. They produce **no**
suggestion, of course — there is no pane to hang one on.

## Failure modes

| Condition | Result |
|---|---|
| No listeners on the host | `200`, `{"ports": []}` |
| Nothing answers HTTP | `200`, `{"ports": []}` |
| `lsof` missing or fails outright | `502` (but `/suggestions` degrades quietly) |
| `lsof` exits non-zero with output | Treated as success — unreadable descriptors are routine |
| A pane's `process_info` read fails | That pane contributes no attribution; the scan is unaffected |
| A session's pane list fails | That session contributes no attribution; others are unaffected |

No elevation is required: the agents' dev servers run as the same user as the
bridge.

## Why this is not part of `/snapshot`

Considered and rejected. Snapshot is the hottest read in the bridge and stays a
passthrough; a scan that shells out twice and opens a connection per listener
belongs on its own cadence, and the two have no reason to share one.
