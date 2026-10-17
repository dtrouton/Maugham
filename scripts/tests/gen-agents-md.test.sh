#!/usr/bin/env bash
# scripts/tests/gen-agents-md.test.sh — AGENTS.md is CLAUDE.md with a header and nothing else changed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/CLAUDE.md" "$TMP/CLAUDE.md"
MAUGHAM_REPO_ROOT="$TMP" "$ROOT/scripts/gen-agents-md.sh"
head -1 "$TMP/AGENTS.md" | grep -q 'GENERATED from CLAUDE.md' || { echo "FAIL: no generated header"; exit 1; }
diff <(tail -n +3 "$TMP/AGENTS.md") "$TMP/CLAUDE.md" > /dev/null || { echo "FAIL: body differs from CLAUDE.md"; exit 1; }
echo "ok"
