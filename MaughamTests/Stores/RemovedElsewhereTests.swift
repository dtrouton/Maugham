import XCTest
import MaughamCore
@testable import Maugham

/// **Pieces removed elsewhere, and Restore** (Denver's ruling, 2026-09-24).
///
/// A manuscript piece can leave the book's structure WITHOUT going to Trash —
/// an older build on another Mac saving a stale outline, which this window
/// adopts last-writer-wins (F7). Its words survive in its op log and its row in
/// the archived outline; this is the surface that lists and restores it.
@MainActor
final class RemovedElsewhereTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - The pure decision

    private func doc(_ id: String, _ title: String = "T", path: String? = nil) -> StructureItem {
        StructureItem(id: id, title: title, type: .document,
                      path: path ?? "manuscript/\(id).md")
    }

    private func group(_ id: String, _ children: [StructureItem]) -> StructureItem {
        StructureItem(id: id, title: id, type: .group, children: children)
    }

    func test_candidatesAreOpLogIdsNothingInTheBookAccountsFor() {
        let live = [group("g", [doc("doc-live")])]
        let found = RemovedElsewhere.candidates(
            opLogDocIds: ["doc-live", "doc-gone", "stmt-1", "doc-trashed"],
            live: live, statementIds: ["stmt-1"], trashedIds: ["doc-trashed"])
        XCTAssertEqual(found, ["doc-gone"])
    }

    func test_theRowComesFromTheNewestArchiveThatHeldIt() {
        let old = RemovedElsewhere.Archive(
            date: Date(timeIntervalSince1970: 100),
            structure: { [self.doc("doc-gone", "Old Title")] })
        let newer = RemovedElsewhere.Archive(
            date: Date(timeIntervalSince1970: 200),
            structure: { [self.doc("doc-a"), self.group("g", [self.doc("doc-b"), self.doc("doc-gone", "New Title")])] })
        let newest = RemovedElsewhere.Archive(
            date: Date(timeIntervalSince1970: 300),
            structure: { [self.doc("doc-a")] })

        let pieces = RemovedElsewhere.pieces(
            candidates: ["doc-gone"], archives: [old, newest, newer])

        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].title, "New Title")
        XCTAssertEqual(pieces[0].parentId, "g")
        XCTAssertEqual(pieces[0].index, 1)
        XCTAssertEqual(pieces[0].removedAt, Date(timeIntervalSince1970: 200))
    }

    /// Leg 3: an op log that no archive ever held is NOT listed. This is what
    /// keeps a chapter the writer trashed and emptied — whose op log Trash
    /// leaves behind — from being offered back as something another device did.
    func test_anIdNoArchiveHeldIsNotListed() {
        let archive = RemovedElsewhere.Archive(
            date: Date(), structure: { [self.doc("doc-other")] })
        XCTAssertEqual(RemovedElsewhere.pieces(
            candidates: ["doc-emptied"], archives: [archive]), [])
    }

    /// Only documents are listed; a group of the same id is not a piece.
    func test_aGroupIsNotAPiece() {
        let archive = RemovedElsewhere.Archive(
            date: Date(), structure: { [self.group("doc-x", [])] })
        XCTAssertEqual(RemovedElsewhere.pieces(candidates: ["doc-x"], archives: [archive]), [])
    }

    /// Cheap: once every candidate is found, older archives are never decoded.
    func test_theScanStopsReadingOnceEveryCandidateIsFound() {
        var decoded: [Int] = []
        let archives = (1...5).map { n in
            RemovedElsewhere.Archive(date: Date(timeIntervalSince1970: Double(n))) {
                decoded.append(n)
                return n == 5 ? [self.doc("doc-gone")] : []
            }
        }
        _ = RemovedElsewhere.pieces(candidates: ["doc-gone"], archives: archives)
        XCTAssertEqual(decoded, [5])
    }

    /// A trashed GROUP accounts for every row under it.
    func test_aTrashedGroupAccountsForItsChildren() throws {
        let trashedGroup = group("grp-1", [doc("doc-child")])
        let entry = TrashEntry(
            id: "20260924-101112-grp-1", trashedAt: Date(),
            originalRelativePath: "manuscript", displayTitle: "grp-1",
            itemMetadata: try JSONEncoder().encode(trashedGroup),
            originalParentId: nil, originalIndex: 0)
        XCTAssertTrue(RemovedElsewhere.trashedIds(in: [entry])
            .isSuperset(of: ["grp-1", "doc-child"]))
    }

    func test_theArchiveNameRoundTripsItsDate() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000.25)
        let name = ManifestConflictArchive.fileName(for: date)
        XCTAssertTrue(name.hasPrefix("manifest-") && !name.contains(":"), name)
        let back = try XCTUnwrap(ManifestConflictArchive.date(fromFileName: name))
        XCTAssertEqual(back.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        // A chapter called `manifest.md` backs up beside the archives.
        XCTAssertNil(ManifestConflictArchive.date(
            fromFileName: "manifest-doc-1234-diverged-2026-09-24T10-11-12.345Z.md"))
    }

    func test_theCaptionSaysWhen() {
        let now = Date()
        XCTAssertEqual(RemovedElsewhereDisclosure.caption(for: now, now: now), "Removed today")
        XCTAssertEqual(RemovedElsewhereDisclosure.caption(
            for: now.addingTimeInterval(-86_400), now: now), "Removed yesterday")
    }

    // MARK: - Against a book on disk

    private func manifestURL(_ url: URL) -> URL {
        url.appendingPathComponent(ProjectManifest.fileName)
    }

    private func openWindow() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Removed", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store
        return (url, store, ds)
    }

    /// Writes `words` into the piece at `path` through the op log.
    private func write(_ words: String, at path: String, in url: URL) async throws {
        let doc = try await Document.load(
            url: url.appendingPathComponent(path), actor: .author,
            session: "removed-elsewhere-test", presenter: nil)
        doc.setFullText(words)
        await doc.close()
    }

    /// An older build on another Mac saves an outline without `id` — no Trash
    /// entry — and this window adopts it, archiving the outline that held it.
    private func anotherMacDrops(
        _ id: String, url: URL, store: ProjectStore, ds: DocumentStore
    ) throws {
        var stale = store.manifest
        stale.structure = TreeWalk.remove(id: id, in: stale.structure)
        try ProjectManifest.makeEncoder().encode(stale)
            .write(to: manifestURL(url), options: [.atomic])
        ds.presenterDidChangeSubitem(at: manifestURL(url))
    }

    private func conflictNames(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent(".maugham/conflicts").path)) ?? [])
    }

    private func derivedRender(_ id: String, _ url: URL) throws -> String {
        MarkdownDisplayFilter.stripAnchors(
            try DerivedManuscript.materialize(forDocId: id, in: url))
    }

    /// **The headline**: the piece is listed, Restore puts the SAME row back
    /// where it was, saves it, and its file is re-derived from the op log.
    func test_aPieceAnotherMacDroppedIsListedAndRestored() async throws {
        let (url, store, ds) = try await openWindow()
        let second = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        let path = try XCTUnwrap(second.path)
        try await write("The words that must come back.", at: path, in: url)
        try anotherMacDrops(second.id, url: url, store: store, ds: ds)
        XCTAssertNil(TreeWalk.find(id: second.id, in: store.manifest.structure))
        // The derived file is gone too (the other Mac never had it).
        try? FileManager.default.removeItem(at: url.appendingPathComponent(path))

        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere.map(\.id), [second.id])
        XCTAssertEqual(store.removedElsewhere.first?.title, "Chapter 2")

        var reports: [String] = []
        let piece = try XCTUnwrap(store.removedElsewhere.first)
        await RemovedElsewhereDisclosure.restore(piece: piece, store: store) { reports.append($0) }

        XCTAssertEqual(reports, [], "a plain restore has nothing more to say")
        XCTAssertEqual(store.manifest.structure.map(\.id).last, second.id,
                       "back at its old place, under its own id")
        let onDisk = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self, from: Data(contentsOf: manifestURL(url)))
        XCTAssertNotNil(TreeWalk.find(id: second.id, in: onDisk.structure), "saved")
        XCTAssertEqual(store.removedElsewhere, [])
        let rendered = try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
        XCTAssertEqual(rendered, try derivedRender(second.id, url))
        XCTAssertTrue(rendered.contains("The words that must come back."))
        XCTAssertFalse(conflictNames(url).contains { $0.contains("-diverged-") },
                       "a missing file is not a divergence: \(conflictNames(url))")
        await ds.close()
    }

    /// A stale `.md` at the path is never trusted: the render replaces it, and
    /// the load keeps its bytes in `.maugham/conflicts/` first.
    func test_aStaleFileAtThePathIsReplacedByTheRender() async throws {
        let (url, store, ds) = try await openWindow()
        let second = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        let path = try XCTUnwrap(second.path)
        try await write("Op-log truth.", at: path, in: url)
        try anotherMacDrops(second.id, url: url, store: store, ds: ds)
        try "Edited outside Maugham.".write(
            to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)

        await store.refreshRemovedElsewhere()
        try await store.restoreRemovedElsewhere(id: second.id)

        let rendered = try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
        XCTAssertEqual(rendered, try derivedRender(second.id, url))
        XCTAssertFalse(rendered.contains("Edited outside"))
        XCTAssertTrue(conflictNames(url).contains { $0.contains("-diverged-") })
        await ds.close()
    }

    /// Its parent is gone: it lands at the top of the manuscript, and says so.
    func test_aPieceWhoseGroupIsGoneLandsAtTheRoot() async throws {
        let (url, store, ds) = try await openWindow()
        let part = try await store.addStructureItem(parentId: nil, title: "Part One", kind: .group)
        let inner = try await store.addStructureItem(
            parentId: part.id, title: "Inside", kind: .document(extension: "md"))
        try await write("Inside words.", at: try XCTUnwrap(inner.path), in: url)
        try anotherMacDrops(part.id, url: url, store: store, ds: ds)

        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere.map(\.id), [inner.id])
        let outcome = try await store.restoreRemovedElsewhere(id: inner.id)

        XCTAssertTrue(store.manifest.structure.contains { $0.id == inner.id })
        XCTAssertTrue(outcome.landedAtRoot)
        XCTAssertNotNil(outcome.message)
        await ds.close()
    }

    /// Its path is someone else's now: it comes back beside it, never over it.
    func test_aClaimedPathIsNotTakenOver() async throws {
        let (url, store, ds) = try await openWindow()
        let second = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        let path = try XCTUnwrap(second.path)
        try await write("Mine.", at: path, in: url)
        try anotherMacDrops(second.id, url: url, store: store, ds: ds)
        // A live row now claims the same path.
        let occupant = StructureItem(id: "doc-occupant", title: "Occupant",
                                     type: .document, path: path)
        store.manifest.structure.append(occupant)
        try await store.saveManifest()

        await store.refreshRemovedElsewhere()
        try await store.restoreRemovedElsewhere(id: second.id)

        let restored = try XCTUnwrap(TreeWalk.find(id: second.id, in: store.manifest.structure))
        XCTAssertNotEqual(restored.path, path)
        XCTAssertEqual(TreeWalk.find(id: "doc-occupant", in: store.manifest.structure)?.path, path)
        await ds.close()
    }

    /// A piece in Trash is Trash's to restore, not this list's.
    func test_aTrashedPieceIsNotListed() async throws {
        let (url, store, ds) = try await openWindow()
        let second = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        try await write("Trashed words.", at: try XCTUnwrap(second.path), in: url)
        // An archive holds it — as it would after any adoption while it lived.
        let conflicts = url.appendingPathComponent(".maugham/conflicts")
        try FileManager.default.createDirectory(at: conflicts, withIntermediateDirectories: true)
        try ProjectManifest.makeEncoder().encode(store.manifest).write(
            to: conflicts.appendingPathComponent(ManifestConflictArchive.fileName(for: Date())),
            options: [.atomic])
        try await store.deleteStructureItem(id: second.id)

        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere, [])
        await ds.close()
    }

    /// A single-device book has no archive, so a chapter trashed and EMPTIED —
    /// whose op log Trash leaves behind — is never offered back.
    func test_anEmptiedTrashIsNotOfferedBack() async throws {
        let (url, store, ds) = try await openWindow()
        let second = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        try await write("Let go of.", at: try XCTUnwrap(second.path), in: url)
        try await store.deleteStructureItem(id: second.id)
        try await store.emptyTrash()

        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere, [])
        await ds.close()
    }
}
