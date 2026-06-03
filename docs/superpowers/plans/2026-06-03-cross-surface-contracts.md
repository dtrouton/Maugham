# Cross-Surface Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring every phone↔Mac contract under explicit, action-triggered enforcement so a future surface that reimplements a shared contract fails the build instead of silently drifting.

**Architecture:** A three-tier model (Tier 1 shared-impl / Tier 2 contracted-divergence / Tier 3 free-divergence). Enforcement teeth are MaughamCore choke-point APIs + reach-around grep tripwires (both action-triggered); a registry doc is only the tripwire's destination. The full contract set comes from a subagent-driven audit; this plan fully specifies the kit + the doc-id Tier-1 exemplar + the audit, then provides complete recipes that get instantiated per audit finding.

**Tech Stack:** Swift, SwiftUI/AppKit, MaughamCore (Foundation-only SPM package), XCTest. Build via `./gen.sh` + `xcodebuild`; MaughamCore unit tests via `swift test` in the package dir.

**Spec:** `docs/superpowers/specs/2026-06-03-cross-surface-contracts-design.md`

---

## Plan shape (read first)

- **Phase A (Tasks 1–6):** the reusable kit + the doc-id contract as the fully-worked Tier-1 exemplar. Fully specified below.
- **Phase B (Task 7):** the subagent-driven audit that produces the complete contract inventory, worklist, and tripwire allowlist.
- **Phase C (Tasks 8+):** instantiate the Tier-1 / Tier-2 **recipes** (given in full below) once per audit worklist item. Task 8 extends this plan with one concrete task per item; the recipes are complete templates, the doc-id work in Phase A is the worked Tier-1 instance, and `ScreenplayEmphasis` is the worked Tier-2 instance.

Choke-point decision (resolves the spec's open question): **extend `OpLogStore`** with the canonical filename↔id predicate rather than introduce a new `SidecarPaths` facade. The audit may later recommend a broader facade; do not pre-build it.

---

## Phase A — Kit + doc-id Tier-1 exemplar

### Task 1: Canonical doc-id predicate in `OpLogStore` (the Tier-1 choke-point)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogFilenameTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MaughamCore

/// The single source of truth for "what op-log filename maps to what docId".
/// Both surfaces delegate here; these assertions use the REAL minted id shapes
/// (doc-<hex> / scene-<hex>, ADR 0008), never a `d_<ULID>` literal.
final class OpLogFilenameTests: XCTestCase {
    func test_docId_parsesRealShapes_excludesProjectAndJunk() {
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "doc-0f677d7e.jsonl"), "doc-0f677d7e")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "doc-0f677d7e.macA.jsonl"), "doc-0f677d7e")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "scene-f8c9644e.mcp-cba8e063.jsonl"), "scene-f8c9644e")
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: "__project__.jsonl"))
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: "__project__.macA.jsonl"))
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: "notes.txt"))
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: ".jsonl"))
    }

    func test_docIds_dedupesPerDeviceAndLegacy() {
        let names = ["doc-0f677d7e.jsonl", "doc-0f677d7e.macA.jsonl",
                     "scene-f8c9644e.phoneB.jsonl", "__project__.jsonl"]
        XCTAssertEqual(OpLogStore.docIds(inOpsDirectoryFilenames: names),
                       ["doc-0f677d7e", "scene-f8c9644e"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter OpLogFilenameTests`
Expected: FAIL — `type 'OpLogStore' has no member 'docId'`.

- [ ] **Step 3: Add the predicate to `OpLogStore`**

In `OpLogStore.swift`, in the `// MARK: - Glob helpers` section (near `opLogFileURLs`), add:

```swift
/// The doc id encoded in an op-log filename, or nil if `name` is not a
/// manuscript doc op-log file. Filenames are `<docId>(.<slug>)?.jsonl`; the
/// doc id is the component before the first `.` (doc ids contain no dot) and is
/// `doc-<hex>` / `scene-<hex>` (ADR 0008). Deliberately NOT format-validated —
/// this store is id-agnostic by contract; the only excluded stream is the
/// synthetic `__project__` (tasks/checkpoints — no manuscript content).
///
/// SINGLE SOURCE OF TRUTH for filename→docId. Surfaces (phone + Mac) MUST call
/// this, never hand-roll a predicate (a stricter local copy is what shipped the
/// phone-v0.1.1 "No open annotations" bug). Enforced by the reach-around
/// tripwires; see docs/superpowers/notes/cross-surface-contracts.md.
public static func docId(fromOpLogFilename name: String) -> String? {
    guard name.hasSuffix(".jsonl") else { return nil }
    let stem = String(name.dropLast(".jsonl".count))
    let head = String(stem.split(separator: ".", maxSplits: 1,
                                 omittingEmptySubsequences: false)[0])
    guard !head.isEmpty, head != "__project__" else { return nil }
    return head
}

/// Distinct doc ids among a set of `.maugham/ops/` filenames (per-device +
/// legacy files for one doc collapse to one id).
public static func docIds(inOpsDirectoryFilenames filenames: [String]) -> Set<String> {
    Set(filenames.compactMap(docId(fromOpLogFilename:)))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/MaughamCore && swift test --filter OpLogFilenameTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/OpLogFilenameTests.swift
git commit -m "feat(core): canonical op-log filename→docId predicate in OpLogStore"
```

---

### Task 2: Route phone `AnnotationLoading` through the choke-point

**Files:**
- Modify: `MaughamPhone/Annotations/AnnotationLoading.swift`
- Test: `MaughamPhoneTests/AnnotationLoadingTests.swift` (already exists; assertions unchanged)

- [ ] **Step 1: Run the existing test to confirm green baseline**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:MaughamPhoneTests/AnnotationLoadingTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: PASS (the post-phone-v0.1.1 tests).

- [ ] **Step 2: Replace the local predicate with delegation**

In `AnnotationLoading.swift`, replace the body of `docIds(inOpsDirectoryFilenames:)` and DELETE the private `docId(fromOpLogFilename:)` and `isDocId(_:)` helpers entirely. Result:

```swift
static func docIds(inOpsDirectoryFilenames filenames: [String]) -> Set<String> {
    // Single source of truth lives in MaughamCore. Do NOT reimplement the
    // predicate here (a stricter local copy shipped the phone-v0.1.1 bug).
    OpLogStore.docIds(inOpsDirectoryFilenames: filenames)
}
```

Keep `openAnnotations(ops:)` exactly as-is.

- [ ] **Step 3: Run the tests to verify still green**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:MaughamPhoneTests/AnnotationLoadingTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: PASS — behavior identical, one fewer copy of the predicate.

- [ ] **Step 4: Commit**

```bash
git add MaughamPhone/Annotations/AnnotationLoading.swift
git commit -m "refactor(phone): AnnotationLoading delegates docId parsing to OpLogStore"
```

---

### Task 3: Route phone `ColdLaunchDownloader` through the choke-point

**Files:**
- Modify: `MaughamPhone/Storage/ColdLaunchDownloader.swift`
- Test: `MaughamPhoneTests/ColdLaunchDownloaderTests.swift` (exists; assertions unchanged)

- [ ] **Step 1: Replace the local filter with the choke-point**

In `liveEnumerateOpLogs`, replace the filter closure body:

```swift
return entries.filter { url in
    OpLogStore.docId(fromOpLogFilename: url.lastPathComponent) != nil
}
```

Update the docstring's last sentence to: `Recognition delegates to OpLogStore.docId(fromOpLogFilename:) — the single source of truth (a local d_-prefix predicate prefetched nothing pre-phone-v0.1.1).`

- [ ] **Step 2: Run the tests to verify still green**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:MaughamPhoneTests/ColdLaunchDownloaderTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: PASS (including `test_liveEnumerateOpLogs_recognizesRealDocIds_excludesProjectAndJunk`).

- [ ] **Step 3: Commit**

```bash
git add MaughamPhone/Storage/ColdLaunchDownloader.swift
git commit -m "refactor(phone): ColdLaunchDownloader delegates docId recognition to OpLogStore"
```

---

### Task 4: Doc-id contract test in both app targets (the anti-lie round-trip)

Pins that the **filename the producer writes** is parseable by the **predicate the reader uses**, against ids from the REAL minter (Mac) / production id form (phone).

**Files:**
- Test (create): `MaughamTests/OpLogFilenameContractTests.swift`
- Test (create): `MaughamPhoneTests/OpLogFilenameContractTests.swift`

- [ ] **Step 1: Write the Mac-side contract test (real minter)**

```swift
import XCTest
import MaughamCore
@testable import Maugham

/// Cross-surface contract: an op-log filename built for a REAL minted docId must
/// round-trip back through OpLogStore.docId(...). Mac half — uses the production
/// minter (ProjectStore.newId) so the test cannot re-encode a wrong id shape.
final class OpLogFilenameContractTests: XCTestCase {
    func test_realMintedDocIds_roundTripThroughParser() {
        for prefix in ["doc", "scene"] {
            let docId = ProjectStore.newId(prefix: prefix)
            let slug = DeviceSlug.make(from: "MacTest:host")
            XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).jsonl"), docId)
            XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).\(slug).jsonl"), docId)
        }
    }
}
```

- [ ] **Step 2: Run it; verify pass (or fix a signature mismatch)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/OpLogFilenameContractTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8`
Expected: PASS. If `ProjectStore.newId(prefix:)` is not visible to the test, use `@testable import Maugham` (already present) — it is an internal static. If its label differs, grep `ProjectStore+CollectionPieces.swift` for the exact signature and match it.

- [ ] **Step 3: Write the phone-side contract test (production id form)**

```swift
import XCTest
import MaughamCore
@testable import MaughamPhone

/// Cross-surface contract: phone half. The real minter lives in the Mac target,
/// so reproduce the PRODUCTION id form here (doc-<8 lowercase hex>) — never a
/// hand-typed `d_<ULID>` literal, which is what let the old test agree with the bug.
final class OpLogFilenameContractTests: XCTestCase {
    func test_productionFormDocIds_roundTripThroughParser() {
        let docId = "doc-" + UUID().uuidString.prefix(8).lowercased()
        let slug = DeviceSlug.make(from: "phone:host")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).jsonl"), String(docId))
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: "\(docId).\(slug).jsonl"), String(docId))
    }
}
```

- [ ] **Step 4: Run it; verify pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:MaughamPhoneTests/OpLogFilenameContractTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MaughamTests/OpLogFilenameContractTests.swift MaughamPhoneTests/OpLogFilenameContractTests.swift
git commit -m "test: doc-id filename round-trip contract in both targets (real-minter fixtures)"
```

---

### Task 5: Reach-around tripwires (both targets)

Build-failing grep tests that fire when surface code hand-rolls op-log filename parsing outside the sanctioned allowlist.

**Files:**
- Modify: `MaughamPhoneTests/TripwirePhoneGrepTest.swift` (add a second test)
- Create: `MaughamTests/TripwireGrepTests.swift` (Mac twin)

- [ ] **Step 1: Add the phone reach-around test**

Append to `TripwirePhoneGrepTest`:

```swift
/// Action-triggered guard: surface code must not hand-roll op-log filename /
/// docId parsing — it must call OpLogStore. Catches the phone-v0.1.1 footgun
/// class. Allowlist = files that legitimately ARE the choke-point or its tests.
func test_noReachAroundOpLogFilenameParsing() throws {
    let here = URL(fileURLWithPath: #filePath)
    let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
    let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)
    let allowed: Set<String> = [
        // none in MaughamPhone today — surfaces delegate to OpLogStore.
        // The audit (Task 7) finalizes this list.
    ]
    let forbidden = ["hasPrefix(\"d_\")", ".hasSuffix(\".jsonl\")"]
    let fm = FileManager.default
    guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
        return XCTFail("could not enumerate \(sourceDir.path)")
    }
    var offenders: [String] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        if allowed.contains(url.lastPathComponent) { continue }
        let text = try String(contentsOf: url, encoding: .utf8)
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for pat in forbidden where line.contains(pat) {
                offenders.append("\(url.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    XCTAssertTrue(offenders.isEmpty,
        "Hand-rolled op-log filename parsing found. Use OpLogStore.docId(fromOpLogFilename:). "
        + "See docs/superpowers/notes/cross-surface-contracts.md:\n" + offenders.joined(separator: "\n"))
}
```

- [ ] **Step 2: Run the phone tripwires; verify pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:MaughamPhoneTests/TripwirePhoneGrepTest CODE_SIGNING_ALLOWED=NO 2>&1 | tail -6`
Expected: PASS (Tasks 2–3 already removed the offenders).

- [ ] **Step 3: Create the Mac twin**

```swift
import XCTest

/// Mac-side reach-around tripwire (twin of TripwirePhoneGrepTest). Scans
/// Maugham/ in pure Swift (mirrors the phone approach; no Process spawn). The
/// allowlist holds the files that legitimately own op-log filename handling.
final class TripwireGrepTests: XCTestCase {
    func test_noReachAroundOpLogFilenameParsing() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("Maugham", isDirectory: true)
        // OpLogStore is in MaughamCore (not scanned). These Mac files legitimately
        // touch op-log/sidecar filenames; the audit (Task 7) finalizes the list.
        let allowed: Set<String> = [
            "MaughamSidecarPath.swift",
        ]
        let forbidden = ["hasPrefix(\"d_\")"]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(sourceDir.path)")
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if allowed.contains(url.lastPathComponent) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for pat in forbidden where line.contains(pat) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "Hand-rolled doc-id parsing in Maugham/. Use OpLogStore.docId(fromOpLogFilename:). "
            + "See docs/superpowers/notes/cross-surface-contracts.md:\n" + offenders.joined(separator: "\n"))
    }
}
```

- [ ] **Step 4: Run the Mac tripwire; verify pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/TripwireGrepTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -6`
Expected: PASS. If it FAILS, an offender is a legitimate owner → add it to `allowed` with a one-line justification comment; if it's a real reach-around, route it through `OpLogStore` first.

- [ ] **Step 5: Commit**

```bash
git add MaughamPhoneTests/TripwirePhoneGrepTest.swift MaughamTests/TripwireGrepTests.swift
git commit -m "test: reach-around tripwires for op-log filename parsing (both targets)"
```

---

### Task 6: Registry skeleton + doc-id entry + pointers

**Files:**
- Create: `docs/superpowers/notes/cross-surface-contracts.md`
- Modify: `CLAUDE.md` (tripwires section), `MaughamPhone/AREA.md`, `Maugham/OpLog/AREA.md`

- [ ] **Step 1: Create the registry**

```markdown
# Cross-Surface Contracts (phone ↔ Mac)

> You were likely sent here by a failing tripwire test. A tripwire fires when
> surface code reimplements something both surfaces share. Find the contract
> below, call its choke-point (Tier 1) or satisfy its contract type (Tier 2),
> and the tripwire passes. Spec: docs/superpowers/specs/2026-06-03-cross-surface-contracts-design.md

Tiers: **1** shared implementation (one MaughamCore impl; surfaces call it) ·
**2** contracted divergence (shared decision + contract test in both targets) ·
**3** free divergence (recorded as having no cross-surface invariant).

| Contract | Tier | Choke-point / contract type | Test | Tripwire |
|---|---|---|---|---|
| op-log filename ↔ docId | 1 | `OpLogStore.docId(fromOpLogFilename:)` / `docIds(inOpsDirectoryFilenames:)` | `OpLogFilenameTests` (core) + `OpLogFilenameContractTests` (both targets) | `test_noReachAroundOpLogFilenameParsing` (both targets) |
| Fountain bold/italic emphasis | 2 | `ScreenplayEmphasis.contract(for:)` | `ScreenplayEmphasisContractTests` (both targets) | — |

_Remaining contracts are populated by the Task 7 audit._
```

- [ ] **Step 2: Add the CLAUDE.md pointer**

In CLAUDE.md, under "Architectural tripwires", add a new numbered tripwire:

```markdown
NN. **Anything touched by BOTH the Mac and the phone goes through a contract.** Op-log/inbox filenames, ids, on-disk formats, anchor-stripping, Fountain decisions — the phone must not reimplement what the Mac implements (a stricter local doc-id parser shipped the phone-v0.1.1 "No open annotations" bug). The single sources of truth live in MaughamCore; reach-around tripwires (`TripwirePhoneGrepTest`, `TripwireGrepTests`) fail the build on hand-rolled copies and point you at `docs/superpowers/notes/cross-surface-contracts.md`. Don't add a third implementation of anything in that registry.
```

- [ ] **Step 3: Add AREA.md pointers**

In `MaughamPhone/AREA.md` and `Maugham/OpLog/AREA.md`, add under their tripwire/pointer sections:

```markdown
- **Cross-surface contracts:** if you touch op-log/inbox filenames, ids, formats, or Fountain rendering, you may be in shared phone↔Mac territory — the reach-around tripwires will tell you. Registry: `docs/superpowers/notes/cross-surface-contracts.md`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/notes/cross-surface-contracts.md CLAUDE.md MaughamPhone/AREA.md Maugham/OpLog/AREA.md
git commit -m "docs: cross-surface contract registry + tripwire-destination pointers"
```

---

## Phase B — The audit

### Task 7: Subagent-driven audit → inventory, worklist, allowlist

**Files:**
- Create: `docs/superpowers/notes/2026-06-03-cross-surface-audit.md` (worklist)
- Modify: `docs/superpowers/notes/cross-surface-contracts.md` (full population)

- [ ] **Step 1: Dispatch parallel audit agents (one per axis)**

Use `superpowers:dispatching-parallel-agents`. Dispatch four read-only explorer agents, each returning a structured list of findings `{location(s), what's shared, current state (shared|reimplemented), proposed tier, one-line justification}`:

1. **On-disk formats** — every read/write of `.maugham/ops`, `.maugham/inbox`, `.md`/`.fountain` anchors, manifest, checkpoints across `Maugham/` and `MaughamPhone/`.
2. **Shared semantics** — id minting/parsing, `DeviceSlug`, monotonic timestamps, op derivation, sweep/echo logic.
3. **Shared derived output** — Fountain rendering (`ScreenplayMode` vs `FountainStyler`), Markdown display, anchor stripping, annotation projection.
4. **Write-contracts** — phone-produced artifacts the Mac consumes (ops via `AnnotationWriter`/`InboxCaptureWriter`) and vice versa.

- [ ] **Step 2: Adversarially verify the Tier-3 calls**

Dispatch one more agent: re-examine every finding the audit filed **Tier 3** and challenge it — "is there genuinely no cross-surface invariant here?" A wrongly-dismissed Tier 1 is the exact failure being prevented. Downgrade/upgrade tiers as the challenge demands.

- [ ] **Step 3: Write the worklist + populate the registry**

Write `2026-06-03-cross-surface-audit.md` partitioning findings into: **Tier 1 currently reimplemented** (collapse), **Tier 2 currently uncontracted** (add contract test), **Tier 3** (record only). Add every finding to the registry table. Record the finalized tripwire **allowlist** (sanctioned choke-point files) in the audit note.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/notes/2026-06-03-cross-surface-audit.md docs/superpowers/notes/cross-surface-contracts.md
git commit -m "docs(audit): complete phone↔Mac contract inventory + worklist + allowlist"
```

---

## Phase C — Recipes (instantiated per audit finding)

### Recipe T1 — Collapse a reimplemented Tier-1 contract

Worked instance: the doc-id contract = Tasks 1–5. For each Tier-1 worklist item, do the same five moves:

1. **Choke-point** — add/confirm the single MaughamCore implementation (extend the type that already owns the concept; do not add a parallel facade). TDD it in `MaughamCoreTests` against real-shaped inputs.
2. **Collapse** — replace each surface's copy with a one-line delegation; delete the local logic. Run that surface's existing tests; they must stay green (behavior identical).
3. **Contract test** — add a round-trip / equivalence test in both app targets using real-minter fixtures (anti-lie rule).
4. **Tripwire** — add the specific reach-around pattern to both grep tripwires; add legitimate owners to the allowlist with justification.
5. **Register + commit** — add the row to the registry; commit each move separately.

### Recipe T2 — Contract a divergent Tier-2 surface

Worked instance: `ScreenplayEmphasis` + `ScreenplayEmphasisContractTests`. For each Tier-2 worklist item:

1. **Extract the decision** into a MaughamCore type — an enum/struct + a `contract(for:)`-style function that returns the shared decision (e.g. element classification, uppercasing rule, anchor-hidden flag), or nil for "intentionally surface-specific". Apply rendering-depth rule **C**: decision-extraction (A) by default; escalate to a fully-decided display IR (B) ONLY where the audit flags that A still leaves decision-logic duplicated across the two renderers.
2. **Consume it** on both surfaces — each renderer reads the shared decision instead of deciding locally.
3. **Contract test in both targets** — mirror `ScreenplayEmphasisContractTests`: iterate all cases, skip where `contract(for:)` is nil, assert each surface matches the contract.
4. **Tripwire (if applicable)** — if the audit found a second renderer/filter, add a tripwire banning a third.
5. **Register + commit.**

### Task 8: Extend this plan from the audit worklist

- [ ] **Step 1:** For each item in `2026-06-03-cross-surface-audit.md`, append a concrete task to this plan instantiating Recipe T1 or T2 — exact files, exact code, exact test/run commands (no placeholders; copy the doc-id / ScreenplayEmphasis worked code and adapt). Order: all Tier-1 collapses first (cheap, pure logic), then Tier-2 contracting, with rendering decision-extraction last (largest, rule-C-sized).
- [ ] **Step 2:** Resume subagent-driven execution against the extended task list.

---

## Closing the loop (after Phase C completes)

- [ ] Run BOTH full suites: `xcodebuild ... -scheme Maugham test` and `xcodebuild ... -scheme MaughamPhone ... test` (CLAUDE.md: a MaughamCore change must pass both). Also `cd Packages/MaughamCore && swift test`.
- [ ] Confirm success criteria from the spec: complete registry; zero Tier-1 contracts with >1 implementation; every Tier-2 contract has a passing dual-target test; reaching around any choke-point fails the build with a registry-pointing message.
- [ ] Record the milestone in `~/.claude/.../memory/` and update `MEMORY.md`. Tag (milestone tag, not a release tag).

## Self-review notes

- **Spec coverage:** three-tier model (Tasks 1/4/Recipes), choke-point (Task 1), reach-around tripwires (Task 5), contract-test kit + anti-lie rule (Task 4), registry as tripwire-destination (Task 6), audit + adversarial Tier-3 check (Task 7), rendering-depth rule C (Recipe T2), build sequence (phases) — all present.
- **Audit-driven tail:** Phase C is intentionally template-not-enumerated because the contract set is data produced by Task 7; the recipes are complete and have worked instances, and Task 8 converts the worklist into concrete no-placeholder tasks before execution resumes.
- **Type consistency:** `OpLogStore.docId(fromOpLogFilename:)` / `docIds(inOpsDirectoryFilenames:)`, `DeviceSlug.make(from:)`, `ProjectStore.newId(prefix:)`, `ScreenplayEmphasis.contract(for:)`, `FountainStyler.style(for:)` used consistently across tasks.
