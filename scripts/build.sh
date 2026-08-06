#!/usr/bin/env bash
#
# Build the gothalo bridge, with the Flutter web UI compiled into the binary.
#
#   ./scripts/build.sh                  bridge + web UI
#   ./scripts/build.sh --no-web         bridge only (fast; leaves any existing UI in place)
#   ./scripts/build.sh --tailscale      also publish it over the tailnet with TLS
#
# WHY THE WEB UI IS EMBEDDED
#
# The bridge serves its static site from `//go:embed assets`, so one binary
# carries both halves and `go install` keeps working. It also makes a version
# skew between bridge and UI impossible — they ship as one artifact, so a client
# can never be older than the API it is talking to.
#
# The generated files are NOT committed: go:embed reads the working tree, so a
# fresh clone embeds only the hand-written files and serves no app until this
# script has run. That keeps several megabytes of canvaskit and wasm out of the
# history at the cost of one build step.
#
# WHY TAILSCALE MATTERS MORE THAN IT LOOKS
#
# A browser withholds service workers and OPFS outside a secure context, so over
# plain http the UI loses push and its local database — and the failures do not
# announce themselves as "no TLS". They look like an unreachable bridge and a
# database that forgets. `tailscale serve` terminates TLS with a real
# certificate, which is why --tailscale exists rather than a note in the README.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_WEB=1
SETUP_TAILSCALE=0
OUT="gothalo"
# Defaults match the README's; overridden below by ~/.gothalo/config.json when
# it exists, so the serve mapping points at wherever this host actually listens.
BRIDGE_ADDR="127.0.0.1:8788"
SERVE_PORT="5338"

info() { printf '\033[0;36m→\033[0m %s\n' "$1"; }
ok()   { printf '\033[0;32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33m!\033[0m %s\n' "$1"; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-web)     BUILD_WEB=0 ;;
    --tailscale)  SETUP_TAILSCALE=1 ;;
    --out)        OUT="$2"; shift ;;
    --port)       SERVE_PORT="$2"; shift ;;
    -h|--help)    sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown flag: $1 (try --help)" ;;
  esac
  shift
done

# Prefer the address this host is actually configured to listen on. A serve
# mapping pointing at the wrong port fails in a way that looks like the bridge
# being down.
CFG="${GOTHALO_DIR:-$HOME/.gothalo}/config.json"
if [ -f "$CFG" ] && command -v python3 >/dev/null 2>&1; then
  FOUND=$(python3 -c "
import json,sys
try:
    print(json.load(open('$CFG')).get('transport',{}).get('addr',''))
except Exception:
    print('')
" 2>/dev/null || true)
  [ -n "$FOUND" ] && BRIDGE_ADDR="$FOUND"
fi

# ---- web UI ---------------------------------------------------------------

ASSETS="internal/web/assets"

if [ "$BUILD_WEB" = "1" ]; then
  command -v flutter >/dev/null 2>&1 || die "flutter not found — install it, or build the bridge alone with --no-web"

  info "building the web UI (flutter build web --release)"
  ( cd app && flutter build web --release >/dev/null )

  # Copy the build in WITHOUT clobbering the hand-written files that live
  # alongside it. firebase-messaging-sw.js must sit at the site root to hold
  # push scope over the whole origin, and it is not part of the Flutter output;
  # push-test.html is the standalone receiver page kept for diagnosing FCM
  # without the app in the way.
  info "embedding it into $ASSETS"
  find "$ASSETS" -mindepth 1 -maxdepth 1 \
    ! -name 'firebase-messaging-sw.js' \
    ! -name 'push-test.html' \
    -exec rm -rf {} +
  # -a preserves the tree; the trailing slash copies contents, not the directory.
  cp -a app/build/web/. "$ASSETS"/

  ok "web UI embedded ($(du -sh "$ASSETS" | cut -f1))"
else
  info "skipping the web UI (--no-web)"
fi

# ---- bridge ---------------------------------------------------------------

info "building the bridge"
go build -o "$OUT" ./cmd/gothalo
ok "built ./$OUT ($(du -h "$OUT" | cut -f1))"

# ---- tailscale ------------------------------------------------------------

if [ "$SETUP_TAILSCALE" = "1" ]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    warn "tailscale not installed — skipping. The UI will still work over http,"
    warn "but without TLS the browser disables push and persistent storage."
  else
    # HTTPS certificates are a TAILNET setting, not a local one, and serve
    # --https fails without them. CertDomains is empty until the feature is
    # switched on in the admin console, so check before trying — a failure here
    # otherwise reads as "serve is broken" when the fix is one toggle on a
    # website.
    CERT_DOMAINS=$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
try:
    print(','.join(json.load(sys.stdin).get('CertDomains') or []))
except Exception:
    print('')
" 2>/dev/null || true)

    if [ -z "$CERT_DOMAINS" ]; then
      warn "HTTPS certificates are not enabled for this tailnet."
      warn "Enable them once, then re-run with --tailscale:"
      warn "  https://login.tailscale.com/admin/dns  →  HTTPS Certificates → Enable"
      warn ""
      warn "Without TLS the UI still loads, but the browser withholds service"
      warn "workers and persistent storage — so push does not work and the local"
      warn "database silently forgets. Neither failure names TLS as the cause."
    else
      TARGET="http://${BRIDGE_ADDR}"
      if tailscale serve status 2>/dev/null | grep -q "proxy ${TARGET}$"; then
        ok "tailscale serve already points at ${TARGET}"
      else
        info "publishing ${TARGET} on :${SERVE_PORT} as ${CERT_DOMAINS}"
        # --bg keeps it configured across restarts instead of living for the
        # lifetime of this shell. Errors are shown, not swallowed: the useful
        # ones name a port already in use or a missing capability.
        if ERR=$(tailscale serve --bg --https="${SERVE_PORT}" "${TARGET}" 2>&1); then
          ok "published"
        else
          warn "tailscale serve failed:"
          printf '    %s\n' "$ERR" | head -4
          warn "run it yourself once the cause is clear:"
          warn "  tailscale serve --bg --https=${SERVE_PORT} ${TARGET}"
        fi
      fi
    fi
    URL=$(tailscale serve status 2>/dev/null | grep -oE 'https://[^ ]+' | head -1 || true)
    [ -n "$URL" ] && ok "open on your phone: $URL"
  fi
fi

echo
ok "done — start it with ./$OUT serve"
[ "$SETUP_TAILSCALE" = "1" ] || info "tip: --tailscale publishes it with TLS, which the web UI needs for push"
