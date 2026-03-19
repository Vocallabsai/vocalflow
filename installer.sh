#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VocalFlow"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_TMP="dist/${APP_NAME}_tmp.dmg"
DMG_OUT="dist/${DMG_NAME}"
STAGING_DIR="dist/${APP_NAME}_staging"
WINDOW_W=540
WINDOW_H=380

# Step 1: build the app
./build.sh

# Step 2: prepare staging folder
rm -rf dist
mkdir -p "${STAGING_DIR}/.background"

cp -r "${APP_BUNDLE}" "${STAGING_DIR}/"
xattr -dr com.apple.quarantine "${STAGING_DIR}/${APP_BUNDLE}" 2>/dev/null || true
ln -s /Applications "${STAGING_DIR}/Applications"

# Step 3: scale logo to DMG window size as background
echo "Creating DMG background..."
sips -z ${WINDOW_H} ${WINDOW_W} oplo_square.png \
    --out "${STAGING_DIR}/.background/bg.png" > /dev/null 2>&1

# Step 4: set DMG volume icon
cp Resources/AppIcon.icns "${STAGING_DIR}/.VolumeIcon.icns"

# Step 5: create temporary read-write DMG
echo "Creating DMG..."
hdiutil create \
    -srcfolder "${STAGING_DIR}" \
    -volname "${APP_NAME}" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,b=16" \
    -format UDRW \
    -size 100m \
    "${DMG_TMP}"

# Step 6: mount and customise window layout
MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "${DMG_TMP}" \
    | grep /Volumes | awk '{print $NF}')"
sleep 2

echo "Customising DMG window..."
osascript - "${MOUNT_DIR}" "${APP_BUNDLE}" "${WINDOW_W}" "${WINDOW_H}" << 'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set appName  to item 2 of argv
    set winW     to (item 3 of argv) as integer
    set winH     to (item 4 of argv) as integer
    set bgFile   to POSIX file (mountPath & "/.background/bg.png")
    tell application "Finder"
        set theDisk to disk (POSIX file mountPath as alias)
        tell theDisk
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {100, 100, 100 + winW, 100 + winH}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 100
            set background picture of viewOptions to bgFile
            set position of item appName       of container window to {140, 220}
            set position of item "Applications" of container window to {400, 220}
            close
            open
            update without registering applications
            delay 2
        end tell
    end tell
end run
APPLESCRIPT

# Mark custom volume icon
SetFile -a C "${MOUNT_DIR}" 2>/dev/null || true

hdiutil detach "${MOUNT_DIR}"
sleep 1

# Step 7: compress to final DMG
echo "Compressing..."
hdiutil convert "${DMG_TMP}" -format UDZO -imagekey zlib-level=9 -o "${DMG_OUT}"
rm -f "${DMG_TMP}"
rm -rf "${STAGING_DIR}"

echo ""
echo "Done! Installer: ${DMG_OUT}"
echo ""
echo "Distribute ${DMG_OUT} — users open it and drag VocalFlow to Applications."
echo ""
echo "IMPORTANT: After first launch, users must grant Accessibility permission:"
echo "  System Settings → Privacy & Security → Accessibility → enable VocalFlow"
