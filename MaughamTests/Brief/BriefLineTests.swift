import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 3, Task 1 — `BriefLine`: the one-line for the corkboard card,
/// the outline, the line above the prose and the MCP listing.
final class BriefLineTests: XCTestCase {

    func test_anExistingSynopsisIsTheLine() {
        XCTAssertEqual(BriefLine.display(synopsis: "  Kelly lies to the harbourmaster. ",
                                         intentEssay: "The chapter turns on a lie."),
                       "Kelly lies to the harbourmaster.",
                       "the stored synopsis is the line, trimmed, with no migration")
    }

    func test_anEmptySynopsisFallsBackToTheIntentsOpening() {
        let essay = "# Going for\n\nThe chapter turns on a lie.\n\nSecond paragraph."
        for empty in [nil, "", "   \n "] as [String?] {
            XCTAssertEqual(BriefLine.display(synopsis: empty, intentEssay: essay),
                           "The chapter turns on a lie.",
                           "a synopsis that trims to empty is absent: \(String(describing: empty))")
        }
        // The opening is IntentStrip's rule: bounded, never mid-word.
        let long = String(repeating: "harbour ", count: 30)
        let line = try? XCTUnwrap(BriefLine.display(synopsis: "", intentEssay: long))
        XCTAssertEqual(line, IntentStrip.line(from: long))
        XCTAssertLessThanOrEqual(line?.count ?? .max, IntentStrip.maximumLength + 1)
        XCTAssertTrue(line?.hasSuffix("harbour…") == true, "cut at a word boundary: \(line ?? "nil")")
    }

    func test_noSynopsisAndNoIntentIsNoLine() {
        XCTAssertNil(BriefLine.display(synopsis: nil, intentEssay: nil))
        XCTAssertNil(BriefLine.display(synopsis: " ", intentEssay: "  \n"))
        XCTAssertNil(BriefLine.display(synopsis: nil, intentEssay: "# Only a heading"))
    }

    // MARK: - Census: the index is built in `.task`, never in `body`

    static let indexCall = "BriefLine.index("

    /// For each file, the lines that call the index outside a `.task` modifier,
    /// plus a marker for a file that never calls it at all.
    static func offenders(in sources: [String: String]) -> [String] {
        sources.flatMap { name, text -> [String] in
            let lines = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let calls = lines.filter { $0.contains(indexCall) }
            if calls.isEmpty { return ["\(name): never reads the line index"] }
            return calls.filter { !$0.contains(".task(id: BriefLine.refreshKey(store: store))") }
                .map { "\(name): \($0.trimmingCharacters(in: .whitespaces))" }
        }.sorted()
    }

    func test_theLineIndexIsBuiltOutsideBody() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sources: [String: String] = [:]
        for name in ["CorkboardGrid.swift", "OutlineTable.swift"] {
            sources[name] = try String(
                contentsOf: repo.appendingPathComponent("Maugham/Views/\(name)"), encoding: .utf8)
        }
        XCTAssertEqual(Self.offenders(in: sources), [])

        // The planted offender: a call in a row's body is caught.
        let planted = sources.merging(
            ["Planted.swift": "Text(BriefLine.index(store: store)[item.id] ?? \"\")"]) { $1 }
        XCTAssertEqual(Self.offenders(in: planted),
                       ["Planted.swift: Text(BriefLine.index(store: store)[item.id] ?? \"\")"])
        // And a task keyed on the manifest alone goes stale after an intent edit.
        let stale = ".task(id: store.manifest.modified) { lines = BriefLine.index(store: store) }"
        XCTAssertEqual(Self.offenders(in: ["Stale.swift": stale]), ["Stale.swift: \(stale)"])
    }

    func test_theRefreshKeyIsAPureValueOfItsThreeInputs() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let key = BriefLine.RefreshKey(manifestModified: t, statementRevision: 1, liveStatementTexts: ["s": "a"])
        XCTAssertEqual(key, BriefLine.RefreshKey(manifestModified: t, statementRevision: 1,
                                                 liveStatementTexts: ["s": "a"]))
        XCTAssertNotEqual(key, BriefLine.RefreshKey(manifestModified: t.addingTimeInterval(1), statementRevision: 1,
                                                    liveStatementTexts: ["s": "a"]), "the manifest")
        XCTAssertNotEqual(key, BriefLine.RefreshKey(manifestModified: t, statementRevision: 2,
                                                    liveStatementTexts: ["s": "a"]), "a statement written out of sight")
        XCTAssertNotEqual(key, BriefLine.RefreshKey(manifestModified: t, statementRevision: 1,
                                                    liveStatementTexts: ["s": "ab"]), "typing in an open pane")
    }
}
