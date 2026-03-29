#!/bin/bash
set -e

APP_NAME="SubtitleGenerator"
DISPLAY_NAME="자막 생성기"
VERSION=$(date +%Y.%m.%d)
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${BUILD_DIR}/build/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dist"
STAGING="${DMG_DIR}/staging"

echo "=== Building ${APP_NAME} v${VERSION} ==="

# 1. Release build
echo "[1/4] Building release..."
cd "$BUILD_DIR"
swift build -c release

# 2. Copy binary to app bundle
echo "[2/4] Preparing app bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"

# Copy Info.plist and icon if they exist in Resources
if [ -f "${BUILD_DIR}/${APP_NAME}/Resources/Info.plist" ]; then
    cp "${BUILD_DIR}/${APP_NAME}/Resources/Info.plist" "${APP_BUNDLE}/Contents/"
fi
if [ -f "${BUILD_DIR}/${APP_NAME}/Resources/AppIcon.icns" ]; then
    cp "${BUILD_DIR}/${APP_NAME}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
fi

# Update version in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true

# 3. Create DMG
echo "[3/4] Creating DMG..."
mkdir -p "${DMG_DIR}"
rm -rf "${STAGING}"
mkdir -p "${STAGING}"
cp -R "${APP_BUNDLE}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

rm -f "${DMG_DIR}/${DMG_NAME}"
hdiutil create \
    -volname "${DISPLAY_NAME}" \
    -srcfolder "${STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_DIR}/${DMG_NAME}"

# 4. Cleanup
rm -rf "${STAGING}"

echo "[4/4] Done!"
echo "DMG: ${DMG_DIR}/${DMG_NAME}"
echo "Size: $(du -h "${DMG_DIR}/${DMG_NAME}" | cut -f1)"
