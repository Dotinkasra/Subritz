#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# Keep the existing production bundle and process intact for comparisons.
export SUBRITZ_APP_PATH="$PWD/dist/Subritz CPU Comparison.app"
export SUBRITZ_BUNDLE_ID="jp.local.Subritz.CPUComparison"
export SUBRITZ_DISPLAY_NAME="Subritz CPU Comparison"
export SUBRITZ_SETTINGS_SOURCE_DOMAIN="jp.local.YouTubeEnglishStudy"
exec ./scripts/build.sh "$@"
