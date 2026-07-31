#!/bin/bash
#
# Optional: notarize the signed binary so Gatekeeper stops complaining and the
# installer no longer has to strip a quarantine flag. Worth doing if the target
# is a managed laptop where you'd rather not explain why you're deleting an
# xattr.
#
# One-time setup — stores an app-specific password in your keychain:
#
#   1. Create an app-specific password at https://appleid.apple.com
#      (Sign-In and Security → App-Specific Passwords)
#   2. xcrun notarytool store-credentials patchthrough-notary \
#        --apple-id "you@example.com" \
#        --team-id DAB6FR7R2R \
#        --password "xxxx-xxxx-xxxx-xxxx"
#
# Then:  ./packaging/notarize.sh dist/patchthrough-local-<sha>-arm64.tar.gz
#
# Note: notarization requires the hardened runtime, which this build does NOT
# currently enable. If Apple rejects the submission for that reason, add
#   --options runtime --entitlements packaging/patchthrough.entitlements
# to the codesign call in make-release.sh, rebuild, and RE-TEST a recording:
# hardened runtime denies microphone access unless the audio-input entitlement
# is present, and that failure is silent.

set -euo pipefail

PROFILE="patchthrough-notary"
TARBALL="${1:-}"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ -n "$TARBALL" ] || fail "usage: $0 dist/patchthrough-local-<sha>-arm64.tar.gz"
[ -f "$TARBALL" ] || fail "no such file: $TARBALL"

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "no stored credentials named '$PROFILE'.
Run the store-credentials command in the header of this script first."

say "submitting $TARBALL — this usually takes a few minutes…"
xcrun notarytool submit "$TARBALL" \
  --keychain-profile "$PROFILE" \
  --wait

echo
say "A tarball can't carry a notarization ticket (only .app/.dmg/.pkg can be"
say "stapled). The notarization is still recorded against the binary's hash,"
say "so Gatekeeper will accept it once Apple's check propagates."
echo
say "verify with:"
echo "  tar -xzf $TARBALL -C /tmp && spctl -a -vvv -t install /tmp/\$(basename ${TARBALL%.tar.gz})/patchthrough"
