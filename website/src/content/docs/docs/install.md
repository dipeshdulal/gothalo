---
title: Install
description: Install the gothalo bridge on your Herdr host, run it on the tailnet, pair a phone, and get the app as an APK or a PWA.
---

Everything here runs on the **Herdr host** — the machine your agents already live on.
One Go binary, `gothalo`, is both the daemon and the CLI.

## 1. Herdr agent integration

Install Herdr's agent integration for every agent you run. This is **required**, or the
transcript view shows one agent's conversation under another:

```bash
herdr integration install claude   # likewise: hermes, codex, opencode, …
```

Why, and where each agent keeps its transcript: [Agent integration](../guides/agent-integration/).

## 2. Install the bridge

macOS or Linux, from the [latest release](https://github.com/dipeshdulal/gothalo/releases):

```sh
curl -fsSL https://raw.githubusercontent.com/dipeshdulal/gothalo/main/install.sh | sh
```

The script detects your OS and architecture, downloads the matching release archive, and
verifies its SHA-256 against the release's `checksums.txt` before installing — best effort:
it needs `shasum` or `sha256sum` on the host and a `checksums.txt` on the release.

Or build from source:

```sh
go install github.com/dipeshdulal/gothalo/cmd/gothalo@latest
```

## 3. Run the bridge

```bash
go install github.com/dipeshdulal/gothalo/cmd/gothalo@latest

gothalo serve            # first run writes ~/.gothalo/config.json + an admin token
gothalo-service install  # supervise it via launchd (macOS) / systemd (Linux)
gothalo pair             # QR-pair a phone
```

It defaults to `127.0.0.1:8787`. Point it at the tailnet so the phone can reach it:

```bash
GOTHALO_ADDR=$(tailscale ip -4):8787 \
GOTHALO_PUBLIC_URL=https://<host>.<tailnet>.ts.net:8787 \
gothalo serve
```

Config lives in `~/.gothalo/config.json`; env wins. The main overrides are `GOTHALO_DIR`,
`GOTHALO_ADDR`, `GOTHALO_PUBLIC_URL`, `GOTHALO_ADMIN_TOKEN`, `GOTHALO_SERVICE_ACCOUNT` and
`GOTHALO_FCM_PROJECT`. Runtime state lives outside the repo in `~/.gothalo`
(`$GOTHALO_DIR`): `config.json`, `devices.json`, the FCM key.

## 4. Pair a phone

```bash
./gothalo pair             # prints a QR: {"url":…,"code":…}, one-time, ~5 min TTL
./gothalo devices list
./gothalo devices revoke <id>
```

The app POSTs `{code, device_name, fcm_token}` to `/pair` and gets back a **per-device
bearer** it sends as `Authorization: Bearer …` from then on. Revoking one device turns away
one phone without touching the others.

## 5. Get the app

Android, no packaged APK yet. Point it at your own Firebase project first
([Push](../guides/push/)), then build it:

```sh
./scripts/setup-firebase.sh --project <firebase-project-id>
cd app && flutter pub get && flutter build apk --release
```

Or skip the install entirely: a bridge built with `./scripts/build.sh` bakes the app in and
serves it as a **PWA** — open the bridge URL (`GOTHALO_PUBLIC_URL`, the same address the app
pairs to) in the phone's browser. The `install.sh` binary does not include the web UI yet.

## 6. Turn on push (optional)

Without credentials the bridge logs instead of notifying. Two steps — credentials for the
bridge, a Firebase project for the app:

```bash
gothalo push login --project <firebase-project-id>
./scripts/setup-firebase.sh --project <firebase-project-id>
```

Full walkthrough, including why every fork needs its own project: [Push](../guides/push/).
