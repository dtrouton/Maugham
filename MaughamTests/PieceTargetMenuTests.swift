import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **The open piece's target, on the status line** (shell p3 Task 8): what the
/// right label offers for each project and posture, what a clear stores, and
/// that the line still fits the narrowest editor. Nothing is pressed
/// (tripwire 33).
@MainActor
final class PieceTargetMenuTests: XCTestCase {

    private let author: (String) -> Posture = { _ in .author }
    private let settling: (String) -> Posture = { _ in .settling }

    private func doc(_ id: String, path: String, wordTarget: Int? = nil,
                     pageTarget: Int? = nil, kind: PieceKind? = nil) -> StructureItem {
        var item = StructureItem(id: id, title: id, type: .document, path: path)
        item.wordTarget = wordTarget
        item.pageTarget = pageTarget
        item.pieceKind = kind
        return item
    }

    func test_theFooterOffersAWordTargetForProseAndAPageTargetForAScript() {
        // A novel's chapter: its own word target.
        let chapter = doc("ch01", path: "manuscript/ch01.md", wordTarget: 2000)
        let novel = PieceTargetMenu.decide(piece: chapter, projectType: .novel,
                                           projectPageTarget: nil, postureOf: author)
        XCTAssertEqual(novel, PieceTargetMenu(write: .pieceWords("ch01"), current: 2000))
        XCTAssertEqual(novel?.setTitle, "Set Word Target…")
        XCTAssertEqual(novel?.range, 0...100_000)
        XCTAssertEqual(novel?.step, 100)
        XCTAssertEqual(novel?.offersClear, true)

        // A screenplay: the PROJECT's page target, InspectorView's 0…500 by 5.
        let script = doc("scr1", path: "script.fountain")
        let screenplay = PieceTargetMenu.decide(piece: script, projectType: .screenplay,
                                                projectPageTarget: 110, postureOf: author)
        XCTAssertEqual(screenplay, PieceTargetMenu(write: .projectPages, current: 110))
        XCTAssertEqual(screenplay?.setTitle, "Set Page Target…")
        XCTAssertEqual(screenplay?.step, 5)

        // A Collection: by the piece's own path; a script piece's page target
        // is its own, PieceInspector's 0…500 by 1.
        let scriptPiece = doc("pc01", path: "pieces/one/one.fountain", pageTarget: 30, kind: .loose)
        let collScript = PieceTargetMenu.decide(piece: scriptPiece, projectType: .collection,
                                                projectPageTarget: nil, postureOf: author)
        XCTAssertEqual(collScript, PieceTargetMenu(write: .piecePages("pc01"), current: 30))
        XCTAssertEqual(collScript?.step, 1)
        let prosePiece = doc("pc02", path: "pieces/two/two.md", kind: .loose)
        let collProse = PieceTargetMenu.decide(piece: prosePiece, projectType: .collection,
                                               projectPageTarget: nil, postureOf: author)
        XCTAssertEqual(collProse, PieceTargetMenu(write: .pieceWords("pc02"), current: nil))
        XCTAssertEqual(collProse?.offersClear, false, "no target: nothing to clear")

        // A reference piece has no target (the goal indicator hides for one),
        // nor does a group or nothing open.
        let reference = doc("ref1", path: "pieces/r/r.md", kind: .reference)
        XCTAssertNil(PieceTargetMenu.decide(piece: reference, projectType: .collection,
                                            projectPageTarget: nil, postureOf: author))
        let group = StructureItem(id: "grp1", title: "Part", type: .group, path: nil)
        XCTAssertNil(PieceTargetMenu.decide(piece: group, projectType: .novel,
                                            projectPageTarget: nil, postureOf: author))
        XCTAssertNil(PieceTargetMenu.decide(piece: nil, projectType: .novel,
                                            projectPageTarget: nil, postureOf: author))
    }

    /// Hidden, never disabled: a posture that may not restructure the piece
    /// (or, for a screenplay's project target, the project) gets the plain
    /// label.
    func test_aRefusingPostureOffersNoTargetMenu() {
        let chapter = doc("ch01", path: "manuscript/ch01.md", wordTarget: 2000)
        XCTAssertNil(PieceTargetMenu.decide(piece: chapter, projectType: .novel,
                                            projectPageTarget: nil, postureOf: settling))
        XCTAssertNil(PieceTargetMenu.decide(piece: doc("scr1", path: "script.fountain"),
                                            projectType: .screenplay, projectPageTarget: 90,
                                            postureOf: settling))
        // A posture that may restructure the piece but not the project stream:
        // the chapter's own target is offered, a screenplay's project one not.
        let pieceOnly: (String) -> Posture = { id in
            id == DocumentClass.projectStreamDocId ? .settling : .author
        }
        XCTAssertNotNil(PieceTargetMenu.decide(piece: chapter, projectType: .novel,
                                               projectPageTarget: nil, postureOf: pieceOnly))
        XCTAssertNil(PieceTargetMenu.decide(piece: doc("scr1", path: "script.fountain"),
                                            projectType: .screenplay, projectPageTarget: 90,
                                            postureOf: pieceOnly))
    }

    /// Set writes the inspector's store call; Clear writes 0, which the store
    /// keeps as nil (`updateInspector`'s and `updateProjectTargets`' rule).
    func test_clearingATargetStoresNil() async throws {
        let dir = TestTemp.root.appendingPathComponent("PieceTarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await ProjectFactory.createNovelProject(named: "Targets", in: dir)
        let store = try await ProjectStore.load(from: url)
        let chapter = try XCTUnwrap(TreeWalk.collect(
            in: store.manifest.structure, where: { $0.type == .document }).first)

        try await PieceTargetMenu.perform(.pieceWords(chapter.id), value: 2000, store: store)
        XCTAssertEqual(TreeWalk.find(id: chapter.id, in: store.manifest.structure)?.wordTarget, 2000)
        try await PieceTargetMenu.perform(.pieceWords(chapter.id), value: 0, store: store)
        XCTAssertNil(TreeWalk.find(id: chapter.id, in: store.manifest.structure)?.wordTarget)

        try await PieceTargetMenu.perform(.piecePages(chapter.id), value: 12, store: store)
        XCTAssertEqual(TreeWalk.find(id: chapter.id, in: store.manifest.structure)?.pageTarget, 12)
        try await PieceTargetMenu.perform(.piecePages(chapter.id), value: 0, store: store)
        XCTAssertNil(TreeWalk.find(id: chapter.id, in: store.manifest.structure)?.pageTarget)

        try await PieceTargetMenu.perform(.projectPages, value: 100, store: store)
        XCTAssertEqual(store.manifest.targets?.pageTarget, 100)
        try await PieceTargetMenu.perform(.projectPages, value: 0, store: store)
        XCTAssertNil(store.manifest.targets?.pageTarget)

        XCTAssertEqual(PieceTargetMenu(write: .pieceWords("x"), current: nil).clamped(250_000), 100_000)
        XCTAssertEqual(PieceTargetMenu(write: .projectPages, current: nil).clamped(-3), 0)
    }

    // MARK: - The field: what a commit writes (Task 8's review)

    private let words = PieceTargetMenu(write: .pieceWords("ch01"), current: 2000)

    /// What the writer typed, as a number — or nothing, quietly.
    func test_theFieldParsesDigitsAndRefusesEverythingElse() {
        XCTAssertEqual(PieceTargetMenu.parse("3000"), 3000)
        XCTAssertEqual(PieceTargetMenu.parse("  3000 \n"), 3000)
        XCTAssertEqual(PieceTargetMenu.parse("3,000"), 3000)
        XCTAssertEqual(PieceTargetMenu.parse("3 000"), 3000)
        XCTAssertEqual(PieceTargetMenu.parse("3\u{202F}000"), 3000)
        XCTAssertEqual(PieceTargetMenu.parse("3'000", groupingSeparator: "'"), 3000,
                       "the locale's own grouping mark")
        XCTAssertEqual(PieceTargetMenu.parse("0"), 0)
        for refused in ["", "   ", "abc", "3k", "-5", "+5", "3.5", "1e3", "٣٠٠٠", "3000 words"] {
            XCTAssertNil(PieceTargetMenu.parse(refused), "\"\(refused)\" is not a target")
        }
        XCTAssertNil(PieceTargetMenu.parse("3.500", groupingSeparator: "."),
                     "a point is never read as a grouping mark: 3.5 must not become 35")
    }

    /// Set, Return and losing focus all ask this one decision: the typed
    /// value, clamped — and nothing where it does not parse or is the target
    /// already standing.
    func test_aCommitWritesTheTypedValueOnceAndRefusesTheUnparseable() {
        // Review Important 2: typed digits, then Set — the TYPED value.
        XCTAssertEqual(words.commitValue(text: "3000"), 3000)
        XCTAssertEqual(words.commitValue(text: "250000"), 100_000, "clamped to the range")
        XCTAssertEqual(words.commitValue(text: "0"), 0, "zero clears (the store stores nil)")
        // Unparseable: refused quietly, the stored target stands.
        XCTAssertNil(words.commitValue(text: "lots"))
        XCTAssertNil(words.commitValue(text: ""))
        // Unchanged: no write.
        XCTAssertNil(words.commitValue(text: "2000"))
        XCTAssertNil(words.commitValue(text: "2,000"))
        // The three commits of one edit (Set, then the focus loss, then the
        // popover's disappearance) write once.
        XCTAssertEqual(words.commitValue(text: "3000", lastWritten: nil), 3000)
        XCTAssertNil(words.commitValue(text: "3000", lastWritten: 3000))
        // …and a second edit after it writes again, back to the stored value
        // included.
        XCTAssertEqual(words.commitValue(text: "2000", lastWritten: 3000), 2000)
        // Escape cancels: nothing is written, whatever was typed.
        XCTAssertNil(words.commitValue(text: "3000", cancelled: true))
        XCTAssertNil(words.commitValue(text: "0", lastWritten: 3000, cancelled: true))
        // No target yet: 0 is what stands.
        let none = PieceTargetMenu(write: .piecePages("pc01"), current: nil)
        XCTAssertNil(none.commitValue(text: "0"))
        XCTAssertEqual(none.commitValue(text: "120"), 120)
        XCTAssertEqual(none.commitValue(text: "900"), 500)
    }

    /// The field is `String`-backed and commits on Set, Return, focus loss and
    /// its own disappearance (a popover dismissed by a click outside); the
    /// status line closes an open popover when the open piece changes, and
    /// keys the field by its target so an edit is never carried across.
    func test_theFieldCommitsOnEveryWayOutAndNeverRetargets() throws {
        let field = try SourceTree.sourceOfType("PieceTargetField", under: ["Maugham"])
        let code = SourceScan.codeLines(of: field).joined(separator: "\n")
        XCTAssertFalse(code.contains("TextField(\"\", value:"),
                       "a value-bound field commits only on Return or focus loss: Set would "
                       + "write the number from before the edit")
        for token in ["TextField(\"\", text: $text)", ".onSubmit { commit(); onDone() }",
                      "Button(\"Set\") { commit(); onDone() }",
                      "if !isFocused { commit() }", ".onDisappear {", "escapeNote.start()",
                      "cancelled: cancelled || escapeNote.pressed)",
                      ".onExitCommand { cancel() }", "cancelled = true",
                      "menu.commitValue(text: text, lastWritten: lastWritten,"] {
            XCTAssertTrue(code.contains(token), "the field lost \(token)")
        }
        let footer = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/EditorStatusFooter.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(footer.contains(".id(target.write)"), "one field per target")
        XCTAssertTrue(footer.contains(".onChange(of: target.write) { _, _ in editingTarget = false }"),
                      "a piece change closes the open popover")
    }

    /// **The status line stays calm**: with no target the right label is what
    /// it was, and the footer takes the menu only where one is offered.
    func test_withNoTargetTheStatusLineSaysWhatItSaidBefore() throws {
        let state = GoalIndicatorState(docWordCount: 1240, wordsToday: 40, readingMinutes: 5)
        XCTAssertEqual(EditorStatusFooter.rightLabel(for: state),
                       "1,240 words · 5 min read · today: 40")
        var targeted = state
        targeted.docWordTarget = 2000
        XCTAssertTrue(EditorStatusFooter.rightLabel(for: targeted).hasPrefix("1,240 / 2,000 words"))
        let code = try SourceTree.read("Maugham/Views/EditorStatusFooter.swift")
        XCTAssertTrue(code.contains("if let target, let store {"),
                      "the menu is drawn only where a target menu is offered")
        XCTAssertTrue(code.contains(".menuIndicator(.hidden)"),
                      "no chevron on the status line")
    }

    /// **A measurement** (allow-listed shape, tripwire 33): the footer with a
    /// target menu and a long label fits the narrowest editor on one line.
    func test_theStatusLineWithATargetFitsTheNarrowEditor() async throws {
        let dir = TestTemp.root.appendingPathComponent("PieceTargetFit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await ProjectFactory.createNovelProject(named: "Fit", in: dir)
        let store = try await ProjectStore.load(from: url)
        let goal = GoalIndicatorState(docWordCount: 123_456, docWordTarget: 100_000,
                                      wordsToday: 12_345, readingMinutes: 600)
        func footer(_ target: PieceTargetMenu?) -> some View {
            EditorStatusFooter(
                goalState: goal, sessionWords: 12_345, sessionStart: Date(),
                paragraphId: "ab12", elementLabel: "Dialogue",
                target: target, store: store)
        }
        let width = ProjectWindow.centreColumnFloor
        let plain = NSHostingController(rootView: footer(nil))
            .sizeThatFits(in: CGSize(width: width, height: 200))
        let menu = NSHostingController(rootView: footer(
            PieceTargetMenu(write: .pieceWords("ch01"), current: 100_000)))
            .sizeThatFits(in: CGSize(width: width, height: 200))
        XCTAssertLessThanOrEqual(menu.width, width + 0.5, "the line fits a \(width)pt editor")
        XCTAssertLessThanOrEqual(menu.height, plain.height + 2,
                                 "one line, as tall as the plain status line (\(plain.height))")
    }
}
