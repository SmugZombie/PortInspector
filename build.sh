#!/usr/bin/env bash
# Build PortInspector.app and package it as a distributable DMG.
#
# Usage:
#   ./build.sh                  # ad-hoc signed, creates dist/PortInspector.dmg
#   ./build.sh --identity "Developer ID Application: Your Name (TEAMID)"
#   ./build.sh --notarize       # sign + notarize (requires --identity + keychain-profile)
#   ./build.sh --clean          # wipe build/ and dist/ before building

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
PROJECT="PortInspector.xcodeproj"
SCHEME="PortInspector"
APP_NAME="PortInspector"
BUNDLE_ID="com.portinspector.app"
VERSION="1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

BUILD_DIR="${PWD}/build"
DIST_DIR="${PWD}/dist"
ARCHIVE="${BUILD_DIR}/${APP_NAME}.xcarchive"
APP="${DIST_DIR}/${APP_NAME}.app"
DMG="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

SIGN_IDENTITY="-"   # ad-hoc by default
NOTARIZE=false
CLEAN=false
KEYCHAIN_PROFILE=""

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)   SIGN_IDENTITY="$2"; shift 2 ;;
    --profile)    KEYCHAIN_PROFILE="$2"; shift 2 ;;
    --notarize)   NOTARIZE=true; shift ;;
    --clean)      CLEAN=true; shift ;;
    *)            echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────
step()  { echo; echo "▶ $*"; }
ok()    { echo "  ✓ $*"; }
die()   { echo "  ✗ $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"
[[ -f "$PROJECT/project.pbxproj" ]] || die "Run this script from the repo root"
ok "Xcode: $(xcodebuild -version | head -1)"

if [[ "$NOTARIZE" == true ]]; then
  [[ "$SIGN_IDENTITY" == "-" ]] && die "--notarize requires --identity"
  [[ -z "$KEYCHAIN_PROFILE" ]]  && die "--notarize requires --profile (notarytool keychain profile)"
fi

# ── Clean ──────────────────────────────────────────────────────────────────────
if [[ "$CLEAN" == true ]]; then
  step "Cleaning previous build artifacts"
  rm -rf "$BUILD_DIR" "$DIST_DIR"
  ok "Removed build/ and dist/"
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ── Archive ────────────────────────────────────────────────────────────────────
step "Building archive (Release)"
xcodebuild archive \
  -project        "$PROJECT" \
  -scheme         "$SCHEME" \
  -configuration  Release \
  -archivePath    "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGNING_REQUIRED=YES \
  DEVELOPMENT_TEAM="" \
  | xcpretty 2>/dev/null || true   # xcpretty is optional

# Fallback if xcpretty swallowed an error
[[ -d "$ARCHIVE" ]] || die "Archive not found at $ARCHIVE — build failed"
ok "Archive: $ARCHIVE"

# ── Export .app ────────────────────────────────────────────────────────────────
step "Exporting .app"
EXPORTED_APP=$(find "$ARCHIVE/Products" -name "*.app" | head -1)
[[ -n "$EXPORTED_APP" ]] || die "No .app found inside archive"

rm -rf "$APP"
cp -R "$EXPORTED_APP" "$APP"
ok "Exported: $APP"

# ── Re-sign (ensure identity is applied to all nested binaries) ────────────────
# Always embed entitlements — without them the app-sandbox flag is ambiguous and
# macOS may apply unexpected restrictions on the spawned lsof/ps subprocesses.
step "Code-signing"
ENTITLEMENTS="${PWD}/PortInspector/PortInspector.entitlements"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep \
    --sign - \
    --entitlements "$ENTITLEMENTS" \
    "$APP"
  ok "Ad-hoc signed (local use only)"
else
  codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$APP"
  ok "Signed with: $SIGN_IDENTITY"

  step "Verifying signature"
  codesign --verify --deep --strict "$APP"
  spctl --assess --type execute --verbose "$APP" 2>&1 || true
  ok "Signature valid"
fi

# ── Notarize ──────────────────────────────────────────────────────────────────
if [[ "$NOTARIZE" == true ]]; then
  step "Notarizing (this may take a few minutes)"
  NOTARIZE_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
  ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"

  xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

  xcrun stapler staple "$APP"
  ok "Notarization complete and stapled"
  rm -f "$NOTARIZE_ZIP"
fi

# ── Create DMG ────────────────────────────────────────────────────────────────
step "Creating DMG"
rm -f "$DMG"

# Build a staging directory with the app + Applications symlink
STAGE="${BUILD_DIR}/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Create a writable sparse image, then convert to compressed read-only
TMP_DMG="${BUILD_DIR}/${APP_NAME}-tmp.dmg"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  "$TMP_DMG" >/dev/null

hdiutil convert "$TMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG" >/dev/null

rm -f "$TMP_DMG"
rm -rf "$STAGE"

DMG_SIZE=$(du -sh "$DMG" | cut -f1)
ok "DMG: $DMG ($DMG_SIZE)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────────────────"
echo "  Build complete"
echo "  App:    $APP"
echo "  DMG:    $DMG"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo
  echo "  Note: ad-hoc signed. To distribute to other Macs,"
  echo "  re-run with --identity \"Developer ID Application: ...\""
  echo "  and optionally --notarize --profile <keychain-profile>"
fi
echo "────────────────────────────────────────────────────"
