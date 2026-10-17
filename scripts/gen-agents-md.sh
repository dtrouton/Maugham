#!/usr/bin/env bash
# scripts/gen-agents-md.sh — write AGENTS.md from CLAUDE.md. Never edit AGENTS.md by hand.
set -euo pipefail
ROOT="${MAUGHAM_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
{
  echo "<!-- GENERATED from CLAUDE.md by scripts/gen-agents-md.sh — edit CLAUDE.md, then re-run. -->"
  echo
  cat "$ROOT/CLAUDE.md"
} > "$ROOT/AGENTS.md"
