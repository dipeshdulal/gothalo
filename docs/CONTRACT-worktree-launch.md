# CONTRACT — create a worktree and launch an agent into it

The mobile flow behind Overview → *Space actions* → **New worktree**: branch off
a repo and, optionally, put an agent to work in the checkout in the same
gesture.

It introduces **no new endpoint and no new payload**. It is a composition of two
contracts that already exist:

1. [`POST /herdr` → `worktree.create`](./CONTRACT-herdr-proxy.md#worktreecreate)
   — makes the git worktree and opens it as a workspace.
2. [`POST /agent/start`](./CONTRACT-agent-lifecycle.md#post-agentstart) with
   `pane_id` — starts the chosen agent in the workspace's root pane, and submits
   the opening prompt if one was given.

This document is the contract for **how those two are joined**: which ids cross
the seam, and what the operator is told for each way the pair can end. That is
the part a reader cannot recover from either endpoint's doc alone.

---

## The sequence

```
→ POST /herdr {"method":"worktree.create",
               "params":{"cwd":"<repo>","branch":"feat/thing","label":"feat/thing"}}

← 200 { "result": { "type": "worktree_created",
                    "workspace":  { "workspace_id": "wZ", … },
                    "tab":        { "tab_id": "wZ:t1", … },
                    "root_pane":  { "pane_id": "wZ:p1",
                                    "cwd": "~/.herdr/worktrees/repo/feat-thing" },
                    "worktree":   { "path": "…/feat-thing", "branch": "feat/thing" } } }

→ POST /agent/start {"kind":"claude","pane_id":"wZ:p1","prompt":"fix the failing test"}

← 200 { "pane_id":"wZ:p1", "kind":"claude", "name":"claude-wz-p1",
        "created_pane":false, "prompt_sent":true }
```

### The ids come from the create response, never from a lookup

`worktree.create` returns the whole tree it just made. The app takes
`result.root_pane.pane_id` and `result.workspace.workspace_id` straight out of
it (`CreatedWorktree.fromResult`). It does **not** re-list workspaces or panes
to find the new one.

That is a correctness rule, not an optimisation. The only thing a re-list could
match on is the label, which is the branch name the operator typed — and
nothing stops two workspaces carrying the same one. A wrong match starts an
agent with full tool access in **someone else's checkout**, which no retry
undoes. If `root_pane` is ever absent from the response, the app reports "there
was nowhere to start it" rather than substituting a pane of its own choosing.

Ids are session-qualified by the proxy on a non-default session
(`acme/wZ:p1`), which is exactly the form `/agent/start` and the app's router
already take, so they pass through untouched.

### Why the existing-pane form, and no `cwd`

The root pane is already a shell sitting in the new checkout, so `pane_id` is
the right targeting form and `cwd` must **not** be sent — `/agent/start` rejects
`cwd` alongside `pane_id` with a `400` (a shell at a prompt cannot be moved
without typing into it; see the lifecycle contract's working-directory rules).

A pane that Herdr has only just created is typically still running its rc files.
That is already handled on the bridge: `resolveStartPane` waits up to 8s for the
pane to reach an interactive prompt for **every** targeting form, including this
one, so a start against a freshly created root pane is not a race.

---

## Why this is composed in the app, not a new bridge endpoint

The lifecycle contract argues that a *start* must not be driven from a client
over several proxy round-trips, and that reasoning was re-examined here rather
than assumed to carry over. It does not, for three reasons:

- **There are two calls, not five, and each is already atomic and validated.**
  The dangerous plumbing a client must not own — creating a pane, waiting for
  its shell, resolving the agent name, retrying `agent.prompt` until Herdr
  accepts it — all still happens inside `/agent/start`. Nothing is
  re-implemented on the phone.
- **The state between them is not a broken one.** It is a worktree with an idle
  shell in it — precisely what the toggle-off flow produces on purpose, and what
  the operator had before this feature existed. There is nothing to roll back
  and nothing to clean up.
- **No new validation surface.** The one field this flow could get dangerously
  wrong is a working directory, and it never sends one: the agent inherits the
  root pane's.

A `POST /worktree/start` would have added an endpoint, a payload, cwd
validation, and a second place where "start an agent" is implemented — to buy
atomicity over a boundary that does not need it. Revisit if the flow ever grows
a step that genuinely cannot be left half-done.

---

## Outcomes, and what the operator is told

The whole point of joining the two calls is that "it failed" is not an
acceptable answer when half of it worked. Every ending is distinct:

| Ending | What exists afterwards | What the operator sees |
|---|---|---|
| Toggle **off**, create ok | worktree + idle shell | `Worktree "feat/thing" created` — unchanged from before this feature |
| Toggle off/on, create **fails** | nothing | The bridge's own message (`{"error"}` body), sheet stays open on the branch field |
| Create ok, agent ok, no prompt asked | worktree + agent | `feat/thing created — claude started`, then straight to the agent's chat |
| Create ok, agent ok, prompt delivered | worktree + agent, instructed | `… started and given your message` |
| Create ok, agent ok, prompt **dropped** (`prompt_sent:false` + `prompt_error`) | worktree + agent, idle | `… started, but your message was not delivered` |
| Create ok, agent **fails** | worktree + idle shell | An outcome panel naming **both** halves, the checkout path, and the bridge's sentence — plus **Try again**, which retries only the agent |
| Create ok, no `root_pane` in the response | worktree + unknown | Same panel, saying there was nowhere to start it and to open the space instead |
| Sheet dismissed mid-flight | whatever completed | The same report as a snackbar — the messenger and router are captured from an ancestor, so a swiped-away launch still lands its outcome |

The **retry** path re-runs `/agent/start` against the same `root_pane` and never
re-creates the worktree. The branch field is locked from the moment the checkout
exists; the agent kind and the prompt stay editable, because the fix for
"claude is not installed on this host" is to pick a different kind.

Agent startup takes 5–30s (Herdr blocks until it has *verified* the agent is
really up), so the sheet shows a two-step checklist while it runs — creating the
worktree, then starting the agent — rather than one anonymous spinner. Which
half you are waiting on matters: only one of them can leave something behind.

---

## App surface

| File | Role |
|---|---|
| `app/lib/features/worktrees/new_worktree_sheet.dart` | The sheet, the two-leg flow, the outcome copy (`worktreeLaunchSummary`, `worktreeAgentFailure`) |
| `app/lib/features/agents/agent_kind_picker.dart` | `AgentKindField` / `AgentKindPicker` — the kind chips + the `state_reporting` warning, shared with the start-agent sheet |
| `app/lib/data/bridge/bridge_client.dart` | `CreatedWorktree.fromResult`, and `StartAgentResult.promptError` |
| `app/lib/features/overview/overview_screen.dart` | Entry point (*Space actions → New worktree*) |

The kind list is `GET /agents/available` via `availableAgentsProvider` — the same
provider the start-agent sheet uses, so no launch surface can offer a kind that
is not installed on that host, and the "Herdr cannot read this kind's status"
warning cannot be present on one sheet and missing on the other. The picker was
extracted from `start_agent_sheet.dart` for exactly that reason rather than
copied.

The provider is watched **inside** the toggle's branch, so a bare worktree never
pays for the round trip.

---

## Verification

- `go build ./... && go test ./...` — **unchanged**. This feature adds no Go: it
  is composition on the client side of two endpoints that already shipped.
- `cd app && flutter analyze && flutter test` — clean; 117 tests pass.
- `app/test/worktree_launch_test.dart` covers the seam and the copy: id
  extraction from the **real captured** `worktree.create` result (including the
  session-qualified form), a missing `root_pane` yielding empty rather than a
  substitute, the checkout-path fallback, all three prompt outcomes, the
  partial-failure message naming both halves and keeping the bridge's words
  verbatim, and `prompt_error` surviving `StartAgentResult.fromJson`.

**Not exercised against a live Herdr.** Running it end-to-end means creating
real worktrees and launching real agents on a shared host, which this change was
not in a position to do. Both legs are individually proven live — see the
capture in [`CONTRACT-herdr-proxy.md`](./CONTRACT-herdr-proxy.md#worktreecreate)
and the success-path table in
[`CONTRACT-agent-lifecycle.md`](./CONTRACT-agent-lifecycle.md#success-paths--verified-live-and-initially-broken),
which includes `POST /agent/start {pane_id}` into an existing idle pane — the
exact call this flow makes. What is unproven is the join: that a root pane Herdr
has just created is reliably at its prompt within the bridge's 8s settle window.
If it is not, the failure is an honest `409` in the outcome panel with a **Try
again** button next to it, not a silent half-state.
