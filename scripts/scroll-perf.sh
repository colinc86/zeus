#!/usr/bin/env bash
# S1: isolated mixed-history round trip, recorded by Animation Hitches. No global input events.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/scroll-perf.py "$PWD" "$@"
