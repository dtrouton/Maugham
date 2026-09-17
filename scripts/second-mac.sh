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

home="$HOME/Library/Application Support/Maugham Dev/SecondMac-home"
app=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Maugham-*/Build/Products/Debug/Maugham.app | head -1)

[[ "${1:-}" == "--reset" ]] && rm -rf "$home"
mkdir -p "$home/Library/Application Support"

echo "second Mac home: $home"
echo "binary:          $app"
CFFIXED_USER_HOME="$home" "$app/Contents/MacOS/Maugham" -ApplePersistenceIgnoreState YES &
disown
