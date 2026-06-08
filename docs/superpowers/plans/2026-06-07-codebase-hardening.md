# Plan — Codebase Hardening (post-2026-06-07 audit)

Derived from `docs/superpowers/notes/2026-06-07-codebase-audit.md` (full audit +
two addenda + 8 sweeps). Finding ids below (0.x, 1.x, C-1, etc.) reference that
note. **Thesis driving the ordering:** the confirmed bugs cluster where the code
gets no feedback — feedback-blind seams (cross-device merge, close-time flush,
future schema changes) and tests that pin or certify the current behavior. So
**Milestone 0 installs the feedback loop first**; the data fixes land behind it,
verified, rather than blind.

Convention per CLAUDE.md: subagent-driven; `haiku` mechanical, `sonnet`/`opus`
substantive (opus when in doubt, especially anything touching the OpLog/Editor
seam). Each task names a model. Manual smoke stays the user's; don't claim a
fix works until confirmed.

---

## What we deliberately leave alone (verified-good — do NOT "fix")

Recorded so a future pass doesn't churn them:
- **MCP→store concurrency** (sweep 4): correctly actor-hopped, no write race. An `actor` redesign would be a regression.
- **Auto-updater verification chain** (sweep 5): codesign+notarize+self-anchored Team-ID, no TOCTOU, no downgrade/dry-run install. Sound. (Only the swap *atomicity* needs a one-liner — task 4.7.)
- **Anchor/Unicode safety** (sweep 8): grapheme-safe by construction; the join can't de-sync on NFC/NFD. Don't refactor anchor emission.
- **The op-log substrate structure** + `EchoState`/`SweepReason`/`SynthesisSource` typed seams + `JSONLAppendStore<T>` generic + backup/Merkle system: clean. Extend, don't restructure.
- The EditorHost single-binding contract (sweep / editor audit): safe-by-construction. Leave it; just add the read-only comment (task 4.8).

---

## Milestone 0 — Install the feedback loop (do first; unblocks everything)

The single highest-leverage move. Nothing in M1–M2 should be merged until M0's
harness + CI are green-on-correct.

- **0.1 — `ci.yml` test gate.** New workflow: on push + PR to `main` and
  `claude/**` branches, run BOTH schemes' suites
  (`xcodebuild ... -scheme Maugham test` and `... -scheme MaughamPhone ...`)
  on a **pinned** Xcode (not `latest-stable` — a predictable pin so an Xcode
  bump can't surprise-break the gate). Add a second job that builds with
  `SWIFT_STRICT_CONCURRENCY=complete` as **warnings** (not errors) and prints
  the count, to surface the lurking concurrency warnings (sweep 4 predicts they
  cluster in `Maugham/Editor/` AppKit-delegate/`Sendable`-closure code, not the
  stores). Model: **sonnet**. _Finding: CI/infra gap._
- **0.2 — Rewrite the three tests that certify bugs** (prerequisite to M1/M2 —
  these currently make the correct fix look like a regression):
  - `CrossMacMergeTests.swift:30-39` — give the duplicate-opId ops *different*
    text; assert a non-byte-equal opId collision is surfaced/quarantined (or at
    minimum a content-deterministic survivor), not silent first-wins. (0.4)
  - `OpLogStorePartitioningTests.swift:63` — give the cross-file `op-a` rows
    *different* `next`; assert which wins, deterministically, through the real
    `OpLogStore.load` glob+merge.
  - `DeriverTests.swift:51-60` — stop blessing "applies in argument order";
    assert the deriver sorts by opId itself (or add a guard test that every
    production call site sorts). Model: **opus** (these encode the resolution
    contract M2 will change). _Findings: 0.4, sweep-3._
- **0.3 — Adversarial cross-device merge/reconcile harness.** New
  `MaughamTests/OpLog/CrossDeviceIntegrationTests` driving the *production*
  load/merge/derive/reconcile path with: skewed device clocks editing the same
  paragraph (0.2); divergent-content opId collision (0.4); external `.md`
  deletion of an anchored paragraph (Reconciler can't see deletions today —
  sweep 3); drastic-rewrite id-reattach where the bigram tier could mis-pair
  (O1/RenderFilter). These tests **will fail initially** — they define done for
  M1/M2. Model: **opus**. _Findings: 0.2, 0.4, Reconciler-deletion, O1._
- **0.4 — Tier-1 doc corrections** (cheap; the docs are wrong *now*):
  CLAUDE.md tripwire 19 reworded ("recurrence-tripper, not a fence; the real net
  is the round-trip integration tests"); the "op log is source of truth"
  invariant amended with the reconcile/`.md`-load-bearing honesty note. Model:
  **haiku**. _Findings: grep-tripwire over-claim; reconcile honesty._

**M0 acceptance:** CI runs both suites on PR; 0.2 tests assert correctness and
currently fail against unfixed code; 0.3 harness exists and red.

---

## Milestone 1 — Tier-0 silent-manuscript-loss fixes (behind the M0 harness)

Each lands with the matching M0 test going green. Not multi-device-design-gated.

- **1.1 — `Document.close()` must not swallow the burst flush.** `Document.swift:593`
  `try? await flushBurstNow()` → propagate (or log+retry+quarantine). `close()`
  runs on quit AND every FS-surgery; this drops the final edits on a write
  error. Also de-`try?` the secondary op-appends: `Document+Tasks.swift:199`,
  `ProjectStore+Tasks.swift:83`, `InboxStore.swift:107`,
  `PartialRestorePicker.swift:92`; and the conflict-backup write
  `DocumentStore.swift:649`. Add tests that a failing append surfaces. Model:
  **opus**. _Finding: sweep-7 (Tier-0)._
- **1.2 — Wiki-rename through the op log.** `ProjectStore+Structure.swift:394`
  `propagateWikiLinkRename` raw-writes manuscripts. Reroute via the
  `ProjectStore+Search.swift` `replaceInManuscript` pattern (open→`setFullText`;
  closed→`Document.load`→`setFullText`→`close()`). Test: open doc B linking
  `[[A]]`, rename A, assert B's op log carries the rewrite and live B isn't
  clobbered. Model: **opus**. _Finding: 0.1 (live bug)._
- **1.3 — `.pending.jsonl` device-partitioning.** `PendingBuffer.swift:69` →
  slug-partition (or relocate outside `.maugham/ops/` so it can't match the
  op-log glob). Verify `MaughamSidecarPath` routing + add a tripwire test.
  Model: **opus**. _Finding: 0.3 (tripwire-17 violation)._
- **1.4 — `resolveDocId` deterministic hash.** `Document+Load.swift:291,300`
  `hashValue` → `DeviceSlug.fnv1a32Hex`-style stable hash; add a tripwire-grep
  forbidding `hashValue` in id/path construction. Test: same input → same docId
  across "launches". Model: **sonnet**. _Finding: 0.5._
- **1.5 — Torn op-append detection.** Frame JSONL lines so a truncated final
  line is unambiguously detectable (length/checksum), or at minimum add a test
  that plants a truncated line and asserts it quarantines, never enters the op
  stream. Wire `IntegrityQuarantine` into the normal load path
  (`loadDiagnosed()` at the `Document+Load` site) so drops get a forensic
  record. Model: **opus**. _Findings: 0.6, sweep-6 (quarantine not on load path)._
- **1.6 — `movePiece`/`renamePiece` flush-before-move.**
  `ProjectStore+CollectionPieces.swift:609-640,713-721` close the manuscript
  Document but not piece-scoped research-note saves → phantom file. Add
  `flushPendingSave()` before the folder move (or fold into the M3 typed mover).
  Model: **sonnet**. _Finding: 1.3._

**M1 acceptance:** the non-LWW M0/0.3 cases (deletion ingest, torn-append,
pending-partition) go green; wiki-rename + close-flush tests pass.

---

## Milestone 2 — Cross-device conflict resolution (brainstorm → spec → implement)

**Design-significant — changes on-disk resolution semantics. Gets its own
brainstorm + spec before code.** Do not patch blindly.

- **2.1 — Brainstorm + spec.** Decide between: **(a, recommended)** surface the
  conflict — detect concurrent same-paragraph writes from different `device`s
  via the existing `prior` snapshots and route to the conflict UI (reuses the
  "writer disposes" membrane; the collaborator-layer roadmap item needs this
  anyway); **(b)** hybrid logical clock (HLC/Lamport) so "newer" is skew-proof
  but still auto-LWW; **(c)** document + defer if same-paragraph multi-device
  editing isn't a near-term scenario. Resolve `Op.at`'s role (wire into
  resolution, or mark display-only). Spec to `docs/superpowers/specs/`.
- **2.2 — Implement** against the 0.3 skewed-clock + collision cases. Update
  `Maugham/OpLog/AREA.md` (merge resolution; `Op.at` semantics). Model: **opus**.
  _Findings: 0.2, 0.4._

**M2 acceptance:** the 0.3 skewed-clock + divergent-collision cases go green per
the chosen design; no silent drop of the newer edit.

---

## Milestone 3 — Enforce-by-construction + schema evolution

Turn the two "convention not construction" generators into types, and close the
cross-version landmine before the next schema change ships.

- **3.1 — One typed user-content mover.** A `DocumentStore.relocate(plan:)` /
  `.trash(relativePath:)` that closes+`unregister`s open Documents AND
  `flushPendingSave()`s for every affected path *internally*, and is the only
  legal way to move/delete a user-editable path. Route `movePiece`/`renamePiece`/
  `moveResearchItem`/wiki-rename's file ops through it; kill the bespoke
  `fm.moveItem` movers. Add a tripwire-grep forbidding raw `FileManager`/`.write(to:`
  on `manuscript/`/`pieces/*/` outside `Document`. Dissolves 0.1's close-gap +
  1.3/1.6 + future recurrences. Update `Maugham/Stores/AREA.md`. Model: **opus**.
  _Finding: tripwire-14 enforce-by-construction._
- **3.2 — Manifest `EchoState`.** `writeManifest` stamps a content signature
  (hash, not truncated timestamp) inside the coordinate block; `handleManifestChanged`
  skips on self-write. Fixes the conflict-archive-on-every-edit (1.2) and the
  equal-whole-second silent-accept (O2). Mirror the `Document.lastDiskEcho`
  factory pattern. Test: own save produces NO `conflicts/manifest-*.json`.
  Model: **opus**. _Findings: 1.2, O2._
- **3.3 — Cross-version schema hardening + ADR.**
  - Add `unknown` fallback cases (or safe-default custom `init(from:)`) to every
    disk-decoded enum: `OpKind`, `SynthesisSource`, `ProjectType`,
    `StructureItem.ItemType`, `ResearchItem.AssetKind`, `PieceKind`,
    `InboxEntry.Kind`/`TranscriptionState`/`Status`, `Checkpoint.LabelSource`,
    `PublishConfig.Format`/`StartOn`. The exhaustive switches (`Deriver.appliesToManuscript`,
    manifest consumers) then turn a future unknown case into a **compile error**
    instead of a silent quarantine / unopenable project.
  - `TypographySettings` custom decoder (`decodeIfPresent`+defaults — 8
    non-optional fields are a landmine for the next add).
  - `schemaVersion` guard on `ProjectManifest` load (explicit "requires a newer
    Maugham" per the `UIState` template), not silent misparse.
  - Write **ADR 0014 — persisted-schema evolution** codifying the rules above +
    naming `UIState` as the template. Model: **opus** (code) + the ADR.
  _Findings: sweep-6 (manifest-unopenable, op-line silent-drop, schemaVersion
  unchecked)._
- **3.4 — CheckpointCapture mirror gap.** Append through the live Document (or
  pre-seed its `_opLogMirror`) so ⌘S doesn't trigger a redundant re-derive.
  Model: **sonnet**. _Finding: sweep-2._

**M3 acceptance:** a planted future enum case fails to *compile* (not at
runtime); manifest self-save archives nothing; the typed mover is the only
FS-surgery path (tripwire-grep green).

---

## Milestone 4 — Bounded correctness, perf, cosmetic, remaining docs

Opportunistic; each is small and independent. Good for haiku/sonnet.

- **4.1 — SmartTypography selection guard.** `transform` returns the full
  replacement range (or consume-count) so the coordinator can't assume a caret
  insert; gate on `replacementRange.length == 0`. Add the selection-replace test
  + the real ellipsis digit-guard test (`SmartTypographyTests:49` tests the
  wrong input). Model: **sonnet**. _Findings: 1.1-editor, C1/C2-editor._
- **4.2 — Publish input validation.** `LaTeXSafeFilename` allowlist for
  `styleFile` (at `set_piece_style` write + `LaTeXBodyEmitter` emit); `..`/leading-`/`
  + embedded-`/` checks on `outputs.directory` and `filenameTemplate` in
  `PublishConfigValidator` and on `republish`. Model: **sonnet**. _Findings:
  C-1, C-2, O-1, O-7 (MCP/publish)._
- **4.3 — `add_note` flush + MCP `send()` loop.** `AddNoteTool.swift:51` flush
  before body write; loop `send()` until drained in `MCPServer.swift:171`
  (mirror the bridge's `writeLine`). Model: **sonnet**. _Findings: C-4, C-3._
- **4.4 — Updater atomic swap.** Replace `rm -rf`+`mv` with an atomic same-volume
  exchange (`FileManager.replaceItemAt` / `renameatx_np(RENAME_SWAP)`); the
  `.inflight` sibling is already same-volume. Add `Maugham/Updates/AREA.md` (new)
  capturing the verify-chain + atomic-swap invariants; reconcile the spec's
  "atomic rename" claim with reality. Model: **sonnet**. _Finding: sweep-5._
- **4.5 — Trash restore nesting.** Honor `originalParentId`/`originalIndex`;
  validate restored descendant paths against disk. Model: **sonnet**. _Finding: 1.8._
- **4.6 — `paragraphId(at:)` fix.** Align `Document.swift:212,216` to its
  correct sibling (`NSString.length` on stripped text) so it actually mirrors
  `TaskAnchorAlignment.cursorParagraph`. Test with an emoji/CJK + task-anchored
  prior paragraph. Model: **sonnet**. _Finding: sweep-8._
- **4.7 — Screenplay perf: collapse the triple-parse.** Thread one parsed
  `FountainScript` through `retokenizeAndStyle` → `applyTypography` (it already
  takes `tokens`; add an optional parsed-script param). O(N²)→O(N) per keystroke
  on large scripts. Model: **opus** (Editor seam). _Finding: P1-editor._
- **4.8 — Net cleanups + remaining tests/docs.** RenderFilter bigram
  margin-over-second-best rule + the missing tier-2/3 disagreement test;
  CommonMark `InlineEmphasisScanner` parity edge cases (unclosed/spaced/intraword/
  `****`/escaped/mixed); grep-tripwire meta-test (plant an offender, assert it
  fires); EditorHost `:136` read-only-by-contract comment; the stray
  `"com.maugham"`/`"Maugham"` identity literals → `BuildVariant`;
  `OpLog/AREA.md` amendments (bigram margin, `Op.at` display-only). Model:
  **sonnet**/**haiku** mix. _Findings: O1, sweep-3 (#13/#14), tripwire-13, A1-editor._

---

## Sequencing & parallelism

- **M0 is the gate.** Land 0.1 (CI) + 0.2 (test rewrites) + 0.3 (harness) before
  merging any M1/M2 data fix, so every fix lands green-on-correct.
- **M1 tasks are largely independent** and parallelizable across subagents once
  the harness exists; 1.1 (close-flush) and 1.2 (wiki-rename) are the two to do
  first (live silent-loss).
- **M2 waits on a brainstorm decision** (2.1) — needs the user's read on whether
  same-paragraph multi-device editing is near-term (→ design a, surface conflict)
  or deferrable (→ document + ship HLC later). Flag for the user at M2 start.
- **M3.1 (typed mover)** should land before or with M1.6 to avoid doing the
  flush-fix twice; **M3.3 (schema)** is independent and can run in parallel.
- **M4** is all opportunistic; fold each task into whichever milestone touches
  the same file.

## Doc strategy — agent-first, lean context

Guiding principle: **the docs exist to help an agent working in this repo, and
bloated always-loaded context hurts more than it helps.** Three rules:

1. **Enforcement > prose.** The best doc is a compile error or a failing test.
   Every tripwire M3 converts to a type/test (`relocate(plan:)`, the schema
   `unknown` cases, the manifest `EchoState`, the tripwire-greps) lets its
   CLAUDE.md entry **shrink to a one-line pointer** ("enforced by X — see Y").
   The doc work and the hardening work are the same effort: as a rule becomes
   structural, its cautionary essay becomes a pointer. **Docs shrink as we
   harden** — track CLAUDE.md size going *down* across M1–M3 as a signal.
2. **CLAUDE.md is a router, not an encyclopedia.** Always-loaded root context is
   borrowed from the agent's attention to the corruption-class invariants.
   Target ~38KB → ~12–15KB: keep first-five-minutes routing, hard invariants,
   default workflow, "questions you don't need to ask", and a **terse tripwire
   index** (one-line rule + where-it's-enforced/read-more). Relocate, never drop.
3. **Push detail to the nearest AREA.md — just-in-time.** Detail is paid for
   only when an agent is actually in that directory. Per-area pointers in root
   become one line deferring to AREA.md.

### Doc tasks (folded into milestones; "describe what ships" per CLAUDE.md)
- **0.4** — Tier-1 corrections (docs wrong *now*): tripwire-19 reword,
  op-log-source-of-truth honesty note.
- **D1 (parallel, sonnet)** — **CLAUDE.md slim-down**: move the Releases recipe
  → new `docs/RELEASING.md`; move phone bundle-id/Phase-G forensics →
  `MaughamPhone/AREA.md`; compress the 19 tripwire paragraphs → an index
  (rule + enforcement pointer), with the post-mortems left in the `memory/`
  files they cite; compress per-area pointers to one line each. **No rule
  dropped** — relocate + compress only; diff reviewed against the current file
  to prove nothing load-bearing was lost.
- **3.3** — ADR 0014 (persisted-schema evolution), `UIState` named as template.
- **3.1** — `Stores/AREA.md`: the typed `relocate(plan:)` mover as *the* way to
  move user content (replaces the prose tripwire-14 description, now enforced).
- **4.4** — new `Maugham/Updates/AREA.md`: verify-chain + atomic-swap invariants.
- **2.2 / 4.8** — `OpLog/AREA.md`: merge resolution + `Op.at` semantics; bigram
  margin rule. Each replaces a "cleanup planned" hand-wave with a stated (and,
  where M-tasks land them, enforced) contract.

As each tripwire becomes enforced, its root-file entry is cut to a pointer in
the **same** PR — so the index stays honest and the file keeps shrinking.
