#!/bin/bash
# Self-test for scripts/test.sh: the `only` mode and the stale-project guard.
# Runs a COPY of test.sh inside a scratch git repo with a stub gen.sh, in dry-run mode.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)/scripts/test.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cd "$W"
git init -q . && mkdir scripts Maugham.xcodeproj Foo bin
cp "$SRC" scripts/test.sh
printf '#!/bin/bash\nmkdir -p Maugham.xcodeproj; touch Maugham.xcodeproj/project.pbxproj\necho gen >> gen.log\n' > gen.sh; chmod +x gen.sh
# Stand-ins for the real tools, so a run that is NOT a dry run says so and builds nothing.
printf '#!/bin/bash\necho "REAL $(basename "$0") $*"\n' > bin/xcodebuild; chmod +x bin/xcodebuild
cp bin/xcodebuild bin/swift
echo 'name: x' > project.yml; echo 'let a = 1' > Foo/A.swift
touch Maugham.xcodeproj/project.pbxproj
export TMPDIR="$W" MAUGHAM_TEST_DRY_RUN=1 PATH="$W/bin:$PATH"
run() { bash scripts/test.sh "$@" 2>&1; }
fail() { echo "FAIL: $1"; exit 1; }
gens() { [[ -f gen.log ]] && wc -l < gen.log | tr -d ' ' || echo 0; }
REGEN='project.yml or the file set changed — regenerating'

# Bad arguments cost nothing: exit 64, no regeneration, no stamp (checked first,
# while the stamp is still missing and the guard WOULD regenerate).
set +e
out=$(run nonsense); code=$?
set -e
[[ $code -eq 64 ]] || fail "bad mode: want exit 64, got $code: $out"
[[ "$out" != *"$REGEN"* && $(gens) -eq 0 ]] || fail "bad mode regenerated: $out"
set +e
out=$(run only); code=$?
set -e
[[ $code -eq 64 ]] || fail "bare only: want exit 64, got $code: $out"
[[ "$out" != *"$REGEN"* && $(gens) -eq 0 ]] || fail "bare only regenerated: $out"
[[ ! -f Maugham.xcodeproj/.maugham-fileset ]] || fail "bad arguments wrote the stamp"

out=$(run only Foo Bar)                # first run: stamp missing -> regenerate once
[[ "$out" == *"$REGEN"* ]] || fail "a missing stamp must regenerate (old checkout, stale pbxproj)"
[[ -f Maugham.xcodeproj/.maugham-fileset ]] || fail "stamp not written"
[[ $(gens) -eq 1 ]] || fail "missing stamp: gen count $(gens)"
[[ $(grep -c '^DRYRUN.*xcodebuild' <<<"$out") -eq 1 ]] || fail "(a) want one xcodebuild line"
grep -q 'lock held: yes.*-only-testing:MaughamTests/Foo -only-testing:MaughamTests/Bar$' <<<"$out" || fail "(a) flags/lock: $out"
run only MaughamTests/X/test_y | grep -q -- '-only-testing:MaughamTests/X/test_y$' || fail "slash passthrough"

out=$(run only Foo); [[ "$out" != *"$REGEN"* ]] || fail "(c) unchanged tree regenerated"
sleep 1; echo '// edit' >> Foo/A.swift
out=$(run only Foo); [[ "$out" != *"$REGEN"* ]] || fail "editing a file must not regenerate"

echo 'let b = 2' > Foo/B.swift                # untracked new file
out=$(run only Foo); [[ "$out" == *"$REGEN"* ]] || fail "(b) new file did not regenerate"
out=$(run only Foo); [[ "$out" != *"$REGEN"* ]] || fail "(c) regenerated twice"

sleep 1; touch project.yml
out=$(run fast); [[ "$out" == *"$REGEN"* ]] || fail "project.yml newer did not regenerate"
rm -rf Maugham.xcodeproj
out=$(run phone); [[ "$out" == *"$REGEN"* ]] || fail "missing project did not regenerate"
[[ $(gens) -eq 4 ]] || fail "gen count: $(cat gen.log)"
out=$(run core); [[ "$out" != *"$REGEN"* ]] || fail "core must not touch the project"

# Dry run is MAUGHAM_TEST_DRY_RUN=1 exactly: any other value runs the real tools.
out=$(MAUGHAM_TEST_DRY_RUN=0 run only Foo)
[[ "$out" == *"REAL xcodebuild"* && "$out" != *DRYRUN* ]] || fail "DRY_RUN=0 must not dry-run: $out"
out=$(MAUGHAM_TEST_DRY_RUN=yes run core)
[[ "$out" == *"REAL swift"* && "$out" != *DRYRUN* ]] || fail "DRY_RUN=yes must not dry-run: $out"
echo ok
