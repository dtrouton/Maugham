# Issue #28 — Canvas robustness (F11, F12, F9, F8, F13) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the five canvas-robustness findings from the 2026-08-09 maintainability review: content-before-derived write order (F11, constitution must #1), honest blank-line round-trip (F12), orphan-scrap prune (F9), `ownedPath` through `SafeRelativePath` (F8), and a decompression-bomb pre-gate (F13).

**Architecture:** All five are local hardenings of existing canvas files — no new types beyond one error branch, no schema change, no UI change. Order is F11 → F12 → F9 → F8 → F13 (the review's own ordering): F11 settles the write path F9's test asserts against, F12's strip arithmetic feeds F9's whitespace-only test fixture, F8 is the largest small one, F13 is independent and droppable.

**Tech Stack:** Swift/XCTest, Mac scheme + one MaughamCore consumer (`SafeRelativePath`, already shipped — no package changes).

## Global Constraints

- Branch: `claude/issue-28-canvas-robustness` off `main`.
- Iteration command: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<Suite>` per task; full gate `./scripts/test.sh` (controller-owned) before merge, `./scripts/test.sh full` at the end.
- Never touch `Maugham.xcodeproj/` (generated) or `project.yml`; run `./gen.sh` only if a file is ADDED (none of these tasks adds source files; new tests go into existing suites).
- `Maugham/Canvas/AREA.md` test rules bind every new test: any `NotificationCenter.default.post(` needs `// adr-0021-ok:` (none expected here); **no `XCTAssertNil`/`XCTAssertEqual(…, nil)` whose subject contains `?.`** (tripwire census) — use plain subscripts; keep both `// adr-0018-ok:` annotations in `CanvasStore.load()` if edited.
- Line numbers below were verified 2026-08-12; still locate each site by content before editing.
- The words-safety framing governs every judgment call: `canvas.md` is CONTENT, `.maugham/canvas.json` is derived (deletable), `canvas_assets/` is content. A fix that can delete a writer's words is worse than the defect it fixes.

---

### Task 1: F11 — `writeNow` writes content before derived

**Files:**
- Modify: `Maugham/Canvas/CanvasStore.swift:128-131` (`writeNow`)
- Test: `MaughamTests/Canvas/CanvasStoreTests.swift`

**Interfaces:**
- Produces: nothing new — a two-line swap plus a source-order pin test. Task 3's prune comment cites this task's window.

- [ ] **Step 1: Write the failing source-order pin**

Black-box I/O cannot observe the interleaving of two writes, so pin the SOURCE order — the house tripwire pattern. Add to `CanvasStoreTests`:

```swift
    /// F11 (issue #28): the content file must hit disk before the derived one.
    /// A crash in the gap between the two writes may only ever LAG `canvas.json`
    /// — the old order could resurrect a node in the sidecar whose words never
    /// reached `canvas.md`, and the scrap reloads empty (constitution must #1).
    /// Black-box I/O cannot see the interleaving, so this pins the source.
    func test_writeNowPutsContentBeforeDerived() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // MaughamTests/Canvas
            .deletingLastPathComponent()          // MaughamTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Maugham/Canvas/CanvasStore.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        guard let fn = text.range(of: "func writeNow") else {
            return XCTFail("writeNow not found — if it was renamed, move this pin with it")
        }
        let tail = text[fn.lowerBound...]
        guard let content = tail.range(of: "ScrapText.render"),
              let derived = tail.range(of: "writeSidecar(") else {
            return XCTFail("writeNow no longer names both writes — re-pin the new spellings")
        }
        XCTAssertTrue(content.lowerBound < derived.lowerBound,
            "canvas.md (content) must be written before canvas.json (derived)")
    }
```

- [ ] **Step 2: Run it — expect FAIL** (current order is derived-first).

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/CanvasStoreTests/test_writeNowPutsContentBeforeDerived`

- [ ] **Step 3: Swap the two lines**

`writeNow` becomes (the doc comment is new; `writeSidecar` itself is untouched — its `createDirectory` is for `.maugham/`, which the content write does not need):

```swift
    private func writeNow(scene: CanvasScene, scraps: [CanvasNodeID: String]) {
        // Content first, derived second (F11, issue #28): both writes are
        // individually atomic but the PAIR is not, and a crash in the gap must
        // only ever lag the deletable sidecar — never leave a node in
        // canvas.json whose words missed canvas.md.
        try? ScrapText.render(scraps).write(to: scrapsURL, atomically: true, encoding: .utf8)
        writeSidecar(scene)
    }
```

- [ ] **Step 4: Run the pin (PASS) and the whole suite**

Run: `… -only-testing:MaughamTests/CanvasStoreTests` — expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasStore.swift MaughamTests/Canvas/CanvasStoreTests.swift
git commit -m "fix(canvas): writeNow puts content before the derived sidecar (#28 F11)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: F12 — `ScrapText.parse` strips at most one blank line per side

**Files:**
- Modify: `Maugham/Canvas/ScrapText.swift:84-85` (the two `while` loops in `flush()`)
- Test: `MaughamTests/Canvas/ScrapTextTests.swift`

**Interfaces:**
- Produces: the round-trip guarantee Task 3's whitespace-orphan fixture depends on (a body of `"   "` survives parse as `"   "`).

- [ ] **Step 1: Write the failing round-trip test**

```swift
    func test_roundTrip_preservesDeliberateLeadingAndTrailingBlankLines() {
        // The renderer adds exactly ONE blank line on each side of a body; the
        // parser must therefore strip AT MOST one from each end — the old
        // `while` loops ate every blank line the writer put there on purpose.
        let scraps = [CanvasNodeID("s1"): "\n\nBody.\n\n"]
        XCTAssertEqual(ScrapText.parse(ScrapText.render(scraps)), scraps)
    }
```

- [ ] **Step 2: Run it — expect FAIL** (`while` loops trim to `"Body."`).

Run: `… -only-testing:MaughamTests/ScrapTextTests/test_roundTrip_preservesDeliberateLeadingAndTrailingBlankLines`

- [ ] **Step 3: `while` → `if`, and fix the comment to match**

In `flush()` inside `parse`:

```swift
            // The renderer added exactly one blank line on each side of the
            // body (see `render`); strip AT MOST one from each end, so blank
            // lines the writer typed survive the round trip. Conditional, not
            // unconditional: a body whose last line is prose must keep it.
            var lines = body
            if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
```

The arithmetic that keeps the existing suite green (verified against the fixtures): empty scrap renders to body `["", "", ""]` → one strip each end → `[""]` → `""` (`test_roundTrip_preservesAnEmptyScrap` holds); `test_parse_keepsMultipleParagraphsAndBlankLines`'s body ends on prose, so the conditional strips leave it alone.

- [ ] **Step 4: Run the whole suite**

Run: `… -only-testing:MaughamTests/ScrapTextTests` — expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/ScrapText.swift MaughamTests/Canvas/ScrapTextTests.swift
git commit -m "fix(canvas): parse strips only the renderer's own blank lines (#28 F12)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: F9 — orphan scraps SURFACE at load: text-bearing orphans resurrect as loose cards, whitespace-only ones drop [DENVER'S RULING 2026-08-12]

**Files:**
- Modify: `Maugham/Canvas/CanvasModel.swift` (`attach(projectRoot:)`, lines ~283-291)
- Test: `MaughamTests/Canvas/CanvasModelTests.swift` (or `CanvasStoreTests` if the fixture fits better there — implementer's call, say which and why)

**Interfaces:**
- Consumes: Task 1's settled write order; Task 2's strip arithmetic (a `"   "` body survives parse as whitespace).
- Produces: after `attach`, every scrap key has a node — orphans no longer exist as a persistent state on the live canvas.

**Denver's ruling (2026-08-12, supersedes the issue's literal fix-shape):** an orphan must be SURFACED to the writer, not silently pruned and not silently kept. A text-bearing orphan resurrects as a loose scrap card — its id gains a node again, so the words are visible where the writer works and the orphan stops accumulating; the writer keeps or deletes the card themselves. A whitespace-only orphan is dropped quietly. This also closes F11's residual window end-to-end: content lands, sidecar lags, crash — and on next open the words come BACK as a card instead of becoming invisible cruft.

Design constraints:
- Resurrect in `CanvasModel.attach`, between `s.load()` and the `scene`/`scraps` assignments — the moment the writer's canvas comes up, which is what "on load" means here. `CanvasStore.load()` itself stays a pure reader (the transient sidecar arm in `CanvasCapture.send` and any future read-only caller must not mutate scenes as a side effect); drop the whitespace-only orphans there or in `attach`, implementer's call, but resurrection is `attach`-only.
- No undo step: this is load-time reconciliation, not a writer gesture — mutate the loaded scene value BEFORE assigning it (no `beginGesture`, no `mutateFromInspector`; tripwire 32 does not apply because no bracket exists at attach time).
- Geometry mirrors the existing loose-landing idiom: reuse/factor the loose placement `CanvasCapture.plan` uses for a keyboard `Send to Canvas` (lands loose, NEVER in a region) rather than inventing a second placement. Do NOT touch `CanvasClaudeWrite`/`CanvasClaudePlacement` — and the resurrected card is the WRITER'S: seeded tilt ≥ `minimumTiltDegrees` and writer authorship, because straight-and-cool means Claude (ADR 0026 §10) and these are the writer's own words.
- `scheduleSave()` after resurrection so the sidecar catches up; a second attach must not duplicate (the id now has a node — inherently idempotent, and the test pins it).

- [ ] **Step 1: Write the failing test**

```swift
    /// F9 + Denver's 2026-08-12 ruling (issue #28): an orphan is SURFACED, not
    /// silently pruned and not silently kept. Text-bearing → a loose card with
    /// the same id (the words come back where the writer works — this is also
    /// how the writeNow crash window heals); whitespace-only → dropped quietly.
    func test_attachResurrectsTextBearingOrphansAndDropsWhitespaceOnes() throws {
        // Seed a canvas whose md carries two orphan sections — ids no node has.
        // (Write scene+scraps through CanvasStore, then append to canvas.md by
        // hand, matching the store fixture idiom.)
        …seed one real node with text "Kept."…
        …append "\n## orph\n\n   \n\n## ghst\n\nThe words survive.\n" to canvas.md…

        let model = CanvasModel()
        model.attach(projectRoot: root)

        XCTAssertEqual(model.scraps[CanvasNodeID("ghst")], "The words survive.",
            "the orphan's words are back under their own id")
        XCTAssertNotNil(model.scene.node(CanvasNodeID("ghst")),
            "and they are VISIBLE — a loose card, not invisible cruft")
        XCTAssertNil(model.scraps[CanvasNodeID("orph")],
            "a whitespace-only orphan is cruft and is dropped at load")
        // Idempotence: a second attach finds no orphans left to resurrect.
        let again = CanvasModel()
        again.attach(projectRoot: root)
        XCTAssertEqual(again.scene.unorderedNodes.count, model.scene.unorderedNodes.count,
            "resurrection is not a duplicator — the id has a node now")
    }
```

(Adapt seeding to the suite's fixture idiom; 4-char alphabet-safe id literals per tripwire 8 — `orph`/`ghst` are inside `[0-9a-hjkmnp-tv-z]`. Plain subscripts, no `?.`-chained nil assertions, per the census. Also assert the resurrected node is NOT in any region and leans like a writer's card if the node shape makes those cheap to read.)

- [ ] **Step 2: Run it — expect FAIL** (today `ghst` has no node and `orph` survives as `"   "`).

- [ ] **Step 3: Implement resurrection in `attach`**

Between `let loaded = s.load()` and the assignments: partition `loaded.scraps` keys with no `loaded.scene.node(id)` into whitespace-only (drop the key) and text-bearing (insert a loose scrap node with that id via the loose-landing idiom above, writer-seeded tilt, top z); then assign `scene`/`scraps` and `scheduleSave()` if anything changed. Keep the sidecar-absent arm honest: when `canvas.json` was missing/corrupt, `load()` returns an EMPTY scene and every scrap is technically an orphan — resurrection then rebuilds a card per scrap, which is exactly the recovery `test_deletingTheSidecar_losesLayoutButKeepsTheWords` describes prose-wise ("an empty layout with the words intact is a recoverable state") — verify that test still passes and extend it to assert the words now come back VISIBLY (nodes exist) rather than only in the dict.

- [ ] **Step 4: Run the whole suite** (`… -only-testing:MaughamTests/CanvasModelTests -only-testing:MaughamTests/CanvasStoreTests`).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasModel.swift MaughamTests/Canvas/
git commit -m "fix(canvas): orphan scraps resurrect as loose cards at load (#28 F9)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

**Considered and excluded:** pruning silently in `load()` (Denver 2026-08-12: orphans must be surfaced; a full prune could also delete the F11 crash window's surviving words); an alert/dialog surface (not Maugham's idiom — the canvas itself is the surface); resurrecting inside the undo `applySnapshot` path (snapshots capture scene+scraps together and cannot disagree).

---

### Task 4: F8 — `ownedPath` through `SafeRelativePath` at the two resolution points

**Files:**
- Modify: `Maugham/Canvas/CanvasThumbnails.swift` (`servicePending`, line ~327-329; add `import MaughamCore`)
- Modify: `Maugham/Canvas/PromotionPerformer.swift` (`assetURL`, lines ~824-828, and its callers)
- Test: `MaughamTests/Canvas/CanvasThumbnailTests.swift`; the promotion suite that covers `PromotionPerformer` (locate by content)

**Interfaces:**
- Consumes: `SafeRelativePath.resolve(_:under:)` from MaughamCore — on success returns the byte-identical URL a bare `appendingPathComponent` builds, so the change is drop-in except for the throw.
- Produces: nothing downstream; the review's other named sites (`CanvasItemFacts.resolve`, `CanvasItemPresentation.resolve`, `CanvasThumbnails.resolved/aspect`, `Promotion.swift:951`) stay unchanged BY DESIGN — they only carry the string; the two places it becomes a filesystem URL are the gates, which is the review's own fix-shape ("thumbnail + promotion resolution points").

- [ ] **Step 1: Write the failing thumbnail test**

In `CanvasThumbnailTests` (main-actor class; fixture pattern generates its image in `setUpWithError`): write a small PNG OUTSIDE the project root (sibling of the temp root), then:

```swift
    /// F8 (issue #28): an `ownedPath` is a claim about a file THIS project owns
    /// and so cannot dangle outside it (AREA.md) — until now that sentence was
    /// asserted, not enforced. A `../` escape must never reach the decoder.
    func test_anEscapingOwnedPathIsRefusedNotDecoded() async {
        let escaping = "../outside-\(UUID().uuidString.prefix(8)).png"
        // …write a valid tiny PNG at root/../<that name>…
        _ = thumbnails.resolved(escaping, in: root, fitting: 256)   // queues it
        _ = await thumbnails.servicePending()
        XCTAssertNil(thumbnails.resolved(escaping, in: root, fitting: 256),
            "the escape resolved to pixels — SafeRelativePath is not being consulted")
        XCTAssertEqual(thumbnails.decodeCount, 0,
            "the refusal must happen BEFORE the decoder ever sees the URL")
    }
```

(Adapt instrument names to the suite's existing spellings — it already reads `decodeCount`; clean up the outside file in teardown. If `decodeCount` increments per attempt rather than per decode, assert on it accordingly and say so in the test comment.)

- [ ] **Step 2: Run it — expect FAIL** (today the escape decodes fine).

- [ ] **Step 3: Gate `servicePending`**

Add `import MaughamCore` to `CanvasThumbnails.swift`. In `servicePending`, replace the URL construction:

```swift
            // F8 (issue #28): the sidecar-supplied path becomes a filesystem
            // URL exactly here — resolve it through the containment gate. A
            // hostile or corrupted `ownedPath` is cached as a failure like any
            // undecodable file: refused once, never re-queued.
            guard let url = try? SafeRelativePath.resolve(
                key.path, under: URL(fileURLWithPath: key.root)) else {
                store(nil, for: key)
                continue
            }
```

(`aspect`/`resolved` key-building stays raw-string — the memo and cache are content-free; only the decode touches disk, and it is now gated.)

- [ ] **Step 4: Gate `assetURL` in `PromotionPerformer`**

Make it throwing and let the failure surface through the performer's existing error path:

```swift
    /// The owned file, absolute. The stored path is project-relative and stays
    /// that way — see `CanvasItemReference.owned(path:)` — and this is the one
    /// place it is resolved against the project, so it is also the one place
    /// the containment gate runs (F8, issue #28).
    private func assetURL(_ picture: PromotedPicture) throws -> URL {
        try SafeRelativePath.resolve(picture.assetPath, under: store.url)
    }
```

Propagate `try` at its call sites through the performer's existing throwing/failure surface — promotion already has a loud failure path for I/O errors; a hostile path joins it. If a call site turns out to swallow errors silently, STOP and report DONE_WITH_CONCERNS naming it rather than inventing a new error surface.

- [ ] **Step 5: Write the failing promotion test, then make it pass**

In the suite covering `PromotionPerformer`: an owned item node whose `ownedPath` is `"../escape.png"` must fail the promotion loudly (assert on the performer's existing error/reporting shape), not copy the file. Follow that suite's existing fixture style.

- [ ] **Step 6: Run both suites + `swift test --parallel --package-path Packages/MaughamCore`** (consumer of the package changed usage only, but the package tests are 6s — cheap insurance).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasThumbnails.swift Maugham/Canvas/PromotionPerformer.swift MaughamTests/Canvas/
git commit -m "fix(canvas): ownedPath resolves through the containment gate (#28 F8)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: F13 — source-dimension pre-gate on thumbnail decode

**Files:**
- Modify: `Maugham/Canvas/CanvasThumbnails.swift` (`decode`, lines ~355-367 — make it `internal` for the direct test; add the cap parameter)
- Test: `MaughamTests/Canvas/CanvasThumbnailTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks (fully independent; DROPPABLE if the branch is getting heavy — the issue itself prices it lowest).
- Produces: `static func decode(_ url: URL, maxPixelSize: Int, sourcePixelCap: Int = CanvasThumbnails.sourcePixelCap) -> CGImage?` (was `private`, now `internal` so the test can exercise the cap directly — a forged-huge-header fixture cannot discriminate the gate from an ordinary decode failure).

- [ ] **Step 1: Write the failing test**

```swift
    /// F13 (issue #28): the OUTPUT is clamped by the bucket ladder, but
    /// ImageIO's peak working set while producing it is proportional to the
    /// SOURCE — a tiny-on-disk bomb claiming enormous dimensions must be
    /// refused before the thumbnailer runs. The cap is exercised directly
    /// (small cap, honest fixture) because a forged header fails to decode
    /// for other reasons and cannot discriminate the gate.
    func test_decodeRefusesASourceOverThePixelCap() {
        let url = /* the suite's existing 2400×1600 generated fixture URL */
        XCTAssertNil(CanvasThumbnails.decode(url, maxPixelSize: 256, sourcePixelCap: 1_000_000),
            "3.8MP source over a 1MP cap must refuse before decoding")
        XCTAssertNotNil(CanvasThumbnails.decode(url, maxPixelSize: 256),
            "the default cap must not refuse an ordinary photograph")
    }
```

- [ ] **Step 2: Run — expect FAIL** (no `sourcePixelCap` parameter exists; after adding the signature but before the gate, the first assertion fails).

- [ ] **Step 3: Implement the gate**

```swift
    /// No single decode may begin on a source claiming more pixels than this
    /// (F13, issue #28) — 200 MP passes any real camera or panorama and
    /// refuses the bomb class. Dimensions come from the header without
    /// decoding; a source with UNREADABLE dimensions proceeds, because the
    /// bomb must declare its size to work and the thumbnailer already fails
    /// honestly on garbage.
    static let sourcePixelCap = 200_000_000

    static func decode(_ url: URL, maxPixelSize: Int,
                       sourcePixelCap: Int = CanvasThumbnails.sourcePixelCap) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w * h > sourcePixelCap {
            return nil
        }
        // …existing options + CGImageSourceCreateThumbnailAtIndex unchanged…
    }
```

Keep `nonisolated` as it is today; the call in `servicePending` is unchanged (default parameter). Preserve the existing doc comment's content above the new paragraphs.

- [ ] **Step 4: Run the suite** (`… -only-testing:MaughamTests/CanvasThumbnailTests`).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasThumbnails.swift MaughamTests/Canvas/CanvasThumbnailTests.swift
git commit -m "fix(canvas): pre-gate thumbnail decode on claimed source dimensions (#28 F13)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Docs sweep + full gate

**Files:**
- Modify: `Maugham/Canvas/AREA.md` ("Persistence" section, ~line 672-686)

- [ ] **Step 1: Record the new invariants where the area doc states the old ones**

In the Persistence section: after the content/derived split paragraph, add one sentence stating the write ORDER and its reason (content first, so a crash gap only lags the deletable file — F11); in the `canvas_assets/`/`ownedPath` paragraph, amend "a node's `ownedPath` is project-relative" to note it is now ENFORCED at the two resolution points via `SafeRelativePath` (F8). One sentence each — AREA.md rows are load-bearing, keep them tight.

- [ ] **Step 2: Full gate**

Run: `./scripts/test.sh full` — expected green, no skips.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Canvas/AREA.md
git commit -m "docs(canvas): record the write order and the ownedPath gate (#28)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Resolved question (2026-08-12)

The issue's F9 fix-shape ("drop scraps keys with no matching scene.node") conflicted with constitution must #1 once F11 lands: the one crash window F11 leaves produces a text-bearing orphan a full prune would delete. Denver's ruling: orphans must be SURFACED on load — text-bearing orphans resurrect as loose scrap cards, whitespace-only ones drop quietly. Task 3 implements that ruling; record it on issue #28 when closing.

## Self-review notes

- All five findings have a task; ordering follows the review's own note (F11 first, F13 last/droppable).
- Sites the review names that this plan deliberately does NOT touch: `CanvasItemFacts.swift:87-104`, `CanvasItemPresentation.swift:110-129`, `CanvasThumbnails.resolved/aspect`, `Promotion.swift:951` — string carriers, not filesystem touchpoints; rationale recorded in Task 4's Interfaces block so the reviewer sees it beside the diff.
- Test-rule compliance checked: no notification posts, no `?.`-chained nil assertions, 4-char alphabet-safe id literals (`orph`, `ghst`, `s1`).
