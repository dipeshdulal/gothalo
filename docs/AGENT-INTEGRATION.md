# Agent integration (Herdr host)

Required for the transcript view. Referenced from the README's Prerequisites.

Install Herdr's agent integration for every agent you run. **This is required, not
optional** — without it the transcript view will not work:

```bash
herdr integration status          # what's installed, and whether it's current
herdr integration install claude  # likewise: hermes, codex, opencode, copilot, …
```

The integration installs a `SessionStart` hook (for Claude, into
`~/.claude/settings.json`) that reports the agent's own session id to Herdr via
`pane.report_agent_session`. That id surfaces as `agent_session.value` in the
snapshot, and it is the **only** key linking a Herdr pane to the agent's
transcript file on disk — Claude's `~/.claude/projects/` store records no pane,
tab, or workspace id, so there is nothing else to join on.

Without the integration, `agent_session` is `null` and the bridge can only match
transcripts by working directory. Two agents in one directory then become
indistinguishable and both resolve to the same file, so the app shows one agent's
conversation under another. Prompt routing is unaffected (that goes by `pane_id`),
which makes the symptom look stranger than it is: you type to the right agent but
read the wrong chat.

Two things to know about the hook:

- It fires **only when an agent session starts.** Installing it does not fix
  already-running panes — restart the agent in each one.
- It exits silently unless `HERDR_ENV=1`, `HERDR_SOCKET_PATH`, and
  `HERDR_PANE_ID` are set and `python3` is on `PATH`. All four hold inside a
  Herdr pane; an agent launched outside Herdr reports nothing.

Verify with `herdr api snapshot` — every agent should carry a non-null
`agent_session`.

Where each agent keeps its transcript, and therefore what the session id is
looked up against:

| Agent | Store | Resolved by |
|---|---|---|
| `claude` | `~/.claude/projects/<encoded-cwd>/<session>.jsonl` | cwd + session id |
| `pi` | `~/.pi/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl` | session id (full path) + cwd |
| `hermes` | `~/.hermes/state.db` (SQLite; `$HERMES_DIR` overrides) | session id |
| `opencode` | OpenCode v2 managed service API (`~/.local/state/opencode/service.json`; legacy SQLite fallback at `~/.local/share/opencode/opencode.db`) | session id + cwd |
| `codex` | recognized, not yet wired | — |

