import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **The in-place grid's read-only states** (report plan 7c Task 8, R7c-5,
/// R7c-6): the gate asked of the figure's posture through the window's door,
/// the editor's modes and the visit's host; a read-only grid selects and
/// scrolls, its bars disabled, typing answered with the reason line; the
/// gate asked again at a `figureCardVersion` edge, a mode flip and a write
/// the host refused, and whenever the figure's drawn posture changes (card
/// or no card). Keys go down the real path (`window.sendEvent`); the edge is
/// the coordinator's verb (`setFigureCardVersion`) and a posture change's
/// re-ask is awaited through its handle; no click is synthesised and nothing
/// waits on a clock.
@MainActor
final class FigureGridReadOnlyTests: FigureGridMountedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // A signed book whose root is this Mac, so another author can be admitted.
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: temp.url.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: temp.url.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: temp.url.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        FigureGridController.writeTurnForTesting = nil
        try await super.tearDown()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }

    // MARK: - Helpers

    private func press(_ m: Mounted, _ characters: String, code: UInt16 = 0) {
        m.window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: m.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    }

    private func down(_ m: Mounted) { press(m, "\u{F701}", code: 125) }

    private func documentStore(_ m: Mounted) throws -> DocumentStore {
        try XCTUnwrap(m.store.documentStore)
    }

    private func chapterId(_ m: Mounted) throws -> String {
        try XCTUnwrap(m.store.manifest.structure.first?.id)
    }

    /// Sam is admitted as the author of the chapter, so this root yields on
    /// it — its text and its figures (a figure is its piece's).
    private func samWritesTheChapter(_ m: Mounted) async throws {
        let ds = try documentStore(m)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await ds.admit(device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                               permit: .author(.pieces([try chapterId(m)])))
        await ds.postureSettled()
    }

    private func expand(_ m: Mounted) async throws -> FigureGridController {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        return try XCTUnwrap(grid.controller)
    }

    private func cellKey(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// The re-ask the last posture change scheduled, landed.
    private func reasked(_ c: FigureGridController) async {
        await c.postureChange?.value
    }

    private func edge(_ m: Mounted) {
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)
    }

    private func notices(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { seen.append(message) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    /// The bars as a read-only grid shows them: nothing that changes the
    /// figure enabled, the reason line saying `reason`.
    private func assertReadOnly(_ c: FigureGridController, _ reason: FigureGridGate.Reason,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.mode, .readOnly(reason), file: file, line: line)
        let toolbar: [NSControl] = [c.bars.formatPopUp, c.bars.fewerDecimals, c.bars.moreDecimals,
                                    c.bars.alignment, c.bars.headerRow, c.bars.totalRow, c.bars.sum]
        XCTAssertTrue(toolbar.allSatisfy { !$0.isEnabled }, "the toolbar is disabled", file: file, line: line)
        XCTAssertFalse(c.bars.formulaField.isEditable, "the formula bar is read", file: file, line: line)
        XCTAssertFalse(c.bars.nameField.isEditable, "the name follows the figure", file: file, line: line)
        XCTAssertTrue(c.bars.doneButton.isEnabled, "Done still folds", file: file, line: line)
        XCTAssertFalse(c.gridView.mayResizeColumns, file: file, line: line)
        XCTAssertEqual(c.bars.reasonMessage, reason.sentence, file: file, line: line)
    }

    private func assertEditable(_ c: FigureGridController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.mode, .editable, file: file, line: line)
        XCTAssertTrue(c.bars.formatPopUp.isEnabled, file: file, line: line)
        XCTAssertTrue(c.bars.formulaField.isEditable, file: file, line: line)
        XCTAssertTrue(c.bars.nameField.isEditable, file: file, line: line)
        XCTAssertTrue(c.gridView.mayResizeColumns, file: file, line: line)
        XCTAssertNil(c.bars.reasonMessage, file: file, line: line)
    }

    // MARK: - Review Focus 3

    /// **Review Focus 3**: a figure in a piece another author holds (the root
    /// yields to Sam) expands read-only: the arrows select and the viewport
    /// scrolls, the bars are disabled, typing writes nothing and is answered
    /// with the reason line. Trust arrives mid-visit (*Edit Anyway*): the
    /// posture change asks again — no card moved — and the grid is editable.
    func test_reviewFocus3_anotherAuthorsFigureExpandsReadOnly_trustArrivingReasks() async throws {
        let m = try await mount(rows: 40)
        try await samWritesTheChapter(m)
        let c = try await expand(m)
        XCTAssertTrue(m.window.firstResponder === c.gridView, "the grid has the keys")
        assertReadOnly(c, .notYours)

        for _ in 1...29 { down(m) }
        XCTAssertEqual(c.bars.addressLabel.stringValue, "A30", "the arrows select")
        XCTAssertGreaterThan(c.gridView.scrollOffset.y, 0, "and the viewport scrolls")

        let before = c.host.state
        press(m, "5")
        press(m, "\r", code: 36)
        press(m, "\u{7F}", code: 51)
        c.handle(.doubleClick(cellKey(c, 2, 3)))
        XCTAssertEqual(c.model.edit, .idle, "no edit opened")
        XCTAssertTrue(c.gridView.cellEditor.isHidden)
        XCTAssertEqual(c.bars.addressLabel.stringValue, "B3", "a double-click still selects its cell")
        XCTAssertTrue(m.window.firstResponder === c.gridView, "the grid keeps the keys")
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.notYours.sentence, "typing is answered")
        c.perform(.format(.currency))
        c.perform(.headerRow(true))
        c.perform(.sum)
        c.perform(.decimals(1))
        c.perform(.align(.center))
        c.perform(.name("cash"))
        c.figureGridView(c.gridView, didResizeColumn: cellKey(c, 1, 1).column, to: 200)
        await c.settleWrites()
        XCTAssertEqual(c.host.state, before, "nothing was written")
        XCTAssertEqual(c.bars.nameField.stringValue, "t")

        // Trust arrives: Edit Anyway on the piece. No card changes; the drawn
        // posture does, and the grid asks again.
        let version = m.coordinator.figureCardVersion
        try documentStore(m).overrideYield(docId: try chapterId(m))
        await reasked(c)
        XCTAssertEqual(m.coordinator.figureCardVersion, version, "no card edge")
        assertEditable(c)
        press(m, "7")
        press(m, "\r", code: 36)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cellKey(c, 2, 3)]?.content, .value(.number(7)), "now typing writes")
    }

    /// The caption follows the TEXT's membrane, the cells the figure's
    /// posture — each field disables on its own (R7c-6).
    func test_theCaptionFollowsTheTextsMembrane_theCellsTheFigures() async throws {
        let m = try await mount()
        let c = try await expand(m)
        assertEditable(c)
        XCTAssertTrue(c.bars.captionField.isEditable)

        m.coordinator.setLockEditing(true)
        XCTAssertFalse(c.bars.captionField.isEditable, "the text is locked: the caption is")
        assertEditable(c)
        let text = m.textView.string
        c.perform(.caption("Changed"))
        XCTAssertEqual(m.textView.string, text, "a caption act is refused")
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash")

        m.coordinator.setLockEditing(false)
        try await samWritesTheChapter(m)
        await reasked(c)
        assertReadOnly(c, .notYours)
        XCTAssertTrue(c.bars.captionField.isEditable, "the figure refused, the caption is still the text's")
    }

    // MARK: - Every mode

    /// The window's explicit review mode (⌘⌥⇧R) expands read-only, and
    /// leaving it gives the grid back.
    func test_explicitReviewModeIsReadOnly_flippedMidVisit() async throws {
        let m = try await mount()
        m.coordinator.setReviewMode(true)
        m.coordinator.setManualReviewMode(true)
        let c = try await expand(m)
        assertReadOnly(c, .reviewMode)
        XCTAssertFalse(c.bars.captionField.isEditable, "review mode refuses the text too")
        m.coordinator.setReviewMode(false)
        m.coordinator.setManualReviewMode(false)
        assertEditable(c)
        XCTAssertTrue(c.bars.captionField.isEditable)
        m.coordinator.setReviewMode(true)
        m.coordinator.setManualReviewMode(true)
        assertReadOnly(c, .reviewMode)
    }

    /// **⌘⌥⇧R flips the grid at once** (T8 review M3): the toggle's
    /// key-window post sets the coordinator's explicit review mode
    /// synchronously, and the open grid turns read-only — and back.
    func test_theReviewToggleFlipsAnOpenGridAtOnce() async throws {
        let m = try await mount()
        XCTAssertTrue(m.window.isKeyWindow, "premise: a .keyWindow post reaches this editor")
        let c = try await expand(m)
        assertEditable(c)
        MaughamEvent.post(.maughamToggleReviewMode, to: .keyWindow)
        XCTAssertTrue(m.coordinator.isManualReviewMode)
        assertReadOnly(c, .reviewMode)
        MaughamEvent.post(.maughamToggleReviewMode, to: .keyWindow)
        XCTAssertFalse(m.coordinator.isManualReviewMode)
        assertEditable(c)
    }

    /// **The two postures are independent** (R7c-6): a Mac that may change
    /// the figure but not the text around it — the membrane locked, review
    /// forced on by the text's posture, the window's own review mode off —
    /// gets an EDITABLE grid whose caption field is locked.
    func test_aTextRefusedButFigureAllowedMacGetsAnEditableGridWithALockedCaption() async throws {
        let m = try await mount()
        m.coordinator.setLockEditing(true)
        m.coordinator.setReviewMode(true)   // forced by the membrane, not the window's toggle
        let c = try await expand(m)
        assertEditable(c)
        XCTAssertFalse(c.bars.captionField.isEditable, "the caption is the text's")
        press(m, "8")
        press(m, "\r", code: 36)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[cellKey(c, 1, 1)]?.content, .value(.number(8)), "the cells are hers")
    }

    /// **A trust change that changes no card re-asks** (the door's epoch):
    /// Sam admitted to the chapter mid-visit turns the grid read-only with
    /// no `figureCardVersion` edge.
    func test_aTrustChangeThatChangesNoCardReasks() async throws {
        let m = try await mount()
        let c = try await expand(m)
        assertEditable(c)
        let version = m.coordinator.figureCardVersion
        try await samWritesTheChapter(m)
        await reasked(c)
        XCTAssertEqual(m.coordinator.figureCardVersion, version, "no card edge")
        assertReadOnly(c, .notYours)
    }

    /// A read-only share is read-only.
    func test_aReadOnlyShareIsReadOnly() async throws {
        let m = try await mount()
        m.coordinator.setShareIsReadOnly(true)
        let c = try await expand(m)
        assertReadOnly(c, .viewOnlyShare)
    }

    /// Translation review never expands; turning it on folds an open grid.
    func test_translationReviewDoesNotExpand_andFoldsAnOpenGrid() async throws {
        let m = try await mount()
        m.coordinator.setTranslationReview(true)
        XCTAssertFalse(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        XCTAssertNil(m.coordinator.figureGrid)
        m.coordinator.setTranslationReview(false)
        _ = try await expand(m)
        m.coordinator.setTranslationReview(true)
        XCTAssertNil(m.coordinator.figureGrid, "the grid folded")
    }

    /// A figure parked in Research expands read-only with the parked sentence.
    func test_aParkedFigureExpandsReadOnly() async throws {
        let m = try await mount()
        let figure = try XCTUnwrap(m.figure)
        _ = try await m.store.sendToResearch(figureId: figure.id, scope: .shared)
        await m.cards.idle()
        edge(m)
        let c = try await expand(m)
        assertReadOnly(c, .parked)
        XCTAssertEqual(c.bars.reasonMessage, "This table is in Research.")
    }

    // MARK: - Refused mid-visit

    /// **The host refuses a write mid-visit**: the door closed between the
    /// keystroke and the write's turn. The refusal is said, the cell shows
    /// the host's value again, and the gate — asked again — makes the grid
    /// read-only.
    func test_aWriteRefusedMidVisitIsSaid_theCellReverts_theGridTurnsReadOnly() async throws {
        let m = try await mount()
        let c = try await expand(m)
        assertEditable(c)
        let b2 = cellKey(c, 2, 2)
        FigureGridController.writeTurnForTesting = { [self] in try? await self.samWritesTheChapter(m) }
        c.handle(.click(b2, extend: false))
        let said = await notices {
            c.handle(.type("5"))
            c.handle(.returnKey(backward: false))
            await c.settleWrites()
        }
        XCTAssertEqual(said, [FigureEditRefused(site: "setCell").localizedDescription])
        XCTAssertNil(c.host.state.table[b2], "nothing written")
        XCTAssertEqual(c.figureGridDisplay(at: b2), "", "the cell shows what the host holds")
        assertReadOnly(c, .notYours)
    }

    /// The same with the figure parked under the visit: the parked sentence.
    func test_aParkMidVisitTurnsTheGridReadOnly() async throws {
        let m = try await mount()
        let c = try await expand(m)
        let figureId = c.figureId
        FigureGridController.writeTurnForTesting = { [store = m.store] in
            _ = try? await store.sendToResearch(figureId: figureId, scope: .shared)
        }
        c.handle(.click(cellKey(c, 2, 2), extend: false))
        let said = await notices {
            c.handle(.type("5"))
            c.handle(.returnKey(backward: false))
            await c.settleWrites()
        }
        XCTAssertEqual(said, ["This table is in Research."])
        XCTAssertNil(c.host.state.table[cellKey(c, 2, 2)])
        assertReadOnly(c, .parked)
    }

    /// Turning read-only over an open edit (a trust change) closes it, and
    /// the typing is said with the reason — never lost.
    func test_anEditOpenWhenTheGridTurnsReadOnlyIsSaidWithItsText() async throws {
        let m = try await mount()
        let c = try await expand(m)
        c.handle(.click(cellKey(c, 2, 2), extend: false))
        c.handle(.type("42"))
        c.handle(.editTextChanged("42"))
        let said = try await notices {
            try await samWritesTheChapter(m)
            await reasked(c)
        }
        XCTAssertEqual(said, ["Couldn't write “42” in B2 — \(FigureGridGate.Reason.notYours.sentence)"])
        XCTAssertEqual(c.model.edit, .idle)
        XCTAssertTrue(c.gridView.cellEditor.isHidden)
        assertReadOnly(c, .notYours)
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[cellKey(c, 2, 2)], "nothing written")
    }
}
