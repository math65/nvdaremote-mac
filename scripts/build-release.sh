#!/bin/bash
# Builds NVDA Remote for distribution outside the App Store: universal Release build,
# Developer ID signature with the hardened runtime, notarization by Apple, stapled
# ticket, and a zip ready to send.
#
# Usage: scripts/build-release.sh [--no-notarize]
#
# Notarization uses a notarytool keychain profile (default: ttaccessible-notary, the
# team's existing profile). Create one with:
#   xcrun notarytool store-credentials <name> --apple-id <id> --team-id 633EG76YX5
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="NVDARemote.xcodeproj"
SCHEME="NVDARemote"
APP_NAME="NVDA Remote"
DERIVED_DATA="build/Release"
OUTPUT_DIR="BuildArtifacts"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Mathieu Martin (633EG76YX5)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ttaccessible-notary}"

NOTARIZE=1
for arg in "$@"; do
	case "$arg" in
		--no-notarize) NOTARIZE=0 ;;
		*) echo "Unknown option: $arg"; exit 1 ;;
	esac
done

echo "==> Building $SCHEME (Release, arm64 + x86_64)..."
xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination "generic/platform=macOS" \
	-derivedDataPath "$DERIVED_DATA" \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	build | grep -E "error|warning: |BUILD" || true

APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "Build failed: $APP_PATH not found"; exit 1; }

echo "==> Signing with $SIGN_IDENTITY..."
# No entitlements: the app cannot run in the App Sandbox (see README, "Building"), and the
# hardened runtime needs no exception. Nested code first (none today besides the resource
# bundle, which needs no signature), then the app itself.
find "$APP_PATH/Contents" \( -name "*.dylib" -o -name "*.framework" \) -print0 |
	while IFS= read -r -d '' nested; do
		codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$nested"
	done
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --strict --deep --verbose=2 "$APP_PATH"

VERSION=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleVersion)
mkdir -p "$OUTPUT_DIR"
ZIP_PATH="$OUTPUT_DIR/NVDA-Remote-$VERSION-$BUILD.zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ $NOTARIZE -eq 1 ]]; then
	echo "==> Notarizing with Apple (usually a few minutes)..."
	xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
	echo "==> Stapling the ticket..."
	xcrun stapler staple "$APP_PATH"
	echo "==> Gatekeeper check..."
	spctl --assess --type execute --verbose=2 "$APP_PATH"
	# The zip must contain the stapled app.
	rm -f "$ZIP_PATH"
	ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
fi

echo "==> Done: $ZIP_PATH"
