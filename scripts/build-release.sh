#!/bin/bash
# Builds NVDA Remote for distribution outside the App Store: universal Release build,
# Developer ID signature with the hardened runtime, notarization by Apple, stapled
# ticket, a zip, and optionally the Sparkle appcast and the GitHub release.
#
# Usage: scripts/build-release.sh [--no-notarize] [--release [--beta]]
#
#   --no-notarize  sign and zip only (quick local check).
#   --release      also update docs/appcast.xml (GitHub Pages), publish the zip as
#                  GitHub release v<version>, and push docs/ when on main.
#   --beta         with --release: the appcast item goes to Sparkle's "beta" channel
#                  (only users who turned on beta versions get it) and the GitHub
#                  release is a prerelease.
#
# Needs: the notarytool keychain profile (default ttaccessible-notary; create one with
#   xcrun notarytool store-credentials <name> --apple-id <id> --team-id 633EG76YX5),
# Sparkle's EdDSA private key in the login keychain (generate_appcast reads it there),
# pandoc for the release notes, gh for the release, and App/AppBackendSecret.plist for
# --release, so published builds can reach the developer's backend.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="NVDARemote.xcodeproj"
SCHEME="NVDARemote"
APP_NAME="NVDA Remote"
REPO="math65/nvdaremote-mac"
DERIVED_DATA="build/Release"
OUTPUT_DIR="BuildArtifacts"
DOCS_DIR="docs"
APPCAST_STAGING=".appcast-staging"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Mathieu Martin (633EG76YX5)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ttaccessible-notary}"

NOTARIZE=1
RELEASE=0
BETA=0
for arg in "$@"; do
	case "$arg" in
		--no-notarize) NOTARIZE=0 ;;
		--release) RELEASE=1 ;;
		--beta) BETA=1 ;;
		*) echo "Unknown option: $arg"; exit 1 ;;
	esac
done

if [[ $RELEASE -eq 1 ]]; then
	[[ $NOTARIZE -eq 1 ]] || { echo "--release needs notarization."; exit 1; }
	[[ -f App/AppBackendSecret.plist ]] || {
		echo "App/AppBackendSecret.plist is missing: Contact the Developer and announcements would not work."
		exit 1
	}
	[[ -f RELEASE_NOTES.md && -f RELEASE_NOTES.fr.md ]] || {
		echo "RELEASE_NOTES.md and RELEASE_NOTES.fr.md are needed for a release."
		exit 1
	}
	# Without --target, gh tags the last commit the remote knows, not the one being
	# built. Checked before the build: finding out after notarization costs the release.
	HEAD_SHA=$(git rev-parse HEAD)
	if ! gh api "repos/$REPO/commits/$HEAD_SHA" --silent 2>/dev/null; then
		echo "The current commit $HEAD_SHA is not on GitHub. Push it first:"
		echo "  git push -u origin $(git rev-parse --abbrev-ref HEAD)"
		exit 1
	fi
fi
[[ $BETA -eq 0 || $RELEASE -eq 1 ]] || { echo "--beta only makes sense with --release."; exit 1; }

echo "==> Building $SCHEME (Release, arm64 + x86_64)..."
LOG="$DERIVED_DATA/xcodebuild.log"
mkdir -p "$DERIVED_DATA"
if ! xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination "generic/platform=macOS" \
	-derivedDataPath "$DERIVED_DATA" \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	build >"$LOG" 2>&1; then
	grep -E "error:" "$LOG" || tail -30 "$LOG"
	echo "Build failed, full log: $LOG"
	exit 1
fi
grep -E "warning: " "$LOG" | grep -v appintents || true

APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "Build failed: $APP_PATH not found"; exit 1; }

echo "==> Signing with $SIGN_IDENTITY..."
# No entitlements: the app cannot run in the App Sandbox (see README, "Building"), and the
# hardened runtime needs no exception. Nested code is signed deepest first: Sparkle's
# helpers, then frameworks and libraries, then the app itself.
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
for nested in \
	"$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
	"$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
	"$SPARKLE_FW/Versions/B/Autoupdate" \
	"$SPARKLE_FW/Versions/B/Updater.app"; do
	if [[ -e "$nested" ]]; then
		codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$nested"
	fi
done
find "$APP_PATH/Contents" \( -name "*.dylib" -o -name "*.framework" \) -print0 |
	while IFS= read -r -d '' nested; do
		codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$nested"
	done
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --strict --deep --verbose=2 "$APP_PATH"

VERSION=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleVersion)
mkdir -p "$OUTPUT_DIR"
ZIP_BASENAME="NVDA-Remote-$VERSION-$BUILD"
ZIP_PATH="$OUTPUT_DIR/$ZIP_BASENAME.zip"
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
[[ $RELEASE -eq 1 ]] || exit 0

echo "==> Generating the Sparkle appcast..."
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "Sparkle tools not found in $SPARKLE_BIN"; exit 1; }
rm -rf "$APPCAST_STAGING"
mkdir -p "$APPCAST_STAGING" "$DOCS_DIR"
cp "$ZIP_PATH" "$APPCAST_STAGING/"
# Release notes shown in Sparkle's dialog. generate_appcast picks up <zip>.html and
# <zip>.fr.html next to the zip; French users get the second, everyone else the first.
scripts/render-release-notes.sh RELEASE_NOTES.md "$DOCS_DIR/$ZIP_BASENAME.html" en
scripts/render-release-notes.sh RELEASE_NOTES.fr.md "$DOCS_DIR/$ZIP_BASENAME.fr.html" fr
cp "$DOCS_DIR/$ZIP_BASENAME.html" "$DOCS_DIR/$ZIP_BASENAME.fr.html" "$APPCAST_STAGING/"
# Keep the earlier entries; only the new one gets the beta channel.
if [[ -f "$DOCS_DIR/appcast.xml" ]]; then cp "$DOCS_DIR/appcast.xml" "$APPCAST_STAGING/"; fi
CHANNEL_ARGS=()
[[ $BETA -eq 1 ]] && CHANNEL_ARGS+=(--channel beta)
"$SPARKLE_BIN/generate_appcast" "$APPCAST_STAGING" \
	${CHANNEL_ARGS[@]+"${CHANNEL_ARGS[@]}"} \
	--download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
	--link "https://github.com/$REPO/releases/tag/v$VERSION" \
	-o "$DOCS_DIR/appcast.xml"
# The English notes link comes without xml:lang, which Sparkle warns about when a
# French sibling exists.
sed -i '' 's#<sparkle:releaseNotesLink>#<sparkle:releaseNotesLink xml:lang="en">#g' "$DOCS_DIR/appcast.xml"
rm -rf "$APPCAST_STAGING"

TAG="v$VERSION"
echo "==> Publishing GitHub release $TAG..."
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
	gh release upload "$TAG" "$ZIP_PATH" --repo "$REPO" --clobber
else
	PRERELEASE_ARGS=()
	[[ $BETA -eq 1 ]] && PRERELEASE_ARGS+=(--prerelease)
	gh release create "$TAG" "$ZIP_PATH" \
		--repo "$REPO" \
		--target "$HEAD_SHA" \
		--title "$APP_NAME $VERSION" \
		--notes-file RELEASE_NOTES.md \
		${PRERELEASE_ARGS[@]+"${PRERELEASE_ARGS[@]}"}
fi
echo "==> Release: https://github.com/$REPO/releases/tag/$TAG"

# The appcast goes live with the push; from another branch it stays local.
if [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]]; then
	git add "$DOCS_DIR/appcast.xml" "$DOCS_DIR/$ZIP_BASENAME.html" "$DOCS_DIR/$ZIP_BASENAME.fr.html"
	git commit -m "Update appcast and release notes for $TAG"
	git push origin main
	echo "==> Appcast published."
else
	echo "Not on main: docs/appcast.xml was updated locally but not pushed."
fi
