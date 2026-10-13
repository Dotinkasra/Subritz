#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
SDK_ARGS=()
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
 SDK_ARGS=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
# Use the selected developer installation, including Xcode on hosted runners.
DEVELOPER_ROOT="${DEVELOPER_DIR:-$(xcode-select -p)}"
TEST_FRAMEWORK_ARGS=()
for FRAMEWORKS in "$DEVELOPER_ROOT/Library/Developer/Frameworks" "$DEVELOPER_ROOT/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
 if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
  TEST_FRAMEWORK_ARGS=(-Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS")
  break
 fi
done
swift test --disable-sandbox --build-system native "${SDK_ARGS[@]}" --disable-xctest --enable-swift-testing "${TEST_FRAMEWORK_ARGS[@]}" "$@"
