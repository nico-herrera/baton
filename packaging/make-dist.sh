#!/bin/bash
#
# Build the release artifact: a tarball of the signed Patchthrough.app plus
# checksums, ready to attach to a GitHub release. This is what the npm
# installer and the manual download both pull.
#
#   ./packaging/make-dist.sh 1.0.1
#
# Produces:
#   dist/patchthrough-<version>-darwin-arm64.tar.gz
#   dist/patchthrough-<version>-darwin-arm64.tar.gz.sha256

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   e.g. $0 1.0.1" >&2; exit 1; }

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

TRACKED_DIRTY="$(git status --porcelain --untracked-files=no)"
RELEASE_UNTRACKED="$(git ls-files --others --exclude-standard -- \
  Package.swift Package.resolved Sources packaging)"
if [ -n "$TRACKED_DIRTY" ] || [ -n "$RELEASE_UNTRACKED" ]; then
  fail "release inputs are dirty — commit them first so the release matches a real commit:
${TRACKED_DIRTY}${RELEASE_UNTRACKED:+
untracked release inputs:
$RELEASE_UNTRACKED}"
fi

# Build + sign the bundle (make-app.sh also installs locally, which is fine).
say "building the app bundle…"
PATCHTHROUGH_VERSION="$VERSION" ./packaging/make-app.sh >/dev/null 2>&1 \
  || fail "make-app.sh failed — run it directly to see why"

APP="dist/patchthrough.app"
[ -d "$APP" ] || fail "no bundle at $APP"

# Refuse to ship an unsigned or wrongly-signed bundle: the npm installer
# verifies the Team ID, so an unsigned artifact would fail on every machine.
codesign --verify --strict "$APP" 2>/dev/null || fail "bundle is not validly signed"
TEAM="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/ && !seen { print $2; seen=1 }')"
[ "$TEAM" = "DAB6FR7R2R" ] || fail "unexpected Team ID '$TEAM'"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUNDLE_VERSION" = "$VERSION" ] \
  || fail "bundle version '$BUNDLE_VERSION' does not match release version '$VERSION'"
say "signed by Team $TEAM"
say "bundle version $BUNDLE_VERSION"

NAME="patchthrough-$VERSION-darwin-arm64"
TARBALL="dist/$NAME.tar.gz"

# --no-mac-metadata keeps AppleDouble ._ files out, which otherwise break
# checksum reproducibility on the other end.
say "packaging…"
tar --no-mac-metadata -czf "$TARBALL" -C dist "patchthrough.app"
shasum -a 256 "$TARBALL" | awk '{print $1}' > "$TARBALL.sha256"

SHA="$(cat "$TARBALL.sha256")"

# Keep the npm version, release tag, filename, checksum, and signer together.
# This intentionally leaves the two metadata files changed so they can be
# reviewed before the release is created and npm is published.
node packaging/npm/prepare-release.js "$VERSION" "$SHA"
(cd packaging/npm && npm pack --dry-run >/dev/null)

echo
say "→ $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
echo "  sha256: $SHA"
say "→ npm metadata verified for $VERSION"
echo
say "next:"
echo "  1. review and commit packaging/npm/package.json + artifact.json"
echo "  2. gh release create v$VERSION $TARBALL $TARBALL.sha256 \\"
echo "       --repo nico-herrera/patchthrough --title \"Patchthrough $VERSION\" --notes '…'"
echo "  3. (cd packaging/npm && npm publish)  # re-verifies the public release first"
