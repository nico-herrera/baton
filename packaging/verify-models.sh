#!/bin/bash
#
# Integrity check for the on-device transcription models.
#
#   ./packaging/verify-models.sh            check against the baseline
#   ./packaging/verify-models.sh --update   re-baseline
#
# Why this exists: the Parakeet CoreML models (~600 MB) are NOT in the repo and
# NOT pinned by Package.resolved. FluidAudio downloads them at runtime from
# HuggingFace on first transcription, and CoreML then executes them. That's the
# least-protected link in the chain — an unpinned fetch of executable content,
# with no signature and no hash published by upstream that we can check against.
#
# There is no way to verify the FIRST download is authentic; nothing to compare
# it to. What this does give you is change detection: baseline the hashes once,
# and any later substitution — a re-download pulling different weights, or
# something writing into the model cache — shows up as a diff.
#
# If a mismatch appears and you didn't deliberately update: delete the model
# directory, re-download while on a network you trust, and compare again.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO/packaging/MODELS.lock"
MODELS="$HOME/Library/Application Support/FluidAudio/Models"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

[ -d "$MODELS" ] || fail "no models at:
  $MODELS
They download on the first transcription. Record a short test session first."

# Hash every file, path-relative and sorted so the output is stable.
hash_models() {
  ( cd "$MODELS" && find . -type f ! -name '.DS_Store' -print0 \
      | sort -z \
      | xargs -0 shasum -a 256 )
}

if [ "${1:-}" = "--update" ]; then
  say "hashing models under $MODELS …"
  COUNT=$(find "$MODELS" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')
  SIZE=$(du -sh "$MODELS" | cut -f1)
  echo "  $COUNT files, $SIZE"
  echo
  warn "Baseline only if you trust the current copy — ideally right after a"
  warn "fresh download on a network you control."
  printf 'Type REVIEWED to confirm: '
  read -r answer
  [ "$answer" = "REVIEWED" ] || fail "aborted — baseline unchanged"
  {
    echo "# Reviewed model baseline for patchthrough."
    echo "# Regenerate with: ./packaging/verify-models.sh --update"
    echo "# Baselined $(date -u '+%Y-%m-%d %H:%M:%SZ') — $COUNT files, $SIZE"
    echo "# Source: FluidAudio downloads these from HuggingFace at runtime."
    hash_models
  } > "$LOCK"
  say "wrote $LOCK — commit it."
  exit 0
fi

[ -f "$LOCK" ] || fail "no baseline at $LOCK
Create one with: ./packaging/verify-models.sh --update"

say "verifying model files against the reviewed baseline…"

BASE="$(grep -v '^#' "$LOCK" | grep -v '^[[:space:]]*$' | sort)"
CURR="$(hash_models | sort)"

if [ "$BASE" = "$CURR" ]; then
  ok "$(echo "$CURR" | wc -l | tr -d ' ') model file(s) unchanged"
  echo
  say "✓ models match the reviewed baseline"
  exit 0
fi

printf '\033[31m  ✗ MODEL FILES CHANGED\033[0m\n'
echo
echo "  --- reviewed baseline"
echo "  +++ what's on disk now"
diff <(echo "$BASE") <(echo "$CURR") | sed 's/^/  /' || true
echo
fail "✗ model verification FAILED.

These files are executed by CoreML on audio from your meetings. If you did not
deliberately re-download or change models, treat this as suspicious:

  1. rm -rf \"$MODELS\"
  2. re-download by recording a short test session on a trusted network
  3. ./packaging/verify-models.sh   (compare again)

If it still differs, upstream FluidAudio changed the published models — verify
that independently before re-baselining."
