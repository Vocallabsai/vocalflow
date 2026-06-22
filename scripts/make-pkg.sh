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

# Sparkle auto-update: the appcast feed URL (must match Info.plist SUFeedURL) and
# the GitHub repo whose Releases host the update .zip assets.
SU_FEED_URL="${SU_FEED_URL:-https://vocallabs.ai/vocalflow/appcast.xml}"
GITHUB_REPO="${GITHUB_REPO:-Vocallabsai/vocalflow}"

SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"          # set to 1 for a local signed-but-not-notarized build
SKIP_SPARKLE="${SKIP_SPARKLE:-0}"            # set to 1 to skip building the Sparkle update zip + appcast

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# SwiftPM shells out to git to resolve dependencies into the per-arch scratch
# paths. If the machine sets `safe.bareRepository=explicit` globally, git refuses
# to operate on SwiftPM's bare clones and the build fails. Allow it just for this
# script's subprocesses (scoped via env, no global git config change).
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.bareRepository
export GIT_CONFIG_VALUE_0=all

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

# Locate the universal Sparkle.framework that SwiftPM downloaded as a binary
# artifact (lives under whichever scratch path resolved it first).
SPARKLE_FW="$(find "${SCRATCH_ARM64}/artifacts" "${SCRATCH_X86_64}/artifacts" .build/artifacts \
    -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
if [[ ! -d "${SPARKLE_FW}" ]]; then
    echo "ERROR: Sparkle.framework not found. Run 'swift package resolve' first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Assemble the .app bundle with a universal binary + embedded Sparkle.
# ---------------------------------------------------------------------------
echo "==> Assembling ${APP_BUNDLE} (universal)..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${CONTENTS}/Frameworks"

lipo -create \
    "${SCRATCH_ARM64}/release/${APP_NAME}" \
    "${SCRATCH_X86_64}/release/${APP_NAME}" \
    -output "${MACOS_DIR}/${APP_NAME}"

cp "Resources/Info.plist"   "${CONTENTS}/Info.plist"
cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

# Embed Sparkle.framework (universal). The executable finds it via the
# @executable_path/../Frameworks rpath baked in at link time.
echo "==> Embedding Sparkle.framework..."
ditto "${SPARKLE_FW}" "${CONTENTS}/Frameworks/Sparkle.framework"

echo "    archs: $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"

# ---------------------------------------------------------------------------
# 3. Sign inside-out with the Developer ID Application identity + hardened
#    runtime. Sparkle ships nested helpers (XPC services, Autoupdate, the
#    Updater.app) that must each be signed before their containing framework,
#    and the framework before the outer app — codesign seals already-signed
#    nested code but won't re-sign it for us. (No --deep: Apple discourages it
#    and it would sign in the wrong order.)
# ---------------------------------------------------------------------------
SIGN=(--force --options runtime --timestamp --sign "${APP_CERT}")
SPK="${CONTENTS}/Frameworks/Sparkle.framework/Versions/B"

echo "==> Signing embedded Sparkle (inside-out)..."
codesign "${SIGN[@]}" "${SPK}/XPCServices/Downloader.xpc"
codesign "${SIGN[@]}" "${SPK}/XPCServices/Installer.xpc"
codesign "${SIGN[@]}" "${SPK}/Autoupdate"
codesign "${SIGN[@]}" "${SPK}/Updater.app"
codesign "${SIGN[@]}" "${CONTENTS}/Frameworks/Sparkle.framework"

echo "==> Signing ${APP_BUNDLE}..."
codesign "${SIGN[@]}" --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE}"

echo "==> Verifying signature (deep, strict)..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
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
# One sweep clears EVERY stale TCC service entry (Accessibility, Microphone,
# Input Monitoring, AppleEvents, ...) left over from the pre-Developer-ID
# ad-hoc builds. The per-service reset by bundle id missed entries keyed to
# the old ad-hoc identity, which suppressed re-prompts and made grants fail
# to stick. "reset All" clears them so the stable signed identity prompts
# fresh and the grants actually persist across future updates.
launchctl asuser "\$USER_ID" tccutil reset All "\$BID" 2>/dev/null || true

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
# 8. Sparkle update archive + appcast.
#    Sparkle installs updates from a .zip of the .app (not the .pkg). The .app
#    is stapled so Gatekeeper accepts it offline after Sparkle swaps it in, and
#    the archive is EdDSA-signed with the team's Sparkle key (login keychain).
#    The .pkg above remains the artifact for first-time installs.
# ---------------------------------------------------------------------------
if [[ "${SKIP_NOTARIZE}" != "1" && "${SKIP_SPARKLE}" != "1" ]]; then
    echo "==> Stapling the .app (for Sparkle's offline Gatekeeper check)..."
    xcrun stapler staple "${APP_BUNDLE}"

    ZIP_OUT="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"
    echo "==> Zipping update archive ${ZIP_OUT}..."
    rm -f "${ZIP_OUT}"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_OUT}"

    SIGN_UPDATE="$(find "${SCRATCH_ARM64}/artifacts" "${SCRATCH_X86_64}/artifacts" .build/artifacts \
        -type f -name sign_update -path '*bin*' 2>/dev/null | head -1)"
    [[ -x "${SIGN_UPDATE}" ]] || { echo "ERROR: Sparkle sign_update tool not found." >&2; exit 1; }

    echo "==> EdDSA-signing the archive..."
    SIG_ATTRS="$("${SIGN_UPDATE}" "${ZIP_OUT}")"   # -> sparkle:edSignature="..." length="..."
    echo "    ${SIG_ATTRS}"

    BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${APP_NAME}-${VERSION}.zip"
    PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    APPCAST_OUT="${DIST_DIR}/appcast.xml"

    cat > "${APPCAST_OUT}" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>VocalFlow</title>
    <link>${SU_FEED_URL}</link>
    <description>Most recent VocalFlow updates.</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUM}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${DEPLOY_TARGET}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}</sparkle:releaseNotesLink>
      <enclosure url="${DOWNLOAD_URL}" ${SIG_ATTRS} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST
    echo "==> Wrote ${APPCAST_OUT}"
fi

# ---------------------------------------------------------------------------
# Cleanup intermediates
# ---------------------------------------------------------------------------
rm -rf "${STAGING_DIR}" "${SCRIPTS_DIR}" "${COMPONENT_PLIST}" "${COMPONENT_PKG}"

echo ""
echo "Done! Installer: ${PKG_OUT}  (v${VERSION})"
echo "Double-clickable on any Mac (Apple Silicon + Intel) without Gatekeeper warnings."
if [[ "${SKIP_NOTARIZE}" != "1" && "${SKIP_SPARKLE}" != "1" ]]; then
    echo ""
    echo "Sparkle update:  ${ZIP_OUT}"
    echo "Appcast:         ${APPCAST_OUT}"
    echo "  1. Upload ${APP_NAME}-${VERSION}.zip (and ${APP_NAME}.pkg) to the v${VERSION} GitHub release."
    echo "  2. Deploy appcast.xml to ${SU_FEED_URL}"
fi
