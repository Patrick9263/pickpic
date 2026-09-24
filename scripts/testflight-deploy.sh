#!/bin/bash
#
# Archive the PickPic iPad app and, when asked, upload it to TestFlight.
#
#   testflight-deploy.sh            archive + export an .ipa locally; uploads nothing
#   testflight-deploy.sh --upload   archive + upload the build to App Store Connect
#
# Run by hand only, from a clean checkout of the commit you want to ship. It is deliberately not
# wired into CI: GitHub's macOS runners have no Xcode 27 yet (#363), and an upload is visible to
# testers and burns a build number, so it should never happen as a side effect of something else.
#
# Upload auth is an App Store Connect API key, so nothing prompts for an Apple ID or 2FA -- which is
# the point, since this is meant to be triggered from a Claude session while Patrick is away from
# the Mac. The key never lives in the repo. Put these in ~/.appstoreconnect/pickpic.env:
#
#   ASC_KEY_ID=XXXXXXXXXX
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# and the key itself at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (the path xcodebuild
# and altool both search).
#
# The key must have the Admin role, even for a local export. This Mac holds no Apple Distribution
# certificate -- Xcode's Distribute App flow signs with Apple's cloud-managed one -- and xcodebuild
# refuses cloud signing to any API key below Admin ("Cloud signing permission error"); App Store
# Connect offers no narrower permission for keys. The alternative, a locally installed distribution
# certificate, would be one more secret to back up and rotate, for no gain on a one-person team.
#
# Set BUILD_NUMBER to override the generated build number.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/ipad/PickPic.xcodeproj"
SCHEME="PickPic"
CONFIG_FILE="$HOME/.appstoreconnect/pickpic.env"

UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    -h | --help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 64
      ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

# An uploaded build should correspond to a commit someone can check out later. A dirty tree would
# ship code that exists nowhere else.
if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
  die "working tree has uncommitted changes; commit or discard them first"
fi
COMMIT="$(git -C "$REPO" rev-parse --short HEAD)"

# The export method name and the upload destination both changed shape in recent Xcodes; this
# script is written against 27 and there is no point guessing about older ones.
XCODE_MAJOR="$(xcodebuild -version | awk 'NR==1 { split($2, v, "."); print v[1] }')"
[[ "$XCODE_MAJOR" -ge 27 ]] || die "Xcode 27 or later required (found $(xcodebuild -version | head -1))"

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi
[[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" ]] ||
  die "no App Store Connect API key configured; set ASC_KEY_ID and ASC_ISSUER_ID in $CONFIG_FILE"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[[ -f "$KEY_PATH" ]] || die "API key not found at $KEY_PATH"
AUTH_ARGS=(
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

# TestFlight rejects any build number it has already seen for a version, and the project's
# CURRENT_PROJECT_VERSION is a static 1. Rather than editing project.pbxproj -- which a running
# Xcode would silently clobber (CLAUDE.md trap 4) -- the number is passed as a build-setting
# override; GENERATE_INFOPLIST_FILE turns it into CFBundleVersion. A UTC timestamp is monotonic
# across branches, which a commit count is not, and two components keep each one inside a 32-bit
# integer. manageAppVersionAndBuildNumber is off below so Xcode doesn't silently replace it.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d).$(date -u +%H%M%S)}"

WORK_DIR="/tmp/pickpic-testflight/$BUILD_NUMBER"
ARCHIVE_PATH="$WORK_DIR/PickPic.xcarchive"
EXPORT_PATH="$WORK_DIR/export"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

# Full xcodebuild output is enormous; keep it in a file and show only the tail when a step fails.
run_logged() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  echo "==> $name (log: $log)"
  if ! "$@" >"$log" 2>&1; then
    grep -E "error:|ERROR|failed|Failed" "$log" | tail -20 >&2 || true
    echo "--- last lines of $log ---" >&2
    tail -15 "$log" >&2
    die "$name failed"
  fi
}

echo "PickPic build $BUILD_NUMBER from $COMMIT"

run_logged archive xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "/tmp/pickpic-testflight/DerivedData" \
  -allowProvisioningUpdates \
  "${AUTH_ARGS[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# destination=upload has xcodebuild sign and send the build to App Store Connect in one step, with
# the same API key used for signing -- no separate altool invocation or second credential.
DESTINATION=export
[[ "$UPLOAD" -eq 1 ]] && DESTINATION=upload
EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"
cat >"$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DESTINATION</string>
	<key>teamID</key>
	<string>BQGJZNJFVU</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

run_logged "export-$DESTINATION" xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  "${AUTH_ARGS[@]}"

if [[ "$UPLOAD" -eq 1 ]]; then
  echo "Uploaded build $BUILD_NUMBER ($COMMIT). It appears in TestFlight once App Store Connect finishes processing."
else
  echo "Exported $(ls "$EXPORT_PATH"/*.ipa) -- nothing uploaded. Rerun with --upload to send it to TestFlight."
fi
