#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VocalFlow"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

echo "Building ${APP_NAME}..."
swift build -c release

echo "Creating .app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"
cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

echo "Code signing (ad-hoc)..."
codesign --force --deep --sign - \
    --entitlements "Resources/VocalFlow.entitlements" \
    "${APP_BUNDLE}"

echo "Stripping quarantine..."
xattr -dr com.apple.quarantine "${APP_BUNDLE}" 2>/dev/null || true

echo "Resetting Accessibility permission (re-add after launch)..."
tccutil reset Accessibility "com.vocalflow.app" 2>/dev/null || true

echo ""
echo "Done! Built: ${APP_BUNDLE}"
echo ""
echo "To run:    open ${APP_BUNDLE}"
echo "To install: cp -r ${APP_BUNDLE} /Applications/ && xattr -dr com.apple.quarantine /Applications/${APP_BUNDLE}"
echo ""
echo "NOTE: After each rebuild you must re-grant Accessibility permission:"
echo "  System Settings → Privacy & Security → Accessibility"
echo "  Remove VocalFlow if present, then re-add it after launching."
