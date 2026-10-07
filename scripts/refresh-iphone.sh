#!/bin/bash
# Run nightly by launchd (see setup.sh --auto-refresh-on). Reinstalls Wispen on the iPhone when the
# free-account signature is within 2 days of its 7-day expiry. Your data on the phone is kept.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$ROOT/.build-wispen/iphone-installed-at"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

installed=$(cat "$STAMP" 2>/dev/null || echo 0)
age_days=$(( ($(date +%s) - installed) / 86400 ))
echo "$(date): last install $age_days day(s) ago"
if (( age_days < 5 )); then
  echo "Nothing to do."
  exit 0
fi
WISPEN_QUIET=1 /bin/bash "$ROOT/scripts/setup.sh" --iphone
