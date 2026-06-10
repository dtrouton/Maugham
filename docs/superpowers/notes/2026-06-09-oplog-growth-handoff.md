# Op-log growth (ADR 0016) — implementation handoff

- **Date:** 2026-06-09
- **From:** the remote audit session that produced the 2026-06-09 audit, ADR 0016, and the spec.
- **To:** the local session implementing it.

## State of the branch

`claude/codebase-quality-audit-05nbug` is **docs-only** (no code changes):

1. `docs/superpowers/notes/2026-06-09-quality-maintainability-audit.md` — post-hardening audit + ranked punch list.
2. `docs/adr/0016-op-log-growth-without-compaction.md` + roadmap item superseded (compaction withdrawn).
3. `docs/superpowers/specs/2026-06-09-oplog-growth-design.md` — the executable spec (M0–M3, T1–T18).

**First step locally: merge this branch to `main`** before branching for
implementation, so the spec/ADR are in place on the implementation branch's
base. Docs-only → no conflict risk, no build impact.

## Read order for the implementing session

1. The spec (`2026-06-09-oplog-growth-design.md`) — it is the contract; this note only adds session-verified facts and process pointers.
2. ADR 0016 (why compaction was rejected — don't relitigate).
3. `Maugham/OpLog/AREA.md` (merge/derive contract; the area is flagged "don't refactor structurally" — all three mechanisms were designed to respect that).

## Facts verified by code-reading this session (trust these; cite-checked at HEAD `12c409f`)

- `Deriver.derive` already carries forward the last explicit `sequence` across `sequence: nil` ops (`Deriver.swift:62-78`). **M1 requires zero deriver changes.**
- `Bootstrap.run` always emits a sequence-bearing op (`Bootstrap.swift:54`) → a keyframed fresh log can never present empty-sequence-with-paragraphs → `Document.load`'s legacy `.md`-recovery branch (`Document+Load.swift:23-47`) is undisturbed. T5 pins this.
- `setFullText` already computes `sequenceChanged` (`Document.swift:398`) but it is **per-call**; bursts span many calls — hence the accumulated `_orderingDirty` on `Document` (spec §4.2). Clear it only after a *successful* sequence-bearing append (T7; failure path = the M1.1 durable re-flush).
- `flushBurstNow` is `Document.swift:578-600`; the unconditional `sequence: sequence` at `:590` is the line M1 replaces.
- Sealing crash-safety needs no recovery logic: `OpLogStore.mergeSortedDedup` collapses ops duplicated between a sealed segment and a not-yet-deleted tail. T10 just pins it.
- Keyframing **fixes a latent cross-device bug** (stale full-sequence on a text-only burst reverting another device's concurrent reorder). T4 pins the improvement so it isn't "fixed" back.
- `OpLogStore.appendFailureForTesting` (`OpLogStore.swift:36`) is the existing injection seam for T7 — don't add another.
- The conflict-twin regex (`IntegrityChecks.conflictTwins`) and `docId(fromOpLogFilename:)` both guard on the `.jsonl` suffix — the `.mzseg` extension bypasses them by construction; extend recognition **only** at the single-source helpers named in spec §5.3 (they're registered in `cross-surfaces-contracts.md`; update the registry in the same commit).

## Process (per CLAUDE.md defaults — restated so nothing gets re-asked)

- Brainstorm ✓ and spec ✓ are done. **Next artifact: the plan** under `docs/superpowers/plans/2026-06-09-oplog-growth.md`, then subagent-driven implementation.
- Model selection: M0 fixture + M1 keyframing + M2 segments all touch the Editor/OpLog seam or MaughamCore → **opus** for implementers; **haiku** reviewers.
- M2 changes MaughamCore → **test BOTH schemes** (`Maugham` and `MaughamPhone`); the phone consumes segment reading through the shared helpers and `TripwirePhoneGrepTest` gains the no-hand-rolled-`.mzseg` pattern.
- Tests crossing the `.md` ↔ op-log boundary use 4-char alphabet-restricted paragraph IDs (tripwire 8). The M0 fixture must drive the **production `Document` API** (spec §3) — not hand-built `[Op]` arrays.
- CryptoKit + Compression imports in MaughamCore are fine (Apple system frameworks). After any `Package.swift` edit, run `./gen.sh`. Clean DerivedData after new public types in MaughamCore if phantom link errors appear.
- Milestone gates are in spec §8 — M1 doesn't start until the M0 baseline table is recorded; M3 ships only if the post-M2 load budget is violated.
- Open questions (spec §9: keyframe floor, seal threshold, LZFSE-vs-LZMA) are **M0 decisions, made from the baseline data** — record them in the milestone note, don't pre-decide.

## Keep separate (do NOT fold into the growth milestones)

The audit's punch list items 1–5 are independent small fixes — good as a quick
standalone pass before or alongside M0, in separate commits:
quarantine-file dedup; `BackupCoordinator.swift:43` integrity-throws gate (+
test); updater `python3` guard; delete `ScreenplayLayoutManager.swift` (+ stale
`Editor/AREA.md:16` bullet); ci.yml Xcode-pin comment / `timeout-minutes` /
caching. Item 10 (live-tail framing) is explicitly **out of scope** of M2
(spec §2) — don't let it creep in.

## Manual smoke after M2 (user-run)

Draft in a screenplay project past the seal threshold → ⌘Q → relaunch → text
intact → History Rewind scrubs back through sealed history → Restore from a
point inside a sealed segment's range. Plus the standard CLAUDE.md smoke.
