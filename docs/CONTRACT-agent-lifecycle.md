# CONTRACT — agent lifecycle (start / restart / stop)

The mobile-side contract for **launching** an agent, not just watching one.
Everything else in the bridge assumes an agent already exists — this is the
piece that closes the loop from *monitor* to *dispatch*
(`RESEARCH-feature-ideas.md` #10). Four endpoints:

- **Discover** — `GET /agents/available` — which agent kinds this host can
  actually run.
- **Start** — `POST /agent/start` — launch one, optionally into a pane it
  creates, optionally with an opening prompt. Returns the session-qualified pane
  id to navigate to.
- **Restart** — `POST /agent/restart` — replace the agent in a pane. **Loses the
  conversation.**
- **Stop** — `POST /agent/stop` — quit the agent, keep the pane.

All captures below are real responses from the running bridge against live Herdr
0.8.0 (protocol 19) — see [Verification](#verification), which is also explicit
about the two paths that could **not** be exercised without destroying other
people's work.

---

## Why these are endpoints and not `POST /herdr` calls

The generic proxy ([`CONTRACT-herdr-proxy.md`](./CONTRACT-herdr-proxy.md))
forwards **one** Herdr method with params **verbatim**. Both halves of that are
wrong here:

- **A start is not one method.** It is: resolve the target → create a pane (for
  two of the three targeting forms) → wait for that pane to reach its shell
  prompt → `agent.start` → optional `agent.prompt`. A client driving those over
  five proxy round-trips would own every failure state in between — a created
  pane with no agent in it, an agent with no prompt, a pane that was still
  running its rc files when the launch was typed into it.
- **"Verbatim" means unvalidated.** The `cwd` field decides where a shell — and
  then an agent with full tool access — starts. That is not a field a phone gets
  to hand straight to the host. See [Working-directory
  rules](#working-directory-rules).
- **Herdr has no stop at all.** `agent.stop` / `agent.kill` do not exist in
  protocol 19; the full agent surface is
  `agent.{explain,focus,get,list,prompt,read,rename,send_keys,start,view.*,wait}`.
  `/agent/stop` could not have been a proxied call even in principle.

`agent.start` is deliberately **not** added to the proxy allowlist either, so
there is exactly one way to launch an agent and it is the validated one.

---

## `GET /agents/available` — what this host can run

```
GET /agents/available
Authorization: Bearer <bearer>
```

Real capture:

```json
{
  "agents": [
    { "kind": "claude",   "path": "/opt/homebrew/bin/claude",                 "state_reporting": true },
    { "kind": "opencode", "path": "/Users/alex/.opencode/bin/opencode","state_reporting": true },
    { "kind": "hermes",   "path": "/opt/homebrew/bin/hermes",                 "state_reporting": true }
  ],
  "discovery": "herdr agent kinds + PATH lookup",
  "known_kinds": ["pi","claude","codex","gemini","cursor","devin","agy","cline","omp",
                  "mastracode","opencode","copilot","kimi","kiro","droid","amp","grok",
                  "hermes","kilo","qodercli","maki"]
}
```

| Field | Meaning |
|---|---|
| `agents[]` | The kinds that can be started **here, now**. This is the only list a launch UI may offer. |
| `agents[].path` | Where the executable was found. `"installed"` is a claim about a machine; the path is what makes it checkable. |
| `agents[].state_reporting` | Whether Herdr holds a detection manifest for the kind. **See below.** |
| `known_kinds` | Every kind Herdr can start, installed or not — so a client can say "codex isn't installed" instead of just omitting it. |
| `discovery` | Names the mechanism, so a surprising answer is debuggable from the response alone. |

### How the list is discovered (nothing is hardcoded)

Two independent sources, intersected:

1. **The catalog** comes from Herdr — the `--kind` enum the *running binary*
   accepts (21 kinds on 0.8.0). It is read from `herdr agent start --help`
   (clap-generated, exit 0, inert), falling back to the `kinds: a|b|c` line in
   the bare `herdr agent` usage block. This shells out on purpose: the socket API
   does **not** expose the catalog — `agent.start`'s params type `kind` as a bare
   `string`, and Herdr's own agent skill says "the installed binary is the
   authority for command syntax".
2. **Installed-ness** comes from a PATH lookup of the kind name. Herdr documents
   `--kind` as "Supported agent kind and **canonical executable**", so the kind
   *is* the binary name — no kind→command table exists anywhere in gothalo.

> **`server.agent_manifests` is deliberately not the catalog.** It reports the
> kinds Herdr can *classify*, which is a **subset** of the kinds it can *start* —
> 19 of the 21 on this build (`omp` and `mastracode` are startable with no
> manifest). Using it as the catalog would have silently hidden two startable
> agents. It is read only to fill `state_reporting`.

### `state_reporting: false` is a real warning

A kind with no detection manifest **starts and runs fine**, but Herdr can never
move it past `unknown` — so in the app it never goes idle/working/blocked, never
raises an approval, and never sends a push. The app surfaces this before the
launch rather than leaving the operator to work out why an agent looks dead.

### The PATH caveat

The set is resolved against **the bridge daemon's environment**, not an
interactive login shell. An agent installed only by a `PATH` line in `~/.zshrc`
is invisible unless the daemon inherited that PATH. This is a **false negative**
(an installed agent isn't offered), never a false positive — which is the right
way round, because the app must never offer a kind that cannot start.

Errors: `401` no/invalid token · `405` non-GET · `502` Herdr unreachable or it
reported no kinds.

---

## `POST /agent/start`

```
POST /agent/start
{ "kind": "claude", "split_from": "wN:p1", "cwd": "/src/app", "prompt": "fix the failing test" }
```

Exactly **one** of three targeting forms:

| Form | Field | What happens |
|---|---|---|
| Existing pane | `pane_id` | Reuses an idle shell pane in place. |
| Split | `split_from` (+ `direction`: `"right"`\|`"down"`, default `down`) | Splits that pane; the agent goes in the new one. |
| New tab | `workspace_id` (+ `label`) | Opens a tab in that workspace; the agent goes in its root pane. |

Naming **none or several is a `400`** — unlike `/pane/new`, where `split_from`
silently wins. Starting an agent in the wrong place is not something a retry
undoes.

Common optional fields:

| Field | Notes |
|---|---|
| `cwd` | Absolute, existing directory. **Rejected with `pane_id`** — see below. |
| `prompt` | Submitted as the agent's first message once it is ready, via `agent.prompt` (atomic text+Enter, bracketed-paste aware) — *not* typed through `/send`. |
| `name` | The agent's Herdr label. Must match `[a-z][a-z0-9_-]{0,31}`. Defaults to `<kind>-<pane id>` lowercased (`claude-wn-p2n`). |
| `timeout_ms` | Herdr's startup budget. Clamped to 5 000–300 000; default 60 000. |

Response `200`:

```json
{
  "pane_id": "wN:p7",
  "tab_id": "wN:t5",
  "workspace_id": "wN",
  "kind": "claude",
  "name": "claude-wn-p7",
  "created_pane": true,
  "prompt_sent": true
}
```

`pane_id` is **session-qualified** (`"acme/w4:p7"` on a non-default session), so
it addresses `/attach`, `/transcript`, `/send` and `/agent/stop` directly — the
app navigates straight to the new agent with no snapshot round-trip.

`prompt_sent` is `false` both when no prompt was asked for **and** when one was
asked for but failed. A failed opening prompt never fails the request: the agent
is up and addressable at that point, and losing a successful launch over an
unsent first line would be the worse outcome.

`prompt_error` disambiguates those two cases. It is present **only** when a
prompt was asked for and did not land, and carries the reason in words. Without
it a client cannot tell "started, carrying your instruction" from "started,
sitting there empty" — which is precisely the state this endpoint used to return
as an undifferentiated `200` while silently dropping the prompt. A client that
shows the agent as instructed should key that on `prompt_sent`, and surface
`prompt_error` when it appears.

### It waits, and the client must let it

`agent.start` returns only after Herdr has **verified the expected agent is
really running in that pane and is ready for input**. That identity check is the
entire reason to go through Herdr instead of typing `claude` into a pane: without
it the bridge would report success for a pane that printed `command not found`.
It also means the request routinely takes **5–30 seconds**. Clients must raise
their receive timeout for this call (the Flutter client uses 120 s here versus
its 8 s default).

### Nothing is created before everything checkable has been checked

Order is deliberate: body shape → `cwd` → target routing → kind installed →
target free. Only then is a pane created. A request that is going to fail must
not leave a stray pane behind.

Once a pane **has** been created, the response is committed to reporting it: if
the agent then fails to start, the error names the pane id and says it is still
open, rather than orphaning a pane nobody knows about.

### Working-directory rules

`cwd` is the one field that decides where a process runs, and it arrives from a
phone. It is validated on the bridge (`validateCWD`), not delegated to Herdr,
which will happily open a pane anywhere:

| Rule | Rejected example | Why |
|---|---|---|
| Absolute | `projects/app`, `../../etc`, `.`, `~/x` | A relative path resolves against the daemon's cwd — an implementation detail no client can reason about, so the same request would mean different places on different installs. |
| Canonical | `/src/../etc`, `/src/./a`, `/src//a`, `/src/` | Every `..`/`.`/`//` form is rejected outright rather than normalised. Normalising would be *worse*: the logged path and the used path would agree, and neither would be what the caller wrote. |
| Exists | `/src/nope` | Otherwise it fails in the terminal, after a pane exists. |
| Is a directory | `/src/a-file` | Same. |

Symlinks **are** followed (`os.Stat`, not `Lstat`): `/tmp` and `/var` are
symlinks on macOS, and rejecting them would reject ordinary directories for no
security gain. A symlink is not a traversal.

`cwd` **with `pane_id` is a `400`**, not silently ignored. A shell already
sitting at a prompt cannot be moved without typing a `cd` into it — and typing
shell commands into a pane on a phone's say-so is exactly what this validation
exists to prevent. Use `split_from` or `workspace_id` to get a pane in a
different directory.

### The target must be an idle shell

Herdr requires "an available shell pane… at its interactive prompt, with the
shell itself in the foreground and no foreground command, editor, or agent
running". The bridge checks this with `pane.process_info`
(`foreground_process_group_id == shell_pid`) rather than letting the launch fail
opaquely, and it serves two purposes:

- **Before a start in an existing pane** — a busy pane gets a `409` naming what
  is holding it, and a pane that already hosts an agent gets a `409` pointing at
  `/agent/restart`.
- **After creating a pane** — `pane.split` returns as soon as the pane exists,
  but the shell behind it is still running its rc files, and bytes written before
  the prompt appears are simply **lost**. That failure is invisible (the pane
  looks fine, the agent never arrives), so the bridge waits up to 8 s for the
  prompt.

### Errors (all captured live)

| Status | Example body |
|---|---|
| `400` | `unknown agent kind "nope"; herdr supports: pi, claude, codex, …` |
| `400` | `cwd must be a canonical path with no "..", "." or "//" segments (did you mean "/root"?)` |
| `400` | `cwd must be an absolute path, got "projects/app"` |
| `400` | `cwd does not exist: /src/nope` · `cwd is not a directory: /src/a-file` |
| `400` | `cwd cannot be set when starting in an existing pane — it inherits that pane's shell directory` |
| `400` | `want exactly one of {pane_id, split_from, workspace_id}` (or `…, not several`) |
| `401` | `unauthorized` |
| `404` | `herdr pane get wZ:p99: … {"code":"pane_not_found"…}` — unknown pane/workspace/session |
| `405` | `use POST` |
| `409` | `pane already hosts a claude agent — use /agent/restart to replace it` |
| `409` | `pane wN:p16 is busy running ./gothalo serve — an agent can only start at an idle shell prompt` |
| `409` | `agent kind "codex" is not installed on this host (no "codex" on the bridge's PATH)` |
| `502` | `agent claude failed to start in wN:p7: … (the pane was created and is still open)` |

Error bodies are **plain text**, matching the other bespoke endpoints (only
`POST /herdr` returns `{"error"}` JSON). They are written to be shown to a human
verbatim — the Flutter client surfaces the body directly rather than a generic
"request failed".

---

## `POST /agent/stop`

```
POST /agent/stop
{ "pane_id": "wN:p7" }
```

Response `200`: `{ "stopped": true, "pane_id": "wN:p7", "kind": "claude" }`.

**This kills running work.** Whatever the agent was doing is interrupted and it
exits. The pane stays open at its shell prompt. The app gates it behind the
standard destructive-action confirm.

### How, given Herdr has no stop

The mechanism is what an operator does: **send `ctrl+c` to the pane, repeatedly**
(`pane.send_keys`, up to 4 rounds, 400 ms apart). Agent TUIs deliberately make a
single Ctrl-C non-fatal — Claude aborts the current turn and arms a "press again
to exit" — so one interrupt is never enough. The pane is re-checked before each
round, so an agent that already quit is never sent a stray keystroke onto the
bare shell.

### Success is observed, never assumed

`200` is returned **only** once `pane.process_info` shows the shell back in the
foreground, which is true only when the agent process is genuinely gone. There is
no acknowledgement to trust: an agent that swallowed the interrupts is still
alive and still holds the pane.

That case is a **`409`**, and clients must treat it as *not stopped* rather than
as a slow success:

```
409  the claude agent in wN:p7 did not exit within 12s and is still running
```

A false "stopped" would have the app navigate away from an agent that is still
running, possibly mid-turn.

Errors: `400` missing `pane_id` · `401` · `404` `no such agent` (the pane has no
agent, or is unknown) · `405` non-POST · `409` above · `502` Herdr failed.

---

## `POST /agent/restart`

```
POST /agent/restart
{ "pane_id": "wN:p7", "prompt": "start again, this time only touch the parser" }
```

Response `200`:

```json
{
  "restarted": true,
  "pane_id": "wN:p7",
  "kind": "claude",
  "name": "claude-wn-p7",
  "cwd": "/src/app",
  "prompt_sent": true,
  "history_kept": false
}
```

Stop the agent in the pane, then start **the same kind** again in **the same
pane and directory**. Same shape as a stop followed by a start, done atomically
so the app cannot end up holding half of it.

### What survives

The pane and its id (so anything holding it stays valid), its scrollback, its
working directory, and the agent's Herdr name.

The **directory survives for free rather than by being restored**: the agent ran
as a child of the pane's shell, and a child cannot move its parent, so the shell
is still exactly where it was when the replacement launches. Nothing is
remembered or re-entered; no `cd` is typed.

The **name** is reused too — Herdr releases a name when its agent exits, so the
operator's own label for that pane comes back with the replacement.

### What does NOT survive

This is the whole reason restart is a destructive action and not a refresh:

- **The conversation.** The replacement is a **new agent session** — no history,
  no memory of what was discussed, no awareness that it is a replacement. It will
  not resume the previous task; it has never heard of it. `history_kept` is
  `false` in the response and is there to be shown, not inspected.
- **The in-flight turn**, including any partially applied tool call.
- **Queued input, permission mode, plan mode**, and every other piece of TUI
  state the agent held in memory.

`prompt` exists precisely because the replacement has to be told what to do from
scratch.

### Partial failure is reported honestly

If the stop succeeds but the replacement fails to start, the old agent is
**already gone**. The `502` says so, so the operator knows the pane is now an
idle shell rather than a running agent:

```
502  the old claude agent was stopped but the replacement failed to start in wN:p7: … (the pane is now an idle shell)
```

If the stop itself fails, nothing is restarted (`409`, same message shape as
`/agent/stop`).

Errors: `400` missing `pane_id` · `401` · `404` `no such agent` · `405` non-POST ·
`409` the agent would not stop · `502` Herdr failed / the replacement failed.

---

## Events

Each endpoint publishes a gothalo-source event on `WS /events`:

| Type | Payload |
|---|---|
| `agent_started` | `{pane_id, kind, name, created_pane}` |
| `agent_stopped` | `{pane_id, kind}` |
| `agent_restarted` | `{pane_id, kind, name}` |

They are gothalo-source rather than Herdr-source because Herdr's own
`pane_agent_detected` says an agent appeared, not that *this bridge* put it
there — which is what a client needs to tell "the phone launched this" from
"someone started one at the desk".

---

## App flow

1. **Entry points** (`app/lib/features/agents/start_agent_sheet.dart`):
   - Overview → *Space actions* → **Start agent** (new tab in that workspace,
     working directory pre-filled from the space).
   - Overview → a **non-agent** pane's overflow → **Start agent here** (in place;
     no cwd field, since the pane keeps its own).
2. **The sheet** picks a kind from `GET /agents/available` — never a hardcoded
   list, never a kind that isn't installed — warns when the chosen kind has no
   state reporting, takes the working directory and an optional first message,
   and on success navigates to `/transcript/<pane_id>`.
3. **Restart / stop** sit with the other destructive actions in
   `app/lib/features/herdr_actions.dart` and use the same `_confirm` dialog as
   *Close pane* / *Remove worktree*. Reachable from an agent pane's overflow in
   the Overview and from the chat screen's overflow menu.

The restart confirm leads with the surprising part — *the conversation is not
carried over* — because "restart" reads like a refresh and it isn't one.

---

## Verification

**Verified live** through the real HTTP handlers against Herdr 0.8.0 on this
host (read-only — no agent or pane was created, stopped or killed):

```
GET  /agents/available                                    -> 200  3 installed of 21 known (capture above)
POST /agent/start {kind:claude,   pane_id:wN:p2N}         -> 409  pane already hosts a claude agent — use /agent/restart to replace it
POST /agent/start {kind:claude,   pane_id:wN:p16}         -> 409  pane wN:p16 is busy running ./gothalo serve — …
POST /agent/start {kind:codex,    pane_id:wQ:p2}          -> 409  agent kind "codex" is not installed on this host …
POST /agent/start {kind:nope,     pane_id:wQ:p2}          -> 400  unknown agent kind "nope"; herdr supports: …
POST /agent/start {kind:claude, split_from:wQ:p2, cwd:/etc/../root} -> 400  cwd must be a canonical path …
POST /agent/start {kind:claude,   pane_id:wZ:p99}         -> 404  pane_not_found
POST /agent/stop    {pane_id:wQ:p2}                       -> 404  no such agent
POST /agent/restart {pane_id:wQ:p2}                       -> 404  no such agent
```

Herdr-layer reads confirmed against the live socket: the kind catalog (21), the
manifest set (19, a strict subset), the PATH intersection (claude, opencode,
hermes), and `pane.process_info` classifying all three pane states correctly — an
idle shell (`atPrompt=true`), a pane running a command (`fg="./gothalo serve"`),
and a pane hosting an agent (`fg="claude"`).

### Success paths — verified live, and initially broken

The success paths originally shipped unproven, because confirming them means
launching and killing real agents. They have since been exercised against Herdr
0.8.0 in a dedicated tab, and **all three composition failures that review could
not see turned out to be real**. Every one came from the same wrong assumption:
that Herdr's state transitions are synchronous with the calls that cause them.

```
POST /agent/start   {kind:claude, pane_id:wN:p2R}                -> 200  agent live in pane
POST /agent/start   {kind:claude, split_from:wN:p2R, prompt:"…"} -> 200  prompt_sent:true, agent answered it
POST /agent/start   {kind:claude, workspace_id:wN, label:"…"}    -> 200  new tab, agent live
POST /agent/restart {pane_id:wN:p34, prompt:"…"}                 -> 200  new session id, same terminal id, prompt delivered
POST /agent/stop    {pane_id:wN:p2R}                             -> 200  agent gone, pane back at its shell
```

Restart was confirmed to be a genuine replacement rather than a reported one:
the agent session id changed (`de445d60…` → `f175d266…`) while the terminal id
did not — exactly the promise this endpoint makes. The pane survives, the
conversation does not.

What was broken, and is now covered by `internal/herdr/lifecycle_retry_test.go`:

| Symptom | Cause |
|---|---|
| Both pane-creating start forms failed **100%** (`agent_pane_busy`), orphaning a pane each time | Herdr's "available shell" test is stricter than `pane.process_info` and settles ~1.5s later. The bridge waited for the wrong signal, got it, and started too early. |
| Opening prompts silently dropped, reported as `200` | `agent.prompt` rejects a just-started agent with `agent_not_ready` even after its name resolves through `agent.get`. The error was logged and swallowed. |
| Restart could kill an agent and fail to replace it | The derived name is still held by the agent the restart just stopped, so the replacement start hit `agent_name_taken` — after the old agent was already dead. |

The fix predicts none of these. Each precondition is either waited for where
Herdr reports it faithfully (name release, via `agent.get`) or discovered by
retrying the real operation until Herdr accepts it. On exhaustion Herdr's own
structured error is returned unchanged, so a genuinely busy pane still reports
as `agent_pane_busy` — just later.

**Still unproven:** how many `ctrl+c` rounds each agent kind needs. Only
`claude` has been stopped for real. The **detection** of success is sound either
way — the pane is only reported stopped once its shell is back in the
foreground — so the failure mode of a wrong guess is an honest `409`, not a
false success.

Go tests: `internal/herdr/lifecycle_test.go` (kind-catalog parsing from real
`--help` and usage fixtures, both parsers failing closed, `pane.process_info`
decoding + the shell-prompt predicate across all three real payload shapes,
manifest parsing) and `internal/server/agentlifecycle_test.go` (cwd validation
including every traversal and relative form, symlinked directories accepted,
name derivation against Herdr's `[a-z][a-z0-9_-]{0,31}` rule, exactly-one
targeting, timeout clamping, discovery filtering to installed kinds and
preserving Herdr's order, plus auth and request-shape guards on all four
endpoints).
