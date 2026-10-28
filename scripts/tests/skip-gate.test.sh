#!/bin/bash
# Self-test for scripts/lib/skip-gate.sh: a rise fails naming the new skip; equal
# and fewer pass; a fall names the stale baseline line.
set -euo pipefail
GATE="$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/skip-gate.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
json() {   # one skipped test per argument, plus a passing one the gate must ignore
  local nodes='{"nodeType":"Test Case","result":"Passed","nodeIdentifier":"A/test_ok()"}'
  for t in "$@"; do nodes+=",{\"nodeType\":\"Test Case\",\"result\":\"Skipped\",\"nodeIdentifier\":\"$t\"}"; done
  echo "{\"testNodes\":[{\"nodeType\":\"Unit test bundle\",\"children\":[$nodes]}]}" > "$W/t.json"
}
printf '# comment\nA/test_x()\nB/test_y()\n' > "$W/base.txt"

json "A/test_x()" "B/test_y()"
out=$("$GATE" "$W/t.json" "$W/base.txt" 2>&1) || fail "equal count must pass: $out"
[[ "$out" == *"2 tests skipped, ceiling 2"* ]] || fail "equal: $out"

json "A/test_x()" "B/test_y()" "C/test_new()"
set +e; out=$("$GATE" "$W/t.json" "$W/base.txt" 2>&1); code=$?; set -e
[[ $code -eq 1 ]] || fail "a rise must fail: $out"
[[ "$out" == *"over by 1"* && "$out" == *"C/test_new()"* ]] || fail "rise must name the delta and the test: $out"
[[ "$out" != *"    A/test_x()"* ]] || fail "rise named a baseline skip: $out"

json "A/test_x()"
out=$("$GATE" "$W/t.json" "$W/base.txt" 2>&1) || fail "a fall must pass: $out"
[[ "$out" == *"remove from"*"B/test_y()"* ]] || fail "fall must name the stale line: $out"

json
out=$("$GATE" "$W/t.json" "$W/base.txt" 2>&1) || fail "no skips must pass: $out"
[[ "$out" == *"0 tests skipped, ceiling 2"* ]] || fail "none: $out"
# No test cases at all (empty export, {} or format drift) fails, never passes as "0 skipped".
for body in '' '{}' '{"testNodes":[]}' 'not json'; do
  printf '%s' "$body" > "$W/t.json"
  set +e; out=$("$GATE" "$W/t.json" "$W/base.txt" 2>&1); code=$?; set -e
  [[ $code -eq 1 && "$out" == *"holds no test cases"* ]] || fail "no test cases ('$body') must fail: $code $out"
done
echo ok
