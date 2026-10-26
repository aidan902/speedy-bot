#!/bin/bash
# Build the Speedy Bot plugin for Logi Options+ (the Logi Plugin Service) and install it for this user.
#
#   LogiPlugin/build.sh              build, then install into the plugin service and reload it
#   LogiPlugin/build.sh --package    also write SpeedyBot.lplug4 (double-click installs it on another Mac)
#   LogiPlugin/build.sh --no-install build only
#
# Needs the .NET 10 SDK (brew install dotnet): the plugin service runs plugins on .NET 10.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=1; PACKAGE=0
for a in "$@"; do
  case "$a" in
    --package) PACKAGE=1 ;;
    --no-install) INSTALL=0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

DOTNET="$(command -v dotnet || true)"
if [ -z "$DOTNET" ] && command -v brew >/dev/null; then DOTNET="$(brew --prefix dotnet 2>/dev/null)/bin/dotnet"; fi
[ -x "$DOTNET" ] || { echo "The .NET 10 SDK is needed: brew install dotnet" >&2; exit 1; }
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname "$(readlink -f "$DOTNET")")}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

SERVICE="/Applications/Utilities/LogiPluginService.app"
[ -f "$SERVICE/Contents/MonoBundle/PluginApi.dll" ] || { echo "Logi Options+ (with the Logi Plugin Service) is not installed." >&2; exit 1; }

OUT="$HOME/Library/Caches/speedy-bot-build/logi-plugin"
"$DOTNET" build -c Release -o "$OUT/bin" -v quiet -nologo | grep -E "error|warning CS" || true
[ -f "$OUT/bin/SpeedyBotPlugin.dll" ] || { echo "Build failed." >&2; exit 1; }

# The installed layout, the same as Logitech's own plugins: the DLL at the top, metadata/ beside it.
STAGE="$OUT/SpeedyBot"
rm -rf "$STAGE"; mkdir -p "$STAGE/metadata"
cp "$OUT/bin/SpeedyBotPlugin.dll" "$STAGE/"
cp metadata/LoupedeckPackage.yaml metadata/Icon256x256.png "$STAGE/metadata/"
echo "Built: $STAGE"

if [ "$PACKAGE" = 1 ]; then
  rm -f "$OUT/SpeedyBot.lplug4"
  (cd "$STAGE" && zip -qr "$OUT/SpeedyBot.lplug4" .)
  echo "Package: $OUT/SpeedyBot.lplug4"
fi

[ "$INSTALL" = 1 ] || exit 0
PLUGINS="$HOME/Library/Application Support/Logi/LogiPluginService/Plugins"
mkdir -p "$PLUGINS/SpeedyBot"
rsync -a --delete "$STAGE/" "$PLUGINS/SpeedyBot/"
echo "Installed: $PLUGINS/SpeedyBot"

# The service only picks up a new or changed plugin when it starts. Quitting it is safe: Logi Options+ starts it
# again straight away (the keypad goes blank for a few seconds).
LOG="$HOME/Library/Application Support/Logi/LogiPluginService/Logs/plugin_logs/SpeedyBot.log"
SERVICE_PROC="LogiPluginService.app/Contents/MacOS/LogiPluginService"
MARK="$(date +%Y-%m-%dT%H-%M-%S)"
if pgrep -f "$SERVICE_PROC" >/dev/null; then
  echo "Restarting the Logi Plugin Service so it loads the plugin..."
  osascript -e 'with timeout of 15 seconds' -e 'tell application id "com.logi.pluginservice" to quit' -e 'end timeout' >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do pgrep -f "$SERVICE_PROC" >/dev/null || break; sleep 0.25; done
fi
for _ in $(seq 1 12); do pgrep -f "$SERVICE_PROC" >/dev/null && break; sleep 0.5; done
pgrep -f "$SERVICE_PROC" >/dev/null || open -g -b com.logi.pluginservice
# Wait for this start's load line (log lines begin with a sortable time stamp).
for _ in $(seq 1 40); do
  if [ -f "$LOG" ] && awk -v m="$MARK" '$1 >= m && /Started loading plugin/' "$LOG" | grep -q .; then
    echo "Loaded by the Logi Plugin Service. In Logi Options+: All Actions > Speedy Bot > drag \"Speedy Bot On/Off\" onto a key."
    exit 0
  fi
  sleep 0.5
done
echo "The plugin is installed but the service has not reported loading it yet. Check: $LOG" >&2
exit 1
