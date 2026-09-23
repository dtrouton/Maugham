import Foundation
import XCTest
@testable import MaughamCore

/// **The runner behind `scripts/census-load-bursts.sh`** (signed op log P3b
/// Task 3, handoff ruling 3).
///
/// MaughamCore is a library package with no executable target, so the kept
/// census is driven through an env-gated test — the `MAUGHAM_PERF_FIXTURE`
/// pattern (`OpLogGrowthBaselineTests`). Without
/// `MAUGHAM_LOAD_BURST_CENSUS_DIRS` in the environment it does nothing at all,
/// so it costs an ordinary gate one skipped test.
///
/// It is READ-ONLY (`LoadBurstCensus` creates, moves, modifies and deletes
/// nothing) and metadata-only. The markers are what the script greps for, so a
/// run that did not happen cannot be mistaken for a clean one.
final class LoadBurstCensusRunTests: XCTestCase {

    static let directoriesVariable = "MAUGHAM_LOAD_BURST_CENSUS_DIRS"
    static let startMarker = "--- LOAD BURST CENSUS ---"
    static let endMarker = "--- END ---"

    func test_runTheCensus() throws {
        guard let raw = ProcessInfo.processInfo
            .environment[Self.directoriesVariable], !raw.isEmpty else {
            throw XCTSkip(
                "Set \(Self.directoriesVariable) to a colon-separated list of "
                + "local directories, or run scripts/census-load-bursts.sh")
        }
        let roots = raw.split(separator: ":").map {
            URL(fileURLWithPath: String($0))
        }
        var reports: [LoadBurstCensus.Report] = []
        for root in roots {
            for project in LoadBurstCensus.projects(under: root) {
                reports.append(LoadBurstCensus.scan(projectURL: project))
            }
        }
        print(Self.startMarker)
        print("Roots: " + roots.map(\.path).joined(separator: ", "))
        print(LoadBurstCensus.describe(reports))
        print(Self.endMarker)
    }
}
