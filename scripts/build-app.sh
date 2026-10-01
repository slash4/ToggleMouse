#!/bin/bash
# Builds a universal (arm64 + x86_64) build/ToggleMouse.app and signs it.
# Signing identity: $SIGN_IDENTITY if set, else the first Developer ID Application,
# else the first Apple Development identity, else ad-hoc. A stable identity keeps the
# Accessibility permission and Keychain access across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

# Build each architecture separately and merge with lipo: multi-arch `swift build` goes
# through Xcode's build system, which rejects per-target language modes in Xcode 16.
for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH"
done

APP=build/ToggleMouse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
for PRODUCT in ToggleMouse ToggleMouseHelper; do
    lipo -create -output "$APP/Contents/MacOS/$PRODUCT" \
        "$(swift build -c release --arch arm64 --show-bin-path)/$PRODUCT" \
        "$(swift build -c release --arch x86_64 --show-bin-path)/$PRODUCT"
done
cp Resources/io.github.slash4.togglemouse.helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

find_identity() {
    security find-identity -v -p codesigning | grep -m1 "$1" | sed -E 's/.*"(.*)"/\1/' || true
}
IDENTITY="${SIGN_IDENTITY:-$(find_identity 'Developer ID Application')}"
IDENTITY="${IDENTITY:-$(find_identity 'Apple Development')}"

if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    # Sign the helper first; its identifier is what the app's XPC requirement checks.
    codesign --force --options runtime --identifier io.github.slash4.togglemouse.helper --sign "$IDENTITY" "$APP/Contents/MacOS/ToggleMouseHelper"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "No signing identity found; signing ad-hoc (the AirDrop helper won't work)"
    codesign --force --identifier io.github.slash4.togglemouse.helper --sign - "$APP/Contents/MacOS/ToggleMouseHelper"
    codesign --force --sign - "$APP"
fi

# Zip for transfer: copying a bare .app onto a network share or some other volumes adds
# metadata to the bundle, which breaks the signature. ditto keeps it intact.
ZIP=build/ToggleMouse.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built $APP and $ZIP"
