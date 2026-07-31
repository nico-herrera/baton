#!/bin/bash
#
# Build, sign, and package baton for installing on another Mac.
# Produces dist/baton-local-<sha>-arm64.tar.gz
#
#   ./packaging/make-release.sh
#   ./packaging/make-release.sh --no-sign     skip codesigning
#
# Signing uses your Developer ID so the binary has a stable identity that
# TCC and Gatekeeper recognize. Notarization is a separate optional step —
# see packaging/notarize.sh.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="Developer ID Application: Nico Herrera (DAB6FR7R2R)"
SIGN=1
[ "${1:-}" = "--no-sign" ] && SIGN=0

cd "$REPO"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || fail "working tree is dirty — commit first so the
version stamp matches what's actually in the tarball:
$(git status --short)"

SHA="$(git rev-parse --short HEAD)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

say "building release binary…"
swift build -c release 2>&1 | tail -3
BIN=".build/release/baton"
[ -x "$BIN" ] || fail "build produced no binary"

NAME="baton-local-$SHA-arm64"
PKG="$STAGE/$NAME"
mkdir -p "$PKG"
cp "$BIN" "$PKG/baton"
cp packaging/install.sh "$PKG/install.sh"
chmod 755 "$PKG/install.sh"

# --- sign ------------------------------------------------------------------

if [ "$SIGN" -eq 1 ]; then
  say "signing…"
  codesign --force --sign "$IDENTITY" --timestamp \
           --identifier com.nicoherrera.baton "$PKG/baton"
  codesign --verify --strict "$PKG/baton" || fail "signature failed to verify"
  codesign -dvv "$PKG/baton" 2>&1 | grep -E "^Authority=|^TeamIdentifier=" | sed 's/^/  /'
else
  say "skipping signing (--no-sign)"
fi

# --- provenance ------------------------------------------------------------

BASE="$(git rev-parse --short origin/main 2>/dev/null || echo unknown)"
cat > "$PKG/VERSION" <<EOF
baton

built:            $(date -u '+%Y-%m-%d %H:%M:%SZ')
branch:           $(git branch --show-current)
commit:           $(git rev-parse HEAD)
pushed base:      $BASE  (nico-herrera/baton main)
local commits not yet pushed:
$(git log --oneline --no-decorate origin/main..HEAD 2>/dev/null | sed 's/^/  /')

built on:         macOS $(sw_vers -productVersion), $(swift --version 2>&1 | head -1)
target:           arm64, macOS 15+
EOF

( cd "$PKG" && shasum -a 256 baton install.sh > SHA256SUMS )

cp README.md "$PKG/README.md"

# --- tar -------------------------------------------------------------------

mkdir -p dist
TARBALL="dist/$NAME.tar.gz"
# --no-mac-metadata keeps AppleDouble ._ files out of the archive; they confuse
# checksum verification on the other end.
tar --no-mac-metadata -czf "$TARBALL" -C "$STAGE" "$NAME"
shasum -a 256 "$TARBALL" > "$TARBALL.sha256"

echo
say "→ $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
cat "$TARBALL.sha256"
echo
say "contents:"
tar -tzf "$TARBALL" | sed 's/^/  /'
echo
say "to install on the other Mac:"
echo "  tar -xzf $NAME.tar.gz && cd $NAME && ./install.sh"
