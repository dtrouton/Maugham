# MaughamPhone app icon — source + render

The committed app icons live in `MaughamPhone/Assets.xcassets/` and are wired
per-config in `project.yml` (`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` for
Release / `AppIconDev` for Debug). This folder holds the **editable source** and a
deterministic re-render script — the PNGs in the asset catalog are committed (CI
builds from them; it does **not** re-render).

## Files

- `icon-stable.svg` — the shipped icon. The `iconA-release-v3` direction: a serif
  **M** (Iowan Old Style) with a rust pilcrow **¶** tucked at the right shoulder, on
  a warm parchment gradient. The ¶ is the brand motif — paragraph IDs are the op
  log's join key.
- `icon-dev.svg` — same mark/geometry, inverted to deep ink (cream M, brightened ¶)
  so the dev build is distinguishable on the home screen (mirrors the Mac's
  AppIcon / AppIconDev split).
- `render.sh` — rasterizes both SVGs into the asset catalog.

## Why bespoke (not the Mac icon)

The Mac `.appiconset` PNGs carry an **alpha channel** plus rounded corners and
transparent padding (the macOS icon-grid template). The App Store **rejects** iOS
marketing icons with an alpha channel, and iOS applies its own corner mask to a
full-bleed square — so the Mac art can't be reused verbatim.

## Re-rendering

```sh
./scripts/phone-icon/render.sh
```

No ImageMagick / rsvg / Playwright on the box — only **QuickLook** (`qlmanage`) and
`sips`. The script rasterizes each SVG with `qlmanage -t -s 1024`, forces exactly
1024×1024, then **strips the alpha channel** via a PNG→JPEG→PNG round-trip (both
QuickLook and canvas PNGs keep an all-opaque alpha channel that App Store Connect
still flags). It fails loudly if any output isn't opaque 1024×1024.

## Tweaking

Edit the colours / glyph sizes in the SVGs and re-run `render.sh`. Both are plain
SVG using a macOS-installed serif (Iowan Old Style → Palatino → Georgia), so they
preview in any browser. Earlier exploration (the M+¶ vs. compound directions) is in
`build/icon-mockups/` (gitignored).
