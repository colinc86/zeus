#!/usr/bin/env bash
# Builds everything. This is the team's definition of "it builds".
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ZEUS_BUILD_ACTION=build
if [[ "$#" -eq 1 && "$1" == "--for-testing" ]]; then
  ZEUS_BUILD_ACTION=build-for-testing
elif [[ "$#" -ne 0 ]]; then
  echo "Usage: scripts/build.sh [--for-testing]" >&2
  exit 2
fi

echo "==> ZeusKit (swift build)"
swift build --package-path Packages/ZeusKit --scratch-path "$ROOT/build/ZeusKit"

if [[ -f project.yml ]]; then
  echo "==> Generating Xcode project"
  xcodegen generate --quiet
  echo "==> Zeus.app (xcodebuild)"
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/build/DerivedData" \
    -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
    "$ZEUS_BUILD_ACTION" -quiet
  echo "==> Built: build/DerivedData/Build/Products/Debug/Zeus.app"
fi
