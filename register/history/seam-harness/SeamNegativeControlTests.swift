import XCTest
import MaughamCore
@testable import Maugham

/// NEGATIVE CONTROL for the Phase 11 harness.
///
/// A deliberately naive mover — a coordinated move and nothing else, which is
/// what tripwire 14 says you get if you skip the close-and-flush discipline.
/// These tests assert the phantom file IS produced. If they ever go green in the
/// "no phantom" direction, the harness has stopped being able to fail and every
/// result from it is void.
@MainActor
final class SeamNegativeControlTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// The naive implementation: coordinated, correct-looking, and wrong.
    private func naiveMove(from oldPath: String, to newPath: String,
                           in store: DocumentStore) async throws {
        try await store.coordinatedMove(
            from: store.projectURL.appendingPathComponent(oldPath),
            to: store.projectURL.appendingPathComponent(newPath))
    }

    func test_naiveMover_researchNote_DOES_leaveAPhantom() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Neg", in: temp.url)
        let research = url.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let old = "research/note.md", new = "research/renamed-note.md"
        try "original body".write(to: url.appendingPathComponent(old),
                                  atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: url)
        store.scheduleFileSave(for: old, text: "the writer's latest sentence")

        try await naiveMove(from: old, to: new, in: store)
        try? await Task.sleep(for: .milliseconds(1_400))

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent(new).path),
                      "the move itself did happen")
        XCTAssertTrue(
            fm.fileExists(atPath: url.appendingPathComponent(old).path),
            "HARNESS SELF-CHECK: the naive mover MUST produce a phantom at the old "
            + "path. If it does not, this harness cannot detect the defect it exists "
            + "to detect, and the arm results are meaningless.")
        await store.close()
    }

    func test_naiveMover_openManuscript_DOES_leaveAPhantom() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Neg2", in: temp.url)
        let manuscript = url.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(at: manuscript, withIntermediateDirectories: true)
        let old = "manuscript/01-chapter.md", new = "manuscript/02-chapter.md"
        try "First line.\n".write(to: url.appendingPathComponent(old),
                                  atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: url)
        let doc = try await Document.load(
            url: url.appendingPathComponent(old),
            device: "test-device", session: "test-session", presenter: nil)
        store.register(document: doc, for: old)
        doc.setFullText("First line.\n\nA sentence typed just before the move.\n")

        try await naiveMove(from: old, to: new, in: store)
        try? await Task.sleep(for: .milliseconds(1_400))

        let fm = FileManager.default
        XCTAssertTrue(
            fm.fileExists(atPath: url.appendingPathComponent(old).path),
            "HARNESS SELF-CHECK: an open Document's own 750ms autosave must "
            + "re-create the manuscript at its old path when the mover skips "
            + "close+unregister.")
        await store.close()
    }
}
