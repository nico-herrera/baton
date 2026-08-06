#!/bin/bash
#
# Wrap the release binary in a minimal patchthrough.app bundle.
#
# Why a bundle at all, when the philosophy is single-binary: LaunchServices
# only reads identity (Dock label, Finder icon, TCC dialog name) from a
# bundle. A bare binary promoted to .regular shows a generic icon and the
# label "exec" in the Dock. A runtime NSApp.applicationIconImage fixes the
# picture but nothing can fix the name. The npm CLI is a separate product and
# no longer points into this bundle.
#
#   ./packaging/make-app.sh          build → dist/patchthrough.app
#   PATCHTHROUGH_VERSION=1.2.3 ./packaging/make-app.sh
#   sudo installs are handled by the caller.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="Developer ID Application: Nico Herrera (U3W37KR29G)"
cd "$REPO"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

say "building…"
swift build -c release 2>&1 | tail -2
BIN=".build/release/patchthrough"
[ -x "$BIN" ] || fail "no binary at $BIN"

APP="dist/patchthrough.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- icon: render the in-code vector mark to a proper .icns ---------------

say "building icns from the approved Signal appiconset…"
ICONSET="$(mktemp -d)/patchthrough.iconset"
mkdir -p "$ICONSET"
for f in packaging/design/AppIcon-signal.appiconset/icon_*.png; do
  base="$(basename "$f")"
  cp "$f" "$ICONSET/${base/-at-2x/@2x}"   # iconutil expects @2x naming
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/patchthrough.icns"

# --- bundle plist ----------------------------------------------------------

VERSION="${PATCHTHROUGH_VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>patchthrough</string>
    <key>CFBundleIdentifier</key>       <string>com.nicoherrera.patchthrough</string>
    <key>CFBundleName</key>             <string>Patchthrough</string>
    <key>CFBundleDisplayName</key>      <string>Patchthrough</string>
    <key>CFBundleIconFile</key>         <string>patchthrough</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>          <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>   <string>15.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSAccentColorName</key>        <string>AccentColor</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Patchthrough records your microphone during meetings so you can transcribe them later. Audio never leaves this Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Patchthrough records system audio (the other side of your meetings) so you can transcribe them later. Audio never leaves this Mac.</string>
</dict>
</plist>
EOF

cp "$BIN" "$APP/Contents/MacOS/patchthrough"

# App accent colour (Signal). macOS takes sidebar selection, toggles and
# prominent buttons from the bundle's compiled AccentColor. SwiftUI .tint
# alone cannot recolour sidebar selection.
#
# actool ships with full Xcode, not the Command Line Tools. A CLT-only machine
# still produces a working bundle, it just inherits the system accent colour;
# make-dist.sh refuses to cut a release without it.
if xcrun --find actool >/dev/null 2>&1; then
  actool packaging/design/Assets.xcassets --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 15.0 \
    --output-partial-info-plist /dev/null >/dev/null
else
  say "actool needs full Xcode. Building without the compiled AccentColor"
fi

# --- sign ------------------------------------------------------------------
# --options runtime is what makes the bundle notarizable: Apple rejects any
# submission without the hardened runtime. That runtime then denies microphone
# access unless the audio-input entitlement is present, and denies it silently,
# so these two flags have to travel together or recordings come back empty.
#
# No --deep: Apple deprecated it, and this bundle has no nested code to reach.

if security find-identity -v -p codesigning 2>/dev/null | grep -q "U3W37KR29G"; then
  say "signing bundle…"
  codesign --force --sign "$IDENTITY" --timestamp \
    --options runtime \
    --entitlements packaging/patchthrough.entitlements \
    "$APP"
  codesign --verify --strict "$APP" || fail "bundle signature failed to verify"
else
  say "no signing identity. Bundle left unsigned"
fi

say "→ $APP"
# --- install ---------------------------------------------------------------
# ~/Applications is user-owned, so updating never prompts for an admin
# password. The standalone npm CLI owns the `patchthrough` shell command.

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/patchthrough.app"
cp -R "$APP" "$DEST/"

# Clean up only the symlink created by older app builds. Never remove a real
# npm-installed command or a symlink owned by something else.
LEGACY_CLI="$HOME/.local/bin/patchthrough"
if [ -L "$LEGACY_CLI" ] && [ "$(readlink "$LEGACY_CLI")" = "$DEST/patchthrough.app/Contents/MacOS/patchthrough" ]; then
  rm "$LEGACY_CLI"
fi

# Launch Services indexes every bundle it can see, so a build copy left in
# dist/ shows up as a second Patchthrough in Launchpad and Spotlight: same
# icon, same bundle ID, listed under its filename instead of its display name.
# An unregister does not stick, because the directory watcher re-adds it. So the
# build copy has to go. make-dist.sh sets KEEP_DIST because it packages this
# exact bundle, and deletes it itself once the tarball exists.
if [ "${PATCHTHROUGH_KEEP_DIST:-0}" != "1" ]; then
  rm -rf "$APP"
fi

say "installed → $DEST/patchthrough.app  (no password needed)"
echo
say "Open Patchthrough from ~/Applications."
echo "  Launch at login can be enabled in Patchthrough Settings."
