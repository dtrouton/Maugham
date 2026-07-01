#!/usr/bin/env bash
# Dev-only: bridge Claude Code's stdio MCP client to the running dev-build
# Maugham app's Unix socket. Points the existing maugham-mcp bridge at the dev
# socket.
#
# Note on naming: the dev variant is the DEBUG build. Its .app bundle on disk is
# named "Maugham.app" (same filename as stable) — only the display name is
# "Maugham Dev", and it's distinguished by bundle id / support folder / the
# Debug build dir. So we locate the bridge under .../Build/Products/Debug/, NOT
# by a "Maugham Dev.app" filename. Release builds (stable) live under
# .../Build/Products/Release/ and are deliberately excluded.
set -euo pipefail

SOCKET="$HOME/Library/Application Support/Maugham Dev/mcp.sock"

# Find the maugham-mcp bridge inside the NEWEST Debug build product. BSD find
# has no -printf, so use stat to sort by mtime (newest first) — picking the most
# recently built dev app rather than filesystem-traversal order.
BRIDGE="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" \
  -type f -path '*/Build/Products/Debug/Maugham.app/Contents/MacOS/maugham-mcp' \
  -print0 2>/dev/null \
  | /usr/bin/xargs -0 /usr/bin/stat -f '%m %N' 2>/dev/null \
  | /usr/bin/sort -rn \
  | /usr/bin/head -n1 \
  | /usr/bin/cut -d' ' -f2- || true)"

if [ -z "${BRIDGE:-}" ]; then
  echo "maugham-test-mcp: no Debug Maugham.app bridge found under DerivedData." >&2
  echo "  Build the Maugham scheme in Debug (the dev variant) in Xcode first," >&2
  echo "  then launch it so the dev socket ($SOCKET) is bound." >&2
  exit 1
fi

exec env MAUGHAM_MCP_SOCKET="$SOCKET" "$BRIDGE"
