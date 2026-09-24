import XCTest
@testable import MaughamCore
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
            live: live, statementIds: ["stmt-1"], trashedIds: ["doc-trashed"],
            letGoIds: [])
        XCTAssertEqual(found, ["doc-gone"])
    }

    /// **Emptying Trash records the let-go** (Denver, 2026-09-24): an id any
    /// device let go of is accounted for, like a live row or a Trash entry.
    func test_anIdSomeDeviceLetGoOfIsNotACandidate() {
        let found = RemovedElsewhere.candidates(
            opLogDocIds: ["doc-gone", "doc-letgo"], live: [], statementIds: [],
            trashedIds: [], letGoIds: ["doc-letgo"])
        XCTAssertEqual(found, ["doc-gone"])
    }

    /// The record is per device (tripwire 17) and read as the UNION of every
    /// device's file; a line this build cannot read is skipped, not fatal.
    func test_theLetGoRecordIsReadAsTheUnionOfEveryDevicesFile() async throws {
        let url = temp.url.appendingPathComponent("letgo-union")
        try await LetGoRecord.record(ids: ["doc-aaaa", "doc-bbbb"], in: url,
                               device: DeviceSlug.unsafeForTesting("thismac"))
        try await LetGoRecord.record(ids: ["doc-cccc"], in: url,
                               device: DeviceSlug.unsafeForTesting("othermac"))
        let other = LetGoRecord.fileURL(for: DeviceSlug.unsafeForTesting("othermac"), in: url)
        let handle = try FileHandle(forWritingTo: other)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()

        XCTAssertEqual(LetGoRecord.ids(in: url), ["doc-aaaa", "doc-bbbb", "doc-cccc"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: LetGoRecord.directory(in: url).path).sorted(),
            ["let-go.othermac.jsonl", "let-go.thismac.jsonl"],
            "one file per device, never one shared file")
        XCTAssertEqual(LetGoRecord.ids(in: temp.url.appendingPathComponent("nothing")), [],
                       "no record at all is nothing let go")
    }

    /// **Review N4**: the record is written by the house coordinated append,
    /// so it round-trips through `JSONLAppendStore`'s own loader — id AND date
    /// — as well as through the union read, and a second record appends to
    /// the same device's file rather than replacing it.
    func test_theLetGoRecordRoundTripsThroughTheHouseAppendStore() async throws {
        let url = temp.url.appendingPathComponent("letgo-roundtrip")
        let slug = DeviceSlug.unsafeForTesting("thismac")
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try await LetGoRecord.record(ids: ["doc-aaaa"], in: url, device: slug, at: when)
        try await LetGoRecord.record(ids: ["doc-bbbb"], in: url, device: slug, at: when)

        let lines = try await JSONLAppendStore<LetGoRecord.Line>(
            fileURL: LetGoRecord.fileURL(for: slug, in: url)).loadStrict()
        XCTAssertEqual(lines, [LetGoRecord.Line(id: "doc-aaaa", at: when),
                               LetGoRecord.Line(id: "doc-bbbb", at: when)])
        XCTAssertEqual(LetGoRecord.ids(in: url), ["doc-aaaa", "doc-bbbb"])
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

    /// Leg 4: an op log that no archive ever held is NOT listed. This is what
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
        XCTAssertEqual(RemovedElsewhereDisclosure.caption(for: now, now: now), "Left the binder today")
        XCTAssertEqual(RemovedElsewhereDisclosure.caption(
            for: now.addingTimeInterval(-86_400), now: now), "Left the binder yesterday")
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

    /// **Another Mac's let-go arriving re-derives the list** (final round).
    /// Its record lands in `.maugham/let-go/`; the presenter's arm for that
    /// folder refreshes Removed Elsewhere, so a piece that Mac emptied from its
    /// Trash stops being offered here without waiting for a structure change.
    func test_anotherMacsLetGoArrivingTakesThePieceOffTheList() async throws {
        let (url, store, ds) = try await openWindow()
        let second = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        try await write("Words another Mac let go of.", at: try XCTUnwrap(second.path), in: url)
        try anotherMacDrops(second.id, url: url, store: store, ds: ds)
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere.map(\.id), [second.id], "premise: listed")

        let other = DeviceSlug.unsafeForTesting("other-mac")
        try LetGoRecord.record(ids: [second.id], in: url, device: other)
        ds.presenterDidChangeSubitem(at: LetGoRecord.fileURL(for: other, in: url))
        await ds.flushLetGoRefreshForTesting()

        XCTAssertEqual(store.removedElsewhere, [],
                       "the let-go another Mac recorded is honoured on arrival")
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

    // MARK: - The let-go (Denver, 2026-09-24)

    /// Writes this window's outline as an archive — the state after any
    /// adoption while the piece was live, which is what the old Limit 2 was
    /// about.
    private func archiveHolding(_ store: ProjectStore, url: URL) throws {
        let conflicts = url.appendingPathComponent(".maugham/conflicts")
        try FileManager.default.createDirectory(at: conflicts, withIntermediateDirectories: true)
        try ProjectManifest.makeEncoder().encode(store.manifest).write(
            to: conflicts.appendingPathComponent(ManifestConflictArchive.fileName(for: Date())),
            options: [.atomic])
    }

    /// A chapter with words, held by an archive, then trashed.
    private func trashedChapter() async throws -> (URL, ProjectStore, DocumentStore, StructureItem) {
        let (url, store, ds) = try await openWindow()
        let piece = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        try await write("Let go of.", at: try XCTUnwrap(piece.path), in: url)
        try archiveHolding(store, url: url)
        try await store.deleteStructureItem(id: piece.id)
        return (url, store, ds, piece)
    }

    /// **The reviewer's missing case**: an archive held the piece, the writer
    /// trashed it and emptied Trash. Before the let-go record this was listed
    /// as removed elsewhere (the old Limit 2).
    func test_aPieceAnArchiveHeldThatWasTrashedAndEmptiedIsNotListed() async throws {
        let (url, store, ds, piece) = try await trashedChapter()
        try await store.emptyTrash()

        XCTAssertTrue(LetGoRecord.ids(in: url).contains(piece.id), "the emptying is recorded")
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere, [])
        XCTAssertFalse(OpLogStore.opLogFileURLs(forDocId: piece.id, in: url).isEmpty,
                       "and its history is still on disk, as before")
        await ds.close()
    }

    /// The same through Delete Permanently on one entry.
    func test_aPieceDeletedPermanentlyFromTrashIsNotListed() async throws {
        let (url, store, ds, piece) = try await trashedChapter()
        let entry = try XCTUnwrap(store.trashEntries.first)
        try await store.permanentlyDeleteTrashEntry(id: entry.id)

        XCTAssertTrue(LetGoRecord.ids(in: url).contains(piece.id))
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere, [])
        await ds.close()
    }

    /// The same through the 30-day sweep.
    func test_aPieceTheRetentionSweepRemovedIsNotListed() async throws {
        let (url, store, ds, piece) = try await trashedChapter()
        let entry = try XCTUnwrap(store.trashEntries.first)
        // Age the entry past the retention window by its folder name's stamp.
        let trashRoot = url.appendingPathComponent(".trash")
        let aged = TrashStore.timestampPrefix(for: Date().addingTimeInterval(-40 * 86_400))
            + "-" + piece.id
        try FileManager.default.moveItem(
            at: trashRoot.appendingPathComponent(entry.id),
            to: trashRoot.appendingPathComponent(aged))
        try await store.trashStore.sweep()

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: trashRoot.appendingPathComponent(aged).path), "precondition: swept")
        XCTAssertTrue(LetGoRecord.ids(in: url).contains(piece.id))
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere, [])
        await ds.close()
    }

    /// A trashed GROUP's emptying lets go of every piece under it.
    func test_emptyingATrashedGroupLetsGoOfItsChildren() async throws {
        let (url, store, ds) = try await openWindow()
        let part = try await store.addStructureItem(parentId: nil, title: "Part", kind: .group)
        let inner = try await store.addStructureItem(
            parentId: part.id, title: "Inside", kind: .document(extension: "md"))
        try await write("Inside.", at: try XCTUnwrap(inner.path), in: url)
        try archiveHolding(store, url: url)
        try await store.deleteStructureItem(id: part.id)
        try await store.emptyTrash()

        XCTAssertTrue(LetGoRecord.ids(in: url).isSuperset(of: [part.id, inner.id]))
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere, [])
        await ds.close()
    }

    /// **Another device let it go**: once that device's record has synced
    /// here, the piece its stale outline dropped is not offered back either.
    func test_aPieceAnotherDeviceLetGoOfIsNotListed() async throws {
        let (url, store, ds) = try await openWindow()
        let second = try await store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
        try await write("Theirs to let go.", at: try XCTUnwrap(second.path), in: url)
        try anotherMacDrops(second.id, url: url, store: store, ds: ds)
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere.map(\.id), [second.id],
                       "precondition: listed while nothing records a let-go")

        try await LetGoRecord.record(ids: [second.id], in: url,
                               device: DeviceSlug.unsafeForTesting("othermac"))
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere, [])
        await ds.close()
    }

    /// Nothing else changes: a restore from Trash records nothing, so a piece
    /// that went to Trash and came back is still offered if a stale outline
    /// later drops it.
    func test_aRestoreFromTrashRecordsNoLetGo() async throws {
        let (url, store, ds, piece) = try await trashedChapter()
        let entry = try XCTUnwrap(store.trashEntries.first)
        try await store.restoreTrashEntry(id: entry.id)

        XCTAssertEqual(LetGoRecord.ids(in: url), [])
        try anotherMacDrops(piece.id, url: url, store: store, ds: ds)
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere.map(\.id), [piece.id])
        await ds.close()
    }
}
