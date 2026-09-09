# Push notifications

Full setup for FCM: bridge credentials, and the per-fork Firebase project the
app needs. Referenced from the README.

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

## App side: bring your own Firebase

FCM binds the **native** app binary to one Firebase project (the sender ID is
compiled into `google-services.json`), so every fork needs its own project —
the repo commits only `.example` templates with inert `YOUR_*` placeholders,
and the real files are gitignored, so `git status` stays clean and real values
can't be committed by accident:

- `app/android/app/google-services.json` (+ `.example`)
- `app/lib/core/firebase_web_options.dart` (+ `.example`, fallback only)
- `internal/web/assets/firebase-messaging-sw.js` (+ `.example` — must agree
  with the Dart options, or the service worker mints tokens the page can't use)
- `internal/web/assets/push-test.html` (+ `.example`, the bridge-served test
  receiver)
- `$GOTHALO_DIR/firebase-web.json` (no example — written by the script,
  served by the bridge, never in the repo)

The **web** app is not bound at build time: a generically-built web client
(the published build at `/gothalo/app/`, a custom domain, the bridge-served
PWA) fetches its bridge's project at pair time from `GET /firebase-config` and
initialises Firebase against it, with the service worker reading the same
values from IndexedDB. One web build works against any bridge; each bridge
keeps serving its own project. Native keeps the compiled-in path exactly as
before.

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

## Serving the web app elsewhere

Nothing to allowlist. FCM web push asks only for HTTPS, the VAPID key, a
reachable `firebase-messaging-sw.js`, and notification permission — the
project values and VAPID key arrive from the bridge at pair time, so any
origin works as-is.

(Firebase's *Authorized domains* list is an Authentication feature — an OAuth
redirect allowlist. gothalo doesn't use Firebase Auth, so it plays no part
here.)

Two things that do bite:

- **The worker must be reachable from the page's base href.** Under a subpath
  (the published app is at `/<repo>/app/`, the site itself at `/<repo>/`) it
  lives beside `index.html`, and its push scope covers that subtree — which is
  where the app is, and no wider, so the docs are outside it.
- **API key referrer restrictions.** If you restricted the browser API key in
  the Google Cloud console (APIs & Services → Credentials), every origin you
  serve from has to be on that list. An unrestricted key needs nothing.

