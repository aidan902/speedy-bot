#!/bin/bash
# Build Speedy Bot (universal, Release).   scripts/build.sh [--adhoc]
#
# Build products go to ~/Library/Caches/speedy-bot-build, never into the project folder: a project kept in an
# iCloud-synced folder picks up file-provider attributes that make codesign refuse the bundle.
#
#   SPEEDYBOT_SIGN_ID   signing identity (SHA-1 or name). Default: the first "Developer ID Application"
#                       certificate for the team in the keychain, by SHA-1 (names can be ambiguous).
#   --adhoc             sign ad hoc instead (no certificate needed; the Accessibility grant then has to be
#                       given again after every rebuild).
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${SPEEDYBOT_TEAM_ID:-SRPFLCC723}"
OUT="${SPEEDYBOT_BUILD_DIR:-$HOME/Library/Caches/speedy-bot-build}"
SIGN_ID="${SPEEDYBOT_SIGN_ID:-}"
[ "${1:-}" = "--adhoc" ] && SIGN_ID="-"

if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk -v t="($TEAM_ID)" '/Developer ID Application/ && index($0, t) { print $2; exit }')"
  [ -n "$SIGN_ID" ] || { echo "No Developer ID Application certificate for team $TEAM_ID. Use --adhoc or set SPEEDYBOT_SIGN_ID." >&2; exit 1; }
fi

command -v xcodegen >/dev/null || { echo "xcodegen is needed: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

xcodebuild -project SpeedyBot.xcodeproj -scheme SpeedyBot -configuration Release \
  -derivedDataPath "$OUT" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="$SIGN_ID" build 2>&1 | grep -E "\.swift:[0-9]+:[0-9]+: (error|warning)|^error:|BUILD (SUCCEEDED|FAILED)" | sort -u || true

APP="$OUT/Build/Products/Release/Speedy Bot.app"
[ -d "$APP" ] || { echo "Build failed." >&2; exit 1; }
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/Speedy Bot" --selftest
echo "Built: $APP"
