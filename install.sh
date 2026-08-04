#!/bin/sh
# gothalo installer — downloads the latest release binary for this OS/arch and
# installs it (plus the gothalo-service helper) onto PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/dipeshdulal/gothalo/main/install.sh | sh
#
# Env overrides:
#   GOTHALO_VERSION=v0.1.0   pin a specific tag (default: latest release)
#   GOTHALO_INSTALL_DIR=...   install location (default: /usr/local/bin, else ~/.local/bin)
set -eu

REPO="dipeshdulal/gothalo"
VERSION="${GOTHALO_VERSION:-latest}"

info()  { printf '\033[0;36m→\033[0m %s\n' "$1"; }
ok()    { printf '\033[0;32m✓\033[0m %s\n' "$1"; }
die()   { printf '\033[0;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need uname; need tar; need mktemp
# Either curl or wget for downloads.
if command -v curl >/dev/null 2>&1; then DL="curl -fsSL"; DLO="curl -fsSL -o"; else
  command -v wget >/dev/null 2>&1 || die "need curl or wget"; DL="wget -qO-"; DLO="wget -qO"; fi

# ---- detect platform (must match .goreleaser.yaml archive name_template) ----
case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)  OS=linux ;;
  *) die "unsupported OS: $(uname -s) (build from source with: go install github.com/$REPO/cmd/gothalo@latest)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) die "unsupported arch: $(uname -m)" ;;
esac

# ---- resolve version ----
if [ "$VERSION" = "latest" ]; then
  info "resolving latest release…"
  VERSION="$($DL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)"
  [ -n "$VERSION" ] || die "could not resolve latest release — set GOTHALO_VERSION"
fi
info "installing gothalo $VERSION ($OS/$ARCH)"

# ---- download + verify + extract ----
ASSET="gothalo_${OS}_${ARCH}.tar.gz"
BASE="https://github.com/$REPO/releases/download/$VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

$DLO "$TMP/$ASSET" "$BASE/$ASSET" || die "download failed: $BASE/$ASSET"

# Checksum verification (best-effort: needs sha256 tooling + checksums.txt asset).
if $DLO "$TMP/checksums.txt" "$BASE/checksums.txt" 2>/dev/null; then
  if command -v shasum >/dev/null 2>&1; then SHA="shasum -a 256"; elif command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA=""; fi
  if [ -n "$SHA" ]; then
    want="$(grep " $ASSET\$" "$TMP/checksums.txt" | awk '{print $1}')"
    got="$(cd "$TMP" && $SHA "$ASSET" | awk '{print $1}')"
    [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for $ASSET"
    ok "checksum verified"
  fi
fi

tar -xzf "$TMP/$ASSET" -C "$TMP"
[ -f "$TMP/gothalo" ] || die "archive missing gothalo binary"

# ---- choose install dir (writable, else sudo, else ~/.local/bin) ----
DIR="${GOTHALO_INSTALL_DIR:-}"
if [ -z "$DIR" ]; then
  if [ -w /usr/local/bin ] 2>/dev/null; then DIR=/usr/local/bin
  elif [ -d /usr/local/bin ] && command -v sudo >/dev/null 2>&1; then DIR=/usr/local/bin; SUDO=sudo
  else DIR="$HOME/.local/bin"; fi
fi
SUDO="${SUDO:-}"
mkdir -p "$DIR" 2>/dev/null || true

install_one() {
  chmod +x "$TMP/$1"
  $SUDO cp "$TMP/$1" "$DIR/$1" || die "cannot write to $DIR (set GOTHALO_INSTALL_DIR)"
}
install_one gothalo
[ -f "$TMP/gothalo-service" ] && install_one gothalo-service

ok "installed gothalo → $DIR/gothalo"
"$DIR/gothalo" version 2>/dev/null || true

case ":$PATH:" in
  *":$DIR:"*) ;;
  *) info "add $DIR to PATH:  export PATH=\"$DIR:\$PATH\"" ;;
esac

cat <<EOF

Next:
  1. gothalo serve            # start once to generate ~/.gothalo/config.json + admin token
  2. edit ~/.gothalo/config.json — set transport.public_url (your tailnet HTTPS URL)
  3. gothalo-service install  # run the bridge in the background, always (launchd/systemd)
  4. gothalo pair             # QR-pair a phone
EOF
