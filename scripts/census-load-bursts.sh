#!/bin/bash
# census-load-bursts.sh — the kept release census (signed op log P3b Task 3,
# handoff ruling 3 "A + 3b").
#
# WHAT IT LOOKS FOR
#
#   Released builds v0.37-v0.40 signed the load path's own emissions with
#   whichever actor opened the document. Two of those kinds (bootstrap,
#   taskCreate) are recognisable by kind alone and are grandfathered; the three
#   typingBursts are not, so any of those lines written under the assistant's or
#   the translator's key are REFUSED by the permit partition in a rooted book.
#   They are set aside and recoverable, never lost — but somebody has to know
#   they are there. A hit is a per-line manual recovery, never a rule change.
#
#   Before the P3 release (P3c release checklist), run it FROM THIS MAC — the
#   one with the checkout and a Swift toolchain — AGAINST EACH MAC'S FOLDERS:
#   every folder of every Mac that has opened a Maugham book, reached from here
#   (a file-sharing mount of the other Mac's folder, or a copy of it made
#   here). The other Macs need no checkout, no toolchain and nothing
#   installed; the census runs `swift test` against this repository. Give
#   Denver the output.
#
# WHAT IT IS NOT
#
#   It is READ-ONLY. It creates, moves, modifies and deletes nothing, and it
#   reads metadata only: a stream's filename, each line's kind, op id, doc id
#   and provenance.synthesis_source. It never looks at `changes`, so it never
#   reads a word of anybody's manuscript. Point it at LOCAL folders only.
#
# USAGE
#
#   scripts/census-load-bursts.sh ~/Documents [more dirs...]
#   scripts/census-load-bursts.sh "/Volumes/Other Mac/Documents"   # another Mac's
#
#   With no arguments it scans THIS Mac's ~/Documents. Each argument is a
#   directory to walk for project folders (a folder holding a .maugham/ops).
#
# HOW IT RUNS
#
#   The census itself is `LoadBurstCensus` in MaughamCore, pinned by
#   `LoadBurstCensusTests`. There is no executable target in the package, so it
#   is driven through an env-gated test — the `MAUGHAM_PERF_FIXTURE` pattern —
#   which skips silently in an ordinary gate and costs nothing.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -eq 0 ]; then
    set -- "$HOME/Documents"
fi

dirs=""
for d in "$@"; do
    if [ ! -d "$d" ]; then
        echo "census-load-bursts: not a directory, skipped: $d" >&2
        continue
    fi
    abs="$(cd "$d" && pwd)"
    case "$abs" in
        *:*) echo "census-load-bursts: refusing a path containing ':' — $abs" >&2
             exit 2 ;;
    esac
    if [ -z "$dirs" ]; then dirs="$abs"; else dirs="$dirs:$abs"; fi
done

if [ -z "$dirs" ]; then
    echo "census-load-bursts: nothing to scan." >&2
    exit 2
fi

echo "census-load-bursts: scanning $dirs"
echo

out="$(mktemp -t maugham-load-burst-census)"
trap 'rm -f "$out"' EXIT

set +e
MAUGHAM_LOAD_BURST_CENSUS_DIRS="$dirs" \
    swift test \
        --package-path "$repo_root/Packages/MaughamCore" \
        --filter 'LoadBurstCensusRunTests/test_runTheCensus' \
        >"$out" 2>&1
status=$?
set -e

# The report is printed between two markers so the test runner's own chatter
# does not have to be read.
if grep -q '^--- LOAD BURST CENSUS ---$' "$out"; then
    sed -n '/^--- LOAD BURST CENSUS ---$/,/^--- END ---$/p' "$out"
else
    echo "census-load-bursts: the census did not run. Output:" >&2
    cat "$out" >&2
    exit "${status:-1}"
fi

exit "$status"
