import XCTest
@testable import Maugham

/// **Every way into the manuscript that is not its own keys asks whether the
/// manuscript is the editor the writer can see** (shell plan 3 Task 5 fix 2,
/// review C1/N1–N3; the one question is `ProjectWindow.manuscriptIsVisible(route:)`).
///
/// The editor's window-command observers are classified here, by name: those
/// that WRITE the manuscript must take `manuscriptCommandContext()` (directly
/// or through `insertCommandContext()`), so under any cover they reach nothing,
/// as with no document open. Those that only move the caret or flip a mode are
/// named with why. A new observer is unclassified until someone decides — the
/// census fails on it (planted offender below).
@MainActor
final class EditorWriteCommandCensusTests: XCTestCase {

    /// Observers that write manuscript text.
    static let writers: Set<String> = [
        ".maughamInsertTable", ".maughamConvertTable", ".maughamInsertFootnote",
        ".maughamInsertFigure", ".maughamInsertExistingFigure", ".maughamInsertCitation",
        ".maughamInsertCrossReference", ".maughamFigureTableCommand",
    ]

    /// Observers that write nothing, and why each may answer under a cover.
    static let nonWriters: [String: String] = [
        ".maughamNavigateToScene": "a caret move; the window's receiver closes the cover first (`go`)",
        ".maughamNavigateToParagraph": "a caret move; the window's receiver closes the cover first (`go`)",
        ".maughamNavigateToAnnotation": "a selection; `ParagraphNavModifier` closes the cover on it",
        ".maughamFindMatchSelected": "a selection; the window's receiver closes the cover first (`go`)",
        ".maughamToggleReviewMode": "flips the review membrane; writes no text",
        ".maughamReadInLanguage": "flips the translation membrane; writes no text",
        ".maughamReadInSource": "flips the translation membrane; writes no text",
        ".maughamSetReadThrough": "flips the read-through membrane of its own document; writes no text",
    ]

    static let askingContexts = ["manuscriptCommandContext()", "insertCommandContext()"]

    struct Observer: Equatable { let name: String; let context: String }

    /// Every `MaughamEvent.observe(.name, context: { … })` in `code`.
    static func observers(in code: String) -> [Observer] {
        let pattern = #"MaughamEvent\.observe\(\s*(\.maugham\w+)\s*,\s*context:\s*\{([^}]*)\}"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map {
            Observer(name: ns.substring(with: $0.range(at: 1)), context: ns.substring(with: $0.range(at: 2)))
        }
    }

    /// What is wrong with a set of observers: an unclassified one, or a writer
    /// whose context does not ask the question.
    static func faults(_ observers: [Observer]) -> [String] {
        var faults: [String] = []
        for observer in observers {
            if writers.contains(observer.name) {
                if !askingContexts.contains(where: observer.context.contains) {
                    faults.append("\(observer.name) writes the manuscript without asking manuscriptIsVisible")
                }
            } else if nonWriters[observer.name] == nil {
                faults.append("\(observer.name) is unclassified")
            }
        }
        return faults
    }

    private func editorSources() throws -> [String] {
        let folder = SourceTree.repoRoot.appendingPathComponent("Maugham/Editor")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { SourceScan.codeLines(of: try String(contentsOf: $0, encoding: .utf8))
            .joined(separator: "\n") }
    }

    func test_everyEditorCommandThatWritesTheManuscriptAsksTheQuestion() throws {
        let found = try editorSources().flatMap(Self.observers(in:))
        XCTAssertEqual(Self.faults(found), [])
        XCTAssertEqual(Set(found.map(\.name)), Self.writers.union(Self.nonWriters.keys),
                       "the census names exactly the observers there are")
        // The shared door asks the one question.
        let door = try SourceTree.declaration(named: "func manuscriptCommandContext(", under: "Maugham")
        XCTAssertTrue(door.contains("CentreKeys.manuscriptIsVisible(holding: textView)"))
        let insert = try SourceTree.declaration(named: "func insertCommandContext(", under: "Maugham")
        XCTAssertTrue(insert.contains("return manuscriptCommandContext()"))
    }

    func test_theCensusFiresOnAPlantedOffender() {
        let planted = """
        convertObserver = MaughamEvent.observe(
            .maughamConvertTable,
            context: { [weak self] in self?.receiverContext(.keyWindow) }
        ) { _ in }
        boldObserver = MaughamEvent.observe(
            .maughamMakeBold,
            context: { [weak self] in self?.manuscriptCommandContext() }
        ) { _ in }
        """
        XCTAssertEqual(Self.faults(Self.observers(in: planted)), [
            ".maughamConvertTable writes the manuscript without asking manuscriptIsVisible",
            ".maughamMakeBold is unclassified",
        ])
    }

    /// The window's and AppKit's doors: the Insert menu's gate (with the
    /// window's centre item), `CentreKeys` (the keys, and the editor-side
    /// door), and ⌘Z under a cover.
    func test_theWindowSideDoorsAskTheOneQuestion() throws {
        let gate = try SourceTree.declaration(named: "static func isEnabled(posture:", under: "Maugham")
        XCTAssertTrue(gate.contains("ProjectWindow.manuscriptIsVisible(route: route)"))
        let window = SourceScan.codeLines(
            of: try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"]))
        let start = try XCTUnwrap(window.firstIndex { $0.contains("private var mayInsertReportElement: Bool") })
        let end = try XCTUnwrap(window[start...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "}" })
        XCTAssertTrue(window[start...end].joined().contains("centreItem: centreItem"),
                      "the gate's route sees the centre item")
        let covered = try SourceTree.declaration(named: "func editorIsCovered(", under: "Maugham")
        XCTAssertTrue(covered.contains("ProjectWindow.manuscriptIsVisible(route: route)"))
        // ⌘Z under the centre item's cover (fix 3): the cover's arrival drops
        // the hidden chapter's typing through the one spelling `detach` uses,
        // and the guard does not swallow ⌘Z.
        let keys = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/CentreKeys.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(keys.contains("if claim != nil { dropTheCoveredManuscriptsUndo() }"))
        XCTAssertTrue(keys.contains("editor.coordinator?.dropTheUndoStack()"))
        XCTAssertFalse(keys.contains("func undo("), "the guard answers no ⌘Z of its own")
        XCTAssertFalse(keys.contains("removeAllActions"), "no second spelling of the drop")
        let detach = try SourceTree.declaration(named: "func dropTheUndoStack(", under: "Maugham")
        // The window's own stack, named explicitly (shell p4 Task 8 fix 2,
        // N1): over a translation the view's manager is the reading
        // throwaway, and clearing that alone left the typing behind.
        XCTAssertTrue(detach.contains("typingUndoManager?.removeAllActions()"))
        XCTAssertTrue(detach.contains("readingUndoManager.removeAllActions()"))
    }
}
