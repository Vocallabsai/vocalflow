#!/usr/bin/env bash
#
# make-pkg.sh — build, sign, notarize & staple a distributable macOS .pkg
# for VocalFlow (Swift Package Manager app, direct distribution / not App Store).
#
# One command, re-runnable for any future build:
#     ./scripts/make-pkg.sh
#
# Produces: dist/VocalFlow.pkg  (signed + notarized + stapled, universal binary)
#
# Reusable team signing assets (already set up on this Mac):
#   - Developer ID Application + Installer certs in the login keychain
#   - notarytool credentials in keychain profile AC_PROFILE_DIALER (team R65MP66K97)
#
# Override any of these via the environment, e.g.:
#     NOTARYTOOL_PROFILE=AC_PROFILE_DIALER SKIP_NOTARIZE=1 ./scripts/make-pkg.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
APP_NAME="${APP_NAME:-VocalFlow}"
BUNDLE_ID="${BUNDLE_ID:-com.vocalflow.app}"
PKG_ID="${PKG_ID:-com.vocalflow.installer}"

APP_CERT="${APP_CERT:-Developer ID Application: Nilesh Kumar (R65MP66K97)}"
INSTALLER_CERT="${INSTALLER_CERT:-Developer ID Installer: Nilesh Kumar (R65MP66K97)}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-AC_PROFILE_DIALER}"

ENTITLEMENTS="${ENTITLEMENTS:-Resources/VocalFlow.entitlements}"
DEPLOY_TARGET="${DEPLOY_TARGET:-13.0}"      # must match Package.swift platforms / LSMinimumSystemVersion

SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"          # set to 1 for a local signed-but-not-notarized build

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

DIST_DIR="dist"
COMPONENT_PKG="${DIST_DIR}/.${APP_NAME}-component.pkg"
PKG_OUT="${DIST_DIR}/${APP_NAME}.pkg"
STAGING_DIR="${DIST_DIR}/.pkg_root"
SCRIPTS_DIR="${DIST_DIR}/.pkg_scripts"
COMPONENT_PLIST="${DIST_DIR}/.pkg_component.plist"

SCRATCH_ARM64=".build-arm64"
SCRATCH_X86_64=".build-x86_64"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 1.0.0)"

echo "==> ${APP_NAME} ${VERSION}  (bundle ${BUNDLE_ID}, pkg ${PKG_ID})"

# ---------------------------------------------------------------------------
# 1. Build a universal (arm64 + x86_64) release binary.
#    SwiftPM's --arch flag needs full Xcode (xcbuild); under Command Line Tools
#    only, we cross-compile each slice with a target triple and lipo them.
# ---------------------------------------------------------------------------
echo "==> Building arm64 slice..."
swift build -c release --scratch-path "${SCRATCH_ARM64}" \
    -Xswiftc -target -Xswiftc "arm64-apple-macosx${DEPLOY_TARGET}"

echo "==> Building x86_64 slice..."
swift build -c release --scratch-path "${SCRATCH_X86_64}" \
    -Xswiftc -target -Xswiftc "x86_64-apple-macosx${DEPLOY_TARGET}"

# ---------------------------------------------------------------------------
# 2. Assemble the .app bundle with a universal binary.
#    (No Qt / no bundled frameworks — nothing to macdeployqt.)
# ---------------------------------------------------------------------------
echo "==> Assembling ${APP_BUNDLE} (universal)..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

lipo -create \
    "${SCRATCH_ARM64}/release/${APP_NAME}" \
    "${SCRATCH_X86_64}/release/${APP_NAME}" \
    -output "${MACOS_DIR}/${APP_NAME}"

cp "Resources/Info.plist"   "${CONTENTS}/Info.plist"
cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

echo "    archs: $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"

# ---------------------------------------------------------------------------
# 3. Sign the .app with the Developer ID Application identity + hardened runtime.
# ---------------------------------------------------------------------------
echo "==> Signing ${APP_BUNDLE}..."
codesign --force --deep --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${APP_CERT}" \
    "${APP_BUNDLE}"

echo "==> Verifying signature..."
codesign --verify --strict --verbose=2 "${APP_BUNDLE}"
codesign -dv --verbose=2 "${APP_BUNDLE}" 2>&1 | grep -E "Authority|TeamIdentifier|flags|Identifier" || true

# ---------------------------------------------------------------------------
# 4. pkgbuild — component pkg installing to /Applications.
#    Relocation is disabled via the component plist so macOS can't "helpfully"
#    install over an existing copy of com.vocalflow.app found elsewhere on disk.
# ---------------------------------------------------------------------------
echo "==> Building component pkg..."
rm -rf "${STAGING_DIR}" "${SCRIPTS_DIR}" "${COMPONENT_PLIST}" "${COMPONENT_PKG}"
mkdir -p "${DIST_DIR}" "${STAGING_DIR}" "${SCRIPTS_DIR}"

cp -R "${APP_BUNDLE}" "${STAGING_DIR}/${APP_BUNDLE}"

cat > "${COMPONENT_PLIST}" <<COMPONENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <true/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
        <key>RootRelativeBundlePath</key>
        <string>${APP_BUNDLE}</string>
    </dict>
</array>
</plist>
COMPONENT

# postinstall: strip quarantine, reset stale TCC grants, refresh LaunchServices,
# then launch the app as the console user.
cat > "${SCRIPTS_DIR}/postinstall" <<POSTINSTALL
#!/bin/bash
APP="/Applications/${APP_BUNDLE}"
BID="${BUNDLE_ID}"

xattr -dr com.apple.quarantine "\$APP" 2>/dev/null || true

USER_NAME=\$(stat -f "%Su" /dev/console)
USER_ID=\$(id -u "\$USER_NAME")
launchctl asuser "\$USER_ID" tccutil reset Accessibility "\$BID" 2>/dev/null || true
launchctl asuser "\$USER_ID" tccutil reset Microphone     "\$BID" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\$APP" 2>/dev/null || true

launchctl asuser "\$USER_ID" open "\$APP" 2>/dev/null || true
exit 0
POSTINSTALL
chmod +x "${SCRIPTS_DIR}/postinstall"

pkgbuild \
    --root "${STAGING_DIR}" \
    --component-plist "${COMPONENT_PLIST}" \
    --install-location /Applications \
    --identifier "${PKG_ID}" \
    --version "${VERSION}" \
    --scripts "${SCRIPTS_DIR}" \
    "${COMPONENT_PKG}"

# ---------------------------------------------------------------------------
# 5. productbuild — distribution pkg, signed with the Developer ID Installer cert.
# ---------------------------------------------------------------------------
echo "==> Building & signing distribution pkg..."
productbuild \
    --package "${COMPONENT_PKG}" \
    --sign "${INSTALLER_CERT}" \
    --timestamp \
    "${PKG_OUT}"

# ---------------------------------------------------------------------------
# 6 & 7. Notarize and staple.
# ---------------------------------------------------------------------------
if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
    echo "==> SKIP_NOTARIZE=1 — signed but NOT notarized: ${PKG_OUT}"
else
    echo "==> Submitting to notary service (profile ${NOTARYTOOL_PROFILE})..."
    xcrun notarytool submit "${PKG_OUT}" \
        --keychain-profile "${NOTARYTOOL_PROFILE}" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "${PKG_OUT}"
    xcrun stapler validate "${PKG_OUT}"

    echo "==> Gatekeeper assessment:"
    spctl -a -vvv -t install "${PKG_OUT}" 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Cleanup intermediates
# ---------------------------------------------------------------------------
rm -rf "${STAGING_DIR}" "${SCRIPTS_DIR}" "${COMPONENT_PLIST}" "${COMPONENT_PKG}"

echo ""
echo "Done! Installer: ${PKG_OUT}  (v${VERSION})"
echo "Double-clickable on any Mac (Apple Silicon + Intel) without Gatekeeper warnings."
