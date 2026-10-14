#!/usr/bin/env bash
# Q2 visual-audit renders. Copies the harness into the app test target, runs only it, and removes it again.
# Output: build/q2-renders/*.png (2x) and *.txt (menu and accessibility dumps). Uses only this checkout's build/.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
DEST=Zeus/App/Tests/DesignerAuditRenders.swift
cp scripts/design-harness/DesignerAuditRenders.swift "$DEST"
trap 'rm -f "$ROOT/$DEST"; xcodegen generate --quiet' EXIT
ONLY="ZeusTests/DesignerAuditRenders${1:+/$1}"
[[ -z "${1:-}" ]] && rm -rf build/q2-renders
xcodegen generate --quiet
xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ROOT/build/DerivedData" -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
  test -only-testing:"$ONLY" 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" || true
ls build/q2-renders | wc -l
