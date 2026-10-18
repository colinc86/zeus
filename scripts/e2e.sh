#!/usr/bin/env bash
# Real bundled zeus-mcp subprocesses against a headless runtime and CardStore.
# ZEUS_TEST_TMUX=1 also runs the isolated, real tmux route. Never touches user history.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${ZEUS_TMUX_HYGIENE_ACTIVE:-0}" != "1" ]]; then
  exec python3 -B scripts/tmux_hygiene.py bash "scripts/e2e.sh" "$@"
fi
ZEUS_E2E_ROOT="$PWD"
ZEUS_E2E_START=$SECONDS
mkdir -p build
scripts/build.sh > build/e2e-build.log 2>&1 || { cat build/e2e-build.log; exit 1; }
ZEUS_E2E_RESULT="$ZEUS_E2E_ROOT/build/e2e-$(date +%Y%m%d-%H%M%S).xcresult"
export TEST_RUNNER_ZEUS_TEST_TMUX="${ZEUS_TEST_TMUX:-0}"
xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ZEUS_E2E_ROOT/build/DerivedData" \
  -clonedSourcePackagesDirPath "$ZEUS_E2E_ROOT/build/SourcePackages" \
  -resultBundlePath "$ZEUS_E2E_RESULT" \
  -only-testing:ZeusTests/ZeusE2ETests \
  test -quiet
xcrun xcresulttool get test-results summary --path "$ZEUS_E2E_RESULT" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["result"] == "Passed" and r["failedTests"] == 0 and r["passedTests"] >= 9, r
print("E2E: %s passed, %s skipped" % (r["passedTests"], r["skippedTests"]))
'
printf '%s\n' "$ZEUS_E2E_RESULT" > build/e2e-latest-result.txt
printf 'Zeus E2E completed in %s seconds. Build log: build/e2e-build.log\n' "$((SECONDS - ZEUS_E2E_START))"
