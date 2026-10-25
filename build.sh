#!/bin/bash
# Builds build/Recorder.app by hand (no Xcode project needed).
#   bash build.sh              build for the Mac you run it on
#   bash build.sh --universal  build for Apple Silicon and Intel (arm64 + x86_64, joined with lipo)
#   bash build.sh --install    build, then copy to ~/Applications/Recorder.app
# The options can be combined, for example: bash build.sh --universal --install
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Recorder"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DEPLOYMENT_TARGET="13.0"
INSTALL=0
UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --universal) UNIVERSAL=1 ;;
        *) echo "Unknown option: $arg" >&2; echo "Usage: bash build.sh [--universal] [--install]" >&2; exit 2 ;;
    esac
done

if [ "$UNIVERSAL" -eq 1 ]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

mkdir -p "$BUILD_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Generating app icon"
swiftc -O scripts/make-icon.swift -o "$BUILD_DIR/make-icon"
rm -rf "$BUILD_DIR/AppIcon.iconset"
"$BUILD_DIR/make-icon" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# One swiftc run per architecture, then lipo joins the results into one binary.
SLICES=()
for arch in "${ARCHS[@]}"; do
    echo "==> Compiling Swift sources ($arch)"
    swiftc -parse-as-library -O -swift-version 5 \
        -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
        -module-name Recorder \
        Sources/*.swift \
        -o "$BUILD_DIR/$APP_NAME-$arch"
    SLICES+=("$BUILD_DIR/$APP_NAME-$arch")
done
if [ "${#SLICES[@]}" -gt 1 ]; then
    echo "==> Joining architectures with lipo"
    lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
    cp "${SLICES[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi
rm -f "${SLICES[@]}"

echo "==> Assembling bundle"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier io.github.saschakubisch.recorder "$APP"
codesign --verify --verbose "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

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
