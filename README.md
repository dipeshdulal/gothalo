# gothalo

[![ci](https://github.com/dipeshdulal/gothalo/actions/workflows/ci.yml/badge.svg)](https://github.com/dipeshdulal/gothalo/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A self-hosted mobile remote for [Herdr](https://getmoshi.app/docs/herdr) — control your
coding agents (Claude Code, Codex, Gemini, Cursor, …) from your phone: see which
agents are blocked/working/done, get pushed when one needs you, approve or type a
reply, and drop into a full terminal — all over your own Tailscale network.

## Why this exists

Herdr exposes an open, documented socket API for driving agent sessions. gothalo is
a small self-hosted client on top of it — a Go bridge plus a Flutter app — shaped
around how my team actually works, and kept on our own Tailscale network so session
data and terminal traffic never leave it.

It's built for me and a few teammates rather than as a product, and it is shared
in that spirit: **Android and web today, no iOS**, and push needs a Firebase
project of your own (see [below](#app-side-bring-your-own-firebase)). If you want
a polished, supported mobile client for Herdr, look at
[Moshi](https://getmoshi.app), which is considerably more capable than this.

MIT licensed — fork it, run it, change it.

## Architecture

```
  Phone app (Flutter)                  Mac Studio (Herdr host)
  ┌──────────────────┐                 ┌────────────────────────────┐
  │  inbox / approve │                 │  gothalo (Go binary)       │
  │  live terminal   │  ── WSS/HTTPS ─▶│   GET  /snapshot           │
  │  xterm.dart      │   over tailnet  │   POST /send /approve      │
  │  key row + FCM   │                 │   WS   /attach  /events    │
  └────────┬─────────┘                 │   watcher: agent wait ──┐  │
           ▲                           └──────────┼─────────────┼───┘
           │                                      │ herdr socket│
           │                                      ▼             │
           │                           ┌────────────────────────┴──┐
           │                           │  Herdr (api/agent/pane)   │
           │                           └───────────────────────────┘
           │  FCM push                            │ outbound
           └──────────── Firebase ◀───────────────┘  (blocked/done)
```

Two independent paths:

- **Interactive** (snapshot / type / terminal): phone → bridge over the
  **tailnet**. No public ports, no SSH on the phone. The tailnet *is* the auth
  boundary; a per-device bearer token lets us revoke a single phone.
- **Push** (notifications): the bridge reaches **outbound** to Firebase/FCM, so
  it works on any network with zero inbound exposure. A phone can't run
  `herdr agent wait` — the bridge does, and calls FCM on `blocked`/`done`.

Because Herdr normalizes ~20 agents *below* the API (`agent:"claude"`,
`agent:"codex"`, …) into a uniform `idle/working/blocked/done` model, the app is
agent-agnostic by construction — multi-agent support is basically free.

The bridge watches **every running Herdr session**, so pane ids that leave the
bridge are session-qualified (`<session>/<pane>`) when they aren't from the
default session.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Bridge | **Go** | Same as my other services; tiny; shells out to `herdr` |
| Transport | **Tailscale** | Already running; no port-forward, no public exposure |
| Push | **Firebase / FCM** | Free for a small team; outbound-only |
| App | **Flutter** | `xterm.dart` is a *native* terminal widget (RN would need xterm.js in a WebView) |
| Terminal | **xterm.dart** | Renders the `attach` stream; themes/fonts for free |

**Runs at zero recurring cost.** Herdr, Tailscale, FCM and the libraries are all
free at this scale. iOS is the only thing that would cost anything (an Apple
Developer account, $99/yr) and it is not built — the notification contract is
Android-only, and the app also runs as a PWA the bridge serves itself.

## Repo layout

The bridge is one Go binary (`gothalo`) that is both the daemon and the CLI.

```
gothalo/
├── cmd/gothalo/     thin entrypoint -> internal/cli
├── internal/        the bridge: cli · config · herdr · watcher · push · store ·
│                    pairing · server · transport · events · agentstate ·
│                    transcript · gitdiff · notify · web
├── app/             Flutter mobile app (lib/{core,data,features})
├── bruno/           Bruno HTTP collection for poking the API by hand
├── CONTRACT.md      WS /events — the unified event stream the app codes against
└── docs/
    ├── API.md            REST/WS surface the app codes against
    ├── ARCHITECTURE.md   package-by-package map of the binary
    ├── CONTRACT-*.md     per-feature contracts (agent state, diff, transcript, …)
    ├── ROADMAP.md        phased build order + status
    ├── DECISIONS.md      architecture decisions and their rationale
    ├── HANDOFF.md        carried-over scoping context
    └── TESTING.md        how to validate each layer with curl / a browser
```

Runtime state lives **outside** the repo, in `~/.gothalo` (override with
`$GOTHALO_DIR`): `config.json`, `devices.json`, and the FCM `serviceAccount.json`.
Nothing secret is committed.

## Install (bridge, on the Herdr host)

Build from source — there is no published release yet, so the installer below
has nothing to download until the first tag is cut:

```bash
go install github.com/dipeshdulal/gothalo/cmd/gothalo@latest
```

Once a release exists, one line fetches the right prebuilt binary for your
OS/arch and drops it (plus the `gothalo-service` helper) onto your PATH:

```bash
curl -fsSL https://raw.githubusercontent.com/dipeshdulal/gothalo/main/install.sh | sh
```

Then bring the bridge up and keep it running in the background, always:

```bash
gothalo serve            # start once: writes ~/.gothalo/config.json + an admin token
# edit ~/.gothalo/config.json → set transport.public_url (your tailnet HTTPS URL)

gothalo-service install  # supervise `gothalo serve` via launchd (macOS) / systemd (Linux):
                         # starts at login, restarts on crash, survives logout
gothalo pair             # QR-pair a phone

# from anything on the tailnet:
curl -H "Authorization: Bearer <admin-token>" http://<tailscale-ip>:8787/snapshot
```

`gothalo-service` also takes `start | stop | restart | status | logs | uninstall`.
Then build and install the Android app — see
[Push: bring your own Firebase](#app-side-bring-your-own-firebase) first, since
notifications are inert until you point the app at a Firebase project of
your own.

See `docs/TESTING.md` for the full ladder — you validate the whole backend
(including a real push landing on a device) before writing any app code.

## Prerequisites (on the Herdr host)

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
| `opencode` | `~/.local/share/opencode/opencode.db` (SQLite; `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME` override) | session id |
| `codex` | recognized, not yet wired | — |

## Quick start (on the Herdr host)

```bash
go build -o gothalo ./cmd/gothalo
./gothalo serve            # first run generates an admin token into ~/.gothalo/config.json
```

Defaults: `direct` transport bound to `127.0.0.1:8787`. Point it at the tailnet
and give the app a reachable base URL:

```bash
GOTHALO_ADDR=$(tailscale ip -4):8787 \
GOTHALO_PUBLIC_URL=https://<host>.<tailnet>.ts.net:8787 \
./gothalo serve
```

| Env var | Overrides |
|---|---|
| `GOTHALO_DIR` | data dir (default `~/.gothalo`) |
| `GOTHALO_ADDR` | direct bind address |
| `GOTHALO_MODE` | `direct` (active) or `relay` (stub) |
| `GOTHALO_PUBLIC_URL` | base URL embedded in the pairing QR |
| `GOTHALO_SERVICE_ACCOUNT` | path to the FCM service-account JSON |
| `GOTHALO_FCM_PROJECT` | Firebase project id to send pushes to |
| `GOTHALO_ADMIN_TOKEN` | admin token (else generated + persisted) |
| `WATCHER=poll` | fall back to the polling watcher |

The same values can live in `~/.gothalo/config.json`; env wins.

### Push notifications (optional)

The bridge runs fine without push credentials — everything works except
notifications, which fall back to logging. To turn them on:

```bash
gothalo push login --project <firebase-project-id>   # authenticate as yourself
gothalo push status                                  # what's in use, and can it send
```

`push login` wraps `gcloud auth application-default login` with the right
scopes. That matters: gcloud's default scope set does **not** include
`firebase.messaging`, and a token minted without it fails at send time with a
403 that looks like a permissions problem rather than a scope problem.

**Why not just share a service-account key.** A downloaded key is a shared
bearer secret — everyone holding the file is the same identity, rotating it
breaks everyone at once, and the audit log cannot say who sent what. With the
gcloud path each person authenticates as themselves, so the project owner grants
and revokes access per person in IAM and nobody copies a key around.

To let a teammate in, grant them **Firebase Cloud Messaging API Admin** on the
project — from the Firebase console (Project settings → Users and permissions)
or, for a narrower grant, GCP IAM with a custom role carrying only
`cloudmessaging.messages.create`. Both write the same IAM policy; the Firebase
console just offers a coarser set of roles.

Until then their `push status` reports the credential as valid but not permitted
— the one failure they cannot fix by logging in again.

**The grant takes up to a minute to take effect.** Measured at ~30s. Re-run
`gothalo push status` rather than concluding it is broken: a teammate who checks
the instant you grant access sees exactly the same "not allowed" message as one
you never granted, and there is nothing on their end that distinguishes the two.

Credentials are found by Google's Application Default Credentials search order,
first hit wins:

1. `push.service_account_path` in config (`GOTHALO_SERVICE_ACCOUNT`)
2. `$GOOGLE_APPLICATION_CREDENTIALS`
3. gcloud's `application_default_credentials.json` — what `push login` writes
4. the GCE/Cloud Run metadata server (no key material anywhere)

Both credential shapes are accepted. A service-account file names its own
project; user credentials name a *person*, so they need `push.project_id` —
which `push login` saves for you.

#### App side: bring your own Firebase

FCM binds the **app binary** to one Firebase project (the sender ID is compiled
in), so every fork needs its own project — the repo commits only `.example`
templates with inert `YOUR_*` placeholders, and the real files are gitignored,
so `git status` stays clean and real values can't be committed by accident:

- `app/android/app/google-services.json` (+ `.example`)
- `app/lib/core/firebase_web_options.dart` (+ `.example`)
- `internal/web/assets/firebase-messaging-sw.js` (+ `.example` — must agree
  with the Dart options, or the service worker mints tokens the page can't use)
- `internal/web/assets/push-test.html` (+ `.example`, the bridge-served test
  receiver)

Until configured, push stays silent: the app builds and runs, notifications
just never arrive. One script generates all four from your project:

```bash
./scripts/setup-firebase.sh [--project ID] [--vapid KEY]
```

It checks auth, creates/selects the project, enables the Cloud Messaging API,
registers the Android + web apps, runs `flutterfire configure`, and propagates
the values into the Dart options and the service worker. You'll paste one thing
by hand: the Web Push VAPID public key (Firebase console → Project settings →
Cloud Messaging → Web Push certificates → Generate key pair) — it has no CLI.
Then finish the bridge side above (`push login`, `push status`) and fire
`POST /testpush` to watch a real notification land.

A committed `.github/workflows/public-hygiene.yml` fails any PR that
reintroduces real project values or personal hostnames, so a fork can't
accidentally push against (or bill) someone else's project.

### Pair a phone

```bash
./gothalo pair             # prints a QR: {"url":…,"code":…}, one-time, ~5 min TTL
./gothalo devices list
./gothalo devices revoke <id>
```

The app POSTs `{code, device_name, fcm_token}` to `/pair` and gets back a
**per-device bearer** it sends as `Authorization: Bearer …` from then on.

### Poke it by hand

The **admin token** (from `~/.gothalo/config.json`) works as a bearer for every
endpoint plus the `/admin/*` routes — dev-only, but it means no app is needed:

```bash
TOKEN=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.gothalo/config.json")))["admin_token"])')
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/snapshot
```

WebSocket routes (`/attach`, `/events`) take the token as `?token=…` instead,
since WS clients can't always set headers. See `docs/API.md` for the full surface
and `CONTRACT.md` for the event stream.

## Releasing (maintainer)

Releases are cut by GoReleaser from a semver tag; GitHub Actions
(`.github/workflows/release.yml`) does the rest:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

This cross-compiles darwin/linux (amd64 + arm64), publishes a GitHub Release with
archives + `checksums.txt`, and generates the changelog. Dry-run locally with
`goreleaser release --snapshot --clean` (artifacts land in `dist/`).

## License

MIT — see [`LICENSE`](LICENSE).

Third-party assets keep their own terms: Inter and JetBrains Mono ship with
their SIL Open Font License texts in `app/assets/fonts/`, and the agent logos in
`app/assets/agents/` are their respective owners' trademarks, included to
identify the agents the app drives.
