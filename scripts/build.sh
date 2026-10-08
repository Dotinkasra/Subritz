#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
# The installed CLT's default macOS 27 SDK lacks SwiftUIMacros; use its 26.5 SDK.
SDK_ARGS=()
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
 SDK_ARGS=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
swift build --disable-sandbox --build-system native "${SDK_ARGS[@]}" "$@"
BIN_DIR=$(swift build --disable-sandbox --build-system native "${SDK_ARGS[@]}" "$@" --show-bin-path)
APP="$PWD/dist/YouTubeEnglishStudy.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/YouTubeEnglishStudy" "$APP/Contents/MacOS/YouTubeEnglishStudy"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"
