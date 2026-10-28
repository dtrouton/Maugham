#!/bin/bash
# core-deaths.sh — read a failed `swift test --parallel` log and decide whether
# its only failures are workers that macOS killed silently.
#
#   scripts/lib/core-deaths.sh <log>
#
# Prints one verdict line, then (for retry) one test name per line:
#   none                no test started without finishing — fail as usual
#   retry <regex>       only silent deaths: re-run exactly these, anchored for --filter
#   real-failure <n>    n silent deaths, but a real failure is in the log too — no retry
#   over-cap <n>        more silent deaths than CORE_DEATH_CAP (default 20) — no retry
#
# A silent death is a `Test Case '-[Mod.Class test]' started.` line with no
# passed/failed/skipped line for the same test. SwiftPM prints exactly that when
# a worker is SIGKILLed: macOS kills a fresh worker whose recycled pid RunningBoard
# still lists as a suspended extension, at its first NSFileCoordinator claim
# (docs/testing/TROUBLESHOOTING.md, "A Core test dies with only …"). A crash is
# NOT silent: SwiftPM adds `error: Process '…' exited with unexpected signal code`
# for SIGSEGV/SIGTRAP and the runtime prints `Fatal error:`, so those count as
# real failures here, as does any assertion (`: error: `, `' failed (`).
set -euo pipefail
LOG="$1"
CAP="${CORE_DEATH_CAP:-20}"

# Progress lines ("[12/2673] Testing …") are SwiftPM's own and name every test.
body=$(grep -v '^\[[0-9]*/[0-9]*\]' "$LOG" || true)

started=$(sed -nE "s/^Test Case '-\[([^ ]+) ([^]]+)\]' started\.\$/\1\/\2/p" <<<"$body" | LC_ALL=C sort -u)
finished=$(sed -nE "s/^Test Case '-\[([^ ]+) ([^]]+)\]' (passed|failed|skipped) \(.*/\1\/\2/p" <<<"$body" | LC_ALL=C sort -u)
silent=$(LC_ALL=C comm -23 <(echo "$started") <(echo "$finished") | grep -v '^$' || true)

if [[ -z "$silent" ]]; then
  echo "none"
  exit 0
fi
n=$(wc -l <<<"$silent" | tr -d ' ')

if grep -qE ": error: |^error: |' failed \(|Fatal error|^✘ " <<<"$body"; then
  echo "real-failure $n"
  exit 0
fi
if (( n > CAP )); then
  echo "over-cap $n"
  exit 0
fi

# Anchored alternation of exact Module.Class/test names; dots escaped.
regex="^($(sed 's/\./\\./g' <<<"$silent" | paste -sd'|' -))\$"
echo "retry $regex"
echo "$silent"
