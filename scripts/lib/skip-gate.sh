#!/bin/bash
# skip-gate.sh — the full gate fails when more Mac tests skip than the baseline names.
#
#   scripts/lib/skip-gate.sh <tests.json> <baseline>
#
# <tests.json> is `xcrun xcresulttool get test-results tests --path <bundle>`.
# <baseline> (scripts/skip-baseline.txt) names one skipped test per line, as
# xcresult spells it (`Class/test_name()`); `#` lines are comments. Its line
# count is the ceiling. More skips than that fails, naming the skips the
# baseline does not hold; fewer passes with a hint to drop the stale names.
# A swap (one gone, one new, same count) passes but names both.
set -euo pipefail
JSON="$1"; BASELINE="$2"

# A result with no test cases at all is format drift or an empty export, not
# "nothing skipped": refuse it rather than pass it.
total=$(/usr/bin/jq -s '[.[] | .. | objects | select(.nodeType? == "Test Case")] | length' "$JSON" 2>/dev/null || echo 0)
if [[ "$total" == 0 ]]; then
  echo "✗ skip gate: $JSON holds no test cases — unreadable, empty, or xcresulttool's" >&2
  echo "  format changed. The skip count cannot be checked." >&2
  exit 1
fi
now=$(/usr/bin/jq -r '[.. | objects | select(.nodeType? == "Test Case" and .result? == "Skipped")
  | .nodeIdentifier] | unique | .[]' "$JSON")
want=$(grep -v '^#' "$BASELINE" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u || true)
count() { [[ -z "$1" ]] && echo 0 || wc -l <<<"$1" | tr -d ' '; }
n=$(count "$now"); ceiling=$(count "$want")
new=$(LC_ALL=C comm -23 <(LC_ALL=C sort <<<"$now") <(echo "$want") | grep -v '^$' || true)
gone=$(LC_ALL=C comm -13 <(LC_ALL=C sort <<<"$now") <(echo "$want") | grep -v '^$' || true)

if (( n > ceiling )); then
  echo "✗ skip gate: $n tests skipped, ceiling $ceiling (over by $((n - ceiling)))." >&2
  [[ -n "$new" ]] && { echo "  skipped and not in $BASELINE:" >&2; sed 's/^/    /' <<<"$new" >&2; }
  echo "  Fix the skip, or — if it is a deliberate environmental skip — add its name to" >&2
  echo "  $BASELINE and say why in the commit message." >&2
  exit 1
fi
echo "✓ skip gate: $n tests skipped, ceiling $ceiling"
if [[ -n "$new" ]]; then
  echo "  new skips (count unchanged): add them to $BASELINE:"; sed 's/^/    /' <<<"$new"
fi
if [[ -n "$gone" ]]; then
  echo "  no longer skipped — remove from $BASELINE to lower the ceiling:"; sed 's/^/    /' <<<"$gone"
fi
