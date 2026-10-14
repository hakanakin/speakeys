#!/bin/bash
# Builds a signed and notarized dist/Speakeys-<version>.dmg that anyone can open.
#   ./release.sh            build the DMG (NOTES="..." adds release notes to the update alert)
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

# Publish the DMG with the website (kept outside this repo); /download points at the latest version
if [[ ! -d site/public ]]; then
  echo "No site/public folder, so the DMG wasn't copied for the website."
  exit 0
fi
# Keep the previous version too, so cached /download redirects never hit a missing file
cp "$DMG" site/public/
ls -t site/public/Speakeys-*.dmg | tail -n +3 | xargs rm -f
printf '/download /Speakeys-%s.dmg 302\n' "$VERSION" > site/public/_redirects
# Read by the app's update check. Optional release notes: NOTES="..." ./release.sh
python3 -c 'import json, sys; v, n = sys.argv[1:]; print(json.dumps({"version": v, "url": "https://speakeys.akins.app/download", **({"notes": n} if n else {})}))' \
  "$VERSION" "${NOTES:-}" > site/public/version.json
echo "Copied to site/public. Deploy with: (cd site && npx wrangler deploy)"

if [[ "${1:-}" == "--publish" ]]; then
  gh release create "v$VERSION" "$DMG" --title "Speakeys $VERSION" --generate-notes
fi
