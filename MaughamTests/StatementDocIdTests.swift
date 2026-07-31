import XCTest
import MaughamCore
@testable import Maugham

/// M1A: a statement's identity comes from the manifest's `statements`
/// section, never from its path.
///
/// This is tripwire 22's identity half. A statement's content is an ordinary
/// `Document` — it has an op log, a history, an undo stack — and all of that is
/// keyed on the doc-id `resolveDocId(for:)` hands back. Derive that id from the
/// path and the writer renaming their intent file orphans everything they ever
/// wrote in it: the file re-bootstraps under a hash of its new path, with no
/// past.
@MainActor
final class StatementDocIdTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatementDocId-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        tmp = nil
    }

    // MARK: - Fixture

    private func writeManifest(
        structure: [StructureItem] = [],
        statements: [Statement] = []
    ) throws {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: [],
            statements: statements)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent(ProjectManifest.fileName))
    }

    // MARK: - The symptom

    /// The writer states an intent, edits it, then moves the file. The op log
    /// that carries every one of those edits must still be theirs afterwards.
    func test_aStatementKeepsItsHistoryAcrossAPathChange() async throws {
        let statementId = "stmt-\(UUID().uuidString)"
        let firstPath = "intent.md"
        let secondPath = "intent/weather.md"
        let firstURL = tmp.appendingPathComponent(firstPath)
        let secondURL = tmp.appendingPathComponent(secondPath)

        try "The book is about weather."
            .write(to: firstURL, atomically: true, encoding: .utf8)
        try writeManifest(statements: [
            Statement(id: statementId, kind: .intent,
                      scope: .project, path: firstPath)
        ])

        // Open it, say a second thing, and make that durable.
        let doc = try await Document.load(
            url: firstURL, device: "test", session: "s", presenter: nil)
        doc.setFullText("The book is about weather.\n\nAnd about waiting.")
        try await doc.flushBurstNow()
        let opsBeforeMove = try await doc.opLog()
        XCTAssertFalse(opsBeforeMove.isEmpty,
            "Precondition: the first session must have written a history.")
        await doc.close()

        // The move: the file goes somewhere else and the manifest follows it.
        try FileManager.default.createDirectory(
            at: secondURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: firstURL, to: secondURL)
        // The `.md` is derived and is allowed to lag its op log — a peer that
        // synced the manifest and `.maugham/ops/` before the render leaves
        // exactly these bytes. Staling it deliberately is what makes the
        // display assertion below able to fail: with the file's own post-edit
        // bytes in place, a re-bootstrap under a hash-derived id produces the
        // same text as an intact history and the assertion passes either way.
        try "The book is about weather."
            .write(to: secondURL, atomically: true, encoding: .utf8)
        try writeManifest(statements: [
            Statement(id: statementId, kind: .intent,
                      scope: .project, path: secondPath)
        ])

        let reopened = try await Document.load(
            url: secondURL, device: "test", session: "s2", presenter: nil)
        let opsAfterMove = try await reopened.opLog()

        XCTAssertTrue(
            Set(opsBeforeMove.map(\.opId))
                .isSubset(of: Set(opsAfterMove.map(\.opId))),
            "Every op written before the move must still be in the reopened "
            + "document's log — the move must not orphan the history.")
        XCTAssertTrue(reopened.displayText.contains("And about waiting."),
            "The reopened document must carry the edit made before the move.")
        XCTAssertEqual(try resolveDocId(for: secondURL), statementId,
            "The statement's identity is its manifest id, at either path.")
    }

    /// The order of the two manifest lookups, pinned. A path that is somehow
    /// both a structure item and a statement resolves as the structure item —
    /// the manuscript's identity is the one that predates this milestone and
    /// the one every op log on disk was written against.
    func test_aStructureItemWinsWhenAPathIsAlsoAStatement() throws {
        let path = "manuscript/c1.md"
        try writeManifest(
            structure: [StructureItem(
                id: "doc-structure", title: "C1", type: .document, path: path)],
            statements: [Statement(
                id: "stmt-statement", kind: .intent,
                scope: .project, path: path)])

        XCTAssertEqual(
            try resolveDocId(for: tmp.appendingPathComponent(path)),
            "doc-structure")
    }

    // MARK: - The control

    /// Both hash fallbacks survive unchanged. Test fixtures and headless
    /// tooling depend on a path with no manifest entry still resolving to a
    /// stable id, so this must pass against the code both before and after the
    /// `statements` lookup exists.
    func test_anUnregisteredPathStillFallsBackToTheHash() throws {
        try writeManifest(
            structure: [StructureItem(
                id: "doc-known", title: "C1", type: .document,
                path: "manuscript/c1.md")],
            statements: [Statement(
                id: "stmt-known", kind: .intent,
                scope: .project, path: "intent.md")])

        // Manifest found, nothing matches: hash of the project-relative path.
        let stranger = tmp.appendingPathComponent("manuscript/stranger.md")
        XCTAssertEqual(
            try resolveDocId(for: stranger),
            "doc-\(StableHash.fnv1a64Hex("manuscript/stranger.md"))")

        // No manifest at all: hash of the basename.
        let orphanRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatementDocIdOrphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: orphanRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: orphanRoot) }
        XCTAssertEqual(
            try resolveDocId(for: orphanRoot.appendingPathComponent("loose.md")),
            "doc-\(StableHash.fnv1a64Hex("loose.md"))")
    }
}
