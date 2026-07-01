#!/usr/bin/env bash
# Dev-only: bridge Claude Code's stdio MCP client to the running Maugham Dev
# app's Unix socket. Points the existing maugham-mcp bridge at the dev socket.
set -euo pipefail

SOCKET="$HOME/Library/Application Support/Maugham Dev/mcp.sock"

# Locate the maugham-mcp bridge inside the most recent Maugham Dev.app build.
BRIDGE="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" \
  -type f -path '*Maugham Dev.app/Contents/MacOS/maugham-mcp' -print 2>/dev/null \
  | /usr/bin/head -n1 || true)"

if [ -z "${BRIDGE:-}" ]; then
  echo "maugham-test-mcp: no Maugham Dev.app bridge found; build the Maugham (Dev) scheme first" >&2
  exit 1
fi

exec env MAUGHAM_MCP_SOCKET="$SOCKET" "$BRIDGE"
