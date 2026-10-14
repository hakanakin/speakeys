#!/bin/bash
# Builds a signed and notarized dist/Speakeys-<version>.dmg that anyone can open.
#   ./release.sh            build the DMG
#   ./release.sh --publish  also create a GitHub release with it (needs `gh`)
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   2. Notary credentials stored in the keychain:
#      xcrun notarytool store-credentials speakeys-notary --apple-id <you@example.com> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-speakeys-notary}"
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
if [[ -z "$IDENTITY" ]]; then
  echo "No \"Developer ID Application\" certificate found. See the setup notes at the top of this script." >&2
  exit 1
fi

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Speakeys.app/Contents/Info.plist)
DMG="dist/Speakeys-$VERSION.dmg"

echo "==> Signing with $IDENTITY"
codesign --force --options runtime --timestamp --entitlements Speakeys.entitlements --sign "$IDENTITY" Speakeys.app
codesign --verify --strict --verbose=2 Speakeys.app

echo "==> Notarizing the app"
rm -rf dist && mkdir -p dist
ditto -c -k --keepParent Speakeys.app dist/Speakeys.zip
xcrun notarytool submit dist/Speakeys.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple Speakeys.app
rm dist/Speakeys.zip

echo "==> Building $DMG"
mkdir -p dist/stage
cp -R Speakeys.app dist/stage/
ln -s /Applications dist/stage/Applications
hdiutil create -volname "Speakeys" -srcfolder dist/stage -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/stage
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Ready: $DMG"

if [[ "${1:-}" == "--publish" ]]; then
  gh release create "v$VERSION" "$DMG" --title "Speakeys $VERSION" --generate-notes
fi
