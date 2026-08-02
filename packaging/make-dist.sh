#!/bin/bash
#
# Build the release artifact: a signed disk image of Patchthrough.app plus a
# checksum, ready to attach to a GitHub release.
#
#   ./packaging/make-dist.sh 1.0.1
#
# Produces:
#   dist/Patchthrough-arm64.dmg
#   dist/Patchthrough-arm64.dmg.sha256
#
# The DMG name deliberately carries no version so the landing page can link
# straight to .../releases/latest/download/Patchthrough-arm64.dmg — one click,
# file downloads, like any commercial Mac app. The version lives in the release
# tag and in the bundle's Info.plist.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   e.g. $0 1.0.1" >&2; exit 1; }

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

IDENTITY="Developer ID Application: Nico Herrera (DAB6FR7R2R)"

TRACKED_DIRTY="$(git status --porcelain --untracked-files=no)"
RELEASE_UNTRACKED="$(git ls-files --others --exclude-standard -- \
  Package.swift Package.resolved Sources packaging)"
if [ -n "$TRACKED_DIRTY" ] || [ -n "$RELEASE_UNTRACKED" ]; then
  fail "release inputs are dirty — commit them first so the release matches a real commit:
${TRACKED_DIRTY}${RELEASE_UNTRACKED:+
untracked release inputs:
$RELEASE_UNTRACKED}"
fi

# make-app.sh degrades gracefully without actool so day-to-day builds work on a
# Command Line Tools-only machine. A release must not: check before the build
# rather than after, so a missing Xcode doesn't cost a full compile.
xcrun --find actool >/dev/null 2>&1 \
  || fail "actool not found — release builds need full Xcode, not just the
Command Line Tools. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"

# Build + sign the bundle (make-app.sh also installs locally, which is fine).
say "building the app bundle…"
PATCHTHROUGH_KEEP_DIST=1 PATCHTHROUGH_VERSION="$VERSION" ./packaging/make-app.sh >/dev/null 2>&1 \
  || fail "make-app.sh failed — run it directly to see why"

APP="dist/patchthrough.app"
[ -d "$APP" ] || fail "no bundle at $APP"

# Refuse to ship an unsigned or wrongly-signed bundle.
codesign --verify --strict "$APP" 2>/dev/null || fail "bundle is not validly signed"
TEAM="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/ && !seen { print $2; seen=1 }')"
[ "$TEAM" = "DAB6FR7R2R" ] || fail "unexpected Team ID '$TEAM'"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUNDLE_VERSION" = "$VERSION" ] \
  || fail "bundle version '$BUNDLE_VERSION' does not match release version '$VERSION'"

# Apple rejects notarization without the hardened runtime, and an un-notarized
# download is exactly the Gatekeeper warning this pipeline exists to avoid.
# Catch it here rather than after a round trip to Apple.
codesign -d --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime' \
  || fail "bundle is not signed with the hardened runtime — notarization would be rejected"
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | grep -q 'com.apple.security.device.audio-input' \
  || fail "bundle is missing the audio-input entitlement — the hardened runtime
would silently deny microphone access to every user"

say "signed by Team $TEAM"
say "bundle version $BUNDLE_VERSION"
say "hardened runtime + audio-input entitlement present"

DMG="dist/Patchthrough-arm64.dmg"

# A DMG rather than a tarball, for two reasons: double-click → drag to
# Applications is the install flow Mac users already know, and a DMG can carry
# a stapled notarization ticket, so Gatekeeper clears it even offline. A
# tarball can do neither.
say "building disk image…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Patchthrough" -srcfolder "$STAGE" \
  -ov -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
rm -rf "$STAGE"

# Sign the image itself so Gatekeeper can evaluate it before it is mounted.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$(basename "$DMG")" > "$DMG.sha256"

# The image is the deliverable; the loose bundle would otherwise linger in
# dist/ and get indexed as a duplicate app. See the KEEP_DIST note in
# make-app.sh.
rm -rf "$APP"

echo
say "→ $DMG  ($(du -h "$DMG" | cut -f1))"
echo "  sha256: $SHA"
echo
say "next:"
echo "  1. ./packaging/notarize.sh $DMG"
echo "     (not optional — an un-notarized download is blocked on macOS 15+."
echo "      Stapling changes the file, so notarize.sh refreshes the .sha256.)"
echo "  2. gh release create v$VERSION $DMG $DMG.sha256 \\"
echo "       --repo nico-herrera/patchthrough --title \"Patchthrough $VERSION\" --notes '…'"
