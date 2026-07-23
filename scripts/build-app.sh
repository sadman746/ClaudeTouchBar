#!/bin/bash
# Builds the release binary and packages it into a runnable ClaudeTouchBar.app.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudeTouchBar"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "==> Compiling (release)"
swift build -c release

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

echo "==> Code signing with stable local identity"
codesign --force --deep --sign "ClaudeTouchBar Local Signing" "${APP_BUNDLE}"

echo "==> Done: $(pwd)/${APP_BUNDLE}"
echo "    Avviala con: open ${APP_BUNDLE}"
