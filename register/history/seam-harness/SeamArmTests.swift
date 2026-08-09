import XCTest
import MaughamCore
@testable import Maugham

/// Runs whichever `CandidateMover` is currently compiled into the target
/// (Arm B or Arm S) through the same two scenarios as the control and the
/// negative control in `SeamPhantomFileTests` / `SeamNegativeControlTests`.
@MainActor
final class SeamArmTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func assertNoPhantom(
        _ url: URL, old: String, new: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        try? await Task.sleep(for: .milliseconds(1_400))
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent(new).path),
                      "the file must exist at its NEW path", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: url.appendingPathComponent(old).path),
                       "PHANTOM FILE at the old path (\(old))", file: file, line: line)
    }

    func test_arm_researchNoteDebounce() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Arm", in: temp.url)
        let research = url.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let old = "research/note.md", new = "research/renamed-note.md"
        try "original body".write(to: url.appendingPathComponent(old),
                                  atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: url)
        store.scheduleFileSave(for: old, text: "the writer's latest sentence")

        try await CandidateMover.move(from: old, to: new, in: store)
        await assertNoPhantom(url, old: old, new: new)

        // The writer's queued sentence must survive the move, at the new path.
        let moved = try? String(contentsOf: url.appendingPathComponent(new), encoding: .utf8)
        XCTAssertEqual(moved, "the writer's latest sentence",
                       "the last edit must arrive at the NEW path, not be lost")
        await store.close()
    }

    func test_arm_openManuscriptAutosave() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Arm2", in: temp.url)
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

        try await CandidateMover.move(from: old, to: new, in: store)
        await assertNoPhantom(url, old: old, new: new)
        await store.close()
    }

    /// Both arms' briefs say a flush failure must not lose the move (Arm S
    /// states it as S-S-05; Arm B's brief has S-B-16 "no half-moved state").
    /// Nothing here forces a flush failure — this pins that the ordinary path
    /// leaves the registry clean, which is the observable half of S-S-04.
    func test_arm_registryNoLongerResolvesTheOldPath() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Arm3", in: temp.url)
        let manuscript = url.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(at: manuscript, withIntermediateDirectories: true)
        let old = "manuscript/01-chapter.md", new = "manuscript/02-chapter.md"
        try "x\n".write(to: url.appendingPathComponent(old), atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: url)
        let doc = try await Document.load(
            url: url.appendingPathComponent(old),
            device: "d", session: "s", presenter: nil)
        store.register(document: doc, for: old)

        try await CandidateMover.move(from: old, to: new, in: store)

        XCTAssertNil(store.document(for: old),
                     "the registry must stop resolving the old path")
        await store.close()
    }
}
