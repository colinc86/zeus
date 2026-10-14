#!/usr/bin/env bash
# Builds everything. This is the team's definition of "it builds".
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

echo "==> ZeusKit (swift build)"
swift build --package-path Packages/ZeusKit --scratch-path "$ROOT/build/ZeusKit"

if [[ -f project.yml ]]; then
  echo "==> Generating Xcode project"
  xcodegen generate --quiet
  echo "==> Zeus.app (xcodebuild)"
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/build/DerivedData" \
    -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
    build -quiet
  echo "==> Built: build/DerivedData/Build/Products/Debug/Zeus.app"
fi
