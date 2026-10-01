#!/bin/bash
# Builds build/ToggleMouse.app and signs it.
# Signing identity: $SIGN_IDENTITY if set, else the first Developer ID Application,
# else the first Apple Development identity, else ad-hoc. A stable identity keeps the
# Accessibility permission and Keychain access across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/ToggleMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/ToggleMouse" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

find_identity() {
    security find-identity -v -p codesigning | grep -m1 "$1" | sed -E 's/.*"(.*)"/\1/' || true
}
IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Developer ID Application')}"
IDENTITY="${IDENTITY:-$(find_identity 'Apple Development')}"

if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "No signing identity found; signing ad-hoc"
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
