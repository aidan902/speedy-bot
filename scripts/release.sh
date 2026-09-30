#!/bin/bash
# Speedy Bot — Developer ID release: sign inside-out -> verify -> zip + disk image ->
# notarize -> staple -> Gatekeeper check. The app embeds a WidgetKit extension (.appex),
# which keeps its OWN entitlements (it must stay sandboxed; the app must not be).
#
#   scripts/release.sh "/path/to/Speedy Bot.app"               sign + verify + package (NO Apple upload)
#   scripts/release.sh "/path/to/Speedy Bot.app" --notarize    ...then notarize and staple app and disk image
#
# Options:
#   --out DIR                   output folder (default: ~/Library/Caches/speedybot-release)
#   --profile NAME              notarytool keychain profile (default: $SPEEDYBOT_NOTARY_PROFILE,
#                               else "SpeedyBot-Notary")
#   --identity SHA1             signing identity (default: a Developer ID Application cert in
#                               team $TEAM_ID, resolved to its SHA-1)
#   --app-entitlements FILE     entitlements for the app (default: keep what the build has)
#   --appex-entitlements FILE   entitlements for every .appex (default: keep what each has)
#   --smoke "ARGS"              run the signed executable headlessly with ARGS (e.g.
#                               "--selftest"), require exit 0, then re-verify the seal
#   --allow-single-arch         let --notarize go ahead with a build that is not universal
#
# Build the input with scripts/build.sh (universal: Intel + Apple silicon).
#
# The input bundle is never modified, and nothing is staged inside the project folder: all
# work happens in a temporary folder, because a synced folder (iCloud Desktop/Documents)
# adds file attributes that break code signatures. Works with the system bash 3.2.
set -euo pipefail

TEAM_ID="${SPEEDYBOT_TEAM_ID:-SRPFLCC723}"
ZIP_BASENAME="${SPEEDYBOT_ZIP_BASENAME:-SpeedyBot}"   # no spaces: it ends up in a URL
VOLUME_NAME="Speedy Bot"

APP_SRC=""; OUT="${SPEEDYBOT_RELEASE_DIR:-$HOME/Library/Caches/speedybot-release}"; NOTARIZE=0
PROFILE="${SPEEDYBOT_NOTARY_PROFILE:-SpeedyBot-Notary}"
SIGN_ID="${SPEEDYBOT_SIGN_ID:-}"
APP_ENT_OVERRIDE=""; APPEX_ENT_OVERRIDE=""; SMOKE_ARGS=""; ALLOW_SINGLE_ARCH=0

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --notarize) NOTARIZE=1 ;;
    --allow-single-arch) ALLOW_SINGLE_ARCH=1 ;;
    --out) OUT="${2:?--out needs a directory}"; shift ;;
    --profile) PROFILE="${2:?--profile needs a name}"; shift ;;
    --identity) SIGN_ID="${2:?--identity needs a SHA-1}"; shift ;;
    --app-entitlements) APP_ENT_OVERRIDE="${2:?--app-entitlements needs a file}"; shift ;;
    --appex-entitlements) APPEX_ENT_OVERRIDE="${2:?--appex-entitlements needs a file}"; shift ;;
    --smoke) SMOKE_ARGS="${2:?--smoke needs the arguments to run with}"; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage 2 ;;
    *) [ -z "$APP_SRC" ] || die "more than one app path given"; APP_SRC="$1" ;;
  esac
  shift
done

# ------------------------------------------------------------------ preflight
[ -n "$APP_SRC" ] || usage 2
APP_SRC="${APP_SRC%/}"
[ -d "$APP_SRC" ] || die "no app bundle at: $APP_SRC"
case "$APP_SRC" in *.app) ;; *) die "not an .app bundle: $APP_SRC" ;; esac
[ -f "$APP_SRC/Contents/Info.plist" ] || die "$APP_SRC has no Contents/Info.plist"
[ -z "$APP_ENT_OVERRIDE" ]   || [ -f "$APP_ENT_OVERRIDE" ]   || die "no such file: $APP_ENT_OVERRIDE"
[ -z "$APPEX_ENT_OVERRIDE" ] || [ -f "$APPEX_ENT_OVERRIDE" ] || die "no such file: $APPEX_ENT_OVERRIDE"
for tool in codesign ditto xcrun security plutil spctl shasum file hdiutil lipo; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

PB=/usr/libexec/PlistBuddy
APP_NAME="$(basename "$APP_SRC")"                                   # "Speedy Bot.app"
BUNDLE_ID="$($PB -c 'Print :CFBundleIdentifier' "$APP_SRC/Contents/Info.plist")"
VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
MIN_OS="$($PB -c 'Print :LSMinimumSystemVersion' "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo '?')"
MAIN_EXE="$($PB -c 'Print :CFBundleExecutable' "$APP_SRC/Contents/Info.plist")"

# Identity. A keychain can hold two Developer ID Application certificates with the same
# name, and codesign refuses a name that matches more than one ("ambiguous"), so always
# sign by SHA-1.
if [ -z "$SIGN_ID" ]; then
  MATCHES="$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" || true)"
  [ -n "$MATCHES" ] || die "no 'Developer ID Application' certificate for team $TEAM_ID in the keychain.
  (Apple Development certs cannot be notarized; Developer ID Installer only signs .pkg.)"
  SIGN_ID="$(printf '%s\n' "$MATCHES" | head -1 | awk '{print $2}')"
fi
say "app:       $APP_NAME  ($BUNDLE_ID $VERSION, min macOS $MIN_OS)"
say "identity:  $SIGN_ID  (team $TEAM_ID)"

# Notary profile — checked BEFORE any work, so a missing credential fails in one second
# instead of after the build is signed. `history` is a read-only call.
if [ "$NOTARIZE" = 1 ]; then
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF

FAILED: no working notarytool keychain profile named "$PROFILE".

  Store one once. Leave --password OFF so notarytool prompts for it — that keeps the
  app-specific password out of shell history:

      xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id $TEAM_ID

  (App-specific passwords: account.apple.com -> Sign-In and Security -> App-Specific Passwords.)
  Then re-run this script. Nothing was signed or uploaded.
EOF
    exit 1
  fi
  say "notary:    keychain profile \"$PROFILE\""
fi

# ------------------------------------------------------------------ stage a clean copy
WORK="$(mktemp -d "${TMPDIR:-/tmp}/speedybot-release.XXXXXX")"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
APP="$WORK/$APP_NAME"
ENTDIR="$WORK/entitlements"
mkdir -p "$ENTDIR"
say "stage a clean copy (the input bundle is never modified)"
ditto "$APP_SRC" "$APP"
xattr -cr "$APP"                      # quarantine / Finder attrs would end up inside the seal
find "$APP" -name ".DS_Store" -delete

# ------------------------------------------------------------------ entitlements
# Every signed item keeps ITS OWN entitlements (the appex must stay sandboxed; the app must
# not be), minus get-task-allow: Xcode injects that into anything it builds outside
# "Archive", and the notary service rejects it. Writes the plist to $2; returns 1 if the
# item ends up with no entitlements at all.
ENT_N=0
prepare_entitlements() {   # <code path> <override file or ""> -> echoes plist path, or nothing
  local item="$1" override="$2" out
  ENT_N=$((ENT_N+1)); out="$ENTDIR/$ENT_N-$(basename "$item").plist"
  if [ -n "$override" ]; then
    cp "$override" "$out"
  else
    codesign -d --entitlements - --xml "$item" >"$out" 2>/dev/null || true
  fi
  [ -s "$out" ] || { rm -f "$out"; return 0; }
  plutil -convert xml1 "$out" 2>/dev/null || die "could not read entitlements of $item"
  $PB -c 'Delete :com.apple.security.get-task-allow' "$out" >/dev/null 2>&1 || true
  if [ "$(plutil -convert json -o - "$out" 2>/dev/null)" = "{}" ]; then rm -f "$out"; return 0; fi

  # Restricted entitlements need a provisioning profile. Without one the app notarizes
  # fine and is then killed at launch by AMFI — the worst kind of failure, so stop here.
  local restricted
  restricted="$(plutil -p "$out" | grep -oE '"(com\.apple\.developer\.[^"]+|com\.apple\.application-identifier|keychain-access-groups)"' || true)"
  if [ -n "$restricted" ] && [ ! -f "$item/Contents/embedded.provisionprofile" ]; then
    die "$(basename "$item") carries restricted entitlements but embeds no provisioning profile:
$restricted
  Remove them from the target's .entitlements (Speedy Bot is meant to need no profile),
  or pass a clean file with --app-entitlements / --appex-entitlements."
  fi
  # App groups: only the TEAMID-prefixed form works on macOS without a profile.
  local badgroup
  badgroup="$(plutil -extract 'com\.apple\.security\.application-groups' json -o - "$out" 2>/dev/null \
              | tr ',' '\n' | grep -oE '"[^"]+"' | grep -v "\"$TEAM_ID\." || true)"
  [ -z "$badgroup" ] || die "$(basename "$item") uses app group $badgroup — without a provisioning profile
  the group must be prefixed with the team ID, e.g. \"$TEAM_ID.net.fm.speedybot\"."
  printf '%s' "$out"
}

sign_item() {   # <path> <entitlements override or "">
  local item="$1" ent
  ent="$(prepare_entitlements "$item" "${2:-}")"
  case "$item" in
    *.appex)
      # A widget/control extension that is not sandboxed is silently never loaded.
      if [ -z "$ent" ] || ! plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$ent" 2>/dev/null | grep -q true; then
        die "$(basename "$item") has no com.apple.security.app-sandbox entitlement — the system will not load it."
      fi ;;
  esac
  if [ -n "$ent" ]; then
    codesign --force --options runtime --timestamp --entitlements "$ent" --sign "$SIGN_ID" "$item" 2>"$WORK/codesign.log" \
      || { sed 's/^/    /' "$WORK/codesign.log" >&2; die "codesign failed for: $item   (timestamp server unreachable? keychain locked?)"; }
    note "signed (with entitlements)  ${item#$WORK/}"
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$item" 2>"$WORK/codesign.log" \
      || { sed 's/^/    /' "$WORK/codesign.log" >&2; die "codesign failed for: $item   (timestamp server unreachable? keychain locked?)"; }
    note "signed                      ${item#$WORK/}"
  fi
  SIGNED_LIST="$SIGNED_LIST$item
"
}
SIGNED_LIST=""

# ------------------------------------------------------------------ sign inside-out
# Never --deep for signing: it would stamp the app's entitlements onto the appex and
# un-sandbox it. Order: loose Mach-O files, then nested bundles deepest-first, the app last.
is_bundle_main_exec() {   # is this file the main executable of the bundle that contains it?
  local f="$1" dir base plist
  dir="$(dirname "$f")"; base="$(basename "$f")"
  case "$dir" in
    */Contents/MacOS)
      plist="$(dirname "$dir")/Info.plist"
      [ -f "$plist" ] && [ "$($PB -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)" = "$base" ] && return 0 ;;
    *.framework/Versions/*|*.framework)
      case "$dir" in *"/$base.framework"*) return 0 ;; esac ;;
  esac
  return 1
}
depth_sorted() { awk '{ n = gsub("/", "/"); print n " " $0 }' | sort -rn | cut -d' ' -f2-; }

say "sign nested code (hardened runtime + secure timestamp)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  file -b "$f" | grep -q "Mach-O" || continue
  is_bundle_main_exec "$f" && continue
  sign_item "$f" ""
done < <(find "$APP/Contents" -type f \( -perm -u+x -o -name "*.dylib" -o -name "*.so" \) ! -type l | depth_sorted)

while IFS= read -r b; do
  [ -n "$b" ] || continue
  case "$b" in
    *.appex) sign_item "$b" "$APPEX_ENT_OVERRIDE" ;;
    *)       sign_item "$b" "" ;;
  esac
done < <(find "$APP/Contents" -type d \( -name "*.appex" -o -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "*.bundle" \) | depth_sorted)

say "sign the app"
sign_item "$APP" "$APP_ENT_OVERRIDE"

# ------------------------------------------------------------------ verify
say "verify"
codesign --verify --deep --strict --verbose=2 "$APP" >"$WORK/verify.log" 2>&1 \
  || { sed 's/^/    /' "$WORK/verify.log" >&2; die "codesign --verify --deep --strict rejected the bundle"; }
sed "s|$WORK/||; s/^/    /" "$WORK/verify.log"

# The exact requirement install.sh enforces on the tech's Mac — if it fails here it
# would fail there.
REQ="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
codesign --verify --strict -R="$REQ" "$APP" || die "app does not satisfy the Developer ID requirement for team $TEAM_ID"

printf '%s' "$SIGNED_LIST" | while IFS= read -r item; do
  [ -n "$item" ] || continue
  info="$(codesign -dv --verbose=4 "$item" 2>&1)"
  name="${item#$WORK/}"
  printf '%s\n' "$info" | grep -q "^TeamIdentifier=$TEAM_ID\$"          || die "$name: TeamIdentifier is not $TEAM_ID"
  printf '%s\n' "$info" | grep -q "^Authority=Developer ID Application" || die "$name: not signed with Developer ID Application"
  printf '%s\n' "$info" | grep -qE "flags=0x[0-9a-f]+\(.*runtime.*\)"   || die "$name: hardened runtime is OFF"
  printf '%s\n' "$info" | grep -q "^Timestamp="                         || die "$name: no secure timestamp (notarization requires one)"
  if codesign -d --entitlements - --xml "$item" 2>/dev/null | grep -q "get-task-allow"; then
    die "$name: still carries get-task-allow"
  fi
done
note "every signed item: Developer ID ($TEAM_ID), hardened runtime, secure timestamp, no get-task-allow"

# Universal or not: an arm64-only build installs fine on an Intel Mac and then cannot launch.
UNIVERSAL=1
check_archs() {   # <label> <executable>
  local archs
  archs="$(lipo -archs "$2" 2>/dev/null || echo '?')"
  note "$1: $archs"
  case "$archs" in *x86_64*arm64*|*arm64*x86_64*) ;; *) UNIVERSAL=0 ;; esac
}
check_archs "app architectures" "$APP/Contents/MacOS/$MAIN_EXE"
while IFS= read -r ex; do
  [ -n "$ex" ] || continue
  check_archs "appex ${ex#$APP/} (sandboxed)" "$ex/Contents/MacOS/$($PB -c 'Print :CFBundleExecutable' "$ex/Contents/Info.plist")"
done < <(find "$APP/Contents" -type d -name "*.appex")
if [ "$UNIVERSAL" != 1 ]; then
  if [ "$NOTARIZE" = 1 ] && [ "$ALLOW_SINGLE_ARCH" != 1 ]; then
    die "this build is not universal (Intel + Apple silicon). Build with scripts/build.sh, or pass --allow-single-arch."
  fi
  note "WARNING: not universal — it will not run on the other CPU family."
fi

# ------------------------------------------------------------------ smoke test (optional)
# Proves the SIGNED binary is allowed to launch with its entitlements (AMFI kills a
# Developer ID app carrying an entitlement it is not entitled to — only visible on a real
# signature) and that running it does not write inside the bundle and break the seal.
if [ -n "$SMOKE_ARGS" ]; then
  say "smoke test: \"$MAIN_EXE\" $SMOKE_ARGS"
  # shellcheck disable=SC2086
  "$APP/Contents/MacOS/$MAIN_EXE" $SMOKE_ARGS >"$WORK/smoke.log" 2>&1 &
  SMOKE_PID=$!
  ( sleep 20; kill -9 "$SMOKE_PID" 2>/dev/null ) >/dev/null 2>&1 &
  WATCHDOG=$!
  RC=0; wait "$SMOKE_PID" 2>/dev/null || RC=$?
  kill "$WATCHDOG" 2>/dev/null || true
  wait "$WATCHDOG" 2>/dev/null || true       # reap it quietly (no "Terminated" job notice)
  sed 's/^/    | /' "$WORK/smoke.log"
  [ "$RC" = 0 ] || die "signed build exited $RC under '$SMOKE_ARGS' (137 = killed: by AMFI for a bad entitlement, or the 20 s watchdog)"
  codesign --verify --deep --strict "$APP" || die "running the app broke its own signature (it wrote inside its bundle)"
  note "ran, exited 0, and the signature still verifies"
fi

# ------------------------------------------------------------------ package
mkdir -p "$OUT"
REQ_APP="identifier \"$BUNDLE_ID\" and $REQ"

make_zip() {   # <zip path>
  xattr -cr "$APP"
  rm -f "$1"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$1"
}

# A disk image holding the app and a shortcut to /Applications: open it, drag, done.
make_dmg() {   # <dmg path>
  local stage="$WORK/dmg-stage"
  rm -rf "$stage"; mkdir -p "$stage"
  xattr -cr "$APP"
  ditto "$APP" "$stage/$APP_NAME"
  ln -s /Applications "$stage/Applications"
  rm -f "$1"
  hdiutil create -volname "$VOLUME_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
    -ov -quiet "$1" || die "hdiutil could not create the disk image"
  codesign --force --timestamp --sign "$SIGN_ID" "$1" 2>"$WORK/codesign.log" \
    || { sed 's/^/    /' "$WORK/codesign.log" >&2; die "codesign failed for the disk image"; }
}

# Apple's verdict on one upload. notarytool exits 0 even for a submission Apple REJECTED
# ("Invalid"), so the status — not the exit code — is the gate.
notarize() {   # <file> <label>
  local result="$WORK/notary-$2.json" id status
  say "notarize the $2 (uploads to Apple; usually 1-5 minutes)"
  if ! xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m \
         --output-format json >"$result" 2>"$WORK/notary-stderr.log"; then
    sed 's/^/    /' "$WORK/notary-stderr.log" >&2 || true
    sed 's/^/    /' "$result" >&2 || true
    die "notarytool submit failed (network, expired credentials, or an unsigned agreement at developer.apple.com)."
  fi
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  note "submission $id: ${status:-unknown}"
  if [ "$status" != "Accepted" ]; then
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/notary-log-$2.json" >/dev/null 2>&1 || true
    [ -f "$OUT/notary-log-$2.json" ] && sed 's/^/    /' "$OUT/notary-log-$2.json" >&2
    die "Apple did not accept the $2 (status: ${status:-unknown}). Log: $OUT/notary-log-$2.json"
  fi
}

staple() {   # <file>
  local attempt
  for attempt in 1 2 3 4 5; do
    if xcrun stapler staple "$1" >"$WORK/stapler.log" 2>&1; then
      xcrun stapler validate "$1" >/dev/null 2>&1 || die "stapler validate failed for $(basename "$1")"
      return 0
    fi
    note "ticket not available yet (attempt $attempt/5) — retrying in 15 s"
    sleep 15
  done
  sed 's/^/    /' "$WORK/stapler.log" >&2
  die "could not staple $(basename "$1") although Apple accepted it. Re-run this script in a few minutes."
}

# What a tech's Mac will actually receive: unpack the zip and mount the image, and check the
# app inside each the same way the installer does.
verify_as_delivered() {   # <zip> <dmg>
  local unz="$WORK/verify-zip"
  rm -rf "$unz"; mkdir -p "$unz"
  ditto -x -k "$1" "$unz" || die "the zip does not unpack"
  codesign --verify --deep --strict "$unz/$APP_NAME" || die "the app inside the zip fails signature verification"
  codesign --verify --strict -R="$REQ_APP" "$unz/$APP_NAME" || die "the app inside the zip is not signed by team $TEAM_ID"

  MOUNT="$WORK/verify-dmg"; mkdir -p "$MOUNT"
  hdiutil attach "$2" -nobrowse -readonly -mountpoint "$MOUNT" -quiet || { MOUNT=""; die "the disk image does not mount"; }
  codesign --verify --deep --strict "$MOUNT/$APP_NAME" || die "the app inside the disk image fails signature verification"
  codesign --verify --strict -R="$REQ_APP" "$MOUNT/$APP_NAME" || die "the app inside the disk image is not signed by team $TEAM_ID"
  [ -L "$MOUNT/Applications" ] || die "the disk image has no Applications shortcut"
  hdiutil detach "$MOUNT" -quiet || true
  MOUNT=""
  codesign --verify --strict "$2" || die "the disk image's own signature does not verify"
  note "zip and disk image both contain an intact app signed by team $TEAM_ID"
}

write_sums() { local f; for f in "$@"; do ( cd "$(dirname "$f")" && shasum -a 256 "$(basename "$f")" >"$(basename "$f").sha256" ); done; }

if [ "$NOTARIZE" != 1 ]; then
  ZIP="$OUT/$ZIP_BASENAME-$VERSION-mac-UNNOTARIZED.zip"
  DMG="$OUT/$ZIP_BASENAME-$VERSION-UNNOTARIZED.dmg"
  say "zip"
  make_zip "$ZIP"
  say "disk image"
  make_dmg "$DMG"
  say "verify what would be delivered"
  verify_as_delivered "$ZIP" "$DMG"
  write_sums "$ZIP" "$DMG"
  cat <<EOF

OK: signed + verified (Developer ID, hardened runtime) — NOT notarized.
  zip        : $ZIP
  disk image : $DMG
  Downloaded through a browser these are blocked by Gatekeeper on first open
  (System Settings > Privacy & Security > Open Anyway gets past it).
  To make a release anyone can open:   "$0" "$APP_SRC" --notarize
EOF
  exit 0
fi

# ------------------------------------------------------------------ notarize
ZIP="$OUT/$ZIP_BASENAME-$VERSION-mac.zip"
LATEST_ZIP="$OUT/$ZIP_BASENAME-mac.zip"      # version-less names = the stable download links
DMG="$OUT/$ZIP_BASENAME-$VERSION.dmg"
LATEST_DMG="$OUT/$ZIP_BASENAME.dmg"
rm -f "$ZIP" "$LATEST_ZIP" "$DMG" "$LATEST_DMG"    # never leave an older or rejected build where it could be shared

say "zip for submission"
make_zip "$WORK/submit.zip"
notarize "$WORK/submit.zip" app
say "staple the app"
staple "$APP"

say "Gatekeeper assessment of the app"
GK="$(spctl -a -vvv -t exec "$APP" 2>&1 || true)"
printf '%s\n' "$GK" | sed 's/^/    /'
printf '%s\n' "$GK" | grep -q "source=Notarized Developer ID" || die "Gatekeeper does not report 'Notarized Developer ID' for the stapled app."
codesign --verify --deep --strict "$APP" || die "signature broke after stapling"

say "zip (now with the stapled ticket)"
make_zip "$ZIP"
say "disk image"
make_dmg "$DMG"
notarize "$DMG" disk-image
say "staple the disk image"
staple "$DMG"
GK="$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
printf '%s\n' "$GK" | sed 's/^/    /'
printf '%s\n' "$GK" | grep -q "source=Notarized Developer ID" || die "Gatekeeper does not report 'Notarized Developer ID' for the disk image."

say "verify what will be delivered"
verify_as_delivered "$ZIP" "$DMG"
cp "$ZIP" "$LATEST_ZIP"
cp "$DMG" "$LATEST_DMG"
write_sums "$ZIP" "$LATEST_ZIP" "$DMG" "$LATEST_DMG"

cat <<EOF

OK: Speedy Bot $VERSION is signed, notarized and stapled.
  disk image : $LATEST_DMG      (and $(basename "$DMG"))
  zip        : $LATEST_ZIP      (and $(basename "$ZIP"); the installer downloads this one)
  NOT PUBLISHED: this script uploads nothing but the notarization requests.
  Next: attach $(basename "$LATEST_DMG"), $(basename "$LATEST_ZIP") and scripts/install.sh to a GitHub release.
EOF
