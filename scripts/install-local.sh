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

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Quit every running copy by its process (asking "the app with this id" to quit can start a different copy first).
# Speedy Bot turns SIGTERM into a normal quit, which puts the screenshot settings back on its way out.
pids="$(pgrep -f "Speedy Bot.app/Contents/MacOS/Speedy Bot$" || true)"
[ -n "$pids" ] && kill -TERM $pids 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -f "Speedy Bot.app/Contents/MacOS/Speedy Bot$" >/dev/null || break; sleep 0.2; done
if pgrep -f "Speedy Bot.app/Contents/MacOS/Speedy Bot$" >/dev/null; then
  echo "Speedy Bot did not quit; nothing was installed." >&2
  exit 1
fi

ditto "$APP" "$DEST.new"
rm -rf "$DEST.old"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$DEST.new" "$DEST"
rm -rf "$DEST.old"
codesign --verify --strict "$DEST"
"$LSREGISTER" -u "$APP" 2>/dev/null || true
"$LSREGISTER" -f "$DEST" 2>/dev/null || true
open -g -a "$DEST" "speedybot://start"   # this copy, not whichever one was registered last (the build folder)
for _ in $(seq 1 25); do pgrep -f "^$DEST/Contents/MacOS/Speedy Bot$" >/dev/null && break; sleep 0.2; done
# Then until it has finished starting (it writes its state file), so the check below starts after it.
STATE="$HOME/Library/Application Support/Speedy Bot/state.json"
pid="$(pgrep -f "^$DEST/Contents/MacOS/Speedy Bot$" | head -1 || true)"
for _ in $(seq 1 25); do
  [ -n "$pid" ] && grep -q "\"pid\":$pid," "$STATE" 2>/dev/null && grep -q '"running":true' "$STATE" 2>/dev/null && break
  sleep 0.2
done
running="$(pgrep -fl "Speedy Bot.app/Contents/MacOS/Speedy Bot$" || true)"
case "$running" in
  *"$DEST/Contents/MacOS/Speedy Bot"*) ;;
  *) echo "WARNING: the installed copy is not the one running: ${running:-none}" >&2 ;;
esac
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
