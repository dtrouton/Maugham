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
set -euo pipefail

# SHORT on purpose: the MCP socket lives under it and a Unix socket path is
# capped at 104 bytes; a home under Application Support silently truncated it.
home="$HOME/.maugham-second-mac"
app=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Maugham-*/Build/Products/Debug/Maugham.app | head -1)

[[ "${1:-}" == "--reset" ]] && rm -rf "$home"
support="$home/Library/Application Support/Maugham Dev"
mkdir -p "$support"
# Share the dev TestWorkspace, so a test project one Mac made can be opened by
# name on the other (`test_open_project`).
ln -sfn "$HOME/Library/Application Support/Maugham Dev/TestWorkspace" "$support/TestWorkspace"

echo "second Mac home: $home"
echo "binary:          $app"
CFFIXED_USER_HOME="$home" "$app/Contents/MacOS/Maugham" -ApplePersistenceIgnoreState YES &
disown
