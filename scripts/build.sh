#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
# The installed CLT's default macOS 27 SDK lacks SwiftUIMacros; use its 26.5 SDK.
SDK_ARGS=()
ICON_SWIFT_ARGS=(-module-cache-path "$PWD/.build/clang-cache")
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
 SDK_ARGS=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
 ICON_SWIFT_ARGS+=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
ICON_SOURCE="$PWD/scripts/Assets/AppIconSource.png"
ICON_OUTPUT="$PWD/scripts/Resources/AppIcon.icns"
if [[ ! -f "$ICON_OUTPUT" || "$ICON_SOURCE" -nt "$ICON_OUTPUT" || "$PWD/scripts/make-app-icon.swift" -nt "$ICON_OUTPUT" ]]; then
 swift "${ICON_SWIFT_ARGS[@]}" "$PWD/scripts/make-app-icon.swift" "$ICON_SOURCE" "$ICON_OUTPUT" "$PWD/scripts/Assets/AppIcon.png"
fi
swift build --disable-sandbox --build-system native "${SDK_ARGS[@]}" "$@"
BIN_DIR=$(swift build --disable-sandbox --build-system native "${SDK_ARGS[@]}" "$@" --show-bin-path)
APP="${SUBRITZ_APP_PATH:-$PWD/dist/Subritz.app}"
if [[ "$APP" == "$PWD/dist/Subritz.app" && -d "$PWD/dist/YouTubeEnglishStudy.app" && ! -d "$APP" ]]; then
 mv "$PWD/dist/YouTubeEnglishStudy.app" "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Subritz" "$APP/Contents/MacOS/Subritz"
rm -f "$APP/Contents/MacOS/YouTubeEnglishStudy"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp -R scripts/Resources/. "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
touch "$APP"
echo "$APP"
