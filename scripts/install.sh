#!/bin/bash
# Speedy Bot installer — the one-line install:
#
#     curl -fsSL https://github.com/aidan902/speedy-bot/releases/latest/download/install.sh | bash
#
#   update     : run the same command again (it replaces the app in place)
#   uninstall  : curl -fsSL https://github.com/aidan902/speedy-bot/releases/latest/download/install.sh | bash -s -- --uninstall
#   no launch  : ... | bash -s -- --no-launch
#
# What it does: downloads the zip, PROVES it is the real thing (valid signature, signed by
# team SRPFLCC723, bundle id net.fm.speedybot, notarized by Apple), installs it to
# /Applications — or ~/Applications when this account cannot write there — opens it, and
# tells you the one permission to switch on. No Homebrew, no Xcode tools, no sudo.
#
# Needs only what ships with macOS: bash 3.2, curl, ditto, codesign, spctl, xattr, file.
#
# Overrides (testing):
#   SPEEDYBOT_URL                 where to download the zip from (https://, or file:// for a local test)
#   SPEEDYBOT_DEST                install into this folder instead of /Applications
#   SPEEDYBOT_ALLOW_UNNOTARIZED=1 accept a build Apple has not notarized yet. The Developer ID
#                                 signature and the team are still enforced.
#   SPEEDYBOT_SKIP_STOP=1         TEST ONLY: do not quit running copies or touch the screenshot settings
set -euo pipefail

# ------------------------------------------------------------------ release settings
DOWNLOAD_URL="${SPEEDYBOT_URL:-https://github.com/aidan902/speedy-bot/releases/latest/download/SpeedyBot-mac.zip}"
EXPECTED_SHA256=""              # optional: pin one exact build. Empty = rely on the signature
                                # checks below, which already prove where the app came from.
EXPECTED_TEAM_ID="SRPFLCC723"
EXPECTED_BUNDLE_ID="net.fm.speedybot"
APP_NAME="Speedy Bot.app"
EXE_SUFFIX="/$APP_NAME/Contents/MacOS/Speedy Bot"
MIN_MACOS_MAJOR=13              # keep equal to the app's LSMinimumSystemVersion

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nSpeedy Bot was NOT installed: %s\n' "$*" >&2; exit 1; }

# PIDs of every running copy of Speedy Bot, wherever it was started from (Applications,
# Downloads, a disk image). Matched on the end of the executable path, so nothing else can be hit.
running_pids() {
  ps -axo pid=,comm= | awk -v s="$EXE_SUFFIX" '{ pid = $1; $1 = ""; sub(/^ +/, ""); n = length($0) - length(s); if (n >= 0 && substr($0, n + 1) == s) print pid }'
}

# Quit politely first: Speedy Bot treats a plain kill as Quit, and quitting is what puts the
# screenshot settings back. Force only if it has not gone after five seconds.
stop_speedybot() {
  [ "${SPEEDYBOT_SKIP_STOP:-0}" = 1 ] && return 0
  local pids i
  pids="$(running_pids)"
  [ -n "$pids" ] || return 0
  note "quitting the running copy"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(running_pids)" ] && return 0
    sleep 0.5
  done
  pids="$(running_pids)"
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
}

uninstall() {
  local found=0 d dirs
  dirs="/Applications/$APP_NAME
$HOME/Applications/$APP_NAME"
  [ -z "${SPEEDYBOT_DEST:-}" ] || dirs="$SPEEDYBOT_DEST/$APP_NAME"
  stop_speedybot
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    found=1
    # If it was force-quit or crashed, the screenshot settings are still Speedy Bot's. Put them back.
    [ "${SPEEDYBOT_SKIP_STOP:-0}" = 1 ] || "$d/Contents/MacOS/Speedy Bot" --restore-screenshot-settings >/dev/null 2>&1 || true
    rm -rf "$d" 2>/dev/null || die "could not remove $d (installed by another account? remove it in Finder)."
    note "removed $d"
  done <<EOF
$dirs
EOF
  [ "$found" = 1 ] || { note "Speedy Bot is not installed — nothing to remove."; return 0; }
  cat <<EOF

Speedy Bot is uninstalled, and screenshots save the way they did before.
Left in place on purpose (optional to clear):
  - Saved screenshots in ~/Documents/SpeedyBot Documentation are never deleted
  - Settings: ~/Library/Group Containers/SRPFLCC723.net.fm.speedybot
  - System Settings > Privacy & Security > Accessibility: select Speedy Bot, click "-"
  - Control Center > Edit Controls: remove the Speedy Bot control, if you added it
EOF
}

main() {
  local launch=1 arg
  for arg in "$@"; do
    case "$arg" in
      --uninstall) uninstall; exit 0 ;;
      --no-launch) launch=0 ;;
      *) die "unknown option: $arg" ;;
    esac
  done

  # ---------------------------------------------------------------- this Mac
  [ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS."
  local os major
  os="$(sw_vers -productVersion)"; major="${os%%.*}"
  [ "$major" -ge "$MIN_MACOS_MAJOR" ] 2>/dev/null \
    || die "Speedy Bot needs macOS $MIN_MACOS_MAJOR or later (this Mac runs $os)."

  local proto
  case "$DOWNLOAD_URL" in
    https://*) proto="=https" ;;
    file://*)  proto="=file" ;;          # local testing only
    *) die "refusing a download URL that is not https: $DOWNLOAD_URL" ;;
  esac

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/speedybot.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  # ---------------------------------------------------------------- download
  say "Downloading Speedy Bot"
  curl -fL --proto "$proto" --retry 3 --connect-timeout 20 -# -o "$tmp/SpeedyBot.zip" "$DOWNLOAD_URL" \
    || die "download failed ($DOWNLOAD_URL). Check the network and try again."

  if [ -n "$EXPECTED_SHA256" ]; then
    local got
    got="$(shasum -a 256 "$tmp/SpeedyBot.zip" | awk '{print $1}')"
    [ "$got" = "$EXPECTED_SHA256" ] || die "checksum mismatch — the download is not the published build."
    note "checksum matches"
  fi

  ditto -x -k "$tmp/SpeedyBot.zip" "$tmp/unpacked" 2>/dev/null || die "the download is not a valid zip."
  local src="$tmp/unpacked/$APP_NAME"
  [ -d "$src" ] || die "the zip does not contain \"$APP_NAME\"."

  # ---------------------------------------------------------------- verify BEFORE installing
  say "Verifying it is the genuine Speedy Bot"
  # 1. the signature is intact, all the way down (app + embedded extension)
  codesign --verify --deep --strict "$src" 2>/dev/null \
    || die "the app's code signature is broken or missing."
  # 2. signed with a Developer ID certificate belonging to OUR team, for OUR bundle id
  local req="identifier \"$EXPECTED_BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  codesign --verify --strict -R="$req" "$src" 2>/dev/null \
    || die "the app is not signed by the expected developer (team $EXPECTED_TEAM_ID)."
  note "signed by team $EXPECTED_TEAM_ID"
  # 3. Apple notarized it (uses the ticket stapled into the app, so this works offline),
  #    and Gatekeeper itself agrees — the same verdict a double-click would get
  if codesign --verify --strict -R="notarized" "$src" 2>/dev/null; then
    local gk
    gk="$(spctl --assess --type execute -vv "$src" 2>&1 || true)"
    case "$gk" in
      *"source=Notarized Developer ID"*) note "notarized by Apple; Gatekeeper accepts it" ;;
      *"accepted"*)                      note "Gatekeeper accepts it" ;;
      *) die "Gatekeeper rejected the app: $(printf '%s' "$gk" | tr '\n' ' ')" ;;
    esac
  elif [ "${SPEEDYBOT_ALLOW_UNNOTARIZED:-0}" = 1 ]; then
    note "NOT notarized by Apple — accepted because SPEEDYBOT_ALLOW_UNNOTARIZED=1 (signature and team were checked)"
  else
    die "the app is not notarized by Apple."
  fi
  # 4. it can run on this Mac's processor
  local cpu archs
  cpu="$(uname -m)"
  archs="$(/usr/bin/file "$src/Contents/MacOS/Speedy Bot" 2>/dev/null || true)"
  case "$archs" in
    *"$cpu"*) ;;
    *) die "this build does not include code for this Mac's processor ($cpu)." ;;
  esac
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$src/Contents/Info.plist" 2>/dev/null || echo '?')"

  # ---------------------------------------------------------------- where to install
  # /Applications when this account can write there (admins can, without sudo). ~/Applications only
  # when there is no copy in /Applications at all: two copies would mean the old one keeps running.
  local destdir=""
  if [ -n "${SPEEDYBOT_DEST:-}" ]; then
    destdir="$SPEEDYBOT_DEST"
  elif [ -d "/Applications/$APP_NAME" ]; then
    if [ -w "/Applications" ] && [ -w "/Applications/$APP_NAME" ]; then
      destdir="/Applications"
    else
      die "there is a copy in /Applications that this account cannot replace. Ask an admin to run this installer, or to delete that copy first."
    fi
  elif [ -d "$HOME/Applications/$APP_NAME" ]; then
    destdir="$HOME/Applications"
  elif [ -w "/Applications" ]; then
    destdir="/Applications"
  else
    destdir="$HOME/Applications"
  fi
  mkdir -p "$destdir" 2>/dev/null || die "cannot create $destdir."
  [ -w "$destdir" ] || die "cannot write to $destdir."
  local final="$destdir/$APP_NAME"

  # ---------------------------------------------------------------- install (swap, with rollback)
  say "Installing Speedy Bot $version to $destdir"
  local staged="$destdir/.speedybot-new.$$" old="$destdir/.speedybot-old.$$"
  rm -rf "$staged" "$old" 2>/dev/null || true
  mkdir -p "$staged"
  ditto "$src" "$staged/$APP_NAME" || { rm -rf "$staged"; die "could not copy the app into $destdir."; }
  stop_speedybot                       # every running copy, wherever it was started from
  if [ -d "$final" ]; then
    mv "$final" "$old" || { rm -rf "$staged"; die "could not replace the existing copy at $final."; }
  fi
  if ! mv "$staged/$APP_NAME" "$final"; then
    [ -d "$old" ] && mv "$old" "$final"          # put the previous version back
    rm -rf "$staged"
    die "could not move the app into place (the previous version was restored)."
  fi
  rm -rf "$staged" "$old" 2>/dev/null \
    || note "could not remove the previous copy at $old (owned by another account?). Delete it in Finder."

  # Quarantine: curl does not set it. Clear it only if something added one, and only now that
  # the app has been verified.
  if xattr -p com.apple.quarantine "$final" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$final" 2>/dev/null || true
    note "cleared the download quarantine flag (the app was verified above)"
  fi
  codesign --verify --deep --strict "$final" 2>/dev/null \
    || die "the installed copy failed verification — delete $final and run this again."

  # ---------------------------------------------------------------- launch + the one permission
  if [ "$launch" = 1 ]; then
    if open "$final"; then
      sleep 2
      local running
      running="$(ps -axo comm= | awk -v s="$EXE_SUFFIX" '{ n = length($0) - length(s); if (n >= 0 && substr($0, n + 1) == s) print }' | head -1)"
      case "$running" in
        "$final"/*) ;;
        "") note "Speedy Bot did not stay open — open \"$final\" from Finder." ;;
        *)  note "WARNING: the copy that is running is $running, not the one just installed. Quit it and open \"$final\"." ;;
      esac
    else
      note "could not open it automatically — open \"$final\" from Finder."
    fi
  fi
  cat <<EOF

Speedy Bot $version is installed: $final
It has a Dock icon and a hare icon in the menu bar (top right of the screen).

ONE permission to switch on (first install only):
  System Settings > Privacy & Security > Accessibility > turn ON "Speedy Bot"
  Speedy Bot asks for this when it opens (a standard account needs an admin password).
  It is what lets Speedy Bot press Cmd+V and type for you. Updates keep the permission.

What it does:
  - Take a screenshot, move the pointer onto ChatGPT: the screenshot pastes itself into the message box.
  - Cmd+Shift+V in a ScreenConnect session types your copied text into the remote machine. Esc stops it.
  - Optional: saves every screenshot under Documents > SpeedyBot Documentation, by incident number.
While a screenshot feature is on, screenshots go to the clipboard instead of the Desktop.

Optional (macOS 26 or later): Control Center > Edit Controls > add "Speedy Bot" for a one-tap on/off.
Update later: run this same command again.
EOF
}

# The whole script is wrapped in main() and called on the LAST line, so a download that is
# cut off halfway can never execute a partial script.
main "$@"
