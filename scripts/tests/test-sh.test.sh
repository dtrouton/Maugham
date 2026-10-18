#!/bin/bash
# Self-test for scripts/test.sh: the `only` mode and the stale-project guard.
# Runs a COPY of test.sh inside a scratch git repo with a stub gen.sh, in dry-run mode.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)/scripts/test.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cd "$W"
git init -q . && mkdir scripts Maugham.xcodeproj Foo
cp "$SRC" scripts/test.sh
printf '#!/bin/bash\nmkdir -p Maugham.xcodeproj; touch Maugham.xcodeproj/project.pbxproj\necho gen >> gen.log\n' > gen.sh; chmod +x gen.sh
echo 'name: x' > project.yml; echo 'let a = 1' > Foo/A.swift
touch Maugham.xcodeproj/project.pbxproj
export TMPDIR="$W" MAUGHAM_TEST_DRY_RUN=1
run() { bash scripts/test.sh "$@" 2>&1; }
fail() { echo "FAIL: $1"; exit 1; }
REGEN='project.yml or the file set changed — regenerating'

out=$(run only Foo Bar)                # first run: stamp missing -> record, no regen
[[ "$out" != *"$REGEN"* ]] || fail "missing stamp must not regenerate"
[[ -f Maugham.xcodeproj/.maugham-fileset ]] || fail "stamp not written"
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
[[ $(wc -l < gen.log) -eq 3 ]] || fail "gen count: $(cat gen.log)"
out=$(run core); [[ "$out" != *"$REGEN"* ]] || fail "core must not touch the project"
echo ok
