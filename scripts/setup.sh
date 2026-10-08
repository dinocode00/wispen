#!/bin/bash
# Wispen one-command setup for your Mac + iPhone.
#
#   ./scripts/setup.sh              # everything: Mac app + iPhone app (+ offer auto-refresh)
#   ./scripts/setup.sh --mac        # Mac app only
#   ./scripts/setup.sh --iphone     # iPhone app only (also what the weekly refresh runs)
#   ./scripts/setup.sh --auto-refresh-on | --auto-refresh-off
#
# Safe to re-run any time (e.g. after pulling updates).

set -euo pipefail
# Never stop silently: say where and why.
trap 'code=$?; printf "\n  \033[31m✗\033[0m setup.sh stopped at line %s (exit %s). Paste this output to Claude.\n" "$LINENO" "$code"' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/.build-wispen"
CONFIG="$ROOT/Config/Wispen.xcconfig"
LOCAL_CONFIG="$ROOT/Config/Local.xcconfig"
LOG="$BUILD/last-build.log"
mkdir -p "$BUILD"

bold() { printf "\n\033[1m%s\033[0m\n" "$*"; }
ok() { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$*"; exit 1; }
ask() { local reply; read -r -p "  $1 [Y/n] " reply </dev/tty || reply=y; [[ -z "$reply" || "$reply" =~ ^[Yy] ]]; }
QUIET="${WISPEN_QUIET:-0}" # set by the auto-refresh job: never prompt

DO_MAC=1
DO_IPHONE=1
case "${1:-}" in
  --mac) DO_IPHONE=0 ;;
  --iphone) DO_MAC=0 ;;
  --auto-refresh-on) MODE=refresh-on ;;
  --auto-refresh-off) MODE=refresh-off ;;
  "") ;;
  *) echo "Unknown option: $1"; exit 2 ;;
esac

PLIST="$HOME/Library/LaunchAgents/app.wispen.refresh.plist"
if [[ "${MODE:-}" == refresh-off ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Auto-refresh turned off."
  exit 0
fi

install_refresh_job() {
  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>app.wispen.refresh</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$ROOT/scripts/refresh-iphone.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$BUILD/refresh.log</string>
  <key>StandardErrorPath</key><string>$BUILD/refresh.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "Your Mac now checks for Wispen updates every 5 minutes, installs them on your iPhone and Mac, and renews the iPhone app before it expires."
}

if [[ "${MODE:-}" == refresh-on ]]; then install_refresh_job; exit 0; fi

# ───────────────────────────── 1. Xcode ─────────────────────────────
bold "1/5  Checking Xcode"
if ! XCODE_PATH=$(xcode-select -p 2>/dev/null) || [[ "$XCODE_PATH" == *CommandLineTools* ]]; then
  if [[ -d /Applications/Xcode.app ]]; then
    [[ "$QUIET" == 1 ]] && fail "Xcode command line tools need setting up; run scripts/setup.sh once in Terminal."
    warn "Pointing the command line tools at Xcode (needs your Mac password)…"
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  else
    warn "Xcode isn't installed. Opening the App Store page — install it (free), open it once, then re-run this script."
    open "macappstore://apps.apple.com/app/xcode/id497799835"
    exit 1
  fi
fi
# (awk reads all input; `| head` can kill xcodebuild mid-write and abort the script under pipefail)
XCODE_VERSION=$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')
if [[ "${XCODE_VERSION%%.*}" -lt 26 ]]; then
  fail "Xcode $XCODE_VERSION found; Wispen needs Xcode 26 or newer (for iOS 26 / Apple Intelligence). Update it in the App Store."
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  [[ "$QUIET" == 1 ]] && fail "Xcode was updated and needs a one-time setup; run scripts/setup.sh once in Terminal."
  warn "Finishing Xcode's first-launch setup (needs your Mac password)…"
  sudo xcodebuild -runFirstLaunch
fi
if [[ "$DO_IPHONE" == 1 ]] && ! xcodebuild -showsdks 2>/dev/null | grep iphoneos >/dev/null; then
  [[ "$QUIET" == 1 ]] && fail "Xcode is missing the iOS platform; run scripts/setup.sh once in Terminal."
  warn "Downloading the iOS platform for Xcode (a few GB, one time)…"
  xcodebuild -downloadPlatform iOS
fi
ok "Xcode $XCODE_VERSION"

# ───────────────────────────── 2. Tools ─────────────────────────────
bold "2/5  Checking tools"
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x $b ]] && eval "$($b shellenv)"; done
fi
if ! command -v brew >/dev/null 2>&1; then
  [[ "$QUIET" == 1 ]] && fail "Homebrew missing."
  warn "Installing Homebrew (https://brew.sh)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x $b ]] && eval "$($b shellenv)"; done
fi
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
ok "Homebrew + XcodeGen"

# ───────────────────────────── 3. Signing ─────────────────────────────
bold "3/5  Signing"
# Your free "Personal Team" ID: from Xcode's account settings, or the OU field of the
# Apple Development certificate Xcode created when you signed in.
find_team() {
  /usr/bin/python3 - <<'PY'
import plistlib, re, subprocess
teams = []
try:
    prefs = plistlib.loads(subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"],
                                          capture_output=True, check=True).stdout)
    for key in ("IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"):
        for account_teams in (prefs.get(key) or {}).values():
            for t in account_teams:
                if t.get("teamID"):
                    # Prefer the free personal team (that's what this setup is built around).
                    teams.append((0 if t.get("isFreeProvisioningTeam") else 1, t["teamID"]))
except Exception:
    pass
if not teams:
    pems = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
                          capture_output=True, text=True).stdout
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pems, re.S):
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=pem,
                                 capture_output=True, text=True).stdout
        m = re.search(r"OU\s*=\s*([A-Z0-9]{10})", subject)
        if m:
            teams.append((0, m.group(1)))
if teams:
    print(sorted(teams)[0][1])
PY
}
TEAM_ID="$(grep -E '^WISPEN_TEAM_ID *=' "$LOCAL_CONFIG" 2>/dev/null | sed 's/.*= *//' || true)"
if [[ -z "$TEAM_ID" ]]; then TEAM_ID="$(find_team || true)"; fi
if [[ -z "$TEAM_ID" ]]; then
  [[ "$QUIET" == 1 ]] && fail "No signing team."
  warn "Xcode isn't signed in to your Apple ID yet. Opening Xcode…"
  echo "     In Xcode: Settings (⌘,) › Accounts › + › Apple ID › sign in."
  echo "     Then select your Apple ID › your (Personal Team) › Manage Certificates… › + › Apple Development."
  open -a Xcode
  read -r -p "  Press Return when that's done… " _ </dev/tty
  TEAM_ID="$(find_team || true)"
  [[ -n "$TEAM_ID" ]] || fail "Still no Apple Development certificate. Re-run the script after creating it in Xcode."
fi

PREFIX="$(grep -E '^WISPEN_BUNDLE_PREFIX *=' "$LOCAL_CONFIG" 2>/dev/null | sed 's/.*= *//' || true)"
if [[ -z "$PREFIX" ]]; then
  # Unique per person: based on your Mac username plus your team ID.
  USER_PART="$(id -un | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')"
  PREFIX="com.${USER_PART:-me}.$(echo "$TEAM_ID" | tr 'A-Z' 'a-z')"
fi
cat >"$LOCAL_CONFIG" <<EOF
// Written by scripts/setup.sh — your personal signing settings (not committed).
WISPEN_TEAM_ID = $TEAM_ID
WISPEN_BUNDLE_PREFIX = $PREFIX
EOF
ok "Team $TEAM_ID · bundle IDs $PREFIX.wispen…"

bold "     Generating the Xcode project"
xcodegen --quiet
ok "Wispen.xcodeproj"

build() { # scheme, destination, extra args…
  local scheme="$1" dest="$2"; shift 2
  local attempt
  for attempt in 1 2 3 4; do
    echo "     Building $scheme (first build downloads WhisperKit and takes a few minutes)…"
    if xcodebuild build -project Wispen.xcodeproj -scheme "$scheme" -configuration Release \
        -destination "$dest" -derivedDataPath "$BUILD/DerivedData" \
        -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation "$@" >"$LOG" 2>&1; then
      return 0
    fi
    if grep -q "Developer Mode disabled" "$LOG"; then
      [[ "$QUIET" == 1 ]] && fail "Developer Mode is off on the iPhone."
      warn "Developer Mode isn't on yet. On the iPhone: Settings › Privacy & Security › Developer Mode › On."
      echo "     After it restarts, unlock it and tap “Turn On”."
    elif grep -q "needs to be unlocked\|is locked\|Please unlock" "$LOG"; then
      [[ "$QUIET" == 1 ]] && fail "iPhone was locked; will try again next time."
      warn "Your iPhone is locked. Unlock it and keep the screen on while Wispen installs"
      echo "     (the first time, Xcode spends a minute or two preparing the iPhone)."
    elif grep -q "Timed out waiting for all destinations" "$LOG"; then
      [[ "$QUIET" == 1 ]] && fail "iPhone not ready; will try again next time."
      warn "The iPhone isn't ready yet (Xcode may still be preparing it). Keep it unlocked and connected."
    else
      grep -E "error:" "$LOG" | sed -n '1,20p' || true
      fail "Build failed. Full log: $LOG"
    fi
    read -r -p "  Press Return to try again… " _ </dev/tty
  done
  fail "Still not working after several tries. Full log: $LOG"
}

# ───────────────────────────── 4. Mac app ─────────────────────────────
if [[ "$DO_MAC" == 1 ]]; then
  bold "4/5  Mac app"
  build WispenMac "generic/platform=macOS"
  APP="$BUILD/DerivedData/Build/Products/Release/Wispen.app"
  osascript -e 'quit app "Wispen"' >/dev/null 2>&1 || true
  rm -rf /Applications/Wispen.app
  ditto "$APP" /Applications/Wispen.app
  osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Wispen.app", hidden:true}' >/dev/null 2>&1 || true
  open /Applications/Wispen.app
  ok "Installed in /Applications, set to open at login, and running (waveform icon in the menu bar)."
  if [[ "$QUIET" != 1 ]]; then
    echo "     macOS will ask for Microphone access — click Allow."
    echo "     Opening Accessibility settings: switch on “Wispen” so it can type for you."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    echo "     Tip: if fn opens the emoji picker, set Keyboard › “Press 🌐 key to” › Do Nothing."
  fi
fi

# ───────────────────────────── 5. iPhone app ─────────────────────────────
if [[ "$DO_IPHONE" == 1 ]]; then
  bold "5/5  iPhone app"
  find_iphone() {
    xcrun devicectl list devices --json-output "$BUILD/devices.json" >/dev/null 2>&1 || return 1
    /usr/bin/python3 - "$BUILD/devices.json" "$(cat "$BUILD/iphone-udid" 2>/dev/null)" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
saved = sys.argv[2].strip() if len(sys.argv) > 2 else ""
candidates = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") == "virtual":
        continue
    conn = d.get("connectionProperties", {})
    props = d.get("deviceProperties", {})
    udid = hw.get("udid") or d.get("identifier", "")
    candidates.append({
        "udid": udid,
        "name": props.get("name", "iPhone"),
        "devmode": props.get("developerModeStatus", "unknown"),
        "paired": conn.get("pairingState") == "paired",
        "connected": conn.get("tunnelState") == "connected",
        "saved": bool(saved) and udid == saved,
    })
# The iPhone Wispen was installed on before always wins. Otherwise only consider iPhones paired
# with this Mac (other iPhones nearby can show up too, but can't be installed on).
pick = next((c for c in candidates if c["saved"]), None)
if pick is None:
    paired = [c for c in candidates if c["paired"]] or (candidates if not saved else [])
    paired.sort(key=lambda c: (c["connected"], c["devmode"] == "enabled"), reverse=True)
    pick = paired[0] if paired else None
if pick:
    print(f"{pick['udid']}\t{pick['name']}\t{pick['devmode']}")
PY
  }
  DEVICE="$(find_iphone || true)"
  while [[ -z "$DEVICE" ]]; do
    [[ "$QUIET" == 1 ]] && { echo "iPhone not reachable; will try again tomorrow."; exit 0; }
    warn "No iPhone found. Plug it in with a cable, unlock it, and tap “Trust This Computer”."
    read -r -p "  Press Return to look again (or Ctrl-C to stop)… " _ </dev/tty
    DEVICE="$(find_iphone || true)"
  done
  IFS=$'\t' read -r UDID NAME DEV_MODE <<<"$DEVICE"
  ok "Found $NAME"
  while [[ "$DEV_MODE" == "disabled" ]]; do
    [[ "$QUIET" == 1 ]] && { echo "Developer Mode is off on the iPhone."; exit 0; }
    warn "Developer Mode is off on $NAME."
    echo "     On the iPhone: Settings › Privacy & Security › Developer Mode › On › Restart."
    echo "     After it restarts, unlock it and tap “Turn On” in the alert (then enter your passcode)."
    read -r -p "  Press Return when that's done… " _ </dev/tty
    DEVICE="$(find_iphone || true)"
    IFS=$'\t' read -r UDID NAME DEV_MODE <<<"$DEVICE"
  done

  build Wispen "id=$UDID"
  IPA_APP="$BUILD/DerivedData/Build/Products/Release-iphoneos/Wispen.app"
  if ! xcrun devicectl device install app --device "$UDID" "$IPA_APP" >"$BUILD/install.log" 2>&1; then
    if grep -q "installapp\|Install Application" "$BUILD/install.log"; then
      [[ "$QUIET" == 1 ]] && fail "$NAME isn't available for installing right now; will try again."
      fail "$NAME can't receive apps right now. Unlock it (and plug it in if it's the first time), then re-run: $0 --iphone"
    fi
    if grep -qi "developer mode" "$BUILD/install.log"; then
      fail "Turn on Developer Mode on your iPhone: Settings › Privacy & Security › Developer Mode (it restarts), then re-run."
    fi
    tail -5 "$BUILD/install.log"
    fail "Install failed (full log: $BUILD/install.log)."
  fi
  echo "$UDID" >"$BUILD/iphone-udid"
  date +%s >"$BUILD/iphone-installed-at"
  git -C "$ROOT" rev-parse HEAD >"$BUILD/iphone-installed-commit" 2>/dev/null || true
  ok "Installed on $NAME"
  BUNDLE_ID="$PREFIX.wispen"
  if ! xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
    [[ "$QUIET" == 1 ]] || warn "First install: on the iPhone open Settings › General › VPN & Device Management › your Apple ID › Trust. Then open Wispen."
  else
    ok "Wispen is open on your iPhone."
  fi

  if [[ "$QUIET" != 1 ]]; then
    cat <<'EOF'

     On your iPhone (one time):
       1. In Wispen, let it download the speech model (use Wi-Fi) and allow the microphone.
       2. Wispen › Flow tab › Setup › “Add the Wispen keyboard” › Open
          → Keyboards › turn on Wispen and Allow Full Access.
       3. Make sure Apple Intelligence is on (Settings › Apple Intelligence & Siri).
EOF
    if [[ ! -f "$PLIST" ]]; then
      echo
      echo "     Free Apple IDs make iPhone apps expire after 7 days."
      if ask "Install Wispen updates automatically and renew it weekly (needs this Mac on and the iPhone on the same Wi-Fi)?"; then
        install_refresh_job
      fi
    fi
  fi
fi

bold "Done 🎉"
