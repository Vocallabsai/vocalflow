#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VocalFlow"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="com.vocalflow.app"
PKG_ID="com.vocalflow.installer"
PKG_OUT="dist/${APP_NAME}.pkg"
SCRIPTS_DIR="dist/.pkg_scripts"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 1.0.0)"

./build.sh

mkdir -p dist
rm -rf "${SCRIPTS_DIR}"
mkdir -p "${SCRIPTS_DIR}"

cat > "${SCRIPTS_DIR}/postinstall" <<POSTINSTALL
#!/bin/bash
APP="/Applications/${APP_BUNDLE}"
BID="${BUNDLE_ID}"

xattr -dr com.apple.quarantine "\$APP" 2>/dev/null || true

# Stale TCC grants from previous ad-hoc builds will look "on" in System
# Settings but won't apply to this build's cdhash. Reset them so the user
# can re-grant cleanly on first launch.
USER_NAME=\$(stat -f "%Su" /dev/console)
USER_ID=\$(id -u "\$USER_NAME")
launchctl asuser "\$USER_ID" tccutil reset Accessibility "\$BID" 2>/dev/null || true
launchctl asuser "\$USER_ID" tccutil reset Microphone     "\$BID" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\$APP" 2>/dev/null || true

launchctl asuser "\$USER_ID" open "\$APP" 2>/dev/null || true
exit 0
POSTINSTALL

chmod +x "${SCRIPTS_DIR}/postinstall"

echo "Building PKG..."
pkgbuild \
    --component "${APP_BUNDLE}" \
    --install-location /Applications \
    --identifier "${PKG_ID}" \
    --version "${VERSION}" \
    --scripts "${SCRIPTS_DIR}" \
    "${PKG_OUT}"

rm -rf "${SCRIPTS_DIR}"

echo ""
echo "Done! Installer: ${PKG_OUT}"
echo ""
echo "Distribute ${PKG_OUT} — users double-click to install."
echo "Postinstall strips quarantine, resets stale TCC grants, and launches the app."
echo ""
echo "NOTE: Without a Developer ID Installer cert this PKG is unsigned. Users"
echo "will see an 'unidentified developer' warning; right-click → Open the"
echo "first time, or run: spctl --add ${PKG_OUT}"
