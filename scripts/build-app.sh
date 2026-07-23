#!/bin/bash
# Builds the release binary and packages it into a runnable ClaudeTouchBar.app.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudeTouchBar"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
CERT_NAME="ClaudeTouchBar Local Signing"

echo "==> Compiling (release)"
swift build -c release

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "==> Code signing with stable local identity"
    codesign --force --deep --sign "$CERT_NAME" "${APP_BUNDLE}"
else
    echo "==> Code signing ad-hoc (no stable identity found)"
    echo "    Run ./scripts/setup-signing.sh once so macOS permission grants"
    echo "    (Screen Recording, etc.) survive future rebuilds."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "==> Done: $(pwd)/${APP_BUNDLE}"
echo "    Run it with: open ${APP_BUNDLE}"
