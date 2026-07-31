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

say "rendering icon…"
ICONSET="$(mktemp -d)/patchthrough.iconset"
mkdir -p "$ICONSET"
cat > /tmp/pt-render-icns.swift <<'EOF'
import AppKit
// Must match Sources/patchthrough/UI/AppIcon.swift.
func icon(_ side: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
        let s = side / 1024.0
        let inset = 100 * s
        let plate = NSRect(x: inset, y: inset, width: side - inset*2, height: side - inset*2)
        let radius = plate.width * 0.225
        NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
        let hl = NSBezierPath(roundedRect: plate.insetBy(dx: 3*s, dy: 3*s), xRadius: radius-3*s, yRadius: radius-3*s)
        NSColor.white.withAlphaComponent(0.06).setStroke(); hl.lineWidth = 6*s; hl.stroke()
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let u = plate.width / 24.0
            return NSPoint(x: plate.minX + x*u, y: plate.minY + (24.0 - y)*u)
        }
        let bar = NSBezierPath(); bar.move(to: pt(8.5,15.5)); bar.line(to: pt(19,5))
        bar.lineWidth = 2.4 * plate.width/24.0; bar.lineCapStyle = .round
        NSColor.white.setStroke(); bar.stroke()
        let accent = NSColor(calibratedRed: 0.91, green: 0.45, blue: 0.32, alpha: 1)
        for (f,t) in [((5.0,12.0),(3.0,14.0)), ((9.0,16.0),(7.0,18.0)), ((13.0,20.0),(11.5,21.5))] {
            let tick = NSBezierPath(); tick.move(to: pt(f.0,f.1)); tick.line(to: pt(t.0,t.1))
            tick.lineWidth = 2.0 * plate.width/24.0; tick.lineCapStyle = .round
            accent.setStroke(); tick.stroke()
        }
        return true
    }
}
let outDir = CommandLine.arguments[1]
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
                   (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),
                   (512,"512x512"),(1024,"512x512@2x")] {
    let img = icon(CGFloat(px))
    var rect = NSRect(x: 0, y: 0, width: px, height: px)
    guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: px, height: px)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
print("iconset written")
EOF
swift /tmp/pt-render-icns.swift "$ICONSET"
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
    <key>CFBundleName</key>             <string>patchthrough</string>
    <key>CFBundleDisplayName</key>      <string>patchthrough</string>
    <key>CFBundleIconFile</key>         <string>patchthrough</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>          <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>   <string>15.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>patchthrough records your microphone during meetings so you can transcribe them later. Audio never leaves this Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>patchthrough records system audio (the other side of your meetings) so you can transcribe them later. Audio never leaves this Mac.</string>
</dict>
</plist>
EOF

cp "$BIN" "$APP/Contents/MacOS/patchthrough"

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
