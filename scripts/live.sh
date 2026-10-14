#!/usr/bin/env bash
# Real-agent release gate. Fixtures use only private sockets/profiles and localhost models.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -B scripts/live_gate.py "$@"
