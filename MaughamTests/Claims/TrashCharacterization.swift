import XCTest
import MaughamCore
@testable import Maugham

/// CHARACTERISATION of `Maugham/Stores/TrashStore.swift` +
/// `Maugham/Stores/ProjectStore+Trash.swift`, plus the delete-side entry points
/// that mint trash entries (`deleteStructureItem`, `deleteResearchItems`) and the
/// load-time sweep.
///
/// Every assertion here was written from OBSERVED output (see `TrashProbe.swift`
/// and `TrashProbe2.swift`), never from what the code looked like it should do.
/// These tests pin behaviour against HEAD `db1bea2c`. A failure means the
/// behaviour changed, NOT that the behaviour is wrong — several of the claims
/// pinned below are defects, and they are pinned AS defects on purpose.
///
/// Claim ids `M3-TR-nnn` correspond to `experiment/reconciliation/Trash.claims.json`.
@MainActor
final class TrashCharacterization: XCTestCase {

    private var temp: TempDirectory!
    override func setUp() { super.setUp(); temp = TempDirectory() }
    override func tearDown() { temp = nil; super.tearDown() }

    // MARK: - Shared helpers

    private func project(_ name: String = "P") throws -> URL {
        let url = temp.url.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ text: String, at relative: String, in project: URL) throws -> URL {
        let url = project.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func exists(_ relative: String, in project: URL) -> Bool {
        FileManager.default.fileExists(atPath: project.appendingPathComponent(relative).path)
    }

    private func trashFolders(in project: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: project.appendingPathComponent(".trash"),
            includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent).sorted()
    }

    private func plantEntry(
        in project: URL, folderName: String, meta: String?, file: (name: String, body: String)?
    ) throws {
        let folder = project.appendingPathComponent(".trash/\(folderName)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let meta {
            try meta.write(to: folder.appendingPathComponent("meta.json"),
                           atomically: true, encoding: .utf8)
        }
        if let file {
            try file.body.write(to: folder.appendingPathComponent(file.name),
                                atomically: true, encoding: .utf8)
        }
    }

    private func metaJSON(
        path: String, title: String = "T", parent: String = "null", index: Int = 0
    ) -> String {
        #"{"originalRelativePath":"\#(path)","displayTitle":"\#(title)","itemMetadata":"","originalParentId":\#(parent),"originalIndex":\#(index)}"#
    }

    // MARK: - moveToTrash

    /// M3-TR-001 / M3-TR-003 / M3-TR-005
    func test_moveToTrash_namesTheFolderByTimestampAndMetadataId_andRecordsPositionInMetaJSON() async throws {
        let p = try project()
        try write("body", at: "manuscript/a.md", in: p)
        let store = TrashStore(projectURL: p)

        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/a.md",
            itemMetadata: Data(#"{"id":"doc-a"}"#.utf8),
            originalParentId: "grp-1", originalIndex: 7, displayTitle: "A")

        // M3-TR-001: "<yyyyMMdd-HHmmss>-<id from itemMetadata>"
        XCTAssertTrue(entry.id.hasSuffix("-doc-a"), "observed id: \(entry.id)")
        XCTAssertEqual(entry.id.count, "yyyyMMdd-HHmmss".count + 1 + "doc-a".count)
        XCTAssertNotNil(TrashStore.parseTimestamp(from: entry.id))

        // M3-TR-003: the file leaves the project tree and lands in the entry folder.
        XCTAssertFalse(exists("manuscript/a.md", in: p))
        XCTAssertTrue(exists(".trash/\(entry.id)/a.md", in: p))
        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent(".trash/\(entry.id)/a.md"),
                                  encoding: .utf8), "body")

        // M3-TR-005: meta.json records the caller's parent id and index.
        let meta = try JSONDecoder().decode(
            TrashStore.TrashMeta.self,
            from: Data(contentsOf: p.appendingPathComponent(".trash/\(entry.id)/meta.json")))
        XCTAssertEqual(meta.originalParentId, "grp-1")
        XCTAssertEqual(meta.originalIndex, 7)
        XCTAssertEqual(meta.originalRelativePath, "manuscript/a.md")
        XCTAssertEqual(meta.displayTitle, "A")
    }

    /// M3-TR-006 — the RETURNED entry drops the position; meta.json and list() keep it.
    /// Three producers of `TrashEntry`, two answers to "where did this come from".
    func test_moveToTrash_returnedEntryDropsThePositionThatMetaJSONAndListBothKeep() async throws {
        let p = try project()
        try write("body", at: "manuscript/a.md", in: p)
        let store = TrashStore(projectURL: p)

        let returned = try await store.moveToTrash(
            fileRelativePath: "manuscript/a.md",
            itemMetadata: Data(#"{"id":"doc-a"}"#.utf8),
            originalParentId: "grp-1", originalIndex: 7, displayTitle: "A")

        XCTAssertNil(returned.originalParentId, "moveToTrash's return omits the parent id")
        XCTAssertEqual(returned.originalIndex, 0, "moveToTrash's return omits the index")

        let entries = try await store.list()
        let listed = try XCTUnwrap(entries.first)
        XCTAssertEqual(listed.originalParentId, "grp-1")
        XCTAssertEqual(listed.originalIndex, 7)
        XCTAssertEqual(listed.id, returned.id)
        XCTAssertNotEqual(listed, returned, "the same entry, unequal by two fields")
    }

    /// M3-TR-002 — no `id` in the metadata (or metadata that is not JSON at all)
    /// names the folder `<timestamp>-x`.
    func test_moveToTrash_metadataWithoutAnId_namesTheFolderX() async throws {
        for metadata in [Data(#"{"title":"no id here"}"#.utf8), Data(), Data("not json".utf8)] {
            let p = try project()
            try write("b", at: "manuscript/b.md", in: p)
            let entry = try await TrashStore(projectURL: p).moveToTrash(
                fileRelativePath: "manuscript/b.md",
                itemMetadata: metadata,
                originalParentId: nil, originalIndex: 0, displayTitle: "B")
            XCTAssertTrue(entry.id.hasSuffix("-x"), "observed: \(entry.id)")
        }
    }

    /// M3-TR-004 — a group's folder moves wholesale, subtree intact.
    func test_moveToTrash_movesAFolderWithItsWholeSubtree() async throws {
        let p = try project()
        try write("x", at: "manuscript/act/01.md", in: p)
        try write("y", at: "manuscript/act/nested/02.md", in: p)

        let entry = try await TrashStore(projectURL: p).moveToTrash(
            fileRelativePath: "manuscript/act",
            itemMetadata: Data(#"{"id":"grp"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "Act")

        XCTAssertFalse(exists("manuscript/act", in: p))
        XCTAssertTrue(exists(".trash/\(entry.id)/act/01.md", in: p))
        XCTAssertTrue(exists(".trash/\(entry.id)/act/nested/02.md", in: p))
    }

    /// M3-TR-007 / M3-TR-008 — an unsafe relative path is refused BEFORE the
    /// filesystem is touched, but the entry folder was already created and is
    /// left behind.
    func test_moveToTrash_refusesUnsafePaths_butLeavesTheEntryFolderBehind() async throws {
        let cases: [(String, SafeRelativePath.PathError)] = [
            ("/etc/passwd", .absolutePath("/etc/passwd")),
            ("../escape.md", .escapesRoot("../escape.md")),
            ("", .emptyPath),
            ("a//b.md", .emptyComponent("a//b.md")),
            ("manuscript/../../x.md", .escapesRoot("manuscript/../../x.md")),
        ]
        for (bad, expected) in cases {
            let p = try project()
            do {
                _ = try await TrashStore(projectURL: p).moveToTrash(
                    fileRelativePath: bad,
                    itemMetadata: Data(#"{"id":"z"}"#.utf8),
                    originalParentId: nil, originalIndex: 0, displayTitle: "Z")
                XCTFail("expected a throw for \(bad.debugDescription)")
            } catch let error as TrashStore.TrashError {
                guard case .unsafeRelativePath(let path, let underlying) = error else {
                    return XCTFail("wrong TrashError case for \(bad.debugDescription)")
                }
                XCTAssertEqual(path, bad)
                XCTAssertEqual(underlying as? SafeRelativePath.PathError, expected)
            }
            // M3-TR-008: the refusal still litters .trash/ with an empty folder.
            XCTAssertEqual(trashFolders(in: p).count, 1,
                           "a refused move still leaves its entry folder for \(bad.debugDescription)")
            let folder = p.appendingPathComponent(".trash/\(trashFolders(in: p)[0])")
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(at: folder,
                                                            includingPropertiesForKeys: nil).count, 0,
                "the leftover folder is empty — no file, no meta.json")
        }
    }

    /// M3-TR-009 / M3-TR-010 — a source that is not there throws a Cocoa error and
    /// leaves an empty, meta-less entry folder that `list()` cannot see.
    func test_moveToTrash_missingSource_leavesAnEntryFolderListCannotSee() async throws {
        let p = try project()
        let store = TrashStore(projectURL: p)
        do {
            _ = try await store.moveToTrash(
                fileRelativePath: "manuscript/missing.md",
                itemMetadata: Data(#"{"id":"gone"}"#.utf8),
                originalParentId: nil, originalIndex: 0, displayTitle: "Gone")
            XCTFail("expected a throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        }
        XCTAssertEqual(trashFolders(in: p).count, 1)
        let visible = try await store.list()
        XCTAssertEqual(visible.count, 0,
                       "the folder exists on disk and is invisible to list()")
    }

    /// M3-TR-011 / M3-TR-012 — two entries minted in the same second under the
    /// same metadata id share ONE folder. The second meta.json overwrites the
    /// first, `list()` reports a single entry, and restoring it destroys the
    /// other file along with the folder.
    ///
    /// Reachability from a writer gesture is UNTRACED: production ids are minted
    /// unique, and the `x` default is only produced by metadata with no `id`
    /// field, which no current caller supplies. Pinned as a property of THIS
    /// module, whose guard against it lives entirely elsewhere.
    func test_moveToTrash_sameSecondSameId_collapseIntoOneEntry_andRestoreDestroysTheOther() async throws {
        var collided: (URL, TrashEntry)?
        for _ in 0..<8 {                       // retry: the two calls must land in one second
            let p = try project()
            try write("one", at: "manuscript/one.md", in: p)
            try write("two", at: "manuscript/two.md", in: p)
            let store = TrashStore(projectURL: p)
            let metadata = Data(#"{"id":"same"}"#.utf8)
            let first = try await store.moveToTrash(
                fileRelativePath: "manuscript/one.md", itemMetadata: metadata,
                originalParentId: nil, originalIndex: 0, displayTitle: "One")
            let second = try await store.moveToTrash(
                fileRelativePath: "manuscript/two.md", itemMetadata: metadata,
                originalParentId: nil, originalIndex: 0, displayTitle: "Two")
            if first.id == second.id { collided = (p, second); break }
        }
        let (p, entry) = try XCTUnwrap(collided, "could not land two moves in one second")
        let store = TrashStore(projectURL: p)

        // One folder, holding BOTH files and one meta.json.
        XCTAssertEqual(trashFolders(in: p), [entry.id])
        XCTAssertTrue(exists(".trash/\(entry.id)/one.md", in: p))
        XCTAssertTrue(exists(".trash/\(entry.id)/two.md", in: p))

        // list() reports a single entry, describing only the second item.
        let listed = try await store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].displayTitle, "Two")

        // Restoring it removes the folder — and with it the other writer's file.
        _ = try await store.restore(trashId: entry.id)
        XCTAssertFalse(exists(".trash/\(entry.id)", in: p))
        let survivors = ["manuscript/one.md", "manuscript/two.md"].filter { exists($0, in: p) }
        XCTAssertEqual(survivors.count, 1,
                       "exactly one of the two files survives; the other is destroyed silently")
    }

    // MARK: - list

    /// M3-TR-013 — no `.trash` directory at all.
    func test_list_withNoTrashDirectory_isEmptyAndDoesNotThrow() async throws {
        let p = try project()
        let listed = try await TrashStore(projectURL: p).list()
        XCTAssertEqual(listed.count, 0)
    }

    /// M3-TR-014 / M3-TR-018 — newest first, position round-tripped through meta.json.
    func test_list_sortsNewestFirst_andRoundTripsTheRecordedPosition() async throws {
        let p = try project()
        let now = Date()
        for (days, name) in [(0, "today"), (10, "older"), (5, "middle")] {
            try plantEntry(
                in: p,
                folderName: "\(TrashStore.timestampPrefix(for: now.addingTimeInterval(Double(-days) * 86_400)))-\(name)",
                meta: metaJSON(path: "manuscript/\(name).md", title: name,
                               parent: "\"grp-\(name)\"", index: days),
                file: (name: "\(name).md", body: name))
        }

        let listed = try await TrashStore(projectURL: p).list()
        XCTAssertEqual(listed.map(\.displayTitle), ["today", "middle", "older"])
        XCTAssertEqual(listed.map(\.originalParentId), ["grp-today", "grp-middle", "grp-older"])
        XCTAssertEqual(listed.map(\.originalIndex), [0, 5, 10])
    }

    /// M3-TR-015 / M3-TR-016 / M3-TR-017 — every unreadable shape is skipped
    /// SILENTLY: absent meta.json, undecodable meta.json, an unparseable folder
    /// name, and a loose file at the `.trash` root.
    func test_list_silentlySkipsEveryEntryItCannotRead() async throws {
        let p = try project()
        let stamp = TrashStore.timestampPrefix(for: Date())
        try plantEntry(in: p, folderName: "\(stamp)-good",
                       meta: metaJSON(path: "manuscript/good.md", title: "Good"),
                       file: ("good.md", "good"))
        try plantEntry(in: p, folderName: "\(stamp)-nometa", meta: nil,
                       file: ("words.md", "the writer's only copy"))
        try plantEntry(in: p, folderName: "\(stamp)-badmeta", meta: "{ not json",
                       file: ("words.md", "the writer's only copy"))
        try plantEntry(in: p, folderName: "not-a-timestamp-at-all",
                       meta: metaJSON(path: "manuscript/x.md", title: "X"),
                       file: ("x.md", "x"))
        try "stray".write(to: p.appendingPathComponent(".trash/loose.txt"),
                          atomically: true, encoding: .utf8)

        let listed = try await TrashStore(projectURL: p).list()
        XCTAssertEqual(listed.map(\.displayTitle), ["Good"])
        // All four skipped shapes are still on disk, holding their contents.
        XCTAssertEqual(trashFolders(in: p).count, 5)
        XCTAssertTrue(exists(".trash/\(stamp)-nometa/words.md", in: p))
        XCTAssertTrue(exists(".trash/\(stamp)-badmeta/words.md", in: p))
    }

    // MARK: - sweep

    /// M3-TR-019 / M3-TR-020 — strictly older than 30 days goes; 29 days stays.
    func test_sweep_destroysEntriesOlderThan30Days_andKeepsA29DayEntry() async throws {
        let p = try project()
        let now = Date()
        for (days, name) in [(31, "old"), (29, "nearly"), (0, "fresh")] {
            try plantEntry(
                in: p,
                folderName: "\(TrashStore.timestampPrefix(for: now.addingTimeInterval(Double(-days) * 86_400)))-\(name)",
                meta: metaJSON(path: "manuscript/\(name).md", title: name),
                file: ("\(name).md", name))
        }

        try await TrashStore(projectURL: p).sweep()

        let survivors = trashFolders(in: p).map { $0.split(separator: "-").last.map(String.init) ?? "" }
        XCTAssertEqual(Set(survivors), ["nearly", "fresh"])
    }

    /// M3-TR-021 — sweep iterates `list()`, so anything list() cannot read is
    /// never swept. A trashed file whose meta.json never landed sits in the
    /// project forever: invisible in the Trash pane and immortal.
    func test_sweep_neverReachesAnEntryListCannotSee_soAMetaLessEntryIsImmortal() async throws {
        let p = try project()
        let ancient = TrashStore.timestampPrefix(for: Date().addingTimeInterval(-900 * 86_400))
        try plantEntry(in: p, folderName: "\(ancient)-ancient", meta: nil,
                       file: ("chapter.md", "the writer's only copy"))

        let store = TrashStore(projectURL: p)
        try await store.sweep()

        let visible = try await store.list()
        XCTAssertEqual(visible.count, 0, "the Trash pane shows nothing")
        XCTAssertTrue(exists(".trash/\(ancient)-ancient/chapter.md", in: p),
                      "and a 900-day-old file is still there")
    }

    /// M3-TR-022 — sweep on a project with no `.trash` is a no-op.
    func test_sweep_withNoTrashDirectory_doesNotThrow() async throws {
        let p = try project()
        try await TrashStore(projectURL: p).sweep()
        XCTAssertFalse(exists(".trash", in: p))
    }

    // MARK: - timestamp parsing

    /// M3-TR-023 / M3-TR-024 — the parser takes the first two dash-separated
    /// fields and ignores the rest.
    func test_parseTimestamp_readsTheFirstTwoFields_andRejectsWhatCannotBeADate() {
        XCTAssertNotNil(TrashStore.parseTimestamp(from: "20260512-153045-abc"))
        XCTAssertNotNil(TrashStore.parseTimestamp(from: "20260512-153045"))
        XCTAssertNotNil(TrashStore.parseTimestamp(from: "20260512-153045-a-b"))
        XCTAssertEqual(TrashStore.parseTimestamp(from: "20260512-153045-abc"),
                       TrashStore.parseTimestamp(from: "20260512-153045-completely-different"),
                       "everything after the second field is ignored")
        XCTAssertNil(TrashStore.parseTimestamp(from: "20260512"))
        XCTAssertNil(TrashStore.parseTimestamp(from: "abc-def-ghi"))
        XCTAssertNil(TrashStore.parseTimestamp(from: "99999999-999999-x"))
    }

    /// M3-TR-025 — the stamp is written and read in the machine's CURRENT zone
    /// and carries no zone in the string.
    func test_timestampFormatter_isLocalTimeWithNoZoneInTheString() throws {
        XCTAssertEqual(TrashStore.timestampFormatter.dateFormat, "yyyyMMdd-HHmmss")
        XCTAssertEqual(TrashStore.timestampFormatter.timeZone, TimeZone.current)

        let d = Date(timeIntervalSince1970: 1_777_000_000)
        let round = try XCTUnwrap(TrashStore.parseTimestamp(from: TrashStore.timestampPrefix(for: d)))
        XCTAssertEqual(round.timeIntervalSince1970, d.timeIntervalSince1970.rounded(.down),
                       accuracy: 1.0)
    }

    // MARK: - restore

    /// M3-TR-026 — the happy path, and the return DOES carry the position.
    func test_restore_movesTheFileBack_removesTheEntry_andReturnsTheRecordedPosition() async throws {
        let p = try project()
        try write("Chapter 9 content", at: "manuscript/ch9.md", in: p)
        let store = TrashStore(projectURL: p)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/ch9.md",
            itemMetadata: Data(#"{"id":"ch9"}"#.utf8),
            originalParentId: "grp-act", originalIndex: 4, displayTitle: "Chapter 9")

        let restored = try await store.restore(trashId: entry.id)

        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("manuscript/ch9.md"),
                                  encoding: .utf8), "Chapter 9 content")
        XCTAssertFalse(exists(".trash/\(entry.id)", in: p))
        XCTAssertEqual(restored.originalParentId, "grp-act")
        XCTAssertEqual(restored.originalIndex, 4)
    }

    /// M3-TR-027 — a restore whose destination is occupied fails, and fails
    /// SAFELY: the occupant is untouched and the trash entry survives whole.
    /// The message the writer sees is Cocoa's, about a filename.
    func test_restore_intoAnOccupiedPath_refuses_leavingBothCopiesIntact() async throws {
        let p = try project()
        try write("original", at: "manuscript/a.md", in: p)
        let store = TrashStore(projectURL: p)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/a.md",
            itemMetadata: Data(#"{"id":"a"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "A")
        try write("replacement", at: "manuscript/a.md", in: p)

        do {
            _ = try await store.restore(trashId: entry.id)
            XCTFail("expected a throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertFalse(error.localizedDescription.contains("A"),
                           "the message names the FILE, not the writer's title: "
                           + error.localizedDescription)
        }

        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("manuscript/a.md"),
                                  encoding: .utf8), "replacement")
        let stillListed = try await store.list()
        XCTAssertEqual(stillListed.map(\.id), [entry.id])
        XCTAssertTrue(exists(".trash/\(entry.id)/a.md", in: p))
        // And it fails identically every time — there is no second route.
        do {
            _ = try await store.restore(trashId: entry.id)
            XCTFail("expected the same throw again")
        } catch {}
        let listedAgain = try await store.list()
        XCTAssertEqual(listedAgain.count, 1)
    }

    /// M3-TR-028 — an entry folder holding only meta.json names its real cause
    /// and lists what it did find.
    func test_restore_entryWithNoFile_throwsEntryFileMissingNamingTheContents() async throws {
        let p = try project()
        let id = "\(TrashStore.timestampPrefix(for: Date()))-only"
        try plantEntry(in: p, folderName: id, meta: metaJSON(path: "manuscript/x.md"), file: nil)

        do {
            _ = try await TrashStore(projectURL: p).restore(trashId: id)
            XCTFail("expected a throw")
        } catch let error as TrashStore.TrashError {
            guard case .entryFileMissing(let trashId, let contents) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(trashId, id)
            XCTAssertEqual(contents, ["meta.json"])
            XCTAssertTrue(error.localizedDescription.contains("missing its source file"))
        }
    }

    /// M3-TR-029 — an unknown id fails at the meta.json read, as a Cocoa error.
    func test_restore_unknownTrashId_throwsACocoaError() async throws {
        let p = try project()
        do {
            _ = try await TrashStore(projectURL: p).restore(trashId: "nope")
            XCTFail("expected a throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        }
    }

    /// M3-TR-030 — a sidecar `originalRelativePath` that escapes the project
    /// root is refused, and the entry is left intact.
    func test_restore_metaPathEscapingTheProject_isRefused_andTheEntrySurvives() async throws {
        let p = try project()
        let id = "\(TrashStore.timestampPrefix(for: Date()))-eek"
        try plantEntry(in: p, folderName: id, meta: metaJSON(path: "../../escaped.md"),
                       file: ("e.md", "words"))

        do {
            _ = try await TrashStore(projectURL: p).restore(trashId: id)
            XCTFail("expected a throw")
        } catch let error as TrashStore.TrashError {
            guard case .unsafeRelativePath(let path, let underlying) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(path, "../../escaped.md")
            XCTAssertEqual(underlying as? SafeRelativePath.PathError,
                           .escapesRoot("../../escaped.md"))
        }
        XCTAssertTrue(exists(".trash/\(id)/e.md", in: p))
    }

    /// M3-TR-031 — a destination whose parent directory has been deleted is
    /// re-created to receive the file.
    func test_restore_recreatesAMissingParentDirectoryToReceiveTheFile() async throws {
        let p = try project()
        try write("ch", at: "manuscript/act-one/ch.md", in: p)
        let store = TrashStore(projectURL: p)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/act-one/ch.md",
            itemMetadata: Data(#"{"id":"ch"}"#.utf8),
            originalParentId: "grp", originalIndex: 2, displayTitle: "Ch")
        try FileManager.default.removeItem(at: p.appendingPathComponent("manuscript/act-one"))
        XCTAssertFalse(exists("manuscript/act-one", in: p))

        _ = try await store.restore(trashId: entry.id)

        XCTAssertTrue(exists("manuscript/act-one/ch.md", in: p),
                      "the deleted folder is resurrected to hold the restored file")
    }

    /// M3-TR-032 — an entry id with no parseable timestamp throws
    /// `malformedEntryId` AFTER every side effect has already happened: the file
    /// is back on disk and the trash entry is gone, yet the caller sees a failure
    /// and does no manifest work.
    func test_restore_malformedEntryId_throwsAfterTheWorkIsAlreadyDone() async throws {
        let p = try project()
        try plantEntry(in: p, folderName: "totally-malformed",
                       meta: metaJSON(path: "manuscript/m.md"), file: ("m.md", "words"))

        do {
            _ = try await TrashStore(projectURL: p).restore(trashId: "totally-malformed")
            XCTFail("expected a throw")
        } catch let error as TrashStore.TrashError {
            guard case .malformedEntryId(let id) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(id, "totally-malformed")
        }
        XCTAssertTrue(exists("manuscript/m.md", in: p), "the file moved before the throw")
        XCTAssertFalse(exists(".trash/totally-malformed", in: p), "the entry was deleted too")
    }

    // MARK: - ProjectStore: the delete side

    /// M3-TR-033 — a structure delete refreshes the pane and arms ⌘⌥Z.
    func test_deleteStructureItem_refreshesTheEntriesAndArmsTheUndoToken() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let ch2 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 2" })

        try await store.deleteStructureItem(id: ch2.id)

        XCTAssertEqual(store.trashEntries.map(\.displayTitle), ["Chapter 2"])
        XCTAssertEqual(store.lastDeletedTrashId, store.trashEntries[0].id)
        XCTAssertFalse(exists("manuscript/01-act-one/02-chapter-2.md", in: url))
    }

    /// M3-TR-034 — a structure item with no path cannot be deleted at all: the
    /// empty path is refused by the path guard, the row survives, and an empty
    /// trash folder is left behind.
    func test_deleteStructureItem_withNoPath_throws_andLeavesTheRowAndALitterFolder() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        XCTAssertTrue(store.manifest.structure.contains { $0.id == "doc-pathless" })

        do {
            try await store.deleteStructureItem(id: "doc-pathless")
            XCTFail("expected a throw")
        } catch let error as TrashStore.TrashError {
            guard case .unsafeRelativePath(let path, let underlying) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(path, "")
            XCTAssertEqual(underlying as? SafeRelativePath.PathError, .emptyPath)
        }
        XCTAssertTrue(store.manifest.structure.contains { $0.id == "doc-pathless" },
                      "the row survives the failed delete")
        XCTAssertEqual(trashFolders(in: url).count, 1, "and an empty entry folder is left")
    }

    /// M3-TR-035 / M3-TR-036 — deleting a research LINK makes no trash entry, and
    /// leaves `lastDeletedTrashId` pointing at an EARLIER, unrelated deletion.
    func test_deleteResearchLink_makesNoTrashEntry_andLeavesTheUndoTokenOnAnEarlierItem() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItem(id: "res-note")
        let tokenAfterNote = try XCTUnwrap(store.lastDeletedTrashId)

        try await store.deleteResearchItem(id: "res-link")

        XCTAssertFalse(store.manifest.research.contains { $0.id == "res-link" },
                       "the link is gone from the manifest")
        XCTAssertFalse(store.trashEntries.contains { $0.displayTitle == "A Link" },
                       "and it left no trash entry — there is no route back to it")
        XCTAssertEqual(store.lastDeletedTrashId, tokenAfterNote,
                       "⌘⌥Z still points at the note deleted BEFORE it")
    }

    /// M3-TR-037 — one delete gesture over three items arms ⌘⌥Z with only the
    /// last of them.
    func test_deleteResearchItems_batch_armsTheUndoTokenWithOnlyTheLastEntry() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItems(ids: ["res-note", "res-note2", "res-note3"])

        XCTAssertEqual(store.trashEntries.count, 3)
        let last = try XCTUnwrap(store.lastDeletedTrashId)
        XCTAssertEqual(store.trashEntries.first { $0.id == last }?.displayTitle, "Note Three")
    }

    // MARK: - ProjectStore: restoreTrashEntry

    /// M3-TR-038 — a structure item returns to its recorded parent at its
    /// recorded index, clamped to the parent's current child count.
    func test_restoreTrashEntry_returnsAStructureItemToItsParentAtAClampedIndex() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let actOne = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })
        let ch2 = try XCTUnwrap(actOne.children?.first { $0.title == "Chapter 2" })
        let ch3 = try XCTUnwrap(actOne.children?.first { $0.title == "Chapter 3" })

        try await store.deleteStructureItem(id: ch2.id)     // originalIndex 1
        try await store.deleteStructureItem(id: ch3.id)     // leaves one sibling
        let ch2Entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "Chapter 2" })
        try await store.restoreTrashEntry(id: ch2Entry.id)

        let back = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })
        XCTAssertEqual(back.children?.map(\.title), ["Chapter 1", "Chapter 2"])
        XCTAssertFalse(store.manifest.structure.contains { $0.id == ch2.id },
                       "not appended to root")
    }

    /// M3-TR-039 — when the original parent is gone the ROW falls back to root
    /// but keeps its original nested PATH, and the file is restored into a
    /// re-created copy of the folder the writer deleted.
    func test_restoreTrashEntry_whenTheParentIsGone_putsTheRowAtRootAndTheFileInAResurrectedFolder() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let actOne = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })
        let ch1 = try XCTUnwrap(actOne.children?.first { $0.title == "Chapter 1" })

        try await store.deleteStructureItem(id: ch1.id)
        let ch1Entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "Chapter 1" })
        try await store.deleteStructureItem(id: actOne.id)
        XCTAssertFalse(exists("manuscript/01-act-one", in: url))

        try await store.restoreTrashEntry(id: ch1Entry.id)

        XCTAssertEqual(store.manifest.structure.map(\.title),
                       ["Chapter 1", "Epilogue", "Pathless"])
        XCTAssertEqual(store.manifest.structure.first { $0.title == "Chapter 1" }?.path,
                       "manuscript/01-act-one/01-chapter-1.md",
                       "the root row still claims a nested path")
        XCTAssertTrue(exists("manuscript/01-act-one/01-chapter-1.md", in: url),
                      "and the deleted folder is re-created on disk to hold it")
    }

    /// M3-TR-040 — a restored group silently loses every descendant whose file is
    /// absent. Nothing is returned, thrown or reported.
    func test_restoreTrashEntry_dropsMissingDescendantsSilently_andKeepsTheTopLevelNode() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let actOne = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })

        try await store.deleteStructureItem(id: actOne.id)
        let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "Act One" })
        try FileManager.default.removeItem(
            at: url.appendingPathComponent(".trash/\(entry.id)/01-act-one/02-chapter-2.md"))

        try await store.restoreTrashEntry(id: entry.id)     // returns Void, no report

        let back = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })
        XCTAssertEqual(back.children?.map(\.title), ["Chapter 1", "Chapter 3"],
                       "Chapter 2's row is dropped with no message")
    }

    /// M3-TR-041 — a research item restores into the MANUSCRIPT tree.
    ///
    /// `restoreTrashEntry` tries `StructureItem` first, and a `ResearchItem`'s
    /// JSON decodes as one (`type: "asset"` forward-tolerates to `.document`),
    /// so the `ResearchItem` branch below it is unreachable for anything the
    /// research tree produces. The writer's note comes back as a manuscript row
    /// pointing at a file under `research/`, and the research tree never gets it
    /// back.
    func test_restoreTrashEntry_putsARestoredResearchItemIntoTheManuscriptTree() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItem(id: "res-note")
        try await store.restoreLastDeleted()

        XCTAssertFalse(store.manifest.research.contains { $0.id == "res-note" },
                       "the research tree does not get it back")
        let row = try XCTUnwrap(store.manifest.structure.first { $0.id == "res-note" },
                                "it lands in the manuscript structure instead")
        XCTAssertEqual(row.title, "A Note")
        XCTAssertEqual(row.type, .document)
        XCTAssertEqual(row.path, "research/note.md")
        XCTAssertTrue(exists("research/note.md", in: url), "the file itself is restored correctly")
    }

    /// M3-TR-041b — the same for a research GROUP, which arrives as a manuscript
    /// group carrying its children.
    func test_restoreTrashEntry_putsARestoredResearchGroupIntoTheManuscriptTree() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItem(id: "res-grp")
        let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "A Folder" })
        try await store.restoreTrashEntry(id: entry.id)

        XCTAssertFalse(store.manifest.research.contains { $0.id == "res-grp" })
        let row = try XCTUnwrap(store.manifest.structure.first { $0.id == "res-grp" })
        XCTAssertEqual(row.type, .group)
        XCTAssertEqual(row.children?.map(\.title), ["Kid"])
    }

    /// M3-TR-042 — a trash entry whose metadata decodes as NEITHER kind restores
    /// its file, changes no manifest row, and reports success.
    func test_restoreTrashEntry_withMetadataOfNeitherKind_restoresTheFileAndReportsSuccess() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        try write("\\usepackage{x}", at: ".maugham/publish/pieces/y.tex", in: url)
        let styleEntry = try await store.trashStore.moveToTrash(
            fileRelativePath: ".maugham/publish/pieces/y.tex",
            itemMetadata: Data(#"{"id":"style-y"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "y.tex")
        let structureBefore = store.manifest.structure
        let researchBefore = store.manifest.research

        try await store.restoreTrashEntry(id: styleEntry.id)    // no throw

        XCTAssertEqual(store.manifest.structure, structureBefore)
        XCTAssertEqual(store.manifest.research, researchBefore)
        XCTAssertTrue(exists(".maugham/publish/pieces/y.tex", in: url))
        XCTAssertFalse(store.trashEntries.contains { $0.id == styleEntry.id })
    }

    /// M3-TR-043 / M3-TR-048 — both disposal verbs disarm ⌘⌥Z when they consume
    /// the entry it points at.
    func test_restoreAndPermanentDelete_clearTheUndoTokenTheyConsume() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let ch1 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 1" })

        try await store.deleteStructureItem(id: ch1.id)
        try await store.restoreTrashEntry(id: try XCTUnwrap(store.lastDeletedTrashId))
        XCTAssertNil(store.lastDeletedTrashId)

        try await store.deleteStructureItem(id: ch1.id)
        try await store.permanentlyDeleteTrashEntry(id: try XCTUnwrap(store.lastDeletedTrashId))
        XCTAssertNil(store.lastDeletedTrashId)
        XCTAssertTrue(store.trashEntries.isEmpty)
    }

    /// M3-TR-044 — ⌘⌥Z with nothing armed is a silent no-op.
    func test_restoreLastDeleted_withNoArmedToken_isASilentNoOp() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let before = store.manifest.structure

        try await store.restoreLastDeleted()    // no throw, no signal of any kind

        XCTAssertEqual(store.manifest.structure, before)
        XCTAssertNil(store.lastDeletedTrashId)
    }

    // MARK: - emptyTrash / permanentlyDelete

    /// M3-TR-045 — `emptyTrash` cannot report a failure: it swallows every
    /// per-entry error and clears the cached array unconditionally.
    func test_emptyTrash_swallowsEveryFailure_andClearsTheCacheRegardless() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let ch1 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 1" })
        try await store.deleteStructureItem(id: ch1.id)
        let id = try XCTUnwrap(store.lastDeletedTrashId)
        // Make the delete fail by removing the folder behind the store's back.
        try FileManager.default.removeItem(at: url.appendingPathComponent(".trash/\(id)"))

        try await store.emptyTrash()            // no throw

        XCTAssertTrue(store.trashEntries.isEmpty)
        XCTAssertNil(store.lastDeletedTrashId)
    }

    /// M3-TR-046 — `emptyTrash` only touches entries in its CACHED array. An
    /// entry written to `.trash/` behind `ProjectStore`'s back (which is exactly
    /// how the MCP piece-style tools write one) survives an "Empty Trash" that
    /// then reports the trash as empty.
    func test_emptyTrash_leavesBehindAnyOnDiskEntryMissingFromItsCache() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let ch1 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 1" })
        try await store.deleteStructureItem(id: ch1.id)
        XCTAssertEqual(store.trashEntries.count, 1)

        try write("\\usepackage{x}", at: ".maugham/publish/pieces/x.tex", in: url)
        let side = try await store.trashStore.moveToTrash(
            fileRelativePath: ".maugham/publish/pieces/x.tex",
            itemMetadata: Data(#"{"id":"style-x"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "x.tex")
        let onDiskBefore = try await store.trashStore.list()
        XCTAssertEqual(onDiskBefore.count, 2, "two entries on disk")

        try await store.emptyTrash()

        XCTAssertTrue(store.trashEntries.isEmpty, "the pane shows an empty trash")
        let onDiskAfter = try await store.trashStore.list()
        XCTAssertEqual(onDiskAfter.map(\.id), [side.id],
                       "while one entry is still on disk")
        XCTAssertTrue(exists(".trash/\(side.id)/x.tex", in: url))
    }

    /// M3-TR-047 — the single-entry path DOES propagate its failure.
    func test_permanentlyDeleteTrashEntry_propagatesAFailure() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        do {
            try await store.permanentlyDeleteTrashEntry(id: "no-such-entry")
            XCTFail("expected a throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        }
    }

    // MARK: - The op log

    /// M3-TR-049 — no verb in this module removes a document's op log. It
    /// survives the trash move, "Permanently Delete", "Empty Trash" and the
    /// 30-day sweep alike.
    func test_noTrashVerbEverRemovesADocumentsOpLog() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let opLog = ".maugham/ops/doc-ch1.jsonl"
        try write("{\"text\":\"every word the writer typed\"}\n", at: opLog, in: url)
        let ch1 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 1" })

        try await store.deleteStructureItem(id: ch1.id)
        XCTAssertTrue(exists(opLog, in: url), "survives the move to trash")

        try await store.permanentlyDeleteTrashEntry(id: try XCTUnwrap(store.lastDeletedTrashId))
        XCTAssertTrue(exists(opLog, in: url), "survives 'This cannot be undone'")

        try await store.emptyTrash()
        XCTAssertTrue(exists(opLog, in: url), "survives Empty Trash")

        try await store.trashStore.sweep()
        XCTAssertTrue(exists(opLog, in: url), "survives the 30-day sweep")

        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent(opLog), encoding: .utf8),
                       "{\"text\":\"every word the writer typed\"}\n")
    }

    // MARK: - load

    /// M3-TR-050 — opening a project destroys expired trash before the window is
    /// on screen, and the sweep's own failure is discarded (`try?`).
    func test_load_sweepsExpiredEntriesBeforeTheProjectIsEvenOpen() async throws {
        let url = try makeNestedProject()
        let expired = "\(TrashStore.timestampPrefix(for: Date().addingTimeInterval(-31 * 86_400)))-old"
        try plantEntry(in: url, folderName: expired,
                       meta: metaJSON(path: "manuscript/gone.md", title: "Gone"),
                       file: ("gone.md", "the writer's chapter"))

        let store = try await ProjectStore.load(from: url)

        XCTAssertFalse(exists(".trash/\(expired)", in: url),
                       "destroyed by the act of opening the project")
        XCTAssertTrue(store.trashEntries.isEmpty)
        XCTAssertNil(store.lastDeletedTrashId, "load never arms the undo token")
    }

    // MARK: - Fixtures

    /// root: Act One [Chapter 1, Chapter 2, Chapter 3], Epilogue, Pathless
    private func makeNestedProject() throws -> URL {
        let url = try project("Nest")
        try write("Chapter 1", at: "manuscript/01-act-one/01-chapter-1.md", in: url)
        try write("Chapter 2", at: "manuscript/01-act-one/02-chapter-2.md", in: url)
        try write("Chapter 3", at: "manuscript/01-act-one/03-chapter-3.md", in: url)
        try write("Epilogue", at: "manuscript/02-epilogue.md", in: url)

        let actOne = StructureItem(
            id: "grp-act1", title: "Act One", type: .group, path: "manuscript/01-act-one",
            children: [
                StructureItem(id: "doc-ch1", title: "Chapter 1", type: .document,
                              path: "manuscript/01-act-one/01-chapter-1.md"),
                StructureItem(id: "doc-ch2", title: "Chapter 2", type: .document,
                              path: "manuscript/01-act-one/02-chapter-2.md"),
                StructureItem(id: "doc-ch3", title: "Chapter 3", type: .document,
                              path: "manuscript/01-act-one/03-chapter-3.md"),
            ])
        let manifest = ProjectManifest(
            type: .novel, title: "Nest", author: "T", created: Date(), modified: Date(),
            structure: [
                actOne,
                StructureItem(id: "doc-epilogue", title: "Epilogue", type: .document,
                              path: "manuscript/02-epilogue.md"),
                StructureItem(id: "doc-pathless", title: "Pathless", type: .document, path: nil),
            ],
            research: [])
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: url.appendingPathComponent(ProjectManifest.fileName))
        return url
    }

    /// research: A Note, Note Two, Note Three, A Folder [Kid], A Link (.link)
    private func makeResearchProject() throws -> URL {
        let url = try project("Res")
        try write("A note", at: "research/note.md", in: url)
        try write("Two", at: "research/note2.md", in: url)
        try write("Three", at: "research/note3.md", in: url)
        try write("Kid", at: "research/folder/kid.md", in: url)

        let items: [ResearchItem] = [
            ResearchItem(id: "res-note", title: "A Note", type: .asset,
                         kind: .document, path: "research/note.md"),
            ResearchItem(id: "res-note2", title: "Note Two", type: .asset,
                         kind: .document, path: "research/note2.md"),
            ResearchItem(id: "res-note3", title: "Note Three", type: .asset,
                         kind: .document, path: "research/note3.md"),
            ResearchItem(id: "res-grp", title: "A Folder", type: .group,
                         path: "research/folder",
                         children: [ResearchItem(id: "res-kid", title: "Kid", type: .asset,
                                                 kind: .document,
                                                 path: "research/folder/kid.md")]),
            ResearchItem(id: "res-link", title: "A Link", type: .asset,
                         kind: .link, path: "research/a-link.link", url: "https://example.com"),
        ]
        let manifest = ProjectManifest(
            type: .novel, title: "Res", author: "T", created: Date(), modified: Date(),
            structure: [], research: items)
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: url.appendingPathComponent(ProjectManifest.fileName))
        return url
    }
}
