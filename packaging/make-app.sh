#!/bin/bash
#
# Wrap the release binary in a minimal patchthrough.app bundle.
#
# Why a bundle at all, when the philosophy is single-binary: LaunchServices
# only reads identity (Dock label, Finder icon, TCC dialog name) from a
# bundle. A bare binary promoted to .regular shows a generic icon and the
# label "exec" in the Dock — a runtime NSApp.applicationIconImage fixes the
# picture but nothing can fix the name. The CLI stays a plain command via a
# symlink into the bundle, so both worlds keep working.
#
#   ./packaging/make-app.sh          build → dist/patchthrough.app
#   sudo installs are handled by the caller.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="Developer ID Application: Nico Herrera (DAB6FR7R2R)"
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

VERSION="0.1.0"
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
# prominent buttons from the bundle's compiled AccentColor — SwiftUI .tint
# alone cannot recolour sidebar selection.
actool packaging/design/Assets.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 \
  --output-partial-info-plist /dev/null >/dev/null

# --- sign ------------------------------------------------------------------

if security find-identity -v -p codesigning 2>/dev/null | grep -q "DAB6FR7R2R"; then
  say "signing bundle…"
  codesign --force --deep --sign "$IDENTITY" --timestamp "$APP"
  codesign --verify --strict "$APP" || fail "bundle signature failed to verify"
else
  say "no signing identity — bundle left unsigned"
fi

say "→ $APP"
# --- install ---------------------------------------------------------------
# ~/Applications and ~/.local/bin are user-owned, so updating never prompts
# for an admin password. That matters more than it sounds: this binary gets
# rebuilt often, and a password prompt per rebuild is the kind of friction
# that stops people from updating.

DEST="$HOME/Applications"
BINDIR="$HOME/.local/bin"
mkdir -p "$DEST" "$BINDIR"
rm -rf "$DEST/patchthrough.app"
cp -R "$APP" "$DEST/"
ln -sf "$DEST/patchthrough.app/Contents/MacOS/patchthrough" "$BINDIR/patchthrough"

say "installed → $DEST/patchthrough.app  (no password needed)"
echo "  CLI: $BINDIR/patchthrough"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) printf '\033[33m  ! %s is not on your PATH — add to ~/.zshrc:\n      export PATH="%s:$PATH"\033[0m\n' "$BINDIR" "$BINDIR" ;;
esac
echo
say "restart the daemon to pick it up:"
echo "  patchthrough install --launch-at-login"
