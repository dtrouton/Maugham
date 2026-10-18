# Foundations Plan 6: Splitting OpLogStore — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift` (3,180 lines, one `@MainActor final class` with 7 concerns) into focused Core types. An agent changing how files are named, how history is classified or how a seal is written should read one concern of about 300–500 lines, not 3,180.

**Architecture:**
- Two-thirds of `OpLogStore`'s functions are `nonisolated static`. They are pure over `(projectURL, bytes, TrustTable?, OpLogDeviceState?)` and use the class only as a namespace, so they move into caseless-enum namespaces: `OpLogFiles`, `StreamCensus`, `StreamPositions`, `OpLogClassifier`.
- The permit builder becomes `LocalWritePermitBuilder`.
- The stateful core (append, chain seal, segment seal) stays on `OpLogStore`, or moves into a `SegmentSealer` it owns.
- `OpLogStore` keeps a THIN forwarding surface for every public or internal entry point it has today, so the 72 caller files do not change in this plan.

**Tech Stack:** Swift 5.10, MaughamCore SPM package, XCTest.

**Spec:** `docs/superpowers/notes/2026-10-17-foundations-audit.md`, specifically §3 B2 and reviewer B's map of OpLogStore's concerns with line ranges (§3, and the B report quoted in §2/§3). This is plan "OpLogStore split" in §4; the docs plan inserted ahead of it on 2026-10-18 makes it plan 6.

## Global Constraints

- **Behaviour is byte-identical.** This is a MOVE: function bodies move verbatim, apart from `Self.`/type qualifiers.
  - Verification, chaining, sealing, rotation, classification, partitioning, marks and the census of missing history must produce identical results.
  - Tripwire 17 (seal rules: never seal a legacy or foreign file) holds unchanged.
- **Census allow-lists follow the code.** Plan 2 made type keys PER DECLARATION: a hit is allowed by `type:X` only inside a declaration of `X`. Code that moves from `OpLogStore` into `OpLogClassifier` therefore leaves `type:OpLogStore`. Each task retargets every affected key to the new type in the same commit and keeps its planted control. Affected censuses include:
  - tripwire 39 (`trustClosureAllowedSpellings` + `typeAllowanceBounds`);
  - tripwire 45 (`partitionCallSites`);
  - tripwire 46 (`localWritePermitAllowed`);
  - tripwire 49 (`narrowingAllowed`);
  - tripwire 50 (`countedLists`);
  - `PersonKeyCensusTests` (`credentialsVerify`).

  Run `TripwireGrepTests` and `PersonKeyCensusTests` fully after every task.
- **`trustOnThisActor` stays synchronous.** A suspension point added inside `Document.load` reds three tests (`OpLogStore.swift:~194-212`).
- **Never introduce a second opinion.** Each moved concern has ONE home. A forwarder on `OpLogStore` calls the new home; it never re-implements anything.
- **Core changes are tested against both apps.** Run `./scripts/test.sh core`, `./scripts/test.sh` (fast) and `./scripts/test.sh phone` after each task. Never use a bare `swift test` or a raw `xcodebuild test`. Use `pgrep -x`.
- **Comments are contract plus pointer** (as in plan 4). Shrink each moved block's history narration as it moves. Never drop a rule sentence, a test citation or a tripwire number.
- **Do not edit `CLAUDE.md`, `docs/tripwires.md` or any `AREA.md`.** The OpLog AREA and the Core AREA get their sweep at merge.
- **Branch:** `claude/foundations-plan6-oplogstore-split`, off plan 4's head 8bc54c42. Worktree `/Users/denver/src/Maugham-plan6`.

## Review Focus

1. **A moved function that silently changes behaviour,** for example a `Self.` that now resolves to a different overload. *Pinned by:* the existing OpLog, Permit, Registry and Chain suites, plus a whitespace-insensitive diff of every moved body in each task's report.
2. **A census allowance lost or wrongly widened when code changes type.** *Pinned by:* per-declaration type keys and each census's planted control. Each task lists every key it retargets.
3. **Two homes for one concern,** where a forwarder grows logic. *Pinned by:* reviewers checking that each forwarder is one line.
4. **The phone breaks on a Core API change.** *Pinned by:* `./scripts/test.sh phone` after every task.
5. **A suspension point creeps into `Document.load`.** *Pinned by:* the existing tests that red on it.

---

### Task 1: `OpLogFiles` — filenames and globs

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/OpLogFiles.swift`
- Modify: `OpLogStore.swift` (the "Glob helpers" section, `:~2960-3097`)

**Contract:**
- Create `public enum OpLogFiles`.
- Move into it every static in the glob-helpers section:
  - `opLogFileURL`
  - `opLogFileURLs`
  - `segmentFileURL`
  - `segmentIndex`
  - the device-slug-taking builders
  - any other function in that section
- `OpLogStore` keeps one-line forwarders with the same signatures and access levels, e.g. `public static func opLogFileURLs(...) -> ... { OpLogFiles.opLogFileURLs(...) }`.
- Tripwire 24 (`DeviceSlug` at the filename point only) is compiler-enforced and still holds.
- Run `./gen.sh` (new Core file), then the three gates.

Commit: `refactor(core): OpLogFiles owns the op log's file names and globs; OpLogStore forwards`

### Task 2: `StreamCensus` — the history this book is missing

**Files:**
- Create: `StreamCensus.swift`
- Modify: `OpLogStore.swift` (the "History this book is missing" section, `:~1855-2092`, including `truncatedStreams`, `lostHistory`, `absentStreams` and `unreadableName`)

**Contract:**
- Create `public enum StreamCensus` holding those statics.
- Leave forwarders on `OpLogStore`.
- Tripwire 50's `countedLists` names `absentStreams`, `acknowledgedLosses` and `expectedStreams` sites by file or type. Retarget the `OpLogStore` entries to `type:StreamCensus` where the code moved, and keep the counts and controls.

Commit: `refactor(core): StreamCensus owns the census of missing history; tripwire 50's counts follow it`

### Task 3: `StreamPositions` — marks and positions

**Files:**
- Create: `StreamPositions.swift`
- Modify: `OpLogStore.swift` (`:~1097-1795`; the "unsigned door's photograph" section at `:~1422`, including `highestAppliedOpId`, `appliedPositions`, `seenPositions`, `positions`, `unattributablePositions`, the placeholder refusal and `verificationForPositions`)

**Contract:**
- Create `public enum StreamPositions`.
- Retarget these keys:
  - `partitionCallSites` (tripwire 45; one of the two counted `PermitPartition.partition` sites lives here);
  - `trustClosureAllowedSpellings`/`typeAllowanceBounds` (tripwire 39; one of the three `trusted: { _ in false }` sites lives here);
  - `narrowingAllowed` (tripwire 49).
- Counts may now split across `type:OpLogStore` and `type:StreamPositions`. The SUM must equal today's count, and `typeAllowanceBounds` must bound each type separately.

Commit: `refactor(core): StreamPositions owns marks and positions; tripwires 39/45/49 follow the code`

### Task 4: `OpLogClassifier` — load and classify, with one verify-walk helper

**Files:**
- Create: `OpLogClassifier.swift`
- Modify: `OpLogStore.swift` (load/classify `:~535-1097` and `:~2093-2636`: `load`, `loadDiagnosed`, `heldLines`, `provenance`, `loadDiagnosedPartial`, `loadFileDiagnosed`, `classify`, `partitioningByPermit`, `classifyTail`, `readmitting`, `classifySegment`, `loadSyncMerged`, `mergeSortedDedup`)

**Contract:**
- Move the PURE classification statics into `public enum OpLogClassifier`.
- Instance methods that need the store's trust cache (`load(docId:)`-style entry points) stay on `OpLogStore` and call the classifier with the table they resolve.
- **One walk helper.** The idiom `trust.map { verify(trust:…keyOfAnUnsealedFile:) } ?? verify(trusted: false)` appears three times (`:~1764-1780`, `~2215-2234`, `~2496-2506`). It becomes ONE helper, `OpLogClassifier.walk(bytes:trust:rememberedHead:url:)`, called from all three sites.
  - That moves the keyless `trusted: { _ in false }` spellings into the helper. Update tripwire 39's allowance and `typeAllowanceBounds` to the helper's type and the new count. Write the old count and the new one in the report.
  - The helper must keep each site's exact semantics. Diff the three call sites' old and new behaviour in the report.
- Tripwire 45's second partition site moves here too. Retarget it.
- Tripwire 37: the seal-line recogniser stays in `OpLogChain`. Confirm this is unaffected.

Commit: `refactor(core): OpLogClassifier owns classification; three copies of the verify walk become one`

### Task 5: `LocalWritePermitBuilder` — the write side's one question

**Files:**
- Create: `LocalWritePermitBuilder.swift`
- Modify: `OpLogStore.swift` (`:~263-406` plus `annotationAmendments` at `:~445-467`)
- Modify: `OpLogPermitContext.swift` (`startedBy`, `unownedPiece` at `:~370-500`)

**Contract:**
- Create `public enum LocalWritePermitBuilder` (or a struct, if state is genuinely needed; justify it in the report).
- It owns the permit construction and the Option-A starter facts.
- `OpLogStore.localWritePermit(as:documentClass:)` stays the ONE public door (tripwire 46). It becomes a forwarder that resolves trust via `trustOnThisActor`, keeping it synchronous, and calls the builder.
- Tripwire 46's census (`localWritePermitAllowed`: `"LocalWritePermit("` and `"func localWritePermit("`) and `typeAllowanceBounds`' `LocalWritePermit(` count: retarget to `type:LocalWritePermitBuilder` for the construction sites. The one door stays on `OpLogStore`.
- Fix the audit-noted coupling while moving: Core's op-log layer reads the manifest from disk for `startedBy` (`:~351-354`). Keep that behaviour, but move the manifest read into the builder behind the existing `ManifestPlacement` overload.

Commit: `refactor(core): LocalWritePermitBuilder owns permit construction; OpLogStore.localWritePermit stays the one door`

### Task 6: `SegmentSealer` and the slimmed `OpLogStore`

**Files:**
- Create: `SegmentSealer.swift`
- Modify: `OpLogStore.swift` (the "Seal" section `:~2809-2960`, `sealTailIfNeeded`, and `SegmentSignature` at `:32-84`)

**Contract:**
- Move `SegmentSignature` and the segment-seal logic (`sealTailIfNeeded` and its helpers) into `SegmentSealer.swift`.
  - Use a struct or enum for the pure parts.
  - The instance state it touches (`linesSinceSeal` and similar) stays on `OpLogStore`, passed in.
- Retarget `PersonKeyCensusTests`' `credentialsVerify` entry (`type:SegmentSignature`; plan 2 already keyed it by type, so confirm it follows) and the tripwire-17 seal tests.
- Then make the comment pass over what remains of `OpLogStore.swift`: contract plus pointer, measured before and after.
- Report:
  - `OpLogStore.swift`'s final LOC;
  - each new file's LOC;
  - the count of one-line forwarders left;
  - a table of `OpLogStore`'s remaining responsibilities, which should be trust cache, append and chain seal, and forwarders.

Commit: `refactor(core): SegmentSealer owns the segment seal; OpLogStore is the trust cache, the append and a forwarding surface`

---

## Finish

1. Run `./scripts/test.sh full` and `./scripts/test.sh phone`. Both must be green, plus a Release build.
2. Whole-branch review on opus. It should:
   - diff every moved body against base, ignoring whitespace;
   - check every census key that changed type, and its control;
   - confirm each forwarder is a single line;
   - confirm `trustOnThisActor` is still synchronous;
   - confirm the three-in-one walk helper preserves each site's behaviour.
3. No smoke beyond the gates: this is pure Core restructuring. Denver's next ordinary session is the smoke.
4. Do not merge without Denver.

## Out of scope

- **Moving the 72 callers off the forwarders.** That is a later mechanical plan, once the forwarders have proved stable.
- **`ProjectTrust`, the project-scoped trust cache (audit B1).** It is its own plan; it changes the trust cache's ownership, not its location.
