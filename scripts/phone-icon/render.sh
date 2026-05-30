#!/usr/bin/env bash
# Rasterize the MaughamPhone app-icon SVGs into the asset catalog.
#
#   ./scripts/phone-icon/render.sh
#
# Why this exists: the Mac .appiconset PNGs carry an alpha channel + rounded
# corners + padding (the macOS icon-grid template), which the App Store rejects for
# iOS marketing icons. These two SVGs are bespoke iOS art (full-bleed, opaque); we
# rasterize with QuickLook (the only SVG renderer on the box — no ImageMagick /
# rsvg / Playwright) and strip the alpha channel via a JPEG round-trip, because both
# canvas and screenshot PNGs keep an (all-opaque) alpha channel that ASC still flags.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$DIR/../../MaughamPhone/Assets.xcassets"

render() {
  local svg="$1" dest="$2"
  local tmp; tmp="$(mktemp -d)"
  qlmanage -t -s 1024 -o "$tmp" "$svg" >/dev/null 2>&1 || true
  local raw="$tmp/$(basename "$svg").png"
  [ -f "$raw" ] || { echo "ERROR: qlmanage produced no PNG for $svg"; exit 1; }
  # Force exact 1024x1024 (qlmanage's -s is a max bound).
  sips -z 1024 1024 "$raw" >/dev/null
  # Strip the alpha channel: PNG -> JPEG (no alpha) -> PNG.
  sips -s format jpeg -s formatOptions best "$raw" --out "$tmp/flat.jpg" >/dev/null
  sips -s format png "$tmp/flat.jpg" --out "$dest" >/dev/null
  # Verify: opaque + exactly 1024x1024, else fail loudly.
  local a w h
  a=$(sips -g hasAlpha "$dest" | awk '/hasAlpha/{print $2}')
  w=$(sips -g pixelWidth "$dest" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$dest" | awk '/pixelHeight/{print $2}')
  [ "$a" = "no" ] && [ "$w" = "1024" ] && [ "$h" = "1024" ] \
    || { echo "ERROR: bad output $dest (hasAlpha=$a ${w}x${h})"; exit 1; }
  rm -rf "$tmp"
  echo "rendered $dest (opaque ${w}x${h})"
}

mkdir -p "$ASSETS/AppIcon.appiconset" "$ASSETS/AppIconDev.appiconset"
render "$DIR/icon-stable.svg" "$ASSETS/AppIcon.appiconset/icon_1024.png"
render "$DIR/icon-dev.svg"    "$ASSETS/AppIconDev.appiconset/icon_1024.png"
echo "OK"
