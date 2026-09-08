#!/usr/bin/env bash
# Bring-your-own-Firebase setup for gothalo push.
#
# FCM binds the APP BINARY to one Firebase project (sender ID compiled in), so
# every fork needs its own project. This script wires the four app-side files
# from your project, all of which are committed as inert YOUR_* placeholders:
#   - app/android/app/google-services.json        (via `flutterfire configure`)
#   - app/lib/core/firebase_web_options.dart      (propagated from the above)
#   - internal/web/assets/firebase-messaging-sw.js (same project, must agree)
#   - internal/web/assets/push-test.html          (bridge-served test receiver)
#
# Usage:
#   ./scripts/setup-firebase.sh [--project ID] [--vapid KEY] [--package NAME]
#
# Prereqs: firebase-tools (`npm i -g firebase-tools`), flutterfire_cli
# (`dart pub global activate flutterfire_cli`), python3. gcloud is optional —
# without it you enable the FCM API in the console when told to.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
PACKAGE="com.dipeshdulal.gothalo"
PROJECT=""
VAPID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --vapid) VAPID="$2"; shift 2 ;;
    --package) PACKAGE="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ($2)" >&2; exit 1; }; }
need firebase "npm i -g firebase-tools"
need python3 ""
if ! command -v flutterfire >/dev/null 2>&1; then
  echo "missing: flutterfire (dart pub global activate flutterfire_cli)" >&2; exit 1
fi

echo "==> checking Firebase auth"
firebase projects:list >/dev/null || { echo "run: firebase login" >&2; exit 1; }

if [[ -z "$PROJECT" ]]; then
  echo "Your Firebase projects:"
  firebase projects:list
  read -rp "Use project ID (or a new ID to create): " PROJECT
fi

if ! firebase projects:list 2>/dev/null | grep -q "$PROJECT"; then
  read -rp "Project '$PROJECT' not found. Create it? [y/N] " ans
  [[ "$ans" == [yY]* ]] || exit 1
  firebase projects:create "$PROJECT"
fi

echo "==> enabling Cloud Messaging API"
if command -v gcloud >/dev/null 2>&1; then
  gcloud services enable fcm.googleapis.com --project="$PROJECT" 2>/dev/null || true
else
  echo "    (no gcloud; if sends later 403, enable 'Cloud Messaging API' for $PROJECT in the GCP console)"
fi

echo "==> registering Android + web apps"
if ! firebase apps:list --project "$PROJECT" 2>/dev/null | grep -qi android; then
  firebase apps:create android gothalo-android --package-name "$PACKAGE" --project "$PROJECT"
fi
if ! firebase apps:list --project "$PROJECT" 2>/dev/null | grep -qi "web"; then
  firebase apps:create web gothalo-web --project "$PROJECT"
fi

echo "==> running flutterfire configure (writes google-services.json)"
cd "$APP"
flutterfire configure --yes --project="$PROJECT" --platforms=android,web

echo "==> generating app-side config from .example templates"
for pair in "app/lib/core/firebase_web_options.dart" "internal/web/assets/firebase-messaging-sw.js" "internal/web/assets/push-test.html"; do
  if [[ ! -f "$ROOT/$pair" ]]; then
    cp "$ROOT/$pair.example" "$ROOT/$pair"
    echo "    created $pair"
  fi
done

echo "==> propagating values into web options + service worker"
if [[ -z "$VAPID" ]]; then
  echo "VAPID public key: Firebase console → Project settings → Cloud Messaging"
  echo "→ Web Push certificates → Generate key pair, then paste the public key."
  read -rp "VAPID public key: " VAPID
fi

python3 - "$ROOT" "$VAPID" <<'EOF'
import re, sys, json
root, vapid = sys.argv[1], sys.argv[2]

opts = open(f"{root}/app/lib/firebase_options.dart").read()
def grab(name):
    m = re.search(rf"{name}\s*:\s*'([^']+)'", opts)
    assert m, f"{name} not found in firebase_options.dart"
    return m.group(1)
web = {k: grab(k) for k in
       ["apiKey", "authDomain", "projectId", "storageBucket", "messagingSenderId", "appId"]}

dart = open(f"{root}/app/lib/core/firebase_web_options.dart").read()
for k, v in {**web, "YOUR_VAPID_PUBLIC_KEY": vapid}.items():
    dart = dart.replace(k if k.startswith("YOUR_") else {
        "apiKey": "YOUR_WEB_API_KEY", "authDomain": "YOUR_PROJECT_ID.firebaseapp.com",
        "projectId": "YOUR_PROJECT_ID", "storageBucket": "YOUR_PROJECT_ID.firebasestorage.app",
        "messagingSenderId": "YOUR_SENDER_ID", "appId": "YOUR_WEB_APP_ID"}[k], v)
open(f"{root}/app/lib/core/firebase_web_options.dart", "w").write(dart)

swmap = {"YOUR_WEB_API_KEY": web["apiKey"],
         "YOUR_PROJECT_ID": web["projectId"],
         "YOUR_SENDER_ID": web["messagingSenderId"],
         "YOUR_WEB_APP_ID": web["appId"]}
sw = open(f"{root}/internal/web/assets/firebase-messaging-sw.js").read()
for ph, v in swmap.items():
    sw = sw.replace(ph, v)
open(f"{root}/internal/web/assets/firebase-messaging-sw.js", "w").write(sw)

pt = open(f"{root}/internal/web/assets/push-test.html").read()
for ph, v in {**swmap, "YOUR_VAPID_PUBLIC_KEY": vapid}.items():
    pt = pt.replace(ph, v)
open(f"{root}/internal/web/assets/push-test.html", "w").write(pt)

gs = json.load(open(f"{root}/app/android/app/google-services.json"))
assert gs["project_info"]["project_id"] == web["projectId"], "google-services.json project mismatch"
print(f"    project: {web['projectId']}")
EOF

echo
echo "App side done. Bridge side (per person, on the Herdr host):"
echo "  gothalo push login --project $PROJECT"
echo "  gothalo push status   # valid + permitted before going further"
echo "Then pair a phone and hit POST /testpush to watch a real notification land."
