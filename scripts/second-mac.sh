#!/bin/zsh
# Launch the dev build as a SECOND MAC on this machine, for smoking admission,
# revocation, the claim and the two-root merge without a second device.
#
# The device's keys live under ~/Library/Application Support/<variant>/device,
# and the app is not sandboxed, so a substituted home gives the same binary a
# fresh device folder: new enclave keys, new fingerprint, its own registry
# cache, admission memory and MCP socket. To every project it opens it IS
# another Mac. Projects are opened by their real paths (Open project…).
#
#   ./scripts/second-mac.sh          launch (keeps its identity between runs)
#   ./scripts/second-mac.sh --reset  forget the second Mac entirely, then launch
#   ./scripts/second-mac.sh --name third   a THIRD Mac (its own home, ~/.maugham-third-mac)
set -euo pipefail

# SHORT on purpose: the MCP socket lives under it and a Unix socket path is
# capped at 104 bytes; a home under Application Support silently truncated it.
name="second"
reset=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset) reset=1 ;;
    --name) name="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
home="$HOME/.maugham-$name-mac"
# THIS tree's DerivedData, by its recorded workspace path — never the newest folder,
# which is usually a review worktree's build of some other commit.
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
app=""
for d in "$HOME"/Library/Developer/Xcode/DerivedData/Maugham-*/; do
  ws=$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null) || continue
  [[ "$ws" == "$repo/Maugham.xcodeproj" ]] && app="$d/Build/Products/Debug/Maugham.app" && break
done
[[ -n "$app" && -d "$app" ]] || { echo "no Debug build of $repo found — build the Maugham scheme in Xcode first" >&2; exit 1; }

[[ $reset -eq 1 ]] && rm -rf "$home"
support="$home/Library/Application Support/Maugham Dev"
mkdir -p "$support"
# Share the dev TestWorkspace, so a test project one Mac made can be opened by
# name on the other (`test_open_project`).
ln -sfn "$HOME/Library/Application Support/Maugham Dev/TestWorkspace" "$support/TestWorkspace"

echo "second Mac home: $home"
echo "binary:          $app"
# Detached with its output closed, so a caller that pipes this script does not wait on the app.
CFFIXED_USER_HOME="$home" nohup "$app/Contents/MacOS/Maugham" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
disown
