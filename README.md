# Maugham

A focus text editor for serious creative writing on macOS.

See `docs/superpowers/specs/2026-05-07-maugham-master-design.md` for the architectural spec.
See `docs/superpowers/plans/` for milestone implementation plans.

## Build

Requires macOS 14+, Xcode 15+, and `xcodegen`:

    brew install xcodegen

Generate the Xcode project, then build:

    ./gen.sh
    open Maugham.xcodeproj

In Xcode: ⌘R to run, ⌘U to test.

## Layout

- `Maugham/` — main app target source
- `MaughamTests/` — XCTest target
- `project.yml` — xcodegen project description; edit this, not `Maugham.xcodeproj`
- `docs/superpowers/specs/` — architectural design documents
- `docs/superpowers/plans/` — milestone implementation plans
