import XCTest
import MaughamCore
@testable import Maugham

/// PHASE 11 — the adversarial harness for the tripwire-14 seam.
///
/// Each arm's blind implementer wrote a `move(from:to:in:)`. This exercises it
/// against the real three-party race: the mover, the two 750ms debounced
/// autosaves, and the filesystem. The observable failure is a PHANTOM FILE —
/// a pending save firing after the move and re-creating the file at the old
/// path, which the manifest does not know about and the writer sees as a
/// duplicate.
///
/// The control (`test_00_control_*`) runs the SHIPPING mover through the same
/// scenario, so a phantom in an arm cannot be blamed on the harness.
@MainActor
final class SeamPhantomFileTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Scenario builders

    /// A project with a research note whose editor has a save queued on the
    /// store's 750ms path-keyed debounce — the `scheduleFileSave` half.
    private func researchNoteScenario() async throws -> (URL, DocumentStore, String, String) {
        let url = try await ProjectFactory.createShortStoryProject(named: "Seam", in: temp.url)
        let research = url.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let old = "research/note.md"
        let new = "research/renamed-note.md"
        try "original body".write(to: url.appendingPathComponent(old),
                                  atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: url)
        // The writer types in the research-note editor: a save is now queued
        // against the OLD path and will fire in 750ms.
        store.scheduleFileSave(for: old, text: "the writer's latest sentence")
        return (url, store, old, new)
    }

    /// A project with an OPEN manuscript Document whose own internal 750ms
    /// autosave is armed — the `Document` half.
    private func openManuscriptScenario() async throws -> (URL, DocumentStore, String, String) {
        let url = try await ProjectFactory.createShortStoryProject(named: "Seam2", in: temp.url)
        let manuscript = url.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(at: manuscript, withIntermediateDirectories: true)
        let old = "manuscript/01-chapter.md"
        let new = "manuscript/02-chapter.md"
        try "First line.\n".write(to: url.appendingPathComponent(old),
                                  atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: url)
        let doc = try await Document.load(
            url: url.appendingPathComponent(old),
            device: "test-device", session: "test-session", presenter: nil)
        store.register(document: doc, for: old)
        // The writer types: the Document's own 750ms autosave is now armed and
        // will write to the URL it captured at load time — the OLD path.
        doc.setFullText("First line.\n\nA sentence typed just before the move.\n")
        return (url, store, old, new)
    }

    /// The assertion. `> 750ms` so both debounces have had their chance to fire.
    private func assertNoPhantom(
        _ url: URL, old: String, new: String, arm: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        try? await Task.sleep(for: .milliseconds(1_400))
        let fm = FileManager.default
        let oldURL = url.appendingPathComponent(old)
        let newURL = url.appendingPathComponent(new)

        XCTAssertTrue(fm.fileExists(atPath: newURL.path),
                      "\(arm): the file must exist at its NEW path", file: file, line: line)
        XCTAssertFalse(
            fm.fileExists(atPath: oldURL.path),
            """
            \(arm): PHANTOM FILE — a debounced save fired after the move and \
            re-created the file at the OLD path (\(old)). The manifest does not \
            know about it; the writer sees a duplicate.
            """,
            file: file, line: line)
    }

    // MARK: - Control: the shipping mover

    func test_00_control_shippingMover_researchNote_leavesNoPhantom() async throws {
        let (url, store, old, new) = try await researchNoteScenario()
        try await store.relocateUserContent(affectedPaths: [old]) {
            try await store.coordinatedMove(from: url.appendingPathComponent(old),
                                            to: url.appendingPathComponent(new))
        }
        await assertNoPhantom(url, old: old, new: new, arm: "CONTROL (shipping)")
        await store.close()
    }

    func test_00_control_shippingMover_openManuscript_leavesNoPhantom() async throws {
        let (url, store, old, new) = try await openManuscriptScenario()
        try await store.relocate(plan: try RenamePlan(steps: [
            .init(oldRelativePath: old, newRelativePath: new)]))
        await assertNoPhantom(url, old: old, new: new, arm: "CONTROL (shipping)")
        await store.close()
    }

    // MARK: - The arms
    //
    // Each arm's file declares `CandidateMoverB` / `CandidateMoverS`. The
    // per-arm test files are generated alongside the candidate so an arm that
    // did not compile is visibly absent rather than silently skipped.
}
