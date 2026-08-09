#!/usr/bin/env bash
# Phase 10 — swap the regenerated TreeNode.swift into an isolated worktree and
# run every suite that depends on it. The main checkout is never touched.
#
#   ./experiment/scripts/10-run-regeneration.sh control     # baseline at HEAD
#   ./experiment/scripts/10-run-regeneration.sh regenerated # with the swap
set -uo pipefail

MODE="${1:-regenerated}"
WT=/tmp/regen-maugham
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$WT/Packages/MaughamCore/Sources/MaughamCore/TreeNode.swift"
OUT="$REPO/experiment/results/$MODE"
mkdir -p "$OUT"

if [ "$MODE" = "regenerated" ]; then
  cp "$REPO/experiment/regenerated/TreeNode.swift" "$TARGET"
  echo "swapped in regenerated TreeNode.swift ($(wc -l < "$TARGET" | tr -d ' ') lines)"
else
  (cd "$WT" && git checkout -- Packages/MaughamCore/Sources/MaughamCore/TreeNode.swift)
  echo "restored original TreeNode.swift"
fi

echo "== 1/3 MaughamCore package =="
(cd "$WT" && swift test --package-path Packages/MaughamCore) > "$OUT/core.txt" 2>&1
grep -E "Executed [0-9]+ tests" "$OUT/core.txt" | tail -1
grep -cE "^Test Case .* failed" "$OUT/core.txt" | sed 's/^/  core failures: /'

echo "== 2/3 Mac scheme =="
(cd "$WT" && xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
    CODE_SIGNING_ALLOWED=NO -skip-testing:MaughamTests/MCPServerLifecycleTests) > "$OUT/mac.txt" 2>&1
grep -E "Executed [0-9]+ tests" "$OUT/mac.txt" | tail -1
grep -E "^Test Case .* failed" "$OUT/mac.txt" | sed 's/^/  /' | sort -u | head -40

echo "== 3/3 Phone scheme =="
(cd "$WT" && xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
    -destination 'platform=iOS Simulator,name=iPhone 17' test \
    CODE_SIGNING_ALLOWED=NO) > "$OUT/phone.txt" 2>&1
grep -E "Executed [0-9]+ tests" "$OUT/phone.txt" | tail -1
grep -E "^Test Case .* failed" "$OUT/phone.txt" | sed 's/^/  /' | sort -u | head -20

echo "== done: $OUT =="
