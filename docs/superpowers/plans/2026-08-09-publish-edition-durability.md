# Publish-Edition Durability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every publication record owns a distinct on-disk artifact and identity from mint time — closing issue #25 (P1 clobber, P2 same-process mint race, P3 [refuted → pin], P4 dead field).

**Architecture:** `Republisher` mints its `-r<suffix>` version before compile and stamps it through an effective config (the orchestrator's stamp=row invariant, extended); a per-project `PublishMintGate` actor reserves the (version, language, format) triple at guard time so a duplicate same-process compile fails fast; the already-existing `{version}` template rule gets its missing test pin; the dead `allowStale` field is deleted. The P1 regression doubles as the claims register's first publish pin (M7-PB-001).

**Tech Stack:** Swift / XCTest, Mac scheme. EPUB format in tests wherever a real compile is needed — `EPUBCompiler` does not require tectonic (only the e2e suite does, and it skips without the binary).

**Spec:** `docs/superpowers/specs/2026-08-09-publish-edition-durability-design.md` — read first. Note §2.3 is corrected by Task 3 (the validator rule already exists; the sweep finding was wrong).

## Global Constraints

- **Read before editing:** the `Maugham/Publish/` row in CLAUDE.md's per-area table (no AREA.md in Publish; ADR 0013 is the area ADR). `EMISSION.md` is generated — do not hand-edit it; nothing in this plan should change emission.
- **TDD** every behavior change: failing test first, RED evidence, then GREEN, per task.
- `PublishingStores` is `@MainActor` with a per-project singleton dictionary and `_resetForTesting()` — MCP-tool-style tests must reset it in setUp/tearDown (its own doc comment says why).
- Republished snapshot on disk stays byte-identical to the original config: `effective` is a local value; `snapshotStore.save(snap)` keeps saving the ORIGINAL. No snapshot schema change anywhere in this plan.
- No MCP tool count change; no catalog changes; `DocSyncTests` stays green.
- Fast loop `./scripts/test.sh`; single class `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<Class>`; **full gate `./scripts/test.sh full` before merge** (Task 6).
- New file in Task 2 (`PublishMintGate.swift`) and Task 5 (claims pin + JSON pair) → after creating new Swift files run `./gen.sh` once before building.
- Commit per task; end every commit body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: P1 — mint first, stamp everywhere (`Republisher`)

**Files:**
- Modify: `Maugham/Publish/Republisher.swift` (mint at ~:79 after `prior` loads; compilers at :131/:142 take `effective`; append at :176-178 reuses the pre-minted version; comment on the `fileExists` guard at :167)
- Test: `MaughamTests/RepublisherTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature changes — behavior only. Task 5's claims pin references the tests written here by name.

- [ ] **Step 1: Read `MaughamTests/RepublisherTests.swift` top to bottom** — it has the project/snapshot/store harness; every new test uses its helpers and `.epub` (no tectonic).
- [ ] **Step 2: Write the failing tests** (adapt names to the file's style; keep the assertions exactly):

```swift
/// P1 (issue #25): republish clobbered the ORIGINAL edition's artifact —
/// the staged filename came from snap.config's pinned nextVersion. The
/// original's bytes must survive a republish, verbatim.
func test_republishLeavesTheOriginalArtifactBytesUntouched() async throws {
    // 1. compile (or fabricate via the harness) an original .epub publication;
    //    record its outputPath and its file's Data.
    // 2. mutate the manuscript (the drift the finding is about).
    // 3. republish(snapshotID:, format: .epub, label: nil)  // nil label = the collision case
    // 4. assert the original outputPath still exists AND its Data == recorded
    //    (bytes, not existence).
    // 5. assert the new Publication's outputPath != the original's.
}

/// Repeated republishes each get their own file — no shared clobber path.
func test_twoRepublishesProduceTwoNewDistinctFiles() async throws {
    // republish twice; assert three distinct outputPaths in the catalog and
    // three files on disk.
}

/// The republished filename carries the republish version (the '{version}'
/// token expands from the EFFECTIVE config), so it says which catalog row
/// it is — and so it can never equal the original's name.
func test_republishedFilenameCarriesTheRepublishVersion() async throws {
    // republish; take the new Publication; assert its version has the
    // "-r" infix and its outputPath's lastPathComponent CONTAINS that full
    // version string.
}
```

- [ ] **Step 3: RED** — `-only-testing:MaughamTests/RepublisherTests`. The first test fails at step 4 (bytes replaced) — capture it.
- [ ] **Step 4: Implement.** In `republish`, immediately after `let priorVersion = prior?.version`:

```swift
// P1 (issue #25): the republish version is minted BEFORE compile and
// stamped through the config — filename, artifact-internal stamp and
// catalog row all agree, which is CompileOrchestrator's own stamp=row
// invariant (its `effective.nextVersion = effectiveVersion`) arriving on
// this path. Minted here, once: the append below must reuse this value.
let suffix = String(UUID().uuidString.prefix(4)).lowercased()
let newVersion = priorVersion.map { "\($0)-r\(suffix)" } ?? "republish-\(suffix)"
var effective = snap.config
effective.nextVersion = newVersion
```

Pass `config: effective` to both compilers. Delete the old mint at :176-177; the `Publication` takes `version: newVersion`. On the move-site guard add:

```swift
// Defensive only: with the republish version in the filename this can
// no longer collide with a SIBLING edition's file — it fires only when
// re-staging after a crashed prior move of this same republish.
```

The snapshot re-validation at :59 stays on `snap.config` (`PublishConfigValidator` does not constrain `nextVersion` — verify with one read; if that turns out false, validate `effective` instead and say so in the commit).

- [ ] **Step 5: GREEN** — class green. Also run `-only-testing:MaughamTests/PublicationStoreTests` (catalog behavior unchanged).
- [ ] **Step 6: Commit** — `fix(publish): a republish mints its version before compile, so it can never wear the original's filename (P1)`.

---

### Task 2: P2 — `PublishMintGate` + wiring

**Files:**
- Create: `Maugham/Publish/PublishMintGate.swift`
- Modify: `Maugham/Publish/PublishingStores.swift` (fifth member), `Maugham/Publish/CompileOrchestrator.swift` (reserve after the triple-guard; release on every exit), `Maugham/Publish/Republisher.swift` (reserve its minted triple), `Maugham/MCP/Tools/PublicationTools.swift` (pass the gate through to `Republisher` if construction needs it — read how the orchestrator gets its collaborators first and mirror it)
- Test: create `MaughamTests/Publish/PublishMintGateTests.swift`; extend the orchestrator-level test class that already drives `compile` (find it: `grep -rln "CompileOrchestrator(" MaughamTests/` — likely `CompileLanguageThreadingTests` or a sibling; use its harness)

**Interfaces:**
- Produces:

```swift
public actor PublishMintGate {
    public struct Key: Hashable, Sendable {
        public let version: String
        public let language: String?
        public let format: PublishConfig.Format
        public init(version: String, language: String?, format: PublishConfig.Format)
    }
    public init()
    /// True = reserved; false = a compile of this triple is already in flight.
    public func reserve(_ key: Key) -> Bool
    public func release(_ key: Key)
}
```

- [ ] **Step 1: Write the failing actor tests** (new file; pure actor semantics, no compile):

```swift
func test_secondReservationOfTheSameTripleRefuses() async { /* reserve → true; reserve same → false */ }
func test_releaseMakesTheTripleReservableAgain() async { /* reserve, release, reserve → true */ }
func test_differentTriplesReserveIndependently() async { /* two keys differing in any one component both reserve */ }
```

- [ ] **Step 2: RED** (does not compile) → **implement the actor** (a `Set<Key>`, insert-if-absent in `reserve`, remove in `release`; doc comment: per-project, per-process — the partitioned store isolates devices; this gate closes the same-process window and the source-compile `next_version` double-grab). Run `./gen.sh`. **GREEN.**
- [ ] **Step 3: Wire it.** `PublishingStores` gains `public let mintGate = PublishMintGate()`. In `CompileOrchestrator.compile`, immediately after the existing triple-guard passes: build `let mintKey = PublishMintGate.Key(version: effectiveVersion, language: language, format: format)`; `guard await mintGate.reserve(mintKey) else { fail the job with a Diagnostic matching the existing collision refusal's shape, message "Publication v\(effectiveVersion) (\(langLabel), \(format.rawValue)) is already compiling; wait for it to finish." and return .failed }`. Release via `defer`-equivalent on EVERY exit after reservation (Swift `defer` inside the reserved scope, or an explicit release before each return — count the returns; the orchestrator has several). `Republisher.republish` reserves its `newVersion` triple right after minting (Task 1's code), same release discipline. How the orchestrator/republisher RECEIVE the gate: mirror how they receive `jobManager` today (constructor injection from `PublishingStores` at the tool call sites) — read `PublicationTools.swift` and pass it the same way.
- [ ] **Step 4: Write the failing concurrency test** in the orchestrator-harness class:

```swift
/// P2: two same-process compiles of one triple — exactly one Publication,
/// one fast refusal naming the in-flight edition. EPUB (no tectonic).
func test_concurrentIdenticalCompiles_mintExactlyOnePublication() async throws {
    // async let both compiles with the same config/format/language;
    // await both outcomes; assert exactly one .completed and one .failed
    // whose diagnostic message contains "already compiling";
    // assert publicationStore.load() has exactly one new record.
}
```

(If the harness's compile is too slow to overlap reliably, reserve manually around a stub — but try the real path first; EPUB compiles of a one-paragraph project are sub-second.)

- [ ] **Step 5: GREEN, plus a release-on-failure test** — force a failing compile (the harness will have a way; an invalid stage or empty project), then compile again with the same triple and assert it is NOT refused (the reservation released).
- [ ] **Step 6: Commit** — `fix(publish): a per-project mint gate — the same edition cannot be compiled twice at once (P2)`.

---

### Task 3: P3 — the finding was wrong; pin the rule it asked for

**Files:**
- Create: `MaughamTests/Publish/PublishConfigValidatorTests.swift`
- Modify: `docs/superpowers/specs/2026-08-09-publish-edition-durability-design.md` (§2.3 dated correction), `docs/superpowers/notes/2026-07-26-sweep.md` (dated one-line amendment under P3 — historical record, append never rewrite)

**Interfaces:** none.

- [ ] **Step 1: Verify the refutation once yourself:** `PublishConfigValidator.swift:54-56` requires `{title}`+`{version}`+`{ext}` and has since the file's creation (`git log -L54,56:Maugham/Publish/PublishConfigValidator.swift`). The sweep's P3 said the validator "does not validate it" — false when filed.
- [ ] **Step 2: The rule is real but UNPINNED (no `PublishConfigValidatorTests` exists). Write the pin:**

```swift
func test_templateMissingVersionTokenIsRefused() { /* validate(cfg with filenameTemplate: "{title}.{ext}") → contains an error whose field is the template field */ }
func test_defaultTemplatePasses() { /* validate(PublishConfig()) → no template errors */ }
func test_republishRefusesASnapshotWhoseTemplateLacksVersion() async throws {
    // RepublisherTests-style harness: doctor a snapshot's config template to
    // "{title}.{ext}", call republish, assert RepublishError.invalidSnapshotConfig.
    // This is the replay half the spec's §2.3 wanted — it already works; pin it.
}
```

- [ ] **Step 3: RED-check honestly** — the first two should pass immediately (the rule exists; note this in the report — the pin is against future regression, the RED discipline here is "watched them run against a deliberately broken rule": comment out the `{version}` clause locally, watch test 1 fail, restore). The third must pass against the real path.
- [ ] **Step 4: Spec correction (append under §2.3):**

```markdown
**Correction (2026-08-09, plan Task 3):** the validator has required `{version}`
(with `{title}`/`{ext}`) since its creation (`28b6fed9`) — sweep finding P3 was
wrong when filed. What was missing was the TEST pin; this task adds it. The
snapshot-replay refusal described below already worked via `Republisher`'s
re-validation.
```

And the matching one-liner under the sweep note's P3 entry.
- [ ] **Step 5: Commit** — `test(publish): pin the {version} template rule — sweep P3 was refuted by source`.

---

### Task 4: P4 — delete the dead `allowStale` field

**Files:**
- Modify: `Maugham/Publish/ProjectStoreASTSource.swift:27-52` (field, init param, doc comment), `Maugham/MCP/Tools/PublicationTools.swift:243` (drop the argument)

**Interfaces:** `ProjectStoreASTSource.init(projectStore:language:)` — anything else constructing it with `allowStale:` will surface as a compile error; fix those sites the same way (drop the argument).

- [ ] **Step 1: Delete** the stored property, the init parameter (and its default), and the misleading doc comment ("stored so the gate can read the same value the substitution used" — the substitution never read it; both gates read their own values).
- [ ] **Step 2: Build** — fix every construction site the compiler names (known: `PublicationTools.swift:243`; tests may construct it too — same fix).
- [ ] **Step 3: Run** `-only-testing:MaughamTests/ProjectStoreASTSourceFreshnessTests` and `-only-testing:MaughamTests/TranslationCoverageGateTests` (the gate suites) — green proves no behavior change.
- [ ] **Step 4: Commit** — `refactor(publish): delete ProjectStoreASTSource.allowStale — dead since birth, misleading by doc comment (P4)`.

---

### Task 5: the claims pin — M7-PB-001, the register's first publish claim

**Files:**
- Create: `MaughamTests/Claims/PublicationsCharacterization.swift`, `experiment/reconciliation/Publications.claims.json`, `experiment/reconciliation/Publications.filings.json` — **path caveat:** if `experiment/reconciliation/` has moved to `register/reconciliation/` by landing time (the spec-phase session's graduation), create there instead; check both.
- Modify: `<experiment|register home>/scripts/27-generate-state.py` — add `"Publications"` to `APP_MODULES` (one line) UNLESS the graduation session already did.

**Interfaces:** consumes Task 1's tests (the pin cites them) and the claim id `M7-PB-001`.

- [ ] **Step 1: Read `experiment/reconciliation/PROTOCOL.md`** and ONE existing pair (`Rewind.claims.json` + `Rewind.filings.json`) plus one resident suite in `MaughamTests/Claims/` — copy their shape exactly; invent nothing.
- [ ] **Step 2: Write the claim + filing pair.** Claim M7-PB-001, statement: *"A republish never rewrites another publication's artifact: every catalog record's `outputPath` resolves to a distinct file, and the bytes at an existing record's `outputPath` are not modified by any later compile or republish."* Filing: `COMPLIES`, citing Task 1's commit and the pin test.
- [ ] **Step 3: Write the pin** (`PublicationsCharacterization.swift`): the claim id in the test name per the resident suites' convention; body re-uses `RepublisherTests`' harness shape to assert the distinct-paths + untouched-bytes facts (a tighter restatement of Task 1's first two tests is fine — the pin's job is permanence, and it must fail if either fact breaks).
- [ ] **Step 4: Run** the new suite + `python3 <home>/scripts/flip-claim.py recompute --module Publications` (home = `experiment/` or `register/` per Step 1's caveat) and commit the regenerated state if the script produces any.
- [ ] **Step 5: Message check** — the controller will coordinate with the spec-phase session before this lands (their request); note in your report whether `APP_MODULES` was already carrying `Publications`.
- [ ] **Step 6: Commit** — `test(claims): M7-PB-001 — the register's first publish claim, filed with the work`.

---

### Task 6: docs + full gate

**Files:**
- Modify: `docs/roadmap.md` (if it carries a publish "left open" touching these findings — check, don't assume), CLAUDE.md's `Maugham/Publish/` row (only if this plan made a sentence false — the mint gate is worth its one clause: "compile mints serialize through `PublishMintGate`")
- No new tests — the deliverable is doc truth + the gate.

- [ ] **Step 1: Sweep** — `grep -rn "republish\|clobber\|allowStale\|mint" docs/roadmap.md CLAUDE.md docs/guide/ | grep -vi "granted"` and fix what the branch made false; add the `PublishMintGate` clause to CLAUDE.md's Publish row.
- [ ] **Step 2: Full gate** — `./scripts/test.sh full`; green required; capture the counts.
- [ ] **Step 3: Commit** — `docs: the publish seam's new guarantees, recorded (issue #25)`.

---

## Post-plan (standing workflow, not tasks)

- Whole-branch review (cross-task seams: the mint-gate release discipline across ALL orchestrator exits; Task 1's effective config vs Task 2's reservation key — both must use `newVersion`; the claims pin's facts vs Task 1's actual assertions), one fix wave max, then merge via finishing-a-development-branch.
- Message the spec-phase session (their standing request) before landing: the claims pair's final path + whether `APP_MODULES` needs their carry.
- Update issue #25 at merge with the P3-refutation note prominent.
- Smoke (Denver): compile an EPUB, edit the manuscript, republish it, open both files — the original still shows the pre-edit text; the republished one names its `-r` version in Exports/.
