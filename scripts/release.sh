#!/bin/bash
# Build, sign (Developer ID), notarize and package Ring for distribution.
#
# Usage:  TEAM=ABCDE12345 scripts/release.sh            (or: make release TEAM=ABCDE12345)
#
#   TEAM            Your Apple Developer Team ID (required).
#   NOTARY_PROFILE  notarytool keychain profile name (default: ring-notary). Create it once with:
#                     xcrun notarytool store-credentials ring-notary \
#                       --apple-id you@example.com --team-id ABCDE12345 --password <app-specific password>
#   SMALL=1         Build against the minimal SDK from `make sdk` instead of the prebuilt one.
#
# Output: dist/Ring-<version>.zip containing the signed, notarized, stapled Ring.app.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${TEAM:?Set TEAM to your Apple Developer Team ID, e.g. make release TEAM=ABCDE12345}"
PROFILE="${NOTARY_PROFILE:-ring-notary}"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)"
DERIVED="build/release"
APP="$DERIVED/Build/Products/Release/Ring.app"
mkdir -p dist
ZIP="dist/Ring-$VERSION.zip"

echo "==> Ring $VERSION, team $TEAM, notary profile $PROFILE"

# 1. Check the signing identity and notary profile exist before a long build.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application:.*($TEAM)"; then
  echo "No 'Developer ID Application' certificate for team $TEAM in your keychain." >&2
  echo "Create one in Xcode › Settings › Accounts › Manage Certificates (+ › Developer ID Application)." >&2
  exit 1
fi
if ! NOTARY_CHECK=$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1); then
  echo "Can't use the notary profile '$PROFILE'. notarytool said:" >&2
  echo "$NOTARY_CHECK" | sed 's/^/    /' >&2
  echo "If the profile is missing or misnamed, (re)create it with:" >&2
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id $TEAM --password <app-specific password>" >&2
  echo "or point at another name with NOTARY_PROFILE=<name>." >&2
  exit 1
fi

# 2. Generate the project (optionally against the minimal SDK).
SPEC="project.yml"
if [ "${SMALL:-0}" = "1" ]; then
  [ -f build/linphone-sdk-min/linphone-sdk-swift-macos/Package.swift ] || { echo "Run make sdk first." >&2; exit 1; }
  sed -e 's|    url: https://gitlab.linphone.org/BC/public/linphone-sdk-swift-macos.git|    path: build/linphone-sdk-min/linphone-sdk-swift-macos|' \
      -e '/    exactVersion: 5.5.41/d' project.yml > project-small.yml
  SPEC="project-small.yml"
fi
xcodegen generate --spec "$SPEC"

# 3. Universal build signed with Developer ID (hardened runtime + secure timestamp, as notarization
#    requires). The post-build step re-signs the embedded SDK frameworks with the same identity.
xcodebuild -project Ring.xcodeproj -scheme Ring -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
  clean build

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier"

# 4. Notarize: submit a zip, wait for Apple's verdict, then staple the ticket to the app.
echo "==> Notarizing (usually a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
# notarytool exits 0 even when Apple marks the submission Invalid, so check the status ourselves
# and print Apple's log (which lists every problem) when it isn't Accepted.
SUBMIT_OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
SUBMIT_ID=$(echo "$SUBMIT_OUT" | awk '$1 == "id:" {print $2; exit}')
if ! echo "$SUBMIT_OUT" | grep -q "status: Accepted"; then
  echo "==> Notarization was not accepted. Apple's log:" >&2
  [ -n "$SUBMIT_ID" ] && xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$PROFILE" >&2
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper check"
spctl --assess --type execute --verbose=2 "$APP"

# 5. Final archive with the stapled app inside.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Done: $ZIP ($(du -h "$ZIP" | cut -f1))"
