#!/bin/zsh
# Offline only: measures local caption payload sizes and temporary SQLite writes.
set -eu
if (( $# < 1 )); then
  echo "Usage: $0 /absolute/path/caption.json3 [result.json]" >&2
  exit 1
fi
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build --disable-sandbox --build-system native --sdk "$SDK" --product Subritz
BIN_DIR=$(swift build --disable-sandbox --build-system native --sdk "$SDK" --show-bin-path)
MEASURE_DIR=$(mktemp -d)
trap 'rm -rf "$MEASURE_DIR"' EXIT
swiftc -parse-as-library -sdk "$SDK" -I "$BIN_DIR/Modules" -I Sources/CSQLite \
  scripts/measure-grammar.swift "$BIN_DIR"/StudyCore.build/*.swift.o -lsqlite3 \
  -o "$MEASURE_DIR/measure"
"$MEASURE_DIR/measure" "$@"
