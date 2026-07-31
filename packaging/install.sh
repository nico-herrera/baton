#!/bin/bash
#
# patchthrough installer (patched local build).
# Run from inside the unpacked tarball directory:  ./install.sh
#
#   --prefix DIR   install somewhere other than /usr/local/bin
#                  (use ~/.local/bin if you don't have admin rights)
#   --no-agent     install the binary only, skip launch-at-login
#   --uninstall    remove the binary and the LaunchAgent

set -euo pipefail

PREFIX="/usr/local/bin"
AGENT="com.nicoherrera.patchthrough"
PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"
WANT_AGENT=1
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --no-agent) WANT_AGENT=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- uninstall -------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
  say "uninstalling…"
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  rm -f "$PLIST"
  if [ -w "$PREFIX" ]; then rm -f "$PREFIX/patchthrough"; else sudo rm -f "$PREFIX/patchthrough"; fi
  say "removed. Your recordings in ~/Recordings were left alone."
  say "To also revoke permissions: System Settings → Privacy & Security →"
  say "Microphone / Screen & System Audio Recording."
  exit 0
fi

# --- preflight -------------------------------------------------------------

say "checking this machine…"

ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || fail "this build is Apple Silicon only (arm64); you're on $ARCH.
Parakeet transcription runs on the Neural Engine — Intel Macs can't run it."

OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OS_MAJOR" -lt 15 ]; then
  fail "patchthrough needs macOS 15 or newer (you're on $(sw_vers -productVersion)).
System audio capture uses Core Audio process taps, which don't exist before 15."
fi
echo "  ✓ $(sw_vers -productVersion) on $ARCH"

[ -f "$SRC_DIR/patchthrough" ] || fail "no 'patchthrough' binary next to this script — unpack the full tarball first"

# Verify the signature before trusting the binary.
if codesign --verify --strict "$SRC_DIR/patchthrough" 2>/dev/null; then
  # No early `exit` in awk: it would close the pipe while codesign is still
  # writing, and SIGPIPE + `set -o pipefail` kills the whole script.
  SIGNER="$(codesign -dvv "$SRC_DIR/patchthrough" 2>&1 \
            | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }')"
  echo "  ✓ signature valid — $SIGNER"
else
  warn "  ! binary is unsigned or the signature is broken"
  warn "    continuing, but macOS may refuse to run it"
fi

# Checksum. A mismatch is fatal, not a warning: this is the one cheap check
# that catches a modified payload, and "it warned me and installed anyway" is
# how bad binaries end up running.
if [ -f "$SRC_DIR/SHA256SUMS" ]; then
  if ( cd "$SRC_DIR" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ); then
    echo "  ✓ checksum matches"
  elif [ "${PATCHTHROUGH_SKIP_CHECKSUM:-}" = "1" ]; then
    warn "  ! checksum MISMATCH — overridden by PATCHTHROUGH_SKIP_CHECKSUM=1"
  else
    ( cd "$SRC_DIR" && shasum -a 256 -c SHA256SUMS 2>&1 | grep -v ': OK$' | sed 's/^/    /' ) || true
    fail "checksum MISMATCH — refusing to install.

The files here don't match the checksums the tarball shipped with. Either the
download is corrupt or the contents were modified after packaging.

Re-download from the release you built, and compare the outer tarball hash too:
  shasum -a 256 patchthrough-local-*.tar.gz

If you changed a file yourself on purpose, either regenerate SHA256SUMS or
re-run with PATCHTHROUGH_SKIP_CHECKSUM=1."
  fi
fi

# --- quarantine ------------------------------------------------------------

# Anything downloaded carries com.apple.quarantine, and this build is signed
# but not notarized, so Gatekeeper blocks it on first run. Strip the flag.
# You don't have to take that on faith — the signature check above is real,
# and you can re-run it yourself: codesign -dvv ./patchthrough
if xattr -p com.apple.quarantine "$SRC_DIR/patchthrough" >/dev/null 2>&1; then
  say "removing the download quarantine flag…"
  xattr -d com.apple.quarantine "$SRC_DIR/patchthrough" 2>/dev/null || true
fi

# --- install ---------------------------------------------------------------

echo
say "installing to $PREFIX/patchthrough…"
mkdir -p "$PREFIX" 2>/dev/null || sudo mkdir -p "$PREFIX"

if [ -w "$PREFIX" ]; then
  cp "$SRC_DIR/patchthrough" "$PREFIX/patchthrough"
  chmod 755 "$PREFIX/patchthrough"
else
  say "  (needs your password)"
  sudo cp "$SRC_DIR/patchthrough" "$PREFIX/patchthrough"
  sudo chmod 755 "$PREFIX/patchthrough"
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) warn "  ! $PREFIX is not on your PATH — add this to ~/.zshrc:"
     warn "      export PATH=\"$PREFIX:\$PATH\"" ;;
esac

# --- launch agent ----------------------------------------------------------

if [ "$WANT_AGENT" -eq 1 ]; then
  echo
  say "registering launch-at-login…"
  "$PREFIX/patchthrough" install --launch-at-login
else
  echo
  say "skipping launch-at-login (--no-agent). Start it by running: patchthrough"
fi

# --- report ----------------------------------------------------------------

echo
say "checking permissions…"
"$PREFIX/patchthrough" doctor || true

cat <<'EOF'

──────────────────────────────────────────────────────────────────────
Installed. Click the feather in your menu bar → Start recording.

First recording prompts for Microphone and Screen & System Audio
Recording. Grant both — system audio is how patchthrough hears the other side
of a call. Sessions land in ~/Recordings/<timestamp>/.

Two things to know:

  · Models (~600 MB) download on the first transcription. Record a
    short test session while you're online, before a real meeting.

  · A global tap records everything the Mac plays, including
    notification sounds and music. Don't play Spotify during meetings.

On a managed / MDM laptop: if the permission prompts never appear, or
appear and immediately deny, your organization is likely enforcing a
PPPC profile. Ask IT to allow Team ID DAB6FR7R2R for Microphone and
Audio Capture, or to whitelist the binary at the installed path.
──────────────────────────────────────────────────────────────────────
EOF
