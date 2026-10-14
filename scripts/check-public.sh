#!/usr/bin/env bash
# Fails if any tracked file contains a term from the git-ignored scripts/public-denylist.txt
# (one case-insensitive extended regex per line: names, emails, team IDs, machine names).
# Run before every push.
set -euo pipefail
cd "$(dirname "$0")/.."
LIST=scripts/public-denylist.txt
[ -f "$LIST" ] || { echo "No $LIST; nothing to check."; exit 0; }
status=0
while IFS= read -r term; do
  [ -z "$term" ] && continue
  case "$term" in \#*) continue ;; esac
  if git grep -I -n -i -E -e "$term" -- . ':!scripts/public-denylist.txt'; then status=1; fi
  if git ls-files -z | xargs -0 grep -l -a -i -E -e "$term" 2>/dev/null | grep -v '^scripts/public-denylist.txt$'; then status=1; fi
done < "$LIST"
[ "$status" -eq 0 ] && echo "Public check passed." || echo "Public check FAILED: remove the matches above." >&2
exit "$status"
