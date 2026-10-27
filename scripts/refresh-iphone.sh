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

# 2. iPhone: install when it's behind, and renew the signature before it expires.
#    The expiry is read from the installed build's provisioning profiles (setup.sh records it): with a
#    free Apple ID a profile lasts 7 days from when it was made, however often the app is reinstalled.
installed_commit="$(cat "$BUILD/iphone-installed-commit" 2>/dev/null || true)"
installed_at="$(cat "$BUILD/iphone-installed-at" 2>/dev/null || echo 0)"
expires_at="$(cat "$BUILD/iphone-expires-at" 2>/dev/null || echo 0)"
# Installs from before the expiry was recorded: assume 7 days from the install.
(( expires_at == 0 && installed_at > 0 )) && expires_at=$(( installed_at + 7 * 86400 ))
now_s=$(date +%s)
left=$(( expires_at - now_s ))
behind=no; [[ "$installed_commit" != "$now" ]] && behind=yes
renew=no; (( left < 3 * 86400 )) && renew=yes
[[ "$behind" == no && "$renew" == no ]] && exit 0

# A renewal that doesn't need a new build is tried at most hourly (every check once it has expired),
# so an unreachable iPhone or a stubborn profile doesn't mean rebuilding every 5 minutes.
if [[ "$behind" == no ]] && (( left > 0 )) && [[ -n "$(find "$BUILD/iphone-renew-tried" -mmin -60 2>/dev/null)" ]]; then
  exit 0
fi
touch "$BUILD/iphone-renew-tried"
echo "$(date): installing on iPhone (behind: $behind, signature left: $(( left / 3600 )) h)"
fresh=0; [[ "$renew" == yes ]] && fresh=1
# setup.sh exits quietly when the iPhone isn't reachable, so success means a new install time.
WISPEN_QUIET=1 WISPEN_FRESH_PROFILE=$fresh /bin/bash "$ROOT/scripts/setup.sh" --iphone
installed=no
if (( $(cat "$BUILD/iphone-installed-at" 2>/dev/null || echo 0) > installed_at )) \
    && [[ "$(cat "$BUILD/iphone-installed-commit" 2>/dev/null)" == "$now" ]]; then
  installed=yes
  [[ "$behind" == yes ]] && notify "Updated on your iPhone: $(git log -1 --format='%s' | cut -c1-80)"
fi
expires_at="$(cat "$BUILD/iphone-expires-at" 2>/dev/null || echo 0)"
left=$(( expires_at - $(date +%s) ))
echo "$(date): installed: $installed, signature now good for $(( left / 3600 )) h"
if (( left >= 3 * 86400 )); then
  rm -f "$BUILD/expiry-notified" "$BUILD/iphone-renew-tried"
  exit 0
fi

# Still expiring soon: warn on the Mac (at most every 12 hours, and right away once it has expired).
(( expires_at > 0 && left > 36 * 3600 )) && exit 0
if (( left > 0 )) && [[ -n "$(find "$BUILD/expiry-notified" -mmin -720 2>/dev/null)" ]]; then exit 0; fi
if (( left <= 0 )) && [[ -n "$(find "$BUILD/expiry-notified" -mmin -120 2>/dev/null)" ]]; then exit 0; fi
touch "$BUILD/expiry-notified"
if (( left <= 0 )); then
  when="has expired"
elif (( left < 86400 )); then
  when="expires in $(( left / 3600 )) hours"
else
  when="expires in $(( left / 86400 )) days"
fi
if [[ "$installed" == yes ]]; then
  why="Apple didn't issue a new signature yet; it will keep trying."
else
  why="Unlock your iPhone on the same Wi-Fi as this Mac (or plug it in) so it can renew."
fi
notify "Wispen on your iPhone $when. $why"
