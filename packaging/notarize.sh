#!/bin/bash
#
# Notarize the release DMG and staple the ticket to it. Stapled, the image
# passes Gatekeeper even offline. The image then gives the same
# double-click-and-drag experience as any commercial Mac app. macOS 15+ blocks
# un-notarized downloads outright, so this step is part of every release. It is
# not an option.
#
# One-time setup. This stores an app-specific password in your keychain:
#
#   1. Create an app-specific password at https://appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords)
#   2. xcrun notarytool store-credentials patchthrough-notary \
#        --apple-id "you@example.com" \
#        --team-id U3W37KR29G \
#        --password "xxxx-xxxx-xxxx-xxxx"
#
# Then:  ./packaging/notarize.sh dist/Patchthrough-arm64.dmg
#
# Notarization requires the hardened runtime, which make-app.sh enables along
# with packaging/patchthrough.entitlements. If you ever change those signing
# flags, RE-TEST an actual recording: the hardened runtime denies microphone
# access without the audio-input entitlement, and that failure is silent.

set -euo pipefail

PROFILE="patchthrough-notary"
DMG="${1:-}"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ -n "$DMG" ] || fail "usage: $0 dist/Patchthrough-arm64.dmg"
[ -f "$DMG" ] || fail "no such file: $DMG"

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "no stored credentials named '$PROFILE'.
Run the store-credentials command in the header of this script first."

say "submitting $DMG. This usually takes a few minutes…"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$PROFILE" \
  --wait

say "stapling the ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" || fail "staple did not validate"

# Stapling rewrites the image, so any checksum computed before this point is
# now wrong. Refresh it.
if [ -f "$DMG.sha256" ]; then
  SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  printf '%s  %s\n' "$SHA" "$(basename "$DMG")" > "$DMG.sha256"
  say "checksum refreshed: $SHA"
fi

echo
say "verify like a user would:"
echo "  spctl -a -vv -t open --context context:primary-signature $DMG"
