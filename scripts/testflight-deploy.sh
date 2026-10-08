#!/bin/bash
#
# Archive the iPad app and, only when asked, upload it to TestFlight.
#
#   testflight-deploy.sh                      archive + export an .ipa, no upload
#   testflight-deploy.sh --upload             archive + export + upload to App Store Connect
#   testflight-deploy.sh --build-number N     override the build number (default: commit count)
#
# Deliberately not wired into CI or any automation: an upload is visible to TestFlight testers and
# permanently consumes a build number, so it only ever happens when someone runs this with --upload.
# It also cannot run on GitHub's macOS runners yet -- they have no Xcode 27 (#363) -- so it relies
# on the signing identities already on Patrick's Mac.
#
# Authentication is an App Store Connect API key, so nothing prompts for an Apple ID or 2FA:
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8   the key (altool's default search path)
#   ~/.appstoreconnect/pickpic.env                            ASC_KEY_ID=... and ASC_ISSUER_ID=...
# Both stay outside the repo, which is public. Environment variables override the env file.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/ipad/PickPic.xcodeproj"
SCHEME="PickPic"
ASC_CONFIG="${ASC_CONFIG:-$HOME/.appstoreconnect/pickpic.env}"

upload=false
build_number=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upload) upload=true ;;
    --build-number)
      build_number="${2:?--build-number needs a value}"
      shift
      ;;
    -h | --help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

die() {
  echo "error: $*" >&2
  exit 1
}

# --- credentials ---------------------------------------------------------------------------------

env_key_id="${ASC_KEY_ID:-}"
env_issuer_id="${ASC_ISSUER_ID:-}"
if [ -f "$ASC_CONFIG" ]; then
  # shellcheck source=/dev/null
  . "$ASC_CONFIG"
fi
ASC_KEY_ID="${env_key_id:-${ASC_KEY_ID:-}}"
ASC_ISSUER_ID="${env_issuer_id:-${ASC_ISSUER_ID:-}}"
[ -n "$ASC_KEY_ID" ] || die "ASC_KEY_ID is not set (expected in $ASC_CONFIG)"
[ -n "$ASC_ISSUER_ID" ] || die "ASC_ISSUER_ID is not set (expected in $ASC_CONFIG)"
key_path="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[ -f "$key_path" ] || die "API key not found at $key_path"

# The archive is signed with the Apple Development identity in the login keychain. Over SSH -- how
# Patrick drives this Mac from the iPad -- every session sees that keychain as locked, whatever its
# state on the Mac's own screen, and codesign then fails only after a full compile with a bare
# errSecInternalComponent. Check up front instead. Exit 36 is errSecInteractionNotAllowed.
login_keychain="$HOME/Library/Keychains/login.keychain-db"
if ! security show-keychain-info "$login_keychain" >/dev/null 2>&1; then
  die "login keychain is locked in this session; run: security unlock-keychain $login_keychain"
fi

auth_args=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$key_path"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

# --- build number --------------------------------------------------------------------------------

# The build must match a commit, both so a TestFlight build can be traced back to source and so the
# commit-count build number below means something. Untracked files are ignored: they are not built.
if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
  die "working tree has uncommitted changes; commit or stash them first"
fi
commit="$(git -C "$REPO" rev-parse --short HEAD)"
branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"

# TestFlight rejects a build number it has already seen for the same marketing version, and the
# project's CURRENT_PROJECT_VERSION is a static 1. The commit count rises monotonically along main;
# a build from a short-lived branch can collide with an earlier one, which is what --build-number
# is for. It is passed as a build-setting override rather than written into project.pbxproj, so
# nothing is edited on disk and Xcode can stay open (CLAUDE.md trap 4).
build_number="${build_number:-$(git -C "$REPO" rev-list --count HEAD)}"
[[ "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "invalid build number: $build_number"

out_dir="/tmp/pickpic-testflight/$build_number"
archive_path="$out_dir/PickPic.xcarchive"
export_path="$out_dir/export"
rm -rf "$out_dir"
mkdir -p "$out_dir"

echo "PickPic build $build_number ($branch @ $commit) -> $out_dir"

# Full xcodebuild logs are enormous; keep them on disk and print only the outcome, so a remote
# Claude session running this doesn't carry thousands of lines of build output in context.
run_logged() {
  local name="$1"
  shift
  local log="$out_dir/$name.log"
  if ! "$@" >"$log" 2>&1; then
    echo "$name failed; log: $log" >&2
    grep -E "error:|errSec|Command .* failed|\*\* .* FAILED \*\*" "$log" | tail -30 >&2 || tail -30 "$log" >&2
    exit 1
  fi
  echo "$name ok"
}

# --- archive -------------------------------------------------------------------------------------

run_logged archive xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$out_dir/DerivedData" \
  "${auth_args[@]}" \
  CURRENT_PROJECT_VERSION="$build_number"

# --- export --------------------------------------------------------------------------------------

# manageAppVersionAndBuildNumber is off so the uploaded build number is exactly the one above rather
# than whatever Xcode picks after querying App Store Connect.
export_options="$out_dir/ExportOptions.plist"
cat >"$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>BQGJZNJFVU</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

run_logged export xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  "${auth_args[@]}"

ipa="$(find "$export_path" -maxdepth 1 -name '*.ipa' | head -1)"
[ -n "$ipa" ] || die "export produced no .ipa in $export_path"

# Confirm the override actually reached the shipped Info.plist before spending an upload on it.
plist="$out_dir/Info.plist"
unzip -p "$ipa" 'Payload/*.app/Info.plist' >"$plist"
shipped_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
shipped_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
[ "$shipped_build" = "$build_number" ] ||
  die "ipa has CFBundleVersion $shipped_build, expected $build_number"
echo "ipa: $ipa (version $shipped_version, build $shipped_build)"

# --- upload --------------------------------------------------------------------------------------

if ! $upload; then
  echo "Not uploading; rerun with --upload to send this build to TestFlight."
  exit 0
fi

# altool --upload-package is the current non-interactive upload path (Xcode 27's altool help lists
# it first; --upload-app is the older form). It finds AuthKey_<id>.p8 in
# ~/.appstoreconnect/private_keys on its own. The output is short, so it is shown in full.
if ! xcrun altool --upload-package "$ipa" \
  --api-key "$ASC_KEY_ID" \
  --api-issuer "$ASC_ISSUER_ID" \
  2>&1 | tee "$out_dir/upload.log"; then
  die "upload failed; log: $out_dir/upload.log"
fi

echo "Uploaded build $build_number. It appears in TestFlight once App Store Connect finishes processing."
