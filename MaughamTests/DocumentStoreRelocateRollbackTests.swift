import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class DocumentStoreRelocateRollbackTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// W5: a mid-plan throw must unwind already-completed moves so files are
    /// back at their manifest paths (the caller never saves the manifest on
    /// throw), not stranded half-moved or in `.maugham/scratch/`.
    func test_relocate_midPlanFailure_rollsBackCompletedSteps() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Roll", in: temp.url)
        let fm = FileManager.default
        let research = url.appendingPathComponent("research")
        try fm.createDirectory(at: research, withIntermediateDirectories: true)
        try "A".write(to: research.appendingPathComponent("a.md"),
                      atomically: true, encoding: .utf8)
        try "B".write(to: research.appendingPathComponent("b.md"),
                      atomically: true, encoding: .utf8)
        // Blocker: the second step's destination already exists on disk and
        // is NOT a plan source, so coordinatedMove throws mid-plan.
        try "X".write(to: research.appendingPathComponent("blocked.md"),
                      atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: url)
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "research/a.md",
                  newRelativePath: "research/moved-a.md"),
            .init(oldRelativePath: "research/b.md",
                  newRelativePath: "research/blocked.md"),
        ])
        do {
            try await store.relocate(plan: plan)
            XCTFail("expected the blocked destination to throw")
        } catch {}

        XCTAssertTrue(fm.fileExists(atPath: research.appendingPathComponent("a.md").path),
                      "completed step must be unwound")
        XCTAssertFalse(fm.fileExists(atPath: research.appendingPathComponent("moved-a.md").path))
        XCTAssertTrue(fm.fileExists(atPath: research.appendingPathComponent("b.md").path))
        XCTAssertEqual(try String(contentsOf: research.appendingPathComponent("blocked.md"),
                                  encoding: .utf8), "X")
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathComponent(".maugham/scratch").path),
                       "no scratch leftovers")
        await store.close()
    }
}
