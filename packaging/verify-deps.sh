#!/bin/bash
#
# Supply-chain check. Compares the dependency git revisions currently in play
# against a reviewed baseline in packaging/DEPS.lock, and fails on any drift.
#
#   ./packaging/verify-deps.sh            check against the baseline
#   ./packaging/verify-deps.sh --update   re-baseline (do this ONLY after you
#                                         have actually reviewed the new code)
#
# What this catches:
#   · a dependency silently resolving to a different version
#   · Package.resolved being edited without you noticing
#   · the source checked out in .build/checkouts not matching Package.resolved
#     (i.e. what actually got compiled != what the lockfile claims)
#
# What it does NOT catch: a dependency that was already malicious at the pinned
# revision. Pinning guarantees you keep getting the same code. It does not
# guarantee that the code is good. A review of FluidAudio's 0.15.5 tree is a
# separate job.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO/packaging/DEPS.lock"
cd "$REPO"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Extract "identity revision version" triples from Package.resolved.
current_pins() {
  python3 - "$REPO/Package.resolved" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for p in sorted(d.get("pins", []), key=lambda x: x["identity"]):
    s = p.get("state", {})
    print(p["identity"], s.get("revision", "?"), s.get("version", "?"), p.get("location", "?"))
PY
}

if [ "${1:-}" = "--update" ]; then
  say "re-baselining dependency pins…"
  echo
  current_pins | while read -r id rev ver loc; do
    printf '  %-24s %s  (%s)\n' "$id" "$ver" "${rev:0:12}"
  done
  echo
  printf 'These revisions will be treated as reviewed and trusted. Type REVIEWED to confirm: '
  read -r answer
  [ "$answer" = "REVIEWED" ] || fail "aborted. Baseline unchanged"
  {
    echo "# Reviewed dependency baseline for patchthrough."
    echo "# Regenerate with: ./packaging/verify-deps.sh --update"
    echo "# Format: identity revision version location"
    echo "# Baselined $(date -u '+%Y-%m-%d %H:%M:%SZ') by $(whoami)"
    current_pins
  } > "$LOCK"
  say "wrote $LOCK. Commit it."
  exit 0
fi

[ -f "$LOCK" ] || fail "no baseline at $LOCK
Create one with: ./packaging/verify-deps.sh --update"

FAILED=0

# --- 1. Package.resolved vs baseline ---------------------------------------

say "dependency pins vs reviewed baseline…"

BASE="$(grep -v '^#' "$LOCK" | grep -v '^[[:space:]]*$' | sort)"
CURR="$(current_pins | sort)"

if [ "$BASE" = "$CURR" ]; then
  echo "$CURR" | while read -r id rev ver loc; do
    ok "$(printf '%-24s %-10s %s' "$id" "$ver" "${rev:0:12}")"
  done
else
  bad "DRIFT DETECTED"
  echo
  echo "  --- reviewed baseline"
  echo "  +++ what you have now"
  diff <(echo "$BASE") <(echo "$CURR") | sed 's/^/  /' || true
  echo
  FAILED=1
fi

# --- 2. what's on disk vs what the lockfile claims -------------------------

echo
say "checked-out source vs Package.resolved…"

if [ ! -d .build/checkouts ]; then
  echo "  (no checkouts yet. Run swift build first)"
else
  while read -r id rev ver loc; do
    # SwiftPM's checkout dir uses the repo name, which may differ in case from
    # the resolved "identity" (e.g. fluidaudio -> FluidAudio).
    dir=""
    for c in .build/checkouts/*/; do
      [ -d "$c" ] || continue
      if [ "$(basename "$c" | tr 'A-Z' 'a-z')" = "$(echo "$id" | tr 'A-Z' 'a-z')" ]; then
        dir="$c"; break
      fi
    done
    if [ -z "$dir" ]; then
      echo "  · $id not checked out"
      continue
    fi
    actual="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"
    if [ "$actual" = "$rev" ]; then
      ok "$(printf '%-24s %s' "$id" "${actual:0:12}")"
    else
      bad "$id: compiled source is $actual, lockfile says $rev"
      FAILED=1
    fi

    # A dirty dependency checkout means someone edited third-party source in
    # place. Nothing legitimate does that.
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      bad "$id: checkout has LOCAL MODIFICATIONS"
      git -C "$dir" status --short | head -5 | sed 's/^/      /'
      FAILED=1
    fi
  done <<< "$(grep -v '^#' "$LOCK" | grep -v '^[[:space:]]*$')"
fi

# --- 3. dependency count sanity -------------------------------------------

echo
say "transitive dependency surface…"
COUNT="$(current_pins | wc -l | tr -d ' ')"
echo "  $COUNT direct+transitive package(s) pinned"
if [ "$COUNT" -gt 5 ]; then
  bad "more dependencies than expected. Did an upstream change add one?"
  FAILED=1
else
  ok "unchanged in size"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  say "✓ dependencies match the reviewed baseline"
else
  fail "✗ dependency verification FAILED. Do not build or install until you have
reviewed the changes above. If they are legitimate and you have read the new
code, re-baseline with: ./packaging/verify-deps.sh --update"
fi
