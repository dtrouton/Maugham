# Edition-aware Publication identity

**Date:** 2026-07-23
**Source:** Denver's v0.25.0 acceptance run of the Playlist editions. The new version-collision guard is correct hardening, but it exposed that a language edition has no first-class relationship to its source publication: shipping v1.0/en + v1.0/es required resetting `next_version` between compiles and smuggling the edition into the version string (`1.0-es`), conflating *what revision of the text* with *which language it's rendered in*.

## Design

**Publication identity becomes `(version, language, format)`.**
- The pre-compile collision guard refuses only an exact `(version, language, format)` match — `1.0/en/pdf`, `1.0/es/pdf`, and `1.0/es/epub` coexist as one family. `language == nil` is the source edition. (Format joins the key so an edition pair can ship both formats at one version; for source compiles this is strictly weaker than the old version-only guard and permits deliberately completing a family at a manually-set version.)
- Republished records remain exempt as today (they share a version deliberately, marked `republishedFrom`).

**`compile` with `language` gains optional `version`.**
- `version` + `language`: compile the edition at that existing source version. Validates a source-language publication (`language == nil`) exists at `version`; refuses loudly otherwise ("no source vX to render in <lang>"). The minted record carries `version` = the param.
- `version` without `language`: refused — source versions come from `next_version`.
- `language` WITHOUT `version` (behavior change from v0.25.0): targets the **latest source publication's version** (most recent `compiledAt` with `language == nil`); loud error when no source publication exists ("compile the source edition first or pass version"). An edition is a rendering *of* a source version — it no longer mints its own.
- **`next_version` auto-bumps only on source-language compiles.** Language compiles never touch it.
- `dry_run` accepts the same `version` param with identical validation, mutating nothing.

**`list_publications`** gains a `language` filter (exact tag; the sentinel `"source"` selects `language == nil` rows) and every row surfaces its `language`. "What shipped as 1.0" answers as a family.

**`read_publication_page`** gains optional `language` to disambiguate version-addressed lookups now that versions are shared across a family (publication_id remains the unique key).

**F7 residue — separator cleanup.** `{language}` in `filename_template` expands empty for the source edition but leaves its separator dangling (`Playlist-v1.0-.pdf`). When the expansion is empty, one immediately-preceding separator (`-`/`_`/`.`) is dropped, so a single template `{title}-v{version}-{language}.{ext}` yields `Playlist-v1.0.pdf` and `Playlist-v1.0-es.pdf`. (The token + auto-suffix-when-absent shipped in v0.24.0; this completes the spec'd "including any separator cleanup".)

**Docs:** the publishing guide's edition workflow drops the "set next_version between compiles" dance in favor of the pinned-version flow; translation-pass skill notes the edition-pair model.

## Out of scope
Personalized per-copy editions (this identity scheme is deliberately the substrate: per-copy = another axis on the same content version). Republish UX changes beyond what the identity gives for free.

## Acceptance
From a project with a source publication at v1.0: `compile language:es` (no version) mints `1.0/es` as a sibling, `next_version` untouched; `compile language:es version:1.0 format:epub` completes the family; a second `1.0/es/pdf` refuses; `list_publications language:es` and `language:"source"` slice the family; one filename template renders both editions' names cleanly.
