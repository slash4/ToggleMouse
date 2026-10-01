#!/bin/bash
# Builds a universal (arm64 + x86_64) build/ToggleMouse.app and signs it.
# Signing identity: $SIGN_IDENTITY if set, else the first Developer ID Application,
# else the first Apple Development identity, else ad-hoc. A stable identity keeps the
# Accessibility permission and Keychain access across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}"

APP=build/ToggleMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/ToggleMouse" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

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

# Zip for transfer: copying a bare .app onto a network share or some other volumes adds
# metadata to the bundle, which breaks the signature. ditto keeps it intact.
ZIP=build/ToggleMouse.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built $APP and $ZIP"
