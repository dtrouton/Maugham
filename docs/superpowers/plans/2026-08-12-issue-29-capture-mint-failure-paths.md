# Issue #29 — Capture/mint failure paths (S5 residue, S6, S7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close what actually remains of issue #29: a shared rollback verb for a statement mint whose purpose failed (S5's surviving residue + S6), and idempotent inbox→canvas image ingest on retry (S7's surviving half).

**Architecture:** Research (2026-08-12) found the issue partially stale: S5's keystroke loss was fixed by issue #21 (`c2742d1f` — scope-keyed drafts, deposit-on-every-arm); S7's double-card was fixed by RULING-8/M8-IN-004 (`6955c2d8` — derived `cap-<entryId>` node id, both send arms short-circuit). What survives is one defect shape three times: **a commit that lands before the thing it was committed for can fail.** S5 residue + S6 share one new store verb ("a mint nothing was deposited into is rolled back"); S7 moves the already-on-canvas question above the asset ingest.

**Tech Stack:** Swift/XCTest, Mac scheme only. No schema changes; one register claims-file update (S7).

## Global Constraints

- Branch: `claude/issue-29-capture-mint-paths` off `main`.
- Iteration: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<Suite>`; `./scripts/test.sh full` at the end. Never touch `Maugham.xcodeproj/` or `project.yml`; no new source files planned (new code joins existing files), so no `./gen.sh` needed — if you DO add a file, run `./gen.sh` and say so.
- **Do not re-implement S5's keystroke fix.** `StatementDraftHandoffTests` (4 tests) pins it; if any of them goes red on your branch, stop and report — you have broken issue #21's fix.
- Tripwire 20/ADR 0018: no raw manuscript/statement `.md` read as truth — a statement's emptiness is asked of the op-log derivation (`statementText(of:)`-family), never `Data(contentsOf:)`; any legitimately-raw sidecar read carries `// adr-0018-ok: <reason>`.
- Tripwire 32: `CanvasCapture` is one of the seven undo-bracket census entries — its writes stay on `mutateFromInspector`; the new query seam must not add a write path. Do not add a second spelling of `CanvasClaudeWrite.liveModel`'s discriminator — call it.
- The canvas-asset well's directory name is census-guarded (`test_theCanvasAssetWellIsDerivedAndNeverSpelledInCode`): neither production nor test code spells `canvas_assets` — derive the directory from an ingested path.
- Tripwires 17/24 in tests: build inbox manifest URLs via `InboxManifest.inboxManifestURL(forDeviceSlug: DeviceSlug.make(from:), in:)`; never seal or hand-build.
- Statement ids/paths: `createStatement` is find-or-create — every rollback decision keys off whether THIS call minted (ask `statement(kind:scope:)` first), never off the returned value.
- House test style: control assertions inside the same test; failure messages state the defect in prose; sabotage levers are the suites' existing idioms (directory-at-manifest-path from `InboxToCanvasTests`, file-where-assets-dir-must-go for `createDirectory` throws, `sabotageAppends`/`healAppends` from `InboxCharacterization`).

---

### Task 1: The rollback verb — `ProjectStore.rollbackUnusedStatement`

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Statements.swift` (beside `createStatement`, lines ~205-237)
- Test: `MaughamTests/StatementImageIngestTests.swift` (same fixture family; or a sibling suite if the implementer finds a cleaner home — say which)

**Interfaces:**
- Produces: `@discardableResult public func rollbackUnusedStatement(_ statement: Statement) async -> Bool` — Tasks 2 and 3 call it. Returns whether it rolled back; refusal is a normal answer, not an error.
- Consumes (all exist on the store today — verify spellings, do not redesign): `statement(kind:scope:)`, `statementText(of:)`, `openStatementDocument(id:)`, `lockStatementOpen`/`unlockStatementOpen`, `saveManifest()`, `manifest.statements`.

- [ ] **Step 1: Write the failing tests**

Three behaviors, three tests, in the ingest suite's fixture style:

```swift
    /// Issue #29 (S5 residue + S6): `createStatement` commits a file and a
    /// manifest row before the thing it was minted for can fail. The rollback
    /// undoes exactly that — and ONLY that: it refuses a statement with words,
    /// because it exists for the mint-then-fail window and a caller reaching
    /// for it any later is wrong.
    func test_rollbackRemovesAFreshlyMintedEmptyStatement() async throws {
        let fixture = try await fixture(named: "RollbackFresh")
        let minted = try await fixture.store.createStatement(kind: .visualLanguage, scope: .project)
        let rolled = await fixture.store.rollbackUnusedStatement(minted)
        XCTAssertTrue(rolled, "an empty scaffold nothing was deposited into rolls back")
        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
            "the manifest row is gone — the writer's visual language is undeclared again")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.projectURL.appendingPathComponent(minted.path).path),
            "and the empty file with it")
    }

    func test_rollbackRefusesAStatementThatHasWords() async throws {
        let fixture = try await fixture(named: "RollbackRefuses")
        let minted = try await fixture.store.createStatement(kind: .intent, scope: .project)
        try await fixture.store.appendToStatement(minted, text: "The writer's own intent.")
        let rolled = await fixture.store.rollbackUnusedStatement(minted)
        XCTAssertFalse(rolled, "words mean the mint was USED — rollback must refuse")
        XCTAssertNotNil(fixture.store.statement(kind: .intent, scope: .project),
            "the statement and its words are untouched")
    }

    func test_rollbackRefusesWhileTheStatementIsOpen() async throws {
        let fixture = try await fixture(named: "RollbackOpen")
        let minted = try await fixture.store.createStatement(kind: .intent, scope: .project)
        // Open it the way production does, then try to roll it back.
        let doc = try await fixture.store.openStatementDocument(… /* the suite's open idiom */)
        let rolled = await fixture.store.rollbackUnusedStatement(minted)
        XCTAssertFalse(rolled, "an OPEN statement is in use whatever its text says")
        …close doc…
    }
```

(Adapt `appendToStatement`/open idioms to the real signatures — both exist on the store surface. Do not weaken the three behaviors.)

- [ ] **Step 2: Run — expect FAIL** (`rollbackUnusedStatement` does not exist).

- [ ] **Step 3: Implement**

```swift
    /// Undo one `createStatement` whose purpose failed before anything reached
    /// it (issue #29: an image save that threw, a superseded mint nothing was
    /// deposited into). `createStatement` commits exactly two things — an empty
    /// file and a manifest row — and this removes exactly those two, manifest
    /// FIRST: a row pointing at a missing file is a dangle every reader hits,
    /// while a stray empty file with no row is inert.
    ///
    /// REFUSES — returning false, because refusal is a normal answer on a
    /// failure path, not a second failure — when the statement is open, when
    /// its op-log derivation has words, or when the manifest no longer knows
    /// it. The emptiness question is asked of the DERIVATION, never a raw read
    /// of the `.md` (tripwire 20): the op log is the record of whether any
    /// deposit ever landed.
    @discardableResult
    public func rollbackUnusedStatement(_ statement: Statement) async -> Bool {
        await lockStatementOpen(statement.id)
        defer { unlockStatementOpen(statement.id) }
        guard openStatementDocument(id: statement.id) == nil else { return false }
        guard let derived = try? statementText(of: statement),
              derived.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let row = manifest.statements.firstIndex(where: { $0.id == statement.id }) else { return false }
        manifest.statements.remove(at: row)
        manifest.modified = Date()
        do { try await saveManifest() } catch {
            // The row could not be dropped: put it back and refuse — deleting
            // the file under a live row would be the dangle this order avoids.
            manifest.statements.insert(statement, at: row)
            return false
        }
        try? FileManager.default.removeItem(at: url.appendingPathComponent(statement.path))
        return true
    }
```

(Adapt exact spellings — `statementText(of:)`'s parameter, whether `lockStatementOpen` is async — to the file; the ORDER and the three refusals are the requirements. If `statementText` cannot answer for a never-opened scaffold, use whatever the store's derivation path for a closed statement is; do not fall back to a raw read without an `// adr-0018-ok:` reason.)

- [ ] **Step 4: Run the three tests (PASS) + the whole suite** (`… -only-testing:MaughamTests/StatementImageIngestTests`).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore+Statements.swift MaughamTests/
git commit -m "feat(statements): rollback verb for a mint nothing was deposited into (#29)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: S6 — both image-ingest arms leave nothing behind

**Files:**
- Modify: `Maugham/Stores/ProjectStore+StatementAssets.swift` (NSImage arm lines ~35-54, fileURL arm ~71-95)
- Modify: `Maugham/Editor/ImagePasteHandler.swift` (split `saveAndReference` into encode + write halves)
- Test: `MaughamTests/StatementImageIngestTests.swift`

**Interfaces:**
- Consumes: Task 1's `rollbackUnusedStatement(_:) async -> Bool`.
- Produces: `ImagePasteHandler.encodePNG(_ image: NSImage) throws -> Data` and a data-writing sibling of `saveAndReference` (e.g. `saveAndReferenceData(_ data: Data, ext: String, forNoteAt:in:) throws -> String`) — `saveAndReference(image:forNoteAt:in:)` becomes a two-line composition of them, so the saver census (`test_theSharedImageSaverIsCalledFromTheSeamsThatOwnAWell`) sees the same files calling the same family.

- [ ] **Step 1: Write the failing tests**

Twin of the existing `test_aTextFileIsRefusedOnItsWayIntoVisualLanguage` (which pins the fileURL arm's leaves-nothing-behind), for each surviving hole:

```swift
    /// S6 (issue #29): the NSImage arm minted the statement BEFORE the save
    /// could fail. An unencodable bitmap must refuse with nothing behind —
    /// not even the empty statement it would have gone into.
    func test_anUnencodableImageLeavesNoStatementBehind() async throws {
        let fixture = try await fixture(named: "VisualLanguageUnencodable")
        do {
            _ = try await fixture.store.addImage(
                toStatement: .visualLanguage, scope: .project, image: NSImage())
            XCTFail("a zero-size NSImage has no bitmap to encode")
        } catch {}
        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
            "a refused picture leaves nothing behind — not even the statement")
    }

    /// The disk-failure case, both arms: plant a regular FILE where the assets
    /// DIRECTORY must go, so `createDirectory` throws after the mint; the
    /// rollback must clean up. (The planted path is predictable in a fresh
    /// project via the statement convention — read it off the CONTROL ingest
    /// in a sibling project, or compute it the way the existing well() helper
    /// does; do not hardcode a spelling the convention owns.)
    func test_aDiskFailureAfterTheMintRollsTheStatementBack() async throws { … }

    /// And the guard that makes rollback safe under find-or-create: a save
    /// failure on a SECOND picture must NOT delete the writer's existing
    /// statement — this call did not mint it.
    func test_aSaveFailureOnASecondPictureKeepsTheExistingStatement() async throws { … }
```

Write all three in full (the `…` bodies follow the suite's fixture + `well(beside:in:)` helpers and the plant/heal idiom); the assertions named in the doc comments are the requirements.

- [ ] **Step 2: Run — expect FAIL** (NSImage arm mints first; no rollback anywhere).

- [ ] **Step 3: Implement**

NSImage arm — encode hoisted above the mint (structurally matching the fileURL arm's validate-first), rollback on the residual write failure:

```swift
    public func addImage(
        toStatement kind: Statement.Kind, scope: Statement.Scope, image: NSImage
    ) async throws -> StatementPicture {
        // Encode FIRST (S6, issue #29): a bitmap that cannot re-encode refuses
        // before anything exists to leave behind — the fileURL arm's ordering.
        let png = try ImagePasteHandler.encodePNG(image)
        let mintedHere = statement(kind: kind, scope: scope) == nil
        let statement = try await createStatement(kind: kind, scope: scope)
        do {
            return StatementPicture(statement: statement,
                ref: try ImagePasteHandler.saveAndReferenceData(
                    png, ext: "png", forNoteAt: statement.path, in: url))
        } catch {
            // The disk said no AFTER the mint: a refused ingest leaves nothing
            // behind. Only the statement THIS call minted — find-or-create
            // means a found one is the writer's existing declaration.
            if mintedHere { await rollbackUnusedStatement(statement) }
            throw error
        }
    }
```

fileURL arm: same `mintedHere`/`do-catch` bracket around `saveAndReferenceFile` (its `copyItem` can throw after the mint), and its doc comment stops overselling: "Validated before the statement is minted" gains "…and a save that fails after it rolls the mint back, so the guarantee holds for the disk's refusals too."

`ImagePasteHandler`: extract the existing tiff→bitmap→png block into `encodePNG` (throws `.encodingFailed`), the `destination`+write block into `saveAndReferenceData`; `saveAndReference(image:…)` composes them so every existing caller is untouched.

- [ ] **Step 4: Run the whole suite** (`… -only-testing:MaughamTests/StatementImageIngestTests`) — the nine existing tests are the regression net for the refactor (`test_pastingIntoAVisualLanguageThatDoesNotExistYetMintsIt` especially: rollback must not fire on success paths).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/ProjectStore+StatementAssets.swift Maugham/Editor/ImagePasteHandler.swift MaughamTests/
git commit -m "fix(statements): image ingest leaves nothing behind on failure (#29 S6)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: S5 residue — a mint that neither bound nor deposited rolls back

**Files:**
- Modify: `Maugham/Views/StatementEditorHost.swift` (`mintAndBind`, lines ~716-730)
- Test: `MaughamTests/StatementDraftHandoffTests.swift` (same fixture; the wedge idiom)

**Interfaces:**
- Consumes: Task 1's `rollbackUnusedStatement`; the host's existing `target.hasWordsWaiting(for:)`, `store.statement(kind:scope:)`.
- Produces: nothing new downstream.

**Scope note (bounded deliberately):** issue #21 fixed the keystroke loss; the surviving residue is the spurious EMPTY statement when a mint's load ends with nothing delivered — (a) superseded load whose deposit had nothing to deposit (type-then-backspace, then switch scope), (b) `Document.load` throwing after the mint. A statement whose editor actually BOUND and was later left empty is NOT in scope: the writer visited it, and `exists:true / markdown:""` is then honest. This is the issue's own "refuse the empty create" fix-shape, one commit later.

- [ ] **Step 1: Write the failing test**

In the handoff suite's wedge idiom (park the mint on `lockStatementOpen`, assert it is parked, move the writer away, release):

```swift
    /// S5 residue (issue #29): issue #21 made a superseded mint DELIVER waiting
    /// words. When there are none to deliver — one keystroke, then backspace,
    /// then a scope switch, all mid-mint — the mint used to leave an empty
    /// statement declaring an intent nobody stated. It now rolls back.
    func test_aSupersededMintWithNothingToDepositLeavesNoStatement() async throws {
        …fixture, settable selection, precondition: no intent for the chapter…
        …park the mint's load on the production gate (create the statement it
           will find, lock it), type "x", assert parked…
        …backspace: type("") so the waiting words become empty…
        …move the selection away, release the gate, pump until settled…

        XCTAssertNil(fixture.store.statement(kind: .intent, scope: .document(docId)),
            "a mint that neither bound nor deposited leaves nothing — no empty "
            + "intent.md declaring an intent nobody stated")
    }
```

CAREFUL with the wedge: the existing tests pre-create the statement to have something to lock — which makes `mintedHere` false and rollback refuse. The test must wedge WITHOUT pre-creating (lock the id the mint WILL get — if the fixture cannot know it, wedge on a different production gate, or extend the fixture minimally and say so in your report). If after an honest attempt the interleaving cannot be staged deterministically, STOP and report the obstacle rather than shipping a test that asserts nothing — the reviewer gate treats a non-discriminating test as a defect.

- [ ] **Step 2: Run — expect FAIL** (the empty statement survives today).

- [ ] **Step 3: Implement**

In `mintAndBind`'s task, capture `mintedHere` before the create and roll back after an unbound, undeposited load:

```swift
            do {
                let mintedHere = store.statement(kind: kind, scope: scope) == nil
                let created = try await store.createStatement(kind: kind, scope: scope)
                let bound = await load(created, for: wanted)
                // S5 residue (issue #29): unbound and nothing waiting means
                // nothing was ever deposited — the superseded arm deposits
                // BEFORE returning false, and a deposit makes the rollback
                // verb refuse on derived words, so this cannot eat a delivery.
                // Words still waiting keep the statement: their retry mint
                // collects them into it.
                if !bound, mintedHere, !target.hasWordsWaiting(for: wanted) {
                    await store.rollbackUnusedStatement(created)
                }
            } catch { …existing logging… }
```

- [ ] **Step 4: Run the WHOLE handoff suite + `StatementEditorMountTests` + `StatementPaneTests`** — all four #21 pins must stay green; a red pin means stop, not adjust.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/StatementEditorHost.swift MaughamTests/StatementDraftHandoffTests.swift
git commit -m "fix(statements): a mint that neither bound nor deposited rolls back (#29 S5)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: S7 — the already-on-canvas question moves above the ingest

**Files:**
- Modify: `Maugham/Canvas/CanvasCapture.swift` (factor `nodeID(forCapture:)`; add the query seam)
- Modify: `Maugham/Stores/InboxStore.swift` (`sendToCanvas` image arm, lines ~475-494)
- Modify: `Maugham/Stores/AREA.md` (line ~174) — same commit, workflow rule 10
- Modify: `register/reconciliation/Inbox.claims.json` — extend M8-IN-004's statement (or add a sibling claim) to cover the ASSET converging too, citing this fix's commit
- Test: `MaughamTests/Stores/InboxToCanvasTests.swift`

**Interfaces:**
- Consumes: `CanvasClaudeWrite.liveModel(of:)` (called, never re-spelled); `CanvasStore.load()`.
- Produces: `CanvasCapture.nodeID(forCapture: String) -> CanvasNodeID` (used by `plan` and the query) and `CanvasCapture.existingNode(forCapture: String, store: ProjectStore, projectRoot: URL) -> CanvasNodeID?` — a READ-ONLY seam; it must not write (tripwire 32's census counts write verbs).

- [ ] **Step 1: Write the failing test**

The image twin of `test_aRetryAfterAFailedFlipLandsOnTheSameCard` (a `.text` capture — which is exactly why the image arm's duplicate ingest slipped through):

```swift
    /// S7 (issue #29): RULING-8 made the retry land on the same CARD
    /// (M8-IN-004) — but the image arm still re-ran the ingest first, so every
    /// retry stranded another copy in the well that no node will ever
    /// reference. The retry now converges on the FILE too.
    func test_anImageRetryAfterAFailedFlipDoesNotIngestASecondCopy() async throws {
        let f = try await openProject("ImageRetryConverge")
        let model = attached(f)
        _ = try seedImageAsset(f, name: "p7.png")
        try await seed(f, [/* photoEntry("p7", filename: "p7.png") seeded into the manifest */])
        let entry = try XCTUnwrap(f.inbox.entries.first { $0.id == "p7" })

        …sabotage the flip (directory-at-manifest-path idiom from the sibling
           test), send, XCTFail-if-no-throw, heal, refresh…
        let retryEntry = try XCTUnwrap(f.inbox.entries.first { $0.id == "p7" })
        let node = try await f.inbox.sendToCanvas(
            retryEntry, projectStore: f.store, placement: .loose)

        // The well is derived from the node's own path — its directory name is
        // census-guarded and never spelled.
        let (scene, _) = CanvasStore(projectRoot: f.url).load()
        guard case .item(.owned(let ownedPath)) = try XCTUnwrap(scene.node(node)).kind else {
            return XCTFail("the capture's card is not an owned item")
        }
        let well = f.url.appendingPathComponent(ownedPath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: well.path)
        XCTAssertEqual(files.count, 1,
            "one capture, one file — the retry converged on the asset as well "
            + "as the card; a second copy would be referenced by nothing, "
            + "invisible forever")
        XCTAssertEqual(scene.count, 1, "control: and still one card (M8-IN-004)")
    }
```

- [ ] **Step 2: Run — expect FAIL** (two files in the well today).

- [ ] **Step 3: Implement**

`CanvasCapture` — factor the derived id (both `plan` and the query call it; one spelling of `"cap-"`):

```swift
    /// The capture's node id, DERIVED from the entry (RULING-8, M8-IN-004) —
    /// the one spelling, shared by the planner and the pre-ingest query.
    static func nodeID(forCapture captureID: String) -> CanvasNodeID {
        CanvasNodeID("cap-" + captureID)
    }

    /// Is this capture already on the canvas? Asked BEFORE the asset ingest so
    /// a retry after a failed status flip re-copies nothing (S7, issue #29).
    /// Read-only; the same liveModel discriminator `send` uses, one call
    /// earlier — never a second spelling of it.
    static func existingNode(forCapture captureID: String,
                             store: ProjectStore, projectRoot: URL) -> CanvasNodeID? {
        let id = nodeID(forCapture: captureID)
        if let model = CanvasClaudeWrite.liveModel(of: store) {
            return model.scene.node(id) != nil ? id : nil
        }
        return CanvasStore(projectRoot: projectRoot).load().scene.node(id) != nil ? id : nil
    }
```

`InboxStore.sendToCanvas` image arm, before the ingest:

```swift
        case .image:
            guard let asset = assetURL(for: entry),
                  FileManager.default.fileExists(atPath: asset.path) else {
                throw InboxError.assetMissing(entry.sourceFilename ?? entry.id)
            }
            // S7 (issue #29): the previous attempt's copy AND card both landed;
            // only the flip failed. Retry the flip alone — re-running the
            // ingest strands a second copy in the well that no node will ever
            // reference. (The text arms need no twin: their send is already
            // side-effect-free before the short-circuit.)
            if let existing = CanvasCapture.existingNode(
                forCapture: entry.id, store: projectStore, projectRoot: projectStore.url) {
                try await updateStatusThrowing(id: entry.id, to: .promoted)
                await trashPromotedAsset(asset, entry: entry, projectStore: projectStore)
                return existing
            }
            content = .picture(path: try await projectStore.ingestCanvasAsset(fileURL: asset))
            originalToRemove = asset
```

`plan`'s hand-built `CanvasNodeID("cap-" + captureID)` switches to `nodeID(forCapture:)`.

Docs in the same commit: `Maugham/Stores/AREA.md:174`'s "a flip that fails … a retry re-copies — a recoverable duplicate" sentence now says the retry converges (asks the canvas before re-copying); `register/reconciliation/Inbox.claims.json` M8-IN-004 gains the asset half (statement + source ref to the new test). Frame it as RULING-8 retry convergence — the palette sibling's answer to the same writer question — NOT as a new deduplication policy (the register's sweep2 history explicitly warns the ruling set has no accumulation vocabulary).

- [ ] **Step 4: Run** `… -only-testing:MaughamTests/InboxToCanvasTests -only-testing:MaughamTests/Claims/InboxCharacterization` (the claims suite is a permanent resident — a red row means the register must move too, and this fix should leave every existing row green).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasCapture.swift Maugham/Stores/InboxStore.swift Maugham/Stores/AREA.md register/reconciliation/Inbox.claims.json MaughamTests/
git commit -m "fix(inbox): image retry converges on the asset as well as the card (#29 S7)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Docs + full gate

**Files:**
- Modify: `Maugham/Stores/AREA.md` (statement-well cell, ~lines 97-101)

- [ ] **Step 1:** Add one sentence to the statement-well cell: the ingest pair now leaves nothing behind on failure — encode-first plus `rollbackUnusedStatement` for the mint-then-fail window (issue #29). Sweep the S6 fileURL doc-comment claim landed in Task 2 for agreement.
- [ ] **Step 2:** Run `./scripts/test.sh full` — green, no skips.
- [ ] **Step 3:** Commit:

```bash
git add Maugham/Stores/AREA.md
git commit -m "docs(stores): record the mint rollback and retry convergence (#29)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- Issue coverage vs reality: S5's keystroke half is FIXED (issue #21) and deliberately not re-implemented — Task 3 takes only the surviving empty-statement residue via the issue's own "refuse the empty create" fix-shape; S6 fully covered (Task 2, both arms — the fileURL arm's `copyItem` residue included, which the sweep did not name but its doc-comment contract implies); S7's card half is FIXED (RULING-8) — Task 4 takes the surviving asset half. Close-out comment on #29 should state both stale halves with the fixing commits (`c2742d1f`, `6955c2d8`).
- Type consistency: `rollbackUnusedStatement(_:) async -> Bool` is spelled identically in Tasks 1, 2, 3; `nodeID(forCapture:)`/`existingNode(forCapture:store:projectRoot:)` in Task 4 only.
- Register discipline: the claims file moves in the same commit as the behavior (Task 4), per the register section of CLAUDE.md.
