#!/usr/bin/env bash
# Runs all tests. This is the team's definition of "tests pass".
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${ZEUS_TMUX_HYGIENE_ACTIVE:-0}" != "1" ]]; then
  exec python3 -B scripts/tmux_hygiene.py bash "scripts/test.sh" "$@"
fi
ROOT="$PWD"

python3 -B scripts/test_tmux_hygiene.py

echo "==> Release/appcast tests (offline fixtures)"
python3 -B scripts/test_release.py

echo "==> Live-gate tests (offline fixtures)"
python3 -B scripts/test_live_gate.py

echo "==> ZeusKit tests"
swift test --package-path Packages/ZeusKit --scratch-path "$ROOT/build/ZeusKit"

if [[ -f project.yml ]] && grep -q "ZeusTests" project.yml; then
  echo "==> Zeus app tests"
  xcodegen generate --quiet
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/build/DerivedData" \
    -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
    test 2>&1 | grep -E "Test run with|error:|\*\* TEST (SUCCEEDED|FAILED)"
fi
