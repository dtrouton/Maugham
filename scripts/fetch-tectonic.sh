#!/usr/bin/env bash
# Fetches the tectonic binary from GitHub releases into Maugham/Resources/bin/.
# Idempotent — does nothing if the binary at $DEST_BIN already matches $EXPECTED_SHA256.

set -euo pipefail

VERSION="0.15.0"
EXPECTED_SHA256="7b8efd258bf04fcd4d200e3e64faa47abc82671285a35c3af2018d2f03ecc890"
PLATFORM="aarch64-apple-darwin"

DEST_DIR="Maugham/Resources/bin"
DEST_BIN="$DEST_DIR/tectonic"

mkdir -p "$DEST_DIR"

if [ -f "$DEST_BIN" ]; then
  actual=$(shasum -a 256 "$DEST_BIN" | awk '{print $1}')
  if [ "$actual" = "$EXPECTED_SHA256" ]; then
    echo "tectonic $VERSION already present"
    exit 0
  fi
  echo "removing stale tectonic binary (sha256 mismatch: $actual vs $EXPECTED_SHA256)"
  rm "$DEST_BIN"
fi

URL="https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40${VERSION}/tectonic-${VERSION}-${PLATFORM}.tar.gz"
echo "Downloading $URL"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fL "$URL" -o "$TMP/tectonic.tar.gz"
tar -xzf "$TMP/tectonic.tar.gz" -C "$TMP"
mv "$TMP/tectonic" "$DEST_BIN"
chmod +x "$DEST_BIN"

actual=$(shasum -a 256 "$DEST_BIN" | awk '{print $1}')
if [ "$EXPECTED_SHA256" != "REPLACE_WITH_RELEASE_SHA256" ] && [ "$actual" != "$EXPECTED_SHA256" ]; then
  echo "SHA mismatch: expected $EXPECTED_SHA256, got $actual"
  exit 1
fi

echo "Installed tectonic $VERSION at $DEST_BIN"
echo "SHA-256 (pin this into the script): $actual"
