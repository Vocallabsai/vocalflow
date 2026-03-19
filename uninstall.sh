#!/usr/bin/env bash
set -euo pipefail

APP_NAME="VocalFlow"
BUNDLE_ID="com.vocalflow.app"
APP_PATH="/Applications/${APP_NAME}.app"

echo "Stopping ${APP_NAME}..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.3

echo "Removing Accessibility permission..."
tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null || true

if [ -d "${APP_PATH}" ]; then
    echo "Removing ${APP_PATH}..."
    rm -rf "${APP_PATH}"
    echo "Done. ${APP_NAME} has been uninstalled."
else
    echo "Done. (${APP_PATH} not found — skipping app removal)"
fi
