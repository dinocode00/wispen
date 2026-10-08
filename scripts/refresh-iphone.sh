#!/bin/bash
# Run every 5 minutes by launchd (see `setup.sh --auto-refresh-on`). It:
#   • installs new Wispen updates (new commits on this branch) on the iPhone and the Mac, and
#   • renews the iPhone app before the free-account 7-day signature expires.
# Your data on both devices is kept. If the iPhone isn't reachable, it simply tries again on the next check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build-wispen"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$ROOT" || exit 0

notify() { osascript -e "display notification \"$1\" with title \"Wispen\"" >/dev/null 2>&1 || true; }

# 1. Pull updates (fast-forward only, so local edits are never overwritten).
branch="$(git rev-parse --abbrev-ref HEAD)"
before="$(git rev-parse HEAD)"
if git fetch -q origin "$branch" 2>/dev/null && ! git merge -q --ff-only "origin/$branch" 2>/dev/null; then
  # The branch's history was rewritten upstream (e.g. to remove personal info). With no local edits,
  # follow it; otherwise leave things alone.
  if [[ -z "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "$(date): branch history was rewritten upstream; following it"
    git reset -q --hard "origin/$branch"
  fi
fi
now="$(git rev-parse HEAD)"
if [[ "$now" != "$before" ]]; then
  echo "$(date): pulled update $(git log -1 --format='%h %s')"
  # Mac app: rebuild and reinstall quietly.
  if WISPEN_QUIET=1 /bin/bash "$ROOT/scripts/setup.sh" --mac; then
    notify "Mac app updated: $(git log -1 --format='%s' | cut -c1-80)"
  fi
fi

# 2. iPhone: install when it's behind, or when the signature is about to expire.
installed_commit="$(cat "$BUILD/iphone-installed-commit" 2>/dev/null || true)"
installed_at="$(cat "$BUILD/iphone-installed-at" 2>/dev/null || echo 0)"
age_days=$(( ($(date +%s) - installed_at) / 86400 ))
if [[ "$installed_commit" == "$now" ]] && (( age_days < 5 )); then
  exit 0
fi
echo "$(date): installing on iPhone (behind: $([[ "$installed_commit" != "$now" ]] && echo yes || echo no), age: $age_days d)"
if WISPEN_QUIET=1 /bin/bash "$ROOT/scripts/setup.sh" --iphone && [[ "$(cat "$BUILD/iphone-installed-commit" 2>/dev/null)" == "$now" ]]; then
  if [[ "$installed_commit" != "$now" ]]; then
    notify "Updated on your iPhone: $(git log -1 --format='%s' | cut -c1-80)"
  fi
fi
