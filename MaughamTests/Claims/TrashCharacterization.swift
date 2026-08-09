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
            originalParentId: "grp-1", originalIndex: 7, displayTitle: "A",
            subject: .manuscriptItem)

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
            originalParentId: "grp-1", originalIndex: 7, displayTitle: "A",
            subject: .manuscriptItem)

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
                originalParentId: nil, originalIndex: 0, displayTitle: "B",
            subject: .manuscriptItem)
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
            originalParentId: nil, originalIndex: 0, displayTitle: "Act",
            subject: .manuscriptItem)

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
                    originalParentId: nil, originalIndex: 0, displayTitle: "Z",
            subject: .manuscriptItem)
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
                originalParentId: nil, originalIndex: 0, displayTitle: "Gone",
            subject: .manuscriptItem)
            XCTFail("expected a throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        }
        XCTAssertEqual(trashFolders(in: p).count, 1)
        let visible = try await store.list()
        XCTAssertEqual(visible.count, 0,
                       "the folder exists on disk and is invisible to list()")
    }

    /// M3-TR-011 / M3-TR-012 — fixed under RULING-4, 2026-08-09. Two deletions
    /// landing in the same second under the same metadata id no longer share an
    /// entry folder: the second claims a uniquified name, both meta.json files
    /// survive, `list()` shows both rows, and each restore returns ITS OWN file
    /// and destroys nothing.
    ///
    /// The collision is provoked, not simulated: the two calls are made back to
    /// back and the test only asserts once their timestamp prefixes match, which
    /// is the exact condition that used to collapse them into one folder.
    func test_moveToTrash_sameSecondSameId_mintsSeparateEntries_andEachRestoresItsOwnFile() async throws {
        var collided: (project: URL, first: TrashEntry, second: TrashEntry)?
        for _ in 0..<8 {                       // retry: the two calls must land in one second
            let p = try project()
            try write("one", at: "manuscript/one.md", in: p)
            try write("two", at: "manuscript/two.md", in: p)
            let store = TrashStore(projectURL: p)
            let metadata = Data(#"{"id":"same"}"#.utf8)
            let first = try await store.moveToTrash(
                fileRelativePath: "manuscript/one.md", itemMetadata: metadata,
                originalParentId: nil, originalIndex: 0, displayTitle: "One",
            subject: .manuscriptItem)
            let second = try await store.moveToTrash(
                fileRelativePath: "manuscript/two.md", itemMetadata: metadata,
                originalParentId: nil, originalIndex: 0, displayTitle: "Two",
            subject: .manuscriptItem)
            if Self.stampPrefix(of: first.id) == Self.stampPrefix(of: second.id) {
                collided = (p, first, second)
                break
            }
        }
        let (p, first, second) = try XCTUnwrap(collided, "could not land two moves in one second")
        let store = TrashStore(projectURL: p)

        // Two folders, one file each.
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(trashFolders(in: p).count, 2)
        XCTAssertTrue(exists(".trash/\(first.id)/one.md", in: p))
        XCTAssertTrue(exists(".trash/\(second.id)/two.md", in: p))

        // Both deletions are where the writer would look for them.
        let listed = try await store.list()
        XCTAssertEqual(Set(listed.map(\.displayTitle)), ["One", "Two"])

        // And each restore gives back its own file, leaving the other alone.
        _ = try await store.restore(trashId: first.id)
        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("manuscript/one.md"),
                                  encoding: .utf8), "one")
        XCTAssertTrue(exists(".trash/\(second.id)/two.md", in: p),
                      "the other deletion is untouched by the first's restore")

        _ = try await store.restore(trashId: second.id)
        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("manuscript/two.md"),
                                  encoding: .utf8), "two")
        let emptied = try await store.list()
        XCTAssertTrue(emptied.isEmpty)
    }

    /// M3-TR-061 (RULING-4 + RULING-39) — the uniquified name keeps the
    /// timestamp PREFIX, so the sweep can still date a collided entry from its
    /// folder name rather than falling back to the filesystem. The two fixes
    /// meet here: RULING-39's sweep walks the directory and dates by name, and
    /// a collision-proof id that dropped the prefix would have quietly taken
    /// that away.
    func test_aCollidedEntryFolderNameIsStillDateableFromItsName() async throws {
        var collided: (project: URL, first: TrashEntry, second: TrashEntry)?
        for _ in 0..<8 {
            let p = try project()
            try write("one", at: "manuscript/one.md", in: p)
            try write("two", at: "manuscript/two.md", in: p)
            let store = TrashStore(projectURL: p)
            let metadata = Data(#"{"id":"same"}"#.utf8)
            let first = try await store.moveToTrash(
                fileRelativePath: "manuscript/one.md", itemMetadata: metadata,
                originalParentId: nil, originalIndex: 0, displayTitle: "One",
                subject: .manuscriptItem)
            let second = try await store.moveToTrash(
                fileRelativePath: "manuscript/two.md", itemMetadata: metadata,
                originalParentId: nil, originalIndex: 0, displayTitle: "Two",
                subject: .manuscriptItem)
            if Self.stampPrefix(of: first.id) == Self.stampPrefix(of: second.id) {
                collided = (p, first, second)
                break
            }
        }
        let (p, first, second) = try XCTUnwrap(collided, "could not land two moves in one second")

        let fromName = try XCTUnwrap(TrashStore.parseTimestamp(from: second.id),
                                     "the uniquified id still parses as a timestamp")
        XCTAssertEqual(fromName, TrashStore.parseTimestamp(from: first.id))
        XCTAssertEqual(
            TrashStore.ageOfEntry(at: p.appendingPathComponent(".trash/\(second.id)")),
            fromName,
            "and the sweep dates it from that name, not from the filesystem")
    }

    /// The first two dash-separated fields of an entry id — the timestamp the
    /// folder name carries, which is what `TrashStore.parseTimestamp` reads.
    private static func stampPrefix(of entryId: String) -> String {
        entryId.split(separator: "-", maxSplits: 2).prefix(2).joined(separator: "-")
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

    /// M3-TR-015 — fixed under RULING-7, 2026-08-09. An entry Maugham itself
    /// half-wrote — the writer's file moved into the folder, the meta.json never
    /// landed — is no longer SILENTLY absent from the Trash while its contents
    /// sit on disk. It appears, labelled as exactly what it is.
    ///
    /// Three shapes still skip, and each for its own reason:
    /// - a folder whose NAME is not one Maugham writes, and a loose file at the
    ///   `.trash` root — not Maugham's entries at all, so not Maugham's to
    ///   describe (M3-TR-016 / M3-TR-017, ruled correct under RULING-9);
    /// - an entry folder holding NOTHING (M3-TR-009's refused move) — there are
    ///   no contents to preserve, and a row promising some would be the same
    ///   misrepresentation pointing the other way.
    func test_list_showsAnEntryItCannotRead_ratherThanHidingIt() async throws {
        let p = try project()
        let stamp = TrashStore.timestampPrefix(for: Date())
        try plantEntry(in: p, folderName: "\(stamp)-good",
                       meta: metaJSON(path: "manuscript/good.md", title: "Good"),
                       file: ("good.md", "good"))
        try plantEntry(in: p, folderName: "\(stamp)-nometa", meta: nil,
                       file: ("words.md", "the writer's only copy"))
        try plantEntry(in: p, folderName: "\(stamp)-badmeta", meta: "{ not json",
                       file: ("words.md", "the writer's only copy"))
        try plantEntry(in: p, folderName: "\(stamp)-empty", meta: nil, file: nil)
        try plantEntry(in: p, folderName: "not-a-timestamp-at-all",
                       meta: metaJSON(path: "manuscript/x.md", title: "X"),
                       file: ("x.md", "x"))
        try "stray".write(to: p.appendingPathComponent(".trash/loose.txt"),
                          atomically: true, encoding: .utf8)

        let listed = try await TrashStore(projectURL: p).list()
        XCTAssertEqual(
            listed.map(\.displayTitle).sorted(),
            ["Good", "Unreadable entry (contents preserved)",
             "Unreadable entry (contents preserved)"],
            "the two half-written entries are in the writer's Trash, named for what they are")
        XCTAssertEqual(
            Set(listed.filter(\.isUnreadable).map(\.id)),
            ["\(stamp)-nometa", "\(stamp)-badmeta"])

        // Nothing was disposed of by being listed: every shape is still on disk.
        XCTAssertEqual(trashFolders(in: p).count, 6)
        XCTAssertTrue(exists(".trash/\(stamp)-nometa/words.md", in: p))
        XCTAssertTrue(exists(".trash/\(stamp)-badmeta/words.md", in: p))
    }

    /// M3-TR-062 (RULING-7) — an unreadable entry REFUSES to restore, and the
    /// refusal names its real cause: Maugham's record of the deletion is what
    /// cannot be read, and what was deleted is still on disk. Both surfaces say
    /// so — the store, which knows the entry from an id that is simply not
    /// there (M3-TR-029, still a plain Cocoa error), and the project, which is
    /// where the writer's Restore lands.
    func test_restoringAnUnreadableEntry_refusesAndNamesTheRealCause() async throws {
        let p = try project()
        let stamp = TrashStore.timestampPrefix(for: Date())
        try plantEntry(in: p, folderName: "\(stamp)-nometa", meta: nil,
                       file: ("words.md", "the writer's only copy"))
        let store = TrashStore(projectURL: p)

        do {
            _ = try await store.restore(trashId: "\(stamp)-nometa")
            XCTFail("expected a throw")
        } catch let error as TrashStore.TrashError {
            guard case .entryMetadataUnreadable(let id, _) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(id, "\(stamp)-nometa")
            XCTAssertTrue(error.localizedDescription.contains("still holds what was deleted"))
        }

        XCTAssertTrue(exists(".trash/\(stamp)-nometa/words.md", in: p),
                      "the refusal costs the writer nothing")
    }

    /// M3-TR-063 (RULING-7) — the same refusal at the surface the writer's
    /// Restore actually reaches, as a `trashEntryNotRewirable` the pane alerts.
    func test_restoreTrashEntry_refusesAnUnreadableEntry_atTheProjectLevel() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let stamp = TrashStore.timestampPrefix(for: Date())
        try plantEntry(in: url, folderName: "\(stamp)-nometa", meta: nil,
                       file: ("words.md", "the writer's only copy"))

        do {
            _ = try await store.restoreTrashEntry(id: "\(stamp)-nometa")
            XCTFail("expected a throw")
        } catch let error as ProjectStoreError {
            guard case .trashEntryNotRewirable(let title, let reason) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(title, "Unreadable entry (contents preserved)")
            XCTAssertTrue(reason.contains("still in the trash folder"), "observed: \(reason)")
        }
        XCTAssertTrue(exists(".trash/\(stamp)-nometa/words.md", in: url))
    }

    /// M3-TR-064 (RULING-7) — and the unreadable entry can still be disposed
    /// of. Being visible is not the same as being immortal: "Permanently
    /// Delete" reaches it by folder name exactly as it reaches a readable one.
    func test_anUnreadableEntryCanStillBePermanentlyDeleted() async throws {
        let p = try project()
        let stamp = TrashStore.timestampPrefix(for: Date())
        try plantEntry(in: p, folderName: "\(stamp)-nometa", meta: nil,
                       file: ("words.md", "the writer's only copy"))
        let store = TrashStore(projectURL: p)
        let listed = try await store.list()
        let entry = try XCTUnwrap(listed.first)

        try await store.permanentlyDelete(trashId: entry.id)

        XCTAssertFalse(exists(".trash/\(stamp)-nometa", in: p))
        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty)
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

    /// M3-TR-021 — fixed under RULING-39, 2026-08-09. The sweep walks the trash
    /// DIRECTORY, so an entry whose meta.json never landed is no longer
    /// invisible AND immortal: it is still invisible (that half is
    /// M3-TR-015's, and ruled correct), but it expires by age like everything
    /// else instead of travelling into every backup for ever.
    func test_sweep_reachesAnEntryListCannotSee_soAMetaLessEntryIsNotImmortal() async throws {
        let p = try project()
        let ancient = TrashStore.timestampPrefix(for: Date().addingTimeInterval(-900 * 86_400))
        try plantEntry(in: p, folderName: "\(ancient)-ancient", meta: nil,
                       file: ("chapter.md", "the writer's only copy"))

        let store = TrashStore(projectURL: p)
        try await store.sweep()

        XCTAssertFalse(exists(".trash/\(ancient)-ancient", in: p),
                       "a 900-day-old meta-less entry is swept")
        let visible = try await store.list()
        XCTAssertEqual(visible.count, 0)
    }

    /// M3-TR-052 (RULING-39) — an entry the sweep can date NEITHER from its
    /// folder name nor from its metadata is dated by the folder's own
    /// filesystem timestamps, so nothing in `.trash/` is unreachable by age.
    func test_sweep_datesAnUnparseableEntryByItsOwnFileTimestamps() async throws {
        let p = try project()
        try plantEntry(in: p, folderName: "not-a-timestamp-at-all", meta: nil,
                       file: ("chapter.md", "words"))
        let folder = p.appendingPathComponent(".trash/not-a-timestamp-at-all")
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-90 * 86_400),
             .modificationDate: Date().addingTimeInterval(-90 * 86_400)],
            ofItemAtPath: folder.path)

        try await TrashStore(projectURL: p).sweep()

        XCTAssertFalse(exists(".trash/not-a-timestamp-at-all", in: p))
    }

    /// M3-TR-053 (RULING-39) — and the age test is real in both directions: a
    /// young undateable entry is left alone.
    func test_sweep_keepsAnUnparseableEntryThatIsNotOldYet() async throws {
        let p = try project()
        try plantEntry(in: p, folderName: "not-a-timestamp-at-all", meta: nil,
                       file: ("chapter.md", "words"))

        try await TrashStore(projectURL: p).sweep()

        XCTAssertTrue(exists(".trash/not-a-timestamp-at-all/chapter.md", in: p))
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
            originalParentId: "grp-act", originalIndex: 4, displayTitle: "Chapter 9",
            subject: .manuscriptItem)

        let restored = try await store.restore(trashId: entry.id)

        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("manuscript/ch9.md"),
                                  encoding: .utf8), "Chapter 9 content")
        XCTAssertFalse(exists(".trash/\(entry.id)", in: p))
        XCTAssertEqual(restored.originalParentId, "grp-act")
        XCTAssertEqual(restored.originalIndex, 4)
    }

    /// M3-TR-027 — fixed under RULING-38, 2026-08-09. A restore blocked by an
    /// occupant now restores BESIDE it under a distinguishing name: both
    /// copies are on disk, nothing is overwritten, nothing is refused, and the
    /// entry is consumed rather than left to fail identically for ever.
    func test_restore_intoAnOccupiedPath_landsBesideTheOccupant_overwritingNothing() async throws {
        let p = try project()
        try write("original", at: "manuscript/a.md", in: p)
        let store = TrashStore(projectURL: p)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/a.md",
            itemMetadata: Data(#"{"id":"a"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "A",
            subject: .manuscriptItem)
        try write("replacement", at: "manuscript/a.md", in: p)

        let restored = try await store.restore(trashId: entry.id)

        XCTAssertEqual(restored.restoredRelativePath, "manuscript/a-2.md",
                       "the writer's item comes back beside the occupant")
        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("manuscript/a.md"),
                                  encoding: .utf8), "replacement",
                       "the occupant is untouched")
        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("manuscript/a-2.md"),
                                  encoding: .utf8), "original",
                       "and the trashed copy is back, whole")
        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty, "the entry is consumed")
    }

    /// M3-TR-054 (RULING-38) — a third copy takes the next number rather than
    /// colliding with the second.
    func test_restore_besideTwoOccupants_takesTheNextFreeName() async throws {
        let p = try project()
        try write("original", at: "manuscript/a.md", in: p)
        let store = TrashStore(projectURL: p)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/a.md",
            itemMetadata: Data(#"{"id":"a"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "A",
            subject: .manuscriptItem)
        try write("replacement", at: "manuscript/a.md", in: p)
        try write("another", at: "manuscript/a-2.md", in: p)

        let restored = try await store.restore(trashId: entry.id)

        XCTAssertEqual(restored.restoredRelativePath, "manuscript/a-3.md")
        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("manuscript/a-2.md"),
                                  encoding: .utf8), "another")
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
            originalParentId: "grp", originalIndex: 2, displayTitle: "Ch",
            subject: .manuscriptItem)
        try FileManager.default.removeItem(at: p.appendingPathComponent("manuscript/act-one"))
        XCTAssertFalse(exists("manuscript/act-one", in: p))

        _ = try await store.restore(trashId: entry.id)

        XCTAssertTrue(exists("manuscript/act-one/ch.md", in: p),
                      "the deleted folder is resurrected to hold the restored file")
    }

    /// M3-TR-032 — fixed under RULING-4, 2026-08-09 (a side effect of the
    /// RULING-38/41 restructure, and the fix its own filing named: "validating
    /// first would have cost nothing"). An entry id with no parseable timestamp
    /// is refused BEFORE anything moves, so the accident that produced it costs
    /// the writer neither route back: the entry survives whole.
    func test_restore_malformedEntryId_throwsBeforeTouchingAnything() async throws {
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
        XCTAssertFalse(exists("manuscript/m.md", in: p), "nothing moved")
        XCTAssertTrue(exists(".trash/totally-malformed/m.md", in: p),
                      "and the entry is still there to be recovered by hand")
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
        XCTAssertEqual(store.lastDeletion?.trashIds, [store.trashEntries[0].id])
        XCTAssertEqual(store.lastDeletion?.label, "Chapter 2")
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

    /// M3-TR-035 / M3-TR-036 — fixed under RULING-45 and RULING-40,
    /// 2026-08-09. Deleting a research LINK makes a trash entry like every
    /// other row (there is no file to move, so the entry IS the record), and
    /// ⌘⌥Z is armed with THAT deletion rather than left pointing at an
    /// earlier, unrelated one.
    func test_deleteResearchLink_makesATrashEntry_andArmsTheUndoTokenWithIt() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItem(id: "res-note")
        let deletionOfTheNote = try XCTUnwrap(store.lastDeletion)

        try await store.deleteResearchItem(id: "res-link")

        XCTAssertFalse(store.manifest.research.contains { $0.id == "res-link" },
                       "the link is gone from the manifest")
        let linkEntry = try XCTUnwrap(
            store.trashEntries.first { $0.displayTitle == "A Link" },
            "and it left a trash entry — there IS a route back to it")
        XCTAssertFalse(linkEntry.carriesFile, "a manifest-only entry, by design")
        XCTAssertNotEqual(store.lastDeletion, deletionOfTheNote,
                          "⌘⌥Z points at the link, not the note deleted before it")
        XCTAssertEqual(store.lastDeletion?.trashIds, [linkEntry.id])
    }

    /// M3-TR-055 (RULING-45) — and the link comes BACK, into the research tree,
    /// carrying the URL and title that were its whole content.
    func test_restoringADeletedResearchLink_returnsItToTheResearchTree() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItem(id: "res-link")
        try await store.restoreLastDeletion()

        let back = try XCTUnwrap(store.manifest.research.first { $0.id == "res-link" })
        XCTAssertEqual(back.title, "A Link")
        XCTAssertEqual(back.url, "https://example.com")
        XCTAssertEqual(back.kind, .link)
        XCTAssertFalse(store.manifest.structure.contains { $0.id == "res-link" },
                       "and not into the manuscript binder")
        XCTAssertTrue(store.trashEntries.isEmpty)
    }

    /// M3-TR-037 — fixed under RULING-40, 2026-08-09. One delete gesture over
    /// three items is ONE deletion: ⌘⌥Z returns all three or refuses.
    func test_deleteResearchItems_batch_armsTheUndoTokenWithTheWholeGesture() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItems(ids: ["res-note", "res-note2", "res-note3"])

        XCTAssertEqual(store.trashEntries.count, 3)
        let deletion = try XCTUnwrap(store.lastDeletion)
        XCTAssertEqual(Set(deletion.trashIds), Set(store.trashEntries.map(\.id)))
        XCTAssertEqual(deletion.label, "3 items")

        let report = try await store.restoreLastDeletion()

        XCTAssertEqual(store.manifest.research.compactMap { $0.title }.sorted(),
                       ["A Folder", "A Link", "A Note", "Note Three", "Note Two"],
                       "the whole gesture comes back in one act")
        XCTAssertTrue(try XCTUnwrap(report).isComplete)
        XCTAssertNil(store.lastDeletion)
    }

    /// M3-TR-056 (RULING-40) — a deletion that can no longer be returned whole
    /// is REFUSED and says why, restoring nothing rather than part of it.
    func test_restoreLastDeletion_refusesAndSaysWhy_whenPartOfTheGestureIsGone() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)
        try await store.deleteResearchItems(ids: ["res-note", "res-note2", "res-note3"])
        let victim = try XCTUnwrap(
            store.trashEntries.first { $0.displayTitle == "Note Two" })
        try await store.permanentlyDeleteTrashEntry(id: victim.id)

        do {
            _ = try await store.restoreLastDeletion()
            XCTFail("expected a refusal")
        } catch let error as ProjectStoreError {
            guard case .deletionNotRestorableWhole(let label, let reason) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(label, "3 items")
            XCTAssertTrue(reason.contains("1 of its 3"), "observed: \(reason)")
        }

        XCTAssertFalse(store.manifest.research.contains { $0.id == "res-note" },
                       "nothing came back — a deletion returns whole or not at all")
        XCTAssertEqual(store.trashEntries.count, 2)
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

    /// M3-TR-039 — fixed under RULING-41, 2026-08-09. When the original parent
    /// is gone the row falls back to root and its FILE follows it there: the
    /// folder the writer deleted is not re-created behind their back, and the
    /// row's path is what the binder says it is.
    func test_restoreTrashEntry_whenTheParentIsGone_putsTheRowAndItsFileAtRoot() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let actOne = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })
        let ch1 = try XCTUnwrap(actOne.children?.first { $0.title == "Chapter 1" })

        try await store.deleteStructureItem(id: ch1.id)
        let ch1Entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "Chapter 1" })
        try await store.deleteStructureItem(id: actOne.id)
        XCTAssertFalse(exists("manuscript/01-act-one", in: url))

        let report = try await store.restoreTrashEntry(id: ch1Entry.id)

        XCTAssertEqual(store.manifest.structure.map(\.title),
                       ["Chapter 1", "Epilogue", "Pathless"])
        XCTAssertEqual(store.manifest.structure.first { $0.title == "Chapter 1" }?.path,
                       "manuscript/01-chapter-1.md",
                       "the root row's path is where the row actually is")
        XCTAssertTrue(exists("manuscript/01-chapter-1.md", in: url))
        XCTAssertFalse(exists("manuscript/01-act-one", in: url),
                       "the folder the writer deleted is not resurrected")
        // RULING-42: the arrangement it could not give back is named.
        XCTAssertEqual(report.relocated.map(\.restoredPath), ["manuscript/01-chapter-1.md"])
        XCTAssertNotNil(report.message)
    }

    /// M3-TR-040 — fixed under RULING-42, 2026-08-09. A restored group still
    /// drops descendants whose files are gone, but it NAMES them: the report
    /// says what it could not bring back, at the moment of the restore.
    func test_restoreTrashEntry_namesTheDescendantsItCouldNotBringBack() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let actOne = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })

        try await store.deleteStructureItem(id: actOne.id)
        let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "Act One" })
        try FileManager.default.removeItem(
            at: url.appendingPathComponent(".trash/\(entry.id)/01-act-one/02-chapter-2.md"))

        let report = try await store.restoreTrashEntry(id: entry.id)

        let back = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })
        XCTAssertEqual(back.children?.map(\.title), ["Chapter 1", "Chapter 3"])
        XCTAssertEqual(report.unreturned, ["Chapter 2"])
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.message, "Couldn’t bring back: Chapter 2.")
    }

    /// M3-TR-041 — fixed under RULING-45's mechanism, 2026-08-09 (the defect
    /// itself is RULING-22's). The entry records WHAT it is a deletion of, so a
    /// research note comes back to the research tree instead of decoding as a
    /// `StructureItem` and landing in the manuscript binder.
    func test_restoreTrashEntry_putsARestoredResearchItemBackInTheResearchTree() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItem(id: "res-note")
        try await store.restoreLastDeletion()

        XCTAssertFalse(store.manifest.structure.contains { $0.id == "res-note" },
                       "not into the manuscript structure")
        let row = try XCTUnwrap(store.manifest.research.first { $0.id == "res-note" })
        XCTAssertEqual(row.title, "A Note")
        XCTAssertEqual(row.kind, .document)
        XCTAssertEqual(row.path, "research/note.md")
        XCTAssertTrue(exists("research/note.md", in: url))
    }

    /// M3-TR-041b — the same for a research GROUP and its children.
    func test_restoreTrashEntry_putsARestoredResearchGroupBackInTheResearchTree() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItem(id: "res-grp")
        let entry = try XCTUnwrap(store.trashEntries.first { $0.displayTitle == "A Folder" })
        try await store.restoreTrashEntry(id: entry.id)

        XCTAssertFalse(store.manifest.structure.contains { $0.id == "res-grp" })
        let row = try XCTUnwrap(store.manifest.research.first { $0.id == "res-grp" })
        XCTAssertEqual(row.type, .group)
        XCTAssertEqual(row.children?.map(\.title), ["Kid"])
    }

    /// M3-TR-042 — fixed under RULING-43, 2026-08-09. Maugham's own safety copy
    /// of a file the writer never deleted does not appear in the Trash pane at
    /// all, and a Restore aimed at one REFUSES by name rather than restoring a
    /// file, changing no manifest row and reporting success.
    func test_anInternalSafetyCopyIsNotInTheWritersTrash_andRefusesToBeRestored() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        try write("\\usepackage{x}", at: ".maugham/publish/pieces/y.tex", in: url)
        let styleEntry = try await store.trashStore.moveToTrash(
            fileRelativePath: ".maugham/publish/pieces/y.tex",
            itemMetadata: Data(#"{"id":"style-y"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "y.tex",
            subject: .internalArtifact)

        let listed = try await store.trashStore.list()
        XCTAssertFalse(listed.contains { $0.id == styleEntry.id },
                       "the writer's Trash shows the writer's deletions only")

        do {
            _ = try await store.restoreTrashEntry(id: styleEntry.id)
            XCTFail("expected a refusal")
        } catch let error as ProjectStoreError {
            guard case .trashEntryNotRewirable(let title, _) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(title, "y.tex")
        }
        XCTAssertTrue(exists(".trash/\(styleEntry.id)/y.tex", in: url),
                      "and the refusal changes nothing")
    }

    /// M3-TR-057 (RULING-43) — a legacy entry (no recorded subject) whose
    /// metadata describes neither tree is refused too: there is no wiring to
    /// put back, so there is no Restore that can honestly claim success.
    func test_restoreTrashEntry_withMetadataOfNeitherKind_refusesLoudly() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        try write("x", at: "manuscript/orphan.md", in: url)
        let planted = try await store.trashStore.moveToTrash(
            fileRelativePath: "manuscript/orphan.md",
            itemMetadata: Data(#"{"id":"style-y"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "orphan.md",
            subject: .manuscriptItem)
        // Strip the subject to make it look like an entry written before the
        // field existed.
        let metaURL = url.appendingPathComponent(".trash/\(planted.id)/meta.json")
        var meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metaURL)) as! [String: Any]
        meta.removeValue(forKey: "subject")
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)

        do {
            _ = try await store.restoreTrashEntry(id: planted.id)
            XCTFail("expected a refusal")
        } catch let error as ProjectStoreError {
            guard case .trashEntryNotRewirable = error else {
                return XCTFail("wrong case: \(error)")
            }
        }
    }

    /// M3-TR-043 / M3-TR-048 — restoring consumes the entry it returns, so the
    /// armed deletion empties out; DESTROYING one does NOT quietly disarm ⌘⌥Z
    /// (changed under RULING-40, 2026-08-09) — the record survives so the next
    /// ⌘⌥Z can refuse and say why rather than doing nothing at all.
    func test_restoreConsumesTheArmedDeletion_whileDestructionLeavesItToRefuse() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let ch1 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 1" })

        try await store.deleteStructureItem(id: ch1.id)
        try await store.restoreLastDeletion()
        XCTAssertNil(store.lastDeletion)

        try await store.deleteStructureItem(id: ch1.id)
        let armed = try XCTUnwrap(store.lastDeletion)
        try await store.permanentlyDeleteTrashEntry(id: armed.trashIds[0])
        XCTAssertEqual(store.lastDeletion, armed)
        XCTAssertTrue(store.trashEntries.isEmpty)

        do {
            _ = try await store.restoreLastDeletion()
            XCTFail("expected a refusal")
        } catch let error as ProjectStoreError {
            guard case .deletionNotRestorableWhole(let label, let reason) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(label, "Chapter 1")
            XCTAssertTrue(reason.contains("no longer in the project’s trash"),
                          "observed: \(reason)")
        }
    }

    /// M3-TR-044 — ⌘⌥Z with nothing armed is a silent no-op.
    func test_restoreLastDeletion_withNothingArmed_isASilentNoOp() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let before = store.manifest.structure

        let report = try await store.restoreLastDeletion()   // no throw, no signal

        XCTAssertNil(report)
        XCTAssertEqual(store.manifest.structure, before)
        XCTAssertNil(store.lastDeletion)
    }

    /// M3-TR-058 (RULING-38, at the ProjectStore level) — a restore blocked by
    /// an occupant leaves the writer with BOTH rows in the binder, under
    /// distinguishable names, and the row's path is the file that is actually
    /// there.
    func test_restoreTrashEntry_besideAnOccupant_leavesBothRowsVisibleAndNamedApart() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let ch1 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 1" })

        try await store.deleteStructureItem(id: ch1.id)
        // The writer replaces it: same title, same freed filename.
        try write("a fresh start", at: "manuscript/01-act-one/01-chapter-1.md", in: url)
        _ = try await store.addStructureItem(
            parentId: "grp-act1", title: "Chapter 1", kind: .document(extension: "md"))

        let report = try await store.restoreLastDeletion()

        let actOne = try XCTUnwrap(store.manifest.structure.first { $0.title == "Act One" })
        let restored = try XCTUnwrap(actOne.children?.first { $0.id == ch1.id })
        XCTAssertNotEqual(restored.title, "Chapter 1", "named apart from the occupant")
        XCTAssertTrue(restored.title.hasPrefix("Chapter 1"), "observed: \(restored.title)")
        let restoredPath = try XCTUnwrap(restored.path)
        XCTAssertTrue(exists(restoredPath, in: url), "the row's path is the file that is there")
        XCTAssertEqual(
            try String(contentsOf: url.appendingPathComponent(restoredPath), encoding: .utf8),
            "Chapter 1", "and it holds the writer's original words")
        XCTAssertEqual(
            actOne.children?.filter { $0.title.hasPrefix("Chapter 1") }.count, 2,
            "both are in the binder")
        XCTAssertNotNil(try XCTUnwrap(report).message, "and the restore says so")
    }

    // MARK: - emptyTrash / permanentlyDelete

    /// M3-TR-045 — fixed under RULING-7, 2026-08-09. `emptyTrash` no longer
    /// swallows its per-entry failures behind a `try?` and reports a completed
    /// destruction regardless: what it could not destroy is thrown to the
    /// caller (TrashView alerts) and is STILL LISTED afterwards, so the pane and
    /// the message agree about what is left.
    ///
    /// The failure is provoked the way a real one arrives — the entry cannot be
    /// removed — by making the entry FOLDER unwritable, so the unlink of its
    /// first child fails and the writer's file is still there afterwards to be
    /// listed. (Making `.trash/` itself unwritable instead destroys the
    /// contents and fails only on the empty folder: a different case, and not
    /// the one this pins.)
    func test_emptyTrash_reportsWhatItCouldNotDestroy_andLeavesItListed() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let ch1 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 1" })
        try await store.deleteStructureItem(id: ch1.id)
        let id = try XCTUnwrap(store.lastDeletion?.trashIds.first)

        let entryFolder = url.appendingPathComponent(".trash/\(id)")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: entryFolder.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: entryFolder.path)
        }

        do {
            try await store.emptyTrash()
            XCTFail("expected a throw — the entry could not be destroyed")
        } catch let error as ProjectStoreError {
            guard case .trashNotEmptied(let undestroyed, let total) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(undestroyed, 1)
            XCTAssertEqual(total, 1)
            XCTAssertTrue(error.localizedDescription.contains("still in the Trash"),
                          "observed: \(error.localizedDescription)")
        }

        XCTAssertEqual(store.trashEntries.map(\.id), [id],
                       "what survived the emptying is still listed")
        XCTAssertTrue(exists(".trash/\(id)/01-chapter-1.md", in: url),
                      "and the writer's file is still in it")
    }

    /// M3-TR-046 — fixed under RULING-7, 2026-08-09. `emptyTrash` empties the
    /// trash DIRECTORY, not its cached array. An entry written to `.trash/`
    /// behind `ProjectStore`'s back — which is exactly how the MCP piece-style
    /// tools write one — is destroyed with the rest, so "the trash is empty" is
    /// true at the moment the pane says it.
    func test_emptyTrash_destroysEveryEntryOnDisk_notOnlyTheCachedOnes() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let ch1 = try XCTUnwrap(store.manifest.structure
            .first { $0.title == "Act One" }?.children?.first { $0.title == "Chapter 1" })
        try await store.deleteStructureItem(id: ch1.id)
        XCTAssertEqual(store.trashEntries.count, 1)

        try write("\\usepackage{x}", at: ".maugham/publish/pieces/x.tex", in: url)
        // Exactly how the MCP piece-style tools write one — and as of
        // RULING-43 that entry declares itself Maugham's own, so it is not in
        // the writer's Trash to begin with.
        let side = try await store.trashStore.moveToTrash(
            fileRelativePath: ".maugham/publish/pieces/x.tex",
            itemMetadata: Data(#"{"id":"style-x"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "x.tex",
            subject: .internalArtifact)
        let onDiskBefore = try await store.trashStore.entriesIncludingInternal()
        XCTAssertEqual(onDiskBefore.count, 2, "two entries on disk")

        try await store.emptyTrash()

        XCTAssertTrue(store.trashEntries.isEmpty, "the pane shows an empty trash")
        let onDiskAfter = try await store.trashStore.entriesIncludingInternal()
        XCTAssertTrue(onDiskAfter.isEmpty, "and the disk agrees with the pane")
        XCTAssertFalse(exists(".trash/\(side.id)", in: url),
                       "the entry ProjectStore never cached is destroyed too")
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

        try await store.permanentlyDeleteTrashEntry(
            id: try XCTUnwrap(store.lastDeletion?.trashIds.first))
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
        XCTAssertNil(store.lastDeletion, "load never arms the undo token")
    }

    // MARK: - Promotion (RULING-15: delete is normalised, nothing is unlinked)

    /// M3-TR-059 (RULING-15) — promoting a capture no longer UNLINKS the inbox
    /// original: it goes to the project trash, where the writer can find it,
    /// restore it, and re-ingest it (RULING-14). One of the three
    /// `FileManager.removeItem` calls RULING-15 named as immediate defects.
    func test_promotingACaptureSendsTheInboxOriginalToTheTrash_notOffTheDisk() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("claims-promote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = try await ProjectFactory.createNovelProject(named: "Promote", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/inbox/audio"),
            withIntermediateDirectories: true)
        let assetURL = url.appendingPathComponent(".maugham/inbox/audio/a1.m4a")
        try Data("the writer's voice".utf8).write(to: assetURL)
        let seedFile = url.appendingPathComponent(".maugham/inbox/inbox.seed.jsonl")
        try await JSONLAppendStore<InboxEntry>(fileURL: seedFile).append(InboxEntry(
            id: "a1", createdAt: Date(timeIntervalSince1970: 100),
            deviceId: "phone", kind: .audio, sourceFilename: "a1.m4a",
            transcript: "a dictated line", transcriptionState: .whisperFinal))
        let inbox = InboxStore(projectURL: url, deviceId: "mac")
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "a1" })

        _ = try await inbox.promoteToResearch(entry, projectStore: store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path),
                       "the original leaves the inbox")
        let listed = try await store.trashStore.list()
        let trashed = try XCTUnwrap(
            listed.first { $0.displayTitle == "a1.m4a" },
            "and it is in the trash, where the writer can see it")
        XCTAssertEqual(trashed.subject, .captureAsset)
        XCTAssertTrue(exists(".trash/\(trashed.id)/a1.m4a", in: url))

        // M3-TR-060 (RULING-15 + RULING-14): and it restores — putting the file
        // back is the whole restore, because no manifest row ever named it.
        try await store.restoreTrashEntry(id: trashed.id)
        XCTAssertEqual(try String(contentsOf: assetURL, encoding: .utf8),
                       "the writer's voice")
        withExtendedLifetime(ds) {}   // documentStore is weak; keep it alive
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
