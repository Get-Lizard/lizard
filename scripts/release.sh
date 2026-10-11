#!/bin/zsh
# Builds a signed, notarized Lizard.dmg ready for GitHub Releases and Homebrew.
#
#   VERSION=0.2.0 scripts/release.sh
#
# Signing: "Developer ID Application" identity from the login keychain (or the CI keychain).
# Notarization, one of:
#   NOTARY_PROFILE=lizard                         (xcrun notarytool store-credentials lizard …, for local use)
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER (App Store Connect API key, used in CI)
#   SKIP_NOTARIZE=1                               (signed only — for testing)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
IDENTITY=${SIGN_IDENTITY:-"Developer ID Application"}
TEAM_ID=${TEAM_ID:-6H728M7XQK}
OUT="$ROOT/build/release"
APP="$OUT/Build/Products/Release/Lizard.app"
DMG="$ROOT/build/Lizard-$VERSION.dmg"

echo "▸ Lizard $VERSION ($BUILD_NUMBER)"
rm -rf "$OUT" "$DMG"
mkdir -p "$ROOT/build"

xcodegen generate >/dev/null
xcodebuild -project Lizard.xcodeproj -scheme Lizard -configuration Release \
  -derivedDataPath "$OUT" -destination 'platform=macOS,arch=arm64' -skipMacroValidation -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

echo "▸ Bundling lizardcli"
# The command-line tool ships inside the app; Homebrew links it onto PATH (cask \`binary\`).
swift build -c release --arch arm64 --product lizardcli --package-path Packages/LizardKit
cp "Packages/LizardKit/.build/arm64-apple-macosx/release/lizardcli" "$APP/Contents/MacOS/lizardcli"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/lizardcli"

echo "▸ Signing nested executables"
# Mach-O files copied in as resources (esbuild's binary in the extension shim) aren't signed by
# Xcode, and notarization rejects any unsigned or non-hardened binary.
find "$APP/Contents/Resources" -type f -perm +111 | while read -r file; do
  if file "$file" | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$file"
  fi
done
# Re-seal the app (its resources changed), keeping entitlements and hardened runtime.
codesign --force --options runtime --timestamp --entitlements App/Lizard.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

notarize() {
  if [[ -n "${SKIP_NOTARIZE:-}" ]]; then echo "  (skipping notarization)"; return; fi
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  fi
}

echo "▸ Notarizing the app"
ZIP="$ROOT/build/Lizard-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
[[ -z "${SKIP_NOTARIZE:-}" ]] && xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "▸ Building the disk image"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Lizard" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
[[ -z "${SKIP_NOTARIZE:-}" ]] && xcrun stapler staple "$DMG"

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "▸ Done: $DMG"
echo "  sha256 $SHA"
[[ -n "${GITHUB_OUTPUT:-}" ]] && { echo "dmg=$DMG" >> "$GITHUB_OUTPUT"; echo "sha256=$SHA" >> "$GITHUB_OUTPUT"; echo "version=$VERSION" >> "$GITHUB_OUTPUT"; }
exit 0
