# CONTRACT — `GET /commands` (slash-command typeahead)

What the composer's `/` typeahead is built on: the slash commands the agent in a
pane will **actually accept**, so a phone user picks from a list instead of
recalling and thumb-typing `/compact`. The bar this endpoint has to clear is that
everything it lists works — a typeahead that offers commands the agent rejects is
worse than no typeahead, because it costs a round trip to find out.

Captured live on **2026-08-06** against a real Herdr pane (a acme backend
worktree, which carries a project skill of its own), not a synthetic fixture.

---

## Request

```
GET /commands?pane=<pane_id>
Authorization: Bearer <bearer>
```

`pane` accepts the session-qualified form (`acme/w1:p2`) like every other
pane-scoped endpoint; the `<session>/` prefix is stripped before the Herdr
lookup.

Read-only and side-effect-free: it walks at most four directories and touches no
agent process. **Nothing is cached**, server or client — a cache is the only
thing that could stand between a command file the user just wrote on the desktop
and the typeahead on their phone. The app refetches on screen open.

---

## Response `200` — schema

```jsonc
{
  "pane": "w5:p18",
  "agent_kind": "claude",       // echoed so an empty list is interpretable
  "commands": [
    {
      "name": "migrations",      // WITHOUT the leading slash
      "description": "…",        // one line; may be absent
      "argument_hint": "[env]",  // frontmatter argument-hint; absent if none
      "source": "skill",         // builtin | command | skill
      "scope": "project"         // user | project; absent for builtin
    }
  ]
}
```

`commands` is always present and always an array — never `null` — so a client can
render it without a null check.

### `source` — and why the distinction is load-bearing

| `source` | Backed by | Drifts? |
|---|---|---|
| `command` | `.claude/commands/**/*.md` | No — read off disk per request |
| `skill` | `.claude/skills/<name>/SKILL.md` | No — read off disk per request |
| `builtin` | Nothing. Compiled into the agent's binary. | **Yes** |

The first two are ground truth. `builtin` is a hand-maintained list in
`internal/commands/claude.go`, because built-ins live inside the CLI, no manifest
on disk lists them, and `claude --help` does not enumerate them. It is the one
part of this feature that can go stale, which is why it is a distinct `source`
the app badges rather than blending in with the rest. A stale entry costs one
"unknown command" reply, not a broken screen.

The built-in list is curated **for a phone**, not exhaustive: `terminal-setup`,
vim mode, `statusline`, `doctor`, `login`/`logout` are deliberately omitted —
they only make sense at the machine you are sitting at, and `/logout` in
particular is a way to log your own bridge's agent out from across the network.

### Nested commands are namespaced

`.claude/commands/frontend/component.md` is listed as `frontend:component`,
because that is the string Claude Code actually accepts. The typeahead never
offers a bare filename that would fail.

### Ordering

Sorted for display, most-specific first:

```
project commands → project skills → user commands → user skills → built-ins
```

**Scope is the primary key, source only the tiebreak.** A thing installed in the
repo the agent is working in is likelier to be what you want than a generic one
from your home directory, whichever kind it is. The first implementation bucketed
by source and sank a project's own skill beneath unrelated user skills — caught
by the live capture below, not by tests. Once the user types a letter the client
re-ranks by prefix, so this ordering only governs the moment right after `/`.

---

## Live example — real capture

`w5:p18`, a claude pane in a repo carrying one project skill, against a host with
two user skills and no custom `.claude/commands` anywhere. 23 commands: 3
discovered, 20 built-in. Truncated after the first built-in.

```json
{
  "pane": "w5:p18",
  "agent_kind": "claude",
  "commands": [
    {
      "name": "migrations",
      "description": "Create, prune, hash, and validate DB migrations (Atlas + GORM) for this repo. Use whenever adding or changing a migration under backend/.",
      "source": "skill",
      "scope": "project"
    },
    {
      "name": "herdr",
      "description": "Control Herdr, a terminal multiplexer for coding agents. Use only when the user explicitly mentions Herdr or asks to use Herdr to inspect or control panes, tabs, workspaces, commands, or another agent. Do not use merely because a task could benefit from a background terminal, delegation, or parallel work.",
      "source": "skill",
      "scope": "user"
    },
    {
      "name": "hr-attendance",
      "description": "Check in, check out, or see HR attendance/leave status via the pm CLI (`pm hr`). Use when the user asks to \"check in\", \"check out\", \"clock in/out\", or check their HR/attendance status. Pre-authorized — run checkin/checkout without asking for confirmation.",
      "source": "skill",
      "scope": "user"
    },
    {
      "name": "agents",
      "description": "View and manage subagents",
      "source": "builtin"
    }
  ]
}
```

Note the descriptions are long — they are written for an agent's own dispatcher,
not for a UI. The app clamps to one line.

---

## Errors

| Status | When | What the app does |
|---|---|---|
| `400` | no `?pane=` | programming error; not reachable from the UI |
| `401` | missing/bad bearer | standard auth path |
| `404` | no such pane, or a plain (non-agent) pane | hide the typeahead |
| `404` | bridge predates this endpoint | hide the typeahead |

**An agent kind with no command surface is `200` with an empty list, not an
error.** "This agent has no typeahead" is a normal answer for a codex or opencode
pane, and turning it into a 404 would put an error state in front of a pane that
is working perfectly. Likewise a discovery failure (an unreadable home directory)
is logged and answered as an empty list: it must never cost the user their
composer.

---

## Implementation notes (for maintainers)

- `internal/commands` — per-kind `Lister` registry, same shape as
  `internal/transcript` and `internal/agentstate`. `claude.go` is real;
  `codex.go` and `opencode.go` are registered **honest stubs** that report
  nothing. Adding a kind is one file plus a `Register` in its `init`; the
  endpoint, this contract, and the app do not change.
- Frontmatter is read by a deliberately minimal scanner (`frontmatter.go`), not a
  YAML dependency: the only keys wanted (`description`, `argument-hint`) are flat
  scalars. Structured values are ignored rather than mis-parsed, and a key that
  cannot be read yields a command with no description — never a dropped command.
  Verified against real plugin commands whose `allowed-tools` values contain
  colons.
- Bounded because the walk is over a path the bridge does not control:
  `maxDepth = 3` below `commands/`, `maxCommands = 500` per response.
- `paneAgent` in `internal/server/pane.go` is the shared pane→agent resolution
  (`paneCwd` delegates to it). This endpoint needs the **kind** as well as the
  cwd; the kind picks the lister, the cwd is where project-scoped commands live.

### Known gap — plugin commands are not listed

Enabled plugins contribute `/<plugin>:<command>`, and this endpoint does not
report them. Deliberate, not an oversight: which plugins are *enabled* lives in
an `enabledPlugins` settings key, and on the machine this was built against that
key is **null in both `settings.json` and `settings.local.json`** while a full
marketplace sits installed on disk. So the only available sample cannot show the
shape of an enabled entry, and enumerating the marketplace directory instead
would list dozens of commands that are installed but **not invocable** — the one
failure mode this endpoint exists to avoid.

To close it: read `enabledPlugins` off a machine that has plugins genuinely
enabled, then walk `~/.claude/plugins/marketplaces/<mp>/plugins/<plugin>/commands`
for those entries only, emitting `name` as `<plugin>:<command>` with a `plugin`
source. Same file, no contract change beyond one new `source` value.
