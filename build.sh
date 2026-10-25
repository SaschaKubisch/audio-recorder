#!/bin/bash
# Builds build/Recorder.app by hand (no Xcode project needed).
#   bash build.sh              build only
#   bash build.sh --install    build, then copy to ~/Applications/Recorder.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Recorder"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; echo "Usage: bash build.sh [--install]" >&2; exit 2 ;;
    esac
done

mkdir -p "$BUILD_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Generating app icon"
swiftc -O scripts/make-icon.swift -o "$BUILD_DIR/make-icon"
rm -rf "$BUILD_DIR/AppIcon.iconset"
"$BUILD_DIR/make-icon" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Compiling Swift sources"
swiftc -parse-as-library -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -module-name Recorder \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> Assembling bundle"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier io.github.saschakubisch.recorder "$APP"
codesign --verify --verbose "$APP"

echo "Built $APP"

if [ "$INSTALL" -eq 1 ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    # Quit a running copy so the old bundle is not replaced under it.
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -rf "$DEST/$APP_NAME.app"
    ditto "$APP" "$DEST/$APP_NAME.app"
    codesign --verify "$DEST/$APP_NAME.app"
    echo "Installed $DEST/$APP_NAME.app"
fi
