import XCTest

/// Pins `register/START-HERE.md`'s generated state table to the claims files (#139 D1).
///
/// The table is written by `register/scripts/27-generate-state.py`, and it drifted once
/// by hand (62 against 68 for Annotations, 6 low in every figure derived from it).
/// This test recounts the row, the subtotal, the totals and the complies figure from
/// `register/reconciliation/<Module>.{claims,filings}.json` itself, not from the
/// filings' `_summary` (which it also checks), and fails when the table differs. If it
/// goes red after a claim or filing change, run `scripts/flip-claim.py recompute
/// --module <Module>` and then `scripts/27-generate-state.py`; never edit the table.
final class StartHereCountsTests: XCTestCase {
    /// Row order of the generator's `APP_MODULES`. A module added to the table without
    /// being added here fails `test_theTableHasExactlyTheAppModulesThisTestKnows`.
    private static let appModules = ["Trash", "Rewind", "Annotations", "Promotion", "Publications", "Inbox", "OpLog"]
    /// The three MaughamCore rows and their totals are frozen history in the generator.
    private static let coreRowCount = 3
    private static let coreReconciled = 148
    private static let coreTotal = 169

    private struct Row { let label: String; let claims: Int; let coverage: String; let complies: Int; let violates: Int }
    private struct Counted { let claims: Int; let filed: Int; let reached: Int; let complies: Int; let violates: Int; let noRuling: Int }

    private var register: URL {
        // .../register/ExperimentTests/Tests/ExperimentTests/<this file>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func json(_ relative: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: register.appendingPathComponent(relative))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]], relative)
    }

    private func count(_ module: String) throws -> Counted {
        let claims = try json("reconciliation/\(module).claims.json")
        let filings = try json("reconciliation/\(module).filings.json")
        let rows = filings.filter { $0["claim_id"] != nil }
        let outcomes = rows.compactMap { $0["outcome"] as? String }
        let complies = outcomes.filter { $0 == "COMPLIES" }.count
        let violates = outcomes.filter { $0 == "VIOLATES" }.count
        let noRuling = outcomes.filter { $0 == "NO_RULING_REACHES" }.count
        XCTAssertEqual(complies + violates + noRuling, rows.count, "\(module): every filing has a known outcome")
        // A filing for a claim that does not exist, or twice, is a register bug the table would hide.
        let claimIds = Set(claims.compactMap { $0["claim_id"] as? String })
        XCTAssertEqual(claimIds.count, claims.count, "\(module): claim ids are unique")
        let filedIds = rows.compactMap { $0["claim_id"] as? String }
        XCTAssertEqual(Set(filedIds).count, filedIds.count, "\(module): a claim is filed once")
        XCTAssertTrue(Set(filedIds).isSubset(of: claimIds), "\(module): every filing names a claim")
        return Counted(claims: claims.count, filed: rows.count, reached: complies + violates,
                       complies: complies, violates: violates, noRuling: noRuling)
    }

    private func coverage(_ c: Counted) -> String {
        guard c.filed > 0 else { return "0%" }
        return "\(Int((100.0 * Double(c.reached) / Double(c.filed)).rounded(.toNearestOrEven)))%"
    }

    private func table() throws -> (rows: [Row], prose: String) {
        let text = try String(contentsOf: register.appendingPathComponent("START-HERE.md"), encoding: .utf8)
        let begin = try XCTUnwrap(text.range(of: "<!-- BEGIN GENERATED STATE"))
        let end = try XCTUnwrap(text.range(of: "<!-- END GENERATED STATE -->"))
        let block = String(text[begin.upperBound..<end.lowerBound])
        var rows: [Row] = []
        for line in block.split(separator: "\n") where line.hasPrefix("| ") && !line.hasPrefix("| Module") && !line.hasPrefix("|---") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(cells.count, 5, "a table row has five cells: \(line)")
            guard cells.count == 5, let claims = Int(cells[1]) else { XCTFail("unparseable row: \(line)"); continue }
            // "42 / 0" for the app layer; "16 reached" or "—" for the frozen core rows.
            let pair = cells[3].split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            rows.append(Row(label: cells[0], claims: claims, coverage: cells[2],
                            complies: (pair.count == 2 ? pair[0] : nil) ?? -1,
                            violates: (pair.count == 2 ? pair[1] : nil) ?? -1))
        }
        let prose = block.split(separator: "\n").first { $0.contains("further claims in their own files") }.map(String.init) ?? ""
        return (rows, prose)
    }

    func test_theTableHasExactlyTheAppModulesThisTestKnows() throws {
        let (rows, _) = try table()
        XCTAssertEqual(rows.count, Self.coreRowCount + Self.appModules.count,
                       "a module added to or dropped from the generator's APP_MODULES must be added here")
    }

    func test_eachAppRowIsTheClaimsFilesCount() throws {
        let (rows, _) = try table()
        try XCTSkipIf(rows.count != Self.coreRowCount + Self.appModules.count, "row count is pinned by the test above")
        for (i, module) in Self.appModules.enumerated() {
            let row = rows[Self.coreRowCount + i]
            let c = try count(module)
            XCTAssertEqual(row.claims, c.claims, "\(module): the Claims column is the claims file's count")
            XCTAssertEqual(row.complies, c.complies, "\(module): complies")
            XCTAssertEqual(row.violates, c.violates, "\(module): violates")
            XCTAssertEqual(row.coverage, coverage(c), "\(module): coverage is reached over the filed claims")
        }
    }

    func test_theSubtotalTheTotalsAndTheCompliesFigureAreTheRecount() throws {
        let (_, prose) = try table()
        var claims = 0, filed = 0, complies = 0, violates = 0
        for module in Self.appModules {
            let c = try count(module)
            claims += c.claims; filed += c.filed; complies += c.complies; violates += c.violates
        }
        XCTAssertTrue(prose.contains("the app-layer rows are \(claims) further claims"), "subtotal \(claims): \(prose)")
        XCTAssertTrue(prose.contains("**\(Self.coreTotal + claims) claims in the experiment, \(Self.coreReconciled + filed) reconciled.**"),
                      "totals \(Self.coreTotal + claims) / \(Self.coreReconciled + filed): \(prose)")
        XCTAssertTrue(prose.contains("**\(complies) complies / \(violates) violates**"), "complies \(complies) / \(violates): \(prose)")
    }

    func test_theFilingsOwnSummaryAgreesWithTheRecount() throws {
        for module in Self.appModules {
            let c = try count(module)
            let holder = try XCTUnwrap(try json("reconciliation/\(module).filings.json").first { $0["_summary"] != nil }, module)
            let s = try XCTUnwrap(holder["_summary"] as? [String: Any])
            XCTAssertEqual(s["total"] as? Int, c.filed, "\(module): _summary.total")
            XCTAssertEqual(s["reached"] as? Int, c.reached, "\(module): _summary.reached")
            XCTAssertEqual(s["complies"] as? Int, c.complies, "\(module): _summary.complies")
            XCTAssertEqual(s["violates"] as? Int, c.violates, "\(module): _summary.violates")
            XCTAssertEqual(s["no_ruling"] as? Int, c.noRuling, "\(module): _summary.no_ruling")
        }
    }
}
