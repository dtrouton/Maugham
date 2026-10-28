#!/bin/bash
# Self-test for scripts/lib/core-deaths.sh and test.sh's one-shot Core re-run:
# a silent death alone is re-run by its exact name; a death beside a real
# failure (or a crash) is not; no deaths passes through; over the cap is not.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib/core-deaths.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# Canned SwiftPM --parallel output, in its real shape: progress lines name every
# test; only a worker that did not pass has its own output printed.
progress() { printf '[1/3] Testing MaughamCoreTests.A/test_one\n[2/3] Testing MaughamCoreTests.B/test_two\n'; }
death() {   # $1 = Class, $2 = test
  printf "Test Suite 'Selected tests' started at 2026-10-28 18:04:28.345.\n"
  printf "Test Suite 'MaughamCoreTests.xctest' started at 2026-10-28 18:04:28.346.\n"
  printf "Test Suite '%s' started at 2026-10-28 18:04:28.346.\n" "$1"
  printf "Test Case '-[MaughamCoreTests.%s %s]' started.\n\n" "$1" "$2"
}
assertion() {
  printf "Test Case '-[MaughamCoreTests.C test_bad]' started.\n"
  printf "/x/C.swift:7: error: -[MaughamCoreTests.C test_bad] : XCTAssertEqual failed\n"
  printf "Test Case '-[MaughamCoreTests.C test_bad]' failed (0.051 seconds).\n"
}
crash() {
  printf "error: Process '/x/xctest -XCTest MaughamCoreTests.D/test_crash /x.xctest' exited with unexpected signal code 5\n"
  printf "Test Case '-[MaughamCoreTests.D test_crash]' started.\nD.swift:7: Fatal error: boom\n"
}
tail_lines() { printf "Note: Some test targets reported failures:\n  - MaughamCoreTests (XCTest)\n"; }

# 1. A silent death alone: retry, with an anchored, dot-escaped filter of exactly it.
{ progress; death PermitLoadTests test_a; death RegistryAdmissionTests test_b; tail_lines; } > "$W/1.log"
out=$("$LIB" "$W/1.log")
[[ "$(head -1 <<<"$out")" == 'retry ^(MaughamCoreTests\.PermitLoadTests/test_a|MaughamCoreTests\.RegistryAdmissionTests/test_b)$' ]] \
  || fail "death alone must retry with the exact filter: $out"
[[ $(tail -n +2 <<<"$out" | wc -l | tr -d ' ') -eq 2 ]] || fail "death alone must name both: $out"
grep -Eq "$(head -1 <<<"$out" | cut -d' ' -f2-)" <<<"MaughamCoreTests.PermitLoadTests/test_a" || fail "filter must match its test"
! grep -Eq "$(head -1 <<<"$out" | cut -d' ' -f2-)" <<<"MaughamCoreTests.PermitLoadTests/test_ab" || fail "filter must be anchored"

# 2. A death beside a real assertion failure, or beside a crash: no retry.
{ progress; death PermitLoadTests test_a; assertion; tail_lines; } > "$W/2.log"
[[ "$("$LIB" "$W/2.log")" == "real-failure 1" ]] || fail "death + assertion must not retry: $("$LIB" "$W/2.log")"
{ progress; crash; tail_lines; } > "$W/2b.log"
[[ "$("$LIB" "$W/2b.log")" == "real-failure 1" ]] || fail "a crash is not silent: $("$LIB" "$W/2b.log")"

# 3. No deaths (an assertion failure only, or a clean log): pass-through.
{ progress; assertion; tail_lines; } > "$W/3.log"
[[ "$("$LIB" "$W/3.log")" == "none" ]] || fail "no deaths must be none: $("$LIB" "$W/3.log")"
progress > "$W/3b.log"
[[ "$("$LIB" "$W/3b.log")" == "none" ]] || fail "clean log must be none"

# 4. Over the cap: no retry.
{ progress; for i in $(seq 1 21); do death Many "test_$i"; done; tail_lines; } > "$W/4.log"
[[ "$("$LIB" "$W/4.log")" == "over-cap 21" ]] || fail "21 deaths must be over the cap: $("$LIB" "$W/4.log")"
{ progress; for i in $(seq 1 3); do death Many "test_$i"; done; } > "$W/4b.log"
[[ "$(CORE_DEATH_CAP=2 "$LIB" "$W/4b.log")" == "over-cap 3" ]] || fail "the cap is configurable"

# 5. End to end through test.sh's core leg, with a stub `swift`: the parallel run
#    dies silently, the re-run gets exactly the filter, and its verdict is the leg's.
cd "$W"; git init -q . && mkdir -p scripts/lib bin
cp "$ROOT/scripts/test.sh" scripts/test.sh; cp "$LIB" scripts/lib/core-deaths.sh
cat > bin/swift <<EOF
#!/bin/bash
echo "\$*" >> "$W/calls.log"
if [[ "\$*" == *--parallel* ]]; then cat "$W/1.log"; exit 1; fi
printf '%b' "\${STUB_RETRY_OUT-\\t Executed 2 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\\n}"
exit "\${STUB_RETRY_RC:-0}"
EOF
chmod +x bin/swift
export TMPDIR="$W" PATH="$W/bin:$PATH"
out=$(bash scripts/test.sh core 2>&1) || fail "a recovered death must pass the leg: $out"
[[ "$out" == *"↻ core: 2 worker(s) died silently"* ]] || fail "the leg must name the re-run: $out"
[[ $(wc -l < calls.log | tr -d ' ') -eq 2 ]] || fail "exactly one re-run: $(cat calls.log)"
[[ "$(tail -1 calls.log)" == *"--filter ^(MaughamCoreTests\.PermitLoadTests/test_a|MaughamCoreTests\.RegistryAdmissionTests/test_b)\$"* \
   && "$(tail -1 calls.log)" != *--parallel* ]] || fail "re-run args: $(tail -1 calls.log)"
rm calls.log
set +e; out=$(STUB_RETRY_RC=1 bash scripts/test.sh core 2>&1); code=$?; set -e
[[ $code -ne 0 ]] || fail "a re-run that fails must fail the leg: $out"

# 6. A re-run that exits 0 must still PROVE it ran every named test, unfailed.
leg_fails() {   # $1 = what the stub re-run prints, $2 = why
  set +e; out=$(STUB_RETRY_OUT="$1" bash scripts/test.sh core 2>&1); code=$?; set -e
  [[ $code -ne 0 && "$out" == *"did not prove itself"* && "$out" == *"core logs kept"* ]] \
    || fail "$2 must fail the leg: $code $out"
}
leg_fails 'error: No matching test cases were run\n' "a filter matching zero tests"
leg_fails '' "a re-run that printed nothing (exit(0))"
leg_fails '\t Executed 1 test, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\n' "one of two names run"
leg_fails '\t Executed 2 tests, with 1 failure (0 unexpected) in 0.1 (0.1) seconds\n' "a reported failure"
echo ok
