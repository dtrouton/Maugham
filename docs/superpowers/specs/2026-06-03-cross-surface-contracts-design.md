# Cross-Surface Contracts — Design

_Date: 2026-06-03_
_Status: design approved, pending spec review_

## Problem

MaughamPhone (iOS) and the Maugham Mac app are two independent surfaces over the
same project folder. They share the `MaughamCore` SPM package, but each owns its
own UI/IO layer. Wherever a surface *reimplements* something the other also
implements — rather than sharing it — the two copies can silently drift.

Every phone↔Mac bug we have shipped is this one shape:

- **Doc-id parser drift** (fixed `phone-v0.1.1`, 2026-06-03): `AnnotationLoading.isDocId`
  + `ColdLaunchDownloader.liveEnumerateOpLogs` required `d_`+26-char-ULID, but doc
  ids are `doc-<hex>`/`scene-<hex>`. Matched zero real files → "No open annotations"
  on every project, while the Mac (which never format-validates) showed them. See
  `memory/project_phone_docid_contract_footgun.md`.
- **Divergent `MarkdownDisplayFilter` copy** that missed task anchors — fixed by
  promoting the single filter into MaughamCore.
- **Double-`d_`-prefix write** (AREA.md tripwire 3) — phone wrote to a filename the
  Mac's glob never read.
- **Fountain title-page double-render** — the phone reimplemented Fountain rendering
  and diverged.

The deepest cause is not any one parser. It is that **a contract can exist between
the two surfaces without anyone deciding it exists** — the author of the phone code
believed they were "just doing a phone thing." Documentation that says "if you are
touching a shared surface, read X" fails precisely here, because the failure mode is
*not realizing* the surface is shared.

## Goals

1. Bring **every** phone↔Mac contract under an explicit enforcement mechanism (full
   inventory, no gaps).
2. Make enforcement **action-triggered, never awareness-triggered**: the build breaks
   because of *what was written*, regardless of whether the author knew it was shared
   territory.
3. Share by default; where divergence is genuinely required (AppKit vs SwiftUI
   rendering), shrink the divergent sliver to its irreducible minimum and contract the
   seam.
4. Leave behind reusable machinery + a meta-guard so a *new* shared surface added in
   the future cannot quietly become an un-enforced contract.

## Non-goals

- Not a rewrite of either surface's rendering. Rendering divergence that is genuinely
  irreducible (drawing primitives) stays divergent.
- Not migration of any on-disk data (project convention: delete/recreate test data).
- Not a perfect automatic "you added an unenforced contract" detector — Swift cannot
  give us that. We get as close as choke-points + reach-around tripwires allow, and
  make the rest legible via the registry.

## Principles

- **Awareness is not a guard.** Any mechanism that depends on the author recognizing
  they are in shared territory is rejected as a *primary* guard.
- **Make the right way the only easy way** (choke-points), **and make the wrong way
  fail loudly with a map to the right way** (reach-around tripwires → registry).
- **Tests must not be able to lie.** Golden inputs are generated from the *real*
  minters, never hand-typed literals — a hand-typed fixture re-encodes the very
  assumption under test (this is exactly how the old doc-id test stayed green).
- **The absence of a contract is itself a recorded decision** (Tier 3), so a
  wrongly-dismissed shared contract is visible rather than invisible.

## The three-tier contract model

Every phone↔Mac touch-point is assigned exactly one tier. A touch-point with no tier
is a defect in the audit, not an allowed state.

### Tier 1 — Shared implementation
Behavior *must* be identical (pure logic). Exactly one implementation in MaughamCore;
both surfaces call it. There is no second copy to drift.

- **Enforcement:** the choke-point API is the only sanctioned implementation, plus a
  reach-around tripwire that fails the build if a surface hand-rolls it.
- **Examples:** op-log / inbox filename ↔ id parsing; directory enumeration of
  `.maugham/*`; format codecs (`JSONLAppendStore` encode/decode); anchor stripping
  (`MarkdownDisplayFilter`); `DeviceSlug`; monotonic `writtenAt`. (The last several
  already live in MaughamCore; the filename parsing does not yet.)

### Tier 2 — Contracted divergence
Surfaces genuinely cannot share code (AppKit vs SwiftUI), but must agree on every
*decision*. The decisions become a data/enum contract in MaughamCore; each surface
consumes it; one contract test runs in **both** test targets.

- **Enforcement:** the shared decision type + a `CrossSurfaceContract` test duplicated
  into both test targets (the `ScreenplayEmphasis` / `ScreenplayEmphasisContractTests`
  shape, which is the one enforcement we already have and the one surface that has not
  re-broken).
- **Rendering-depth rule (C):** for each divergent surface, extract the *decision* into
  MaughamCore (depth A) by default; escalate to a fully-decided display intermediate
  representation (depth B) only where depth A still leaves decision-logic duplicated
  across the two renderers. The audit decides per surface; B is not applied
  pre-emptively.
- **Examples:** Fountain bold/italic emphasis (exists); element classification;
  display-uppercasing rules; title-page handling; which anchors are hidden in display.

### Tier 3 — Free divergence
No cross-surface invariant exists (pure presentation: column width, fonts, animations,
platform affordances). Enforcement is *none*, **but the touch-point is explicitly
recorded as Tier 3** so the audit is provably complete and the absence of a contract is
a decision rather than an oversight.

## Enforcement primitives

### Choke-point APIs (Tier 1)
Narrow MaughamCore facades that own a shared operation, so the obvious path of least
resistance is the correct one. Concretely, a `SidecarPaths` (working name) type in
MaughamCore that owns:
- filename → docId (`docId(fromOpLogFilename:)`, the component before the first `.`,
  excluding the synthetic `__project__`),
- docId → its op-log file set,
- inbox filename construction/parsing,
- enumeration of `.maugham/ops` and `.maugham/inbox`.

`OpLogStore.opLogFileURLs` and the existing inbox helpers fold into / delegate through
this so there is a single predicate. Surfaces never hand-parse these names or paths.

### Reach-around tripwires (the teeth)
Build-failing grep tests — expand the existing `TripwirePhoneGrepTest` and add a Mac
twin (`TripwireGrepTests` in `MaughamTests`). They fire when surface code, **outside a
small sanctioned allowlist**, contains a shared-format reach-around:
- literal parsing of `.jsonl`, `.maugham/ops`, `.maugham/inbox` names,
- `hasPrefix("d_")` / fixed-length-ULID-style doc-id predicates,
- `FileManager.contentsOfDirectory` (or equivalents) on a `.maugham/` path,
- a *second* Codable decode of `Op` / `Annotation` / `InboxEntry`,
- a *second* type acting as a Fountain renderer or markdown display filter.

The failure message names the choke-point to use and links the registry. The allowlist
(the set of files that legitimately *are* the choke-points) is produced by the audit
and is itself reviewed — a too-broad grep that yields false-positive breaks is a
defect, so patterns must be specific.

### Contract-test kit (Tier 2)
A shared golden corpus + a `CrossSurfaceContract` test pattern duplicated into both
test targets. **Anti-lie rule:** the corpus is built from the real minters
(`ProjectFactory` / `ProjectStore.newId` on the Mac side; the production
`"doc-" + UUID().uuidString.prefix(8)` form where the real minter is not reachable from
the test target), never hand-typed `d_…`-style literals.

### Registry
`docs/superpowers/notes/cross-surface-contracts.md`: a table of every contract — tier,
choke-point or contract type, its test, its tripwire. It is the *destination* the
tripwire messages point at, **not** a proactive-read expectation. CLAUDE.md and both
`AREA.md`s link to it as "where a tripwire sends you," not "read this before working."

## The audit

A subagent-driven systematic sweep (`dispatching-parallel-agents`); completeness is the
point — a partial inventory recreates the "nobody realized it was shared" gap. Parallel
agents each sweep one axis of where `Maugham/` and `MaughamPhone/` independently touch
the same thing:

- **Shared on-disk formats** — `.maugham/ops`, `.maugham/inbox`, `.md`/`.fountain`
  anchors, manifest, checkpoints: who parses what; shared or reimplemented?
- **Shared semantics** — id minting/parsing, device slug, monotonic timestamps, op
  derivation, sweep/echo logic.
- **Shared derived output** — Fountain rendering, Markdown display, anchor stripping,
  annotation projection.
- **Shared write-contracts** — phone-produced artifacts the Mac must consume (ops,
  inbox rows) and vice versa.

Each finding is classified into a tier with a one-line justification. Outputs:
1. the registry's first complete population;
2. a worklist partitioned into **Tier 1 currently reimplemented** (collapse),
   **Tier 2 currently uncontracted** (add contract test), **Tier 3** (record only);
3. the tripwire **allowlist** (the sanctioned choke-point files).

**Adversarial verification:** a second agent re-checks that no surface-to-surface
touch-point was filed Tier 3 without justification — a wrongly-dismissed Tier 1 is
exactly the failure being prevented.

## Build sequence

1. **Kit first** — tripwire harness (both targets) + the `CrossSurfaceContract` test
   pattern + the real-minter golden-corpus helper + the registry skeleton. No behavior
   change; independently landable.
2. **Audit** — run the sweep; populate registry + worklist + allowlist.
3. **Tier 1 collapse** — per contract: confirm/add the MaughamCore choke-point, delete
   the surface copies, add its reach-around tripwire. The doc-id contract is the worked
   first example (choke-point logic exists post-`phone-v0.1.1`; route the surface copies
   through it and add the tripwire).
4. **Tier 2 contracting** — per contract: extract decisions to MaughamCore, add the
   dual-target contract test, applying rendering-depth rule C per surface.
   `ScreenplayEmphasis` is the template.
5. **Close the loop** — enable the full tripwire suite; point CLAUDE.md + both
   `AREA.md`s at the registry as the tripwire destination; record the milestone.

## Risks

- **Tier-2 rendering extraction is the expensive bucket.** Sequence it last, size it
  from the audit, and lean on rule C so we do not over-refactor surfaces that only need
  depth A.
- **Tripwire false positives.** Over-broad grep patterns break the build spuriously;
  patterns must be specific and the allowlist must be maintained. Treat a false positive
  as a defect to fix immediately (tighten pattern or extend allowlist with
  justification).
- **Test-target reachability.** The real doc-id minter lives in the Mac target, not
  MaughamCore; the phone test target must use the production id *form* instead. The
  contract-test kit must make this explicit so a future author does not regress to
  hand-typed literals.

## Success criteria

- A complete registry: every phone↔Mac touch-point appears with a tier.
- Zero Tier-1 contracts with more than one implementation.
- Every Tier-2 contract has a contract test passing in both test targets.
- Reaching around any Tier-1 choke-point fails the build with a message that routes to
  the registry.
- The doc-id contract is fully under the model (choke-point + tripwire + the surfaces
  delegating), as the proof case.
