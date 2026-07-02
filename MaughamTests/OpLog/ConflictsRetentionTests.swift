import XCTest
import MaughamCore
@testable import Maugham

/// F7 — `.maugham/conflicts/` retention. Every discard/divergence bounce writes
/// a backup; without a cap the dir grows unbounded. The writer prunes to the
/// newest `conflictBackupRetention` (20) per doc after each write. Grouping is
/// per-docId (the filename carries it) so two Collection pieces that share a
/// file stem but live under the SAME project-scope conflicts dir don't
/// cross-prune each other.
@MainActor
final class ConflictsRetentionTests: XCTestCase {

    /// A project root carrying a manifest so `resolveProjectURL` anchors every
    /// piece's backups under `<root>/.maugham/conflicts/`.
    private func makeProjectRoot() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CRT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .collection, title: "T", author: "A", created: Date(),
            modified: Date(), structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    private func conflictFiles(_ root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(".maugham/conflicts"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    func test_pruneToNewestTwentyPerDoc() throws {
        let root = try makeProjectRoot()
        let docURL = root.appendingPathComponent("pieces/01-intro/scene.md")
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        var written: [URL] = []
        for i in 1...25 {
            let url = try Document.writeConflictBackup(
                forFileAt: docURL, docId: "doc-a", text: "bytes \(i)",
                kind: "diverged", at: base.addingTimeInterval(Double(i)))
            written.append(url)
        }

        XCTAssertEqual(conflictFiles(root).count, 20,
            "retention keeps the newest 20 backups for the doc")
        let fm = FileManager.default
        // The 5 oldest were pruned…
        for url in written.prefix(5) {
            XCTAssertFalse(fm.fileExists(atPath: url.path),
                "the oldest backups must be pruned")
        }
        // …the newest 20 survive.
        for url in written.suffix(20) {
            XCTAssertTrue(fm.fileExists(atPath: url.path),
                "the newest 20 backups must survive")
        }
    }

    func test_sameStemDifferentDocIds_doNotCrossPrune() throws {
        let root = try makeProjectRoot()
        // Two Collection pieces sharing the file stem `scene` but distinct docIds.
        let pieceA = root.appendingPathComponent("pieces/01-intro/scene.md")
        let pieceB = root.appendingPathComponent("pieces/02-body/scene.md")
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        // Piece B gets a few backups first.
        var bURLs: [URL] = []
        for i in 1...3 {
            bURLs.append(try Document.writeConflictBackup(
                forFileAt: pieceB, docId: "doc-b", text: "b \(i)",
                kind: "diverged", at: base.addingTimeInterval(Double(i))))
        }

        // Piece A then floods 25 backups — its pruning must key on doc-a only.
        for i in 1...25 {
            _ = try Document.writeConflictBackup(
                forFileAt: pieceA, docId: "doc-a", text: "a \(i)",
                kind: "diverged", at: base.addingTimeInterval(Double(100 + i)))
        }

        // Both pieces share the project conflicts dir…
        XCTAssertEqual(conflictFiles(root).count, 23,
            "20 (doc-a, pruned) + 3 (doc-b, untouched) backups coexist")
        // …and doc-b's three backups are all intact (never cross-pruned by doc-a).
        let fm = FileManager.default
        for url in bURLs {
            XCTAssertTrue(fm.fileExists(atPath: url.path),
                "doc-b's backups must not be pruned by doc-a's writes")
        }
    }
}
