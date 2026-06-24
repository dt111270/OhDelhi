#!/bin/bash
#
# release.sh — build, notarise, Sparkle-sign and publish a new OhDelhi release.
#
#   Usage:  ./release/release.sh <marketing-version> <build-number>
#   e.g.    ./release/release.sh 0.2 3
#
# What it does:
#   1. Archives a Release build (Developer ID) and exports the .app
#   2. Zips, notarises (notarytool), staples, re-zips
#   3. Signs the zip with Sparkle's sign_update (EdDSA)
#   4. Prepends a new <item> to release/appcast.xml
#   5. Creates a GitHub release (tag vX) and uploads the zip (gh)
#   6. Commits + pushes the updated appcast.xml
#
# Prerequisites (one-time — see SETUP.md):
#   - Sparkle added via SPM; its `sign_update` tool located (SPARKLE_SIGN below)
#   - EdDSA private key generated and stored in your login keychain
#   - notarytool keychain profile created (NOTARY_PROFILE below)
#   - `gh` (GitHub CLI) installed and authenticated
#   - release/ExportOptions.plist filled in with your Team ID

set -euo pipefail

# ============================== CONFIG (edit me) =============================
APP_NAME="OhDelhi"
SCHEME="OhDelhi"
PROJECT="OhDelhi.xcodeproj"
GITHUB_REPO="REPLACE_USER/OhDelhi"        # e.g. davidturnbull/OhDelhi
NOTARY_PROFILE="ohdelhi-notary"           # `xcrun notarytool store-credentials` profile name
MIN_MACOS="14.0"                          # minimum supported macOS (match deployment target)
# Path to Sparkle's sign_update tool. After adding Sparkle via SPM it lives under
# DerivedData; or download the Sparkle release and point here. SETUP.md explains.
SPARKLE_SIGN="${SPARKLE_SIGN:-$HOME/bin/sign_update}"
# ============================================================================

VERSION="${1:?Usage: release.sh <version> <build>}"
BUILD="${2:?Usage: release.sh <version> <build>}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # project root (one level up from release/)
cd "$ROOT"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
APPCAST="$ROOT/release/appcast.xml"
DL_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.zip"

echo "==> Cleaning"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

echo "==> Archiving $APP_NAME $VERSION ($BUILD)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive

echo "==> Exporting (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$ROOT/release/ExportOptions.plist"

echo "==> Zipping for notarisation"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Notarising (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"     # re-zip so the distributed zip is stapled

echo "==> Sparkle signing"
SIG_LINE="$("$SPARKLE_SIGN" "$ZIP")"        # -> sparkle:edSignature="..." length="..."
ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIG_LINE")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIG_LINE")"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || { echo "sign_update output not understood: $SIG_LINE"; exit 1; }

echo "==> Updating appcast.xml"
PUBDATE="$(LC_ALL=en_US.UTF-8 date '+%a, %d %b %Y %H:%M:%S %z')"
ITEM="    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <enclosure url=\"$DL_URL\" sparkle:edSignature=\"$ED_SIG\" length=\"$LENGTH\" type=\"application/octet-stream\" />
    </item>"
# Insert the new item right after the <language>en</language> line (newest first).
python3 - "$APPCAST" "$ITEM" <<'PY'
import sys
path, item = sys.argv[1], sys.argv[2]
src = open(path).read()
marker = "<language>en</language>"
i = src.index(marker) + len(marker)
open(path, "w").write(src[:i] + "\n\n" + item + src[i:])
PY

echo "==> Creating GitHub release v$VERSION + uploading zip"
gh release create "v$VERSION" "$ZIP" \
  --repo "$GITHUB_REPO" \
  --title "$APP_NAME $VERSION" \
  --notes "OhDelhi $VERSION (build $BUILD)"

echo "==> Committing appcast"
git -C "$ROOT" add release/appcast.xml
git -C "$ROOT" commit -m "Release $VERSION (build $BUILD)"
git -C "$ROOT" push

echo "==> Done. OhDelhi $VERSION published; MMUtil will pick it up on its next check."
