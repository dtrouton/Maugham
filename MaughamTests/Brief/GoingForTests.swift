import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Going for**: which face it shows, the marks it draws and what a mark
/// does (shell plan 3 Task 4). Pure, plus one source census.
@MainActor
final class GoingForTests: XCTestCase {

    private static let essay = "Kelly never lies. The harbour stays shut.\n\nThe storm is the climax."
    private static let intent = essay + "\n\n## Rulings\n\n- no flashbacks\n"

    private func run(snapshot: String?, clauses: [DiagnosticIngest.ClauseStatus]) -> CompilerRun {
        CompilerRun(id: "run-1", at: Date(timeIntervalSince1970: 1_700_000_000), model: "m",
                    lastOpId: nil, deltaSummary: "", intentSnapshot: snapshot,
                    clauseStatuses: clauses, kind: .check)
    }

    private static let clauses = [
        DiagnosticIngest.ClauseStatus(clauseQuote: "Kelly never lies.", status: "strains", refs: []),
        DiagnosticIngest.ClauseStatus(clauseQuote: "The storm is the climax.", status: "silent", refs: []),
        DiagnosticIngest.ClauseStatus(clauseQuote: "The harbour stays shut.", status: "holds", refs: []),
    ]

    // MARK: - Which face

    func test_goingForReadsWithMarksOnlyWhileTheyApply() {
        let check = run(snapshot: Self.intent, clauses: Self.clauses)
        let marks = BriefPane.marks(essay: Self.essay, intentText: Self.intent, run: check)
        XCTAssertEqual(marks.map(\.kind), [.strains, .silent], "holds is no mark")
        XCTAssertEqual(GoingForView.mode(hasMarks: !marks.isEmpty, editingRequested: false,
                                         inTheCentre: false, hasIntent: true), .reading)

        // The intent edited since the check: no marks at all, and the editor.
        let edited = Self.intent.replacingOccurrences(of: "shut", with: "open")
        let none = BriefPane.marks(essay: Self.essay, intentText: edited, run: check)
        XCTAssertEqual(none, [], "marks never land on text the check did not read")
        XCTAssertEqual(GoingForView.mode(hasMarks: !none.isEmpty, editingRequested: false,
                                         inTheCentre: false, hasIntent: true), .editing)
        // No check at all: the editor.
        XCTAssertEqual(BriefPane.marks(essay: Self.essay, intentText: Self.intent, run: nil), [])
        // A check that read the intent but marked nothing (every clause holds): the editor.
        let allHold = run(snapshot: Self.intent, clauses: [Self.clauses[2]])
        XCTAssertEqual(BriefPane.marks(essay: Self.essay, intentText: Self.intent, run: allHold), [])
    }

    func test_anEditedIntentShowsTheEditor() {
        // Edit pressed over marks that apply: the editor.
        XCTAssertEqual(GoingForView.mode(hasMarks: true, editingRequested: true,
                                         inTheCentre: false, hasIntent: true), .editing)
        // No marks: the editor, written or not (an empty one mints on a keystroke).
        for hasIntent in [true, false] {
            XCTAssertEqual(GoingForView.mode(hasMarks: false, editingRequested: false,
                                             inTheCentre: false, hasIntent: hasIntent), .editing)
        }
        // A posture that refuses the edit reads — hidden, never a locked editor.
        XCTAssertEqual(GoingForView.mode(hasMarks: false, editingRequested: true, inTheCentre: false,
                                         hasIntent: true, mayEdit: false), .reading)
    }

    /// Review Focus 3, the pure half: the centre's cover wins over every
    /// other input. The mounted half is in `BriefPaneTests`.
    func test_theIntentInTheCentreLeavesAPlaceholderNotASecondEditor() {
        for hasMarks in [true, false] {
            for editing in [true, false] {
                for mayEdit in [true, false] {
                    for held in [true, false] {
                        XCTAssertEqual(
                            GoingForView.mode(hasMarks: hasMarks, editingRequested: editing,
                                              inTheCentre: true, hasIntent: true,
                                              mayEdit: mayEdit, heldElsewhere: held),
                            .inTheCentre)
                    }
                }
            }
        }
    }

    /// The one-host rule, the pure half: a statement another host holds reads
    /// here; our own host holding it is not "elsewhere".
    func test_aStatementHeldByAnotherHostReads() {
        XCTAssertTrue(GoingForView.heldElsewhere(registryHoldsIt: true, editorHeldHere: false))
        XCTAssertFalse(GoingForView.heldElsewhere(registryHoldsIt: true, editorHeldHere: true))
        XCTAssertFalse(GoingForView.heldElsewhere(registryHoldsIt: false, editorHeldHere: false))
        for marks in [true, false] {
            for editing in [true, false] {
                XCTAssertEqual(GoingForView.mode(hasMarks: marks, editingRequested: editing,
                                                 inTheCentre: false, hasIntent: true,
                                                 heldElsewhere: true), .reading)
            }
        }
    }

    // MARK: - The marks

    func test_aMarkCarriesNoModelText() throws {
        // What is drawn is the writer's own characters, nothing added.
        let marks = BriefPane.marks(essay: Self.essay, intentText: Self.intent,
                                    run: run(snapshot: Self.intent, clauses: Self.clauses))
        let drawn = GoingForView.paragraphs(of: Self.essay, marks: marks)
        XCTAssertEqual(drawn.map { String($0.characters) },
                       ["Kelly never lies. The harbour stays shut.", "The storm is the climax."])
        // The legend's words are the two app constants, for the kinds present.
        XCTAssertEqual(GoingForView.legendKinds(marks), [.strains, .silent])
        XCTAssertEqual(GoingForView.strainsHelp, "The draft pulls against this")
        XCTAssertEqual(GoingForView.silentHelp, "Nothing in this draft touches it")

        // The census: in the view's source, the check's quote never reaches a
        // Text, a help, an accessibility label or a string interpolation.
        let source = try Self.source("Maugham/Views/Brief/GoingForView.swift")
        XCTAssertEqual(Self.quoteOffenders(in: source), [])
        // Planted offenders are caught.
        for planted in ["Text(mark.clauseQuote)", ".help(marks[0].clauseQuote)",
                        ".accessibilityLabel(mark.clauseQuote)", "Text(\"\\(mark.clauseQuote)\")"] {
            XCTAssertEqual(Self.quoteOffenders(in: source + "\n" + planted), [planted],
                           "the census must catch \(planted)")
        }
    }

    func test_aStrainsMarkAsksForItsFinding() throws {
        let marks = BriefPane.marks(essay: Self.essay, intentText: Self.intent,
                                    run: run(snapshot: Self.intent, clauses: Self.clauses))
        let first = try XCTUnwrap(GoingForView.paragraphs(of: Self.essay, marks: marks).first)
        let links = first.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 1, "one solid mark, one link")
        let url = try XCTUnwrap(links.first)
        XCTAssertEqual(GoingForView.strainQuote(for: url, marks: marks), "Kelly never lies.")
        // The link carries an index, never the quote.
        XCTAssertFalse(url.absoluteString.lowercased().contains("kelly"))
        // Anything else asks for nothing.
        XCTAssertNil(GoingForView.strainQuote(for: URL(string: "https://example.com")!, marks: marks))
        XCTAssertNil(GoingForView.strainQuote(for: URL(string: "maugham-mark:9")!, marks: marks))
    }

    func test_aSilentMarkGoesNowhere() throws {
        let marks = BriefPane.marks(essay: Self.essay, intentText: Self.intent,
                                    run: run(snapshot: Self.intent, clauses: Self.clauses))
        let silent = try XCTUnwrap(marks.firstIndex { $0.kind == .silent })
        let second = try XCTUnwrap(GoingForView.paragraphs(of: Self.essay, marks: marks).last)
        let dotted = second.runs.filter { $0[GoingForView.Underline.self] != nil }
        XCTAssertFalse(dotted.isEmpty, "the silent clause is marked")
        XCTAssertTrue(dotted.allSatisfy { $0.link == nil }, "a dotted mark is no link")
        XCTAssertNil(GoingForView.strainQuote(for: URL(string: "maugham-mark:\(silent)")!, marks: marks),
                     "nothing in To resolve corresponds to a silent clause")
    }

    // MARK: - Census helpers

    static func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// Lines where `clauseQuote` meets something that draws or speaks words.
    static func quoteOffenders(in source: String) -> [String] {
        let drawers = ["Text(", ".help(", "accessibilityLabel", "accessibilityValue", "\\("]
        return source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("///") && !$0.hasPrefix("//") }
            .filter { line in line.contains("clauseQuote") && drawers.contains { line.contains($0) } }
    }
}
