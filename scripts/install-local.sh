#!/bin/bash
# Install the local build into /Applications and check it against the real ChatGPT.   scripts/install-local.sh
#
# Quits the running copy, puts the build from scripts/build.sh in its place, starts it again quietly (it comes back
# in the mode it was in), then asks the installed app whether auto-send would send into ChatGPT's message box as it
# is right now (--check-chat, the same rule auto-send uses). With ChatGPT's box empty that must say OK; anything
# else means ChatGPT draws its box differently from what Speedy Bot expects, and auto-send would only paste.
set -euo pipefail

OUT="${SPEEDYBOT_BUILD_DIR:-$HOME/Library/Caches/speedy-bot-build}"
APP="$OUT/Build/Products/Release/Speedy Bot.app"
DEST="/Applications/Speedy Bot.app"
[ -d "$APP" ] || { echo "No build at $APP; run scripts/build.sh first." >&2; exit 1; }

osascript -e 'tell application id "net.fm.speedybot" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 30); do pgrep -f "Speedy Bot.app/Contents/MacOS/Speedy Bot" >/dev/null || break; sleep 0.2; done

ditto "$APP" "$DEST.new"
rm -rf "$DEST.old"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$DEST.new" "$DEST"
rm -rf "$DEST.old"
codesign --verify --strict "$DEST"
open -g -a "$DEST" "speedybot://start"   # this copy, not whichever one was registered last (the build folder)
echo "Installed $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString) ($(defaults read "$DEST/Contents/Info" CFBundleVersion))"

set +e
"$DEST/Contents/MacOS/Speedy Bot" --check-chat
status=$?
set -e
case $status in
  0) echo "Live check passed: auto-send would send." ;;
  1) echo "LIVE CHECK FAILED (see above). If ChatGPT's message box really is empty, auto-send needs a fix before use." ;;
  *) echo "Live check skipped: open ChatGPT (empty message box) and run: \"$DEST/Contents/MacOS/Speedy Bot\" --check-chat" ;;
esac
