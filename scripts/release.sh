#!/bin/zsh
# Build a fresh universal app and a drag-to-Applications disk image.
set -eu
set -o pipefail
cd "${0:A:h:h}"

RELEASE_TAG="${1:-}"
if [[ ! "$RELEASE_TAG" =~ '^v([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' ]]; then
 print -u2 'Usage: ./scripts/release.sh vMAJOR.MINOR.PATCH[-PRERELEASE]'
 exit 1
fi
export SUBRITZ_VERSION="$match[1]"
export SUBRITZ_BUILD_NUMBER="${SUBRITZ_BUILD_NUMBER:-1}"
if [[ ! "$SUBRITZ_BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
 print -u2 'SUBRITZ_BUILD_NUMBER must be a nonnegative integer.'
 exit 1
fi
mkdir -p dist
RELEASE_WORK=$(mktemp -d "$PWD/dist/.release-XXXXXX")
MOUNT_POINT=""
cleanup() {
 if [[ -n "$MOUNT_POINT" ]]; then
  hdiutil detach "$MOUNT_POINT" >/dev/null || true
  rmdir "$MOUNT_POINT" || true
 fi
 rm -rf "$RELEASE_WORK"
}
trap cleanup EXIT

for ARCHITECTURE in arm64 x86_64; do
 SUBRITZ_APP_PATH="$RELEASE_WORK/$ARCHITECTURE/Subritz.app" ./scripts/build.sh \
  -c release --triple "$ARCHITECTURE-apple-macosx15.0" --scratch-path ".build/release-$ARCHITECTURE"
done

STAGING="$RELEASE_WORK/image"
mkdir -p "$STAGING"
ditto "$RELEASE_WORK/arm64/Subritz.app" "$STAGING/Subritz.app"
lipo -create "$RELEASE_WORK/arm64/Subritz.app/Contents/MacOS/Subritz" \
 "$RELEASE_WORK/x86_64/Subritz.app/Contents/MacOS/Subritz" \
 -output "$STAGING/Subritz.app/Contents/MacOS/Subritz"
# Combining Mach-O slices invalidates their individual signatures.
codesign --force --sign - "$STAGING/Subritz.app"
codesign --verify --deep --strict "$STAGING/Subritz.app"
for ARCHITECTURE in arm64 x86_64; do
 lipo "$STAGING/Subritz.app/Contents/MacOS/Subritz" -verify_arch "$ARCHITECTURE"
done
ln -s /Applications "$STAGING/Applications"

DMG_NAME="Subritz-$RELEASE_TAG-universal.dmg"
DMG_PATH="$PWD/dist/$DMG_NAME"
hdiutil create -volname "Subritz $RELEASE_TAG" -srcfolder "$STAGING" \
 -format UDZO -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"

# Verify the shipped app itself, not only the temporary build directory.
MOUNT_POINT=$(mktemp -d "${TMPDIR:-/tmp}/subritz-release-verify.XXXXXX")
hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_POINT"
codesign --verify --deep --strict "$MOUNT_POINT/Subritz.app"
for ARCHITECTURE in arm64 x86_64; do
 lipo "$MOUNT_POINT/Subritz.app/Contents/MacOS/Subritz" -verify_arch "$ARCHITECTURE"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT_POINT/Subritz.app/Contents/Info.plist")" == "$SUBRITZ_VERSION" ]]
[[ "$(readlink "$MOUNT_POINT/Applications")" == /Applications ]]
hdiutil detach "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
MOUNT_POINT=""
(cd dist && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
print "$DMG_PATH"
