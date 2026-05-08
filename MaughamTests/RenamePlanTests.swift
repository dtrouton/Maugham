import XCTest
@testable import Maugham

final class RenamePlanTests: XCTestCase {

    func test_emptyPlan_isValid_andHasNoSteps() throws {
        let plan = try RenamePlan(steps: [])
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(plan.scratchSteps, [])
        XCTAssertEqual(plan.directSteps, [])
    }

    func test_planFiltersNoOpSteps() throws {
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "a/01-foo.md", newRelativePath: "a/01-foo.md"),
            .init(oldRelativePath: "a/02-bar.md", newRelativePath: "a/03-bar.md"),
        ])
        // No-op step is filtered out
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].oldRelativePath, "a/02-bar.md")
    }

    func test_planRejectsDuplicateSourcePaths() {
        XCTAssertThrowsError(try RenamePlan(steps: [
            .init(oldRelativePath: "a.md", newRelativePath: "b.md"),
            .init(oldRelativePath: "a.md", newRelativePath: "c.md"),
        ])) { error in
            guard case RenamePlanError.duplicateSource(let p) = error else {
                return XCTFail("expected duplicateSource, got \(error)")
            }
            XCTAssertEqual(p, "a.md")
        }
    }

    func test_planRejectsDuplicateDestinationPaths() {
        XCTAssertThrowsError(try RenamePlan(steps: [
            .init(oldRelativePath: "a.md", newRelativePath: "x.md"),
            .init(oldRelativePath: "b.md", newRelativePath: "x.md"),
        ])) { error in
            guard case RenamePlanError.duplicateDestination(let p) = error else {
                return XCTFail("expected duplicateDestination, got \(error)")
            }
            XCTAssertEqual(p, "x.md")
        }
    }

    func test_planRejectsAncestorOverlap() {
        // Renaming a parent folder AND a child within it would invalidate the
        // child's oldRelativePath after the parent move. Reject up front.
        XCTAssertThrowsError(try RenamePlan(steps: [
            .init(oldRelativePath: "act-one", newRelativePath: "act-uno"),
            .init(oldRelativePath: "act-one/01-chapter-1.md",
                  newRelativePath: "act-one/02-chapter-1.md"),
        ])) { error in
            guard case RenamePlanError.ancestorOverlap = error else {
                return XCTFail("expected ancestorOverlap, got \(error)")
            }
        }
    }

    func test_nonCollidingRenames_areAllDirect() throws {
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "01-a.md", newRelativePath: "10-a.md"),
            .init(oldRelativePath: "02-b.md", newRelativePath: "20-b.md"),
        ])
        XCTAssertEqual(plan.scratchSteps.count, 0)
        XCTAssertEqual(plan.directSteps.count, 2)
    }

    func test_collidingRenames_useScratch() throws {
        // Swap A and B: A's new path = B's old path, B's new path = A's old path.
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "01-a.md", newRelativePath: "02-a.md"),
            .init(oldRelativePath: "02-b.md", newRelativePath: "01-b.md"),
        ])
        // Both steps need scratch because each one's new path matches another's old path.
        XCTAssertEqual(plan.scratchSteps.count, 2)
        XCTAssertEqual(plan.directSteps.count, 0)
    }

    func test_mixedColliding_andNonColliding() throws {
        // c → d (no collision), a → b (collision with second step), b → x (collision)
        let plan = try RenamePlan(steps: [
            .init(oldRelativePath: "c.md", newRelativePath: "d.md"),
            .init(oldRelativePath: "a.md", newRelativePath: "b.md"),
            .init(oldRelativePath: "b.md", newRelativePath: "x.md"),
        ])
        XCTAssertEqual(plan.directSteps.count, 1)
        XCTAssertEqual(plan.directSteps.first?.oldRelativePath, "c.md")
        XCTAssertEqual(plan.scratchSteps.count, 2)
    }
}
