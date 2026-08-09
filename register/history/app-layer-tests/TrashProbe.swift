import XCTest
import MaughamCore
@testable import Maugham

/// A PROBE, not a test. It asserts almost nothing; it PRINTS observed behaviour
/// so the characterisation assertions in `TrashCharacterization.swift` can be
/// written from what the code ACTUALLY does rather than from what I expected.
///
/// Run just this:
///   xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
///     CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/TrashObservationProbe
@MainActor
final class TrashObservationProbe: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() { super.setUp(); temp = TempDirectory() }
    override func tearDown() { temp = nil; super.tearDown() }

    private func show(_ label: String, _ value: Any) {
        print("PROBE | \(label) = \(value)")
    }

    private func project(_ name: String = "P") throws -> URL {
        let url = temp.url.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, at relative: String, in project: URL) throws -> URL {
        let url = project.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func tree(_ root: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL)?.path.replacingOccurrences(of: root.path + "/", with: "") }
            .sorted()
    }

    // MARK: - TrashStore: moveToTrash

    func test_probe_moveToTrash() async throws {
        // 1. What does the RETURNED entry carry vs what meta.json records?
        let p = try project()
        _ = try write("body", at: "manuscript/a.md", in: p)
        let store = TrashStore(projectURL: p)
        let entry = try await store.moveToTrash(
            fileRelativePath: "manuscript/a.md",
            itemMetadata: Data(#"{"id":"doc-a"}"#.utf8),
            originalParentId: "grp-1",
            originalIndex: 7,
            displayTitle: "A")
        show("moveToTrash/returned.id", entry.id)
        show("moveToTrash/returned.originalParentId", String(describing: entry.originalParentId))
        show("moveToTrash/returned.originalIndex", entry.originalIndex)
        let metaData = try Data(contentsOf: p.appendingPathComponent(".trash/\(entry.id)/meta.json"))
        let meta = try JSONDecoder().decode(TrashStore.TrashMeta.self, from: metaData)
        show("moveToTrash/meta.originalParentId", String(describing: meta.originalParentId))
        show("moveToTrash/meta.originalIndex", meta.originalIndex)
        show("moveToTrash/listed.originalParentId",
             String(describing: (try await store.list()).first?.originalParentId))
        show("moveToTrash/listed.originalIndex",
             String(describing: (try await store.list()).first?.originalIndex))

        // 2. Folder naming when metadata carries no id.
        let p2 = try project()
        _ = try write("b", at: "manuscript/b.md", in: p2)
        let s2 = TrashStore(projectURL: p2)
        let e2 = try await s2.moveToTrash(
            fileRelativePath: "manuscript/b.md",
            itemMetadata: Data(#"{"title":"no id here"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "B")
        show("moveToTrash/no-id-in-metadata/entryId-suffix", e2.id)

        // 3. Empty metadata (not JSON at all).
        let p3 = try project()
        _ = try write("c", at: "manuscript/c.md", in: p3)
        let s3 = TrashStore(projectURL: p3)
        let e3 = try await s3.moveToTrash(
            fileRelativePath: "manuscript/c.md",
            itemMetadata: Data(),
            originalParentId: nil, originalIndex: 0, displayTitle: "C")
        show("moveToTrash/empty-metadata/entryId", e3.id)

        // 4. Two entries, same second, same id -> collision?
        let p4 = try project()
        _ = try write("one", at: "manuscript/one.md", in: p4)
        _ = try write("two", at: "manuscript/two.md", in: p4)
        let s4 = TrashStore(projectURL: p4)
        let c1 = try await s4.moveToTrash(
            fileRelativePath: "manuscript/one.md",
            itemMetadata: Data(#"{"id":"same"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "One")
        let c2 = try await s4.moveToTrash(
            fileRelativePath: "manuscript/two.md",
            itemMetadata: Data(#"{"id":"same"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "Two")
        show("collision/ids-equal", c1.id == c2.id)
        show("collision/entry-count", (try await s4.list()).count)
        show("collision/folder-contents", tree(p4.appendingPathComponent(".trash")))
        if c1.id == c2.id {
            let restored = try await s4.restore(trashId: c1.id)
            show("collision/restored.displayTitle", restored.displayTitle)
            show("collision/project-after-restore", tree(p4))
        }

        // 5. Failure paths: does the entry folder survive a failed move?
        let p5 = try project()
        let s5 = TrashStore(projectURL: p5)
        do {
            _ = try await s5.moveToTrash(
                fileRelativePath: "manuscript/missing.md",
                itemMetadata: Data(#"{"id":"gone"}"#.utf8),
                originalParentId: nil, originalIndex: 0, displayTitle: "Gone")
            show("moveToTrash/missing-source", "DID NOT THROW")
        } catch {
            show("moveToTrash/missing-source/error", "\(type(of: error)): \(error)")
        }
        show("moveToTrash/missing-source/trash-tree", tree(p5.appendingPathComponent(".trash")))
        show("moveToTrash/missing-source/list-count", (try await s5.list()).count)

        // 6. Unsafe relative paths.
        for bad in ["/etc/passwd", "../escape.md", "", "a//b.md", "manuscript/../../x.md"] {
            let pb = try project()
            let sb = TrashStore(projectURL: pb)
            do {
                _ = try await sb.moveToTrash(
                    fileRelativePath: bad,
                    itemMetadata: Data(#"{"id":"z"}"#.utf8),
                    originalParentId: nil, originalIndex: 0, displayTitle: "Z")
                show("moveToTrash/unsafe(\(bad.debugDescription))", "DID NOT THROW")
            } catch {
                show("moveToTrash/unsafe(\(bad.debugDescription))",
                     "\((error as? TrashStore.TrashError) != nil ? "TrashError" : "\(type(of: error))"): "
                     + "\(error.localizedDescription)")
            }
            show("moveToTrash/unsafe(\(bad.debugDescription))/trash-tree",
                 tree(pb.appendingPathComponent(".trash")))
        }

        // 7. A folder (group) with a subtree.
        let p7 = try project()
        _ = try write("x", at: "manuscript/act/01.md", in: p7)
        _ = try write("y", at: "manuscript/act/nested/02.md", in: p7)
        let s7 = TrashStore(projectURL: p7)
        let e7 = try await s7.moveToTrash(
            fileRelativePath: "manuscript/act",
            itemMetadata: Data(#"{"id":"grp"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "Act")
        show("moveToTrash/folder/trash-tree", tree(p7.appendingPathComponent(".trash/\(e7.id)")))
        show("moveToTrash/folder/manuscript-remains",
             FileManager.default.fileExists(
                atPath: p7.appendingPathComponent("manuscript/act").path))
    }

    // MARK: - TrashStore: list / sweep

    func test_probe_listAndSweep() async throws {
        let p = try project()
        let trash = p.appendingPathComponent(".trash")
        let fm = FileManager.default
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)

        func stamp(_ d: Date) -> String { TrashStore.timestampPrefix(for: d) }
        func makeEntry(_ folderName: String, meta: String?, file: String? = "f.md") throws {
            let f = trash.appendingPathComponent(folderName)
            try fm.createDirectory(at: f, withIntermediateDirectories: true)
            if let meta { try meta.write(to: f.appendingPathComponent("meta.json"),
                                         atomically: true, encoding: .utf8) }
            if let file { try "content".write(to: f.appendingPathComponent(file),
                                              atomically: true, encoding: .utf8) }
        }
        func goodMeta(_ path: String) -> String {
            #"{"originalRelativePath":"\#(path)","displayTitle":"T","itemMetadata":"","originalParentId":null,"originalIndex":3}"#
        }

        let now = Date()
        try makeEntry("\(stamp(now))-fresh", meta: goodMeta("manuscript/fresh.md"))
        try makeEntry("\(stamp(now.addingTimeInterval(-31 * 86_400)))-old",
                      meta: goodMeta("manuscript/old.md"))
        try makeEntry("\(stamp(now.addingTimeInterval(-29 * 86_400)))-nearly",
                      meta: goodMeta("manuscript/nearly.md"))
        try makeEntry("\(stamp(now))-nometa", meta: nil)                      // no meta.json
        try makeEntry("\(stamp(now))-badmeta", meta: "{ not json")            // undecodable
        try makeEntry("not-a-timestamp-at-all", meta: goodMeta("manuscript/x.md"))
        try makeEntry("\(stamp(now))-a-b-c-d", meta: goodMeta("manuscript/multi.md"))
        try "stray".write(to: trash.appendingPathComponent("loose.txt"),
                          atomically: true, encoding: .utf8)

        let store = TrashStore(projectURL: p)
        let listed = try await store.list()
        show("list/ids", listed.map(\.id))
        show("list/originalIndex-roundtrip", listed.map(\.originalIndex))
        show("list/sorted-newest-first",
             listed.map { $0.trashedAt.timeIntervalSince1970 })

        try await store.sweep()
        show("sweep/surviving-folders",
             (try fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil))
                .map(\.lastPathComponent).sorted())

        // A very old entry with NO meta: does sweep ever reach it?
        let p2 = try project()
        let t2 = p2.appendingPathComponent(".trash")
        try fm.createDirectory(at: t2, withIntermediateDirectories: true)
        let ancient = t2.appendingPathComponent("\(stamp(now.addingTimeInterval(-900 * 86_400)))-ancient")
        try fm.createDirectory(at: ancient, withIntermediateDirectories: true)
        try "the writer's only copy".write(to: ancient.appendingPathComponent("chapter.md"),
                                           atomically: true, encoding: .utf8)
        let s2 = TrashStore(projectURL: p2)
        try await s2.sweep()
        show("sweep/900-day-old-entry-without-meta-survives",
             fm.fileExists(atPath: ancient.path))
        show("sweep/list-reports", (try await s2.list()).count)

        // list on a project with no .trash at all
        let p3 = try project()
        show("list/no-trash-dir", (try await TrashStore(projectURL: p3).list()).count)
        do {
            try await TrashStore(projectURL: p3).sweep()
            show("sweep/no-trash-dir", "did not throw")
        } catch { show("sweep/no-trash-dir/error", "\(error)") }

        // parseTimestamp shapes
        for name in ["20260512-153045-abc", "20260512-153045", "20260512", "abc-def-ghi",
                     "20260512-153045-a-b", "99999999-999999-x", "-20260512-153045-x"] {
            show("parseTimestamp(\(name))", String(describing: TrashStore.parseTimestamp(from: name)))
        }
    }

    // MARK: - TrashStore: restore

    func test_probe_restore() async throws {
        // 1. Destination occupied.
        let p = try project()
        _ = try write("original", at: "manuscript/a.md", in: p)
        let s = TrashStore(projectURL: p)
        let e = try await s.moveToTrash(
            fileRelativePath: "manuscript/a.md",
            itemMetadata: Data(#"{"id":"a"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "A")
        _ = try write("replacement", at: "manuscript/a.md", in: p)
        do {
            _ = try await s.restore(trashId: e.id)
            show("restore/occupied-destination", "DID NOT THROW")
        } catch {
            show("restore/occupied-destination/error-type", "\(type(of: error))")
            show("restore/occupied-destination/message", error.localizedDescription)
        }
        show("restore/occupied-destination/entry-survives", (try await s.list()).map(\.id))
        show("restore/occupied-destination/replacement-intact",
             try String(contentsOf: p.appendingPathComponent("manuscript/a.md"), encoding: .utf8))

        // 2. Entry folder holding only meta.json.
        let p2 = try project()
        let fm = FileManager.default
        let f2 = p2.appendingPathComponent(".trash/\(TrashStore.timestampPrefix(for: Date()))-only")
        try fm.createDirectory(at: f2, withIntermediateDirectories: true)
        try #"{"originalRelativePath":"manuscript/x.md","displayTitle":"X","itemMetadata":"","originalParentId":null,"originalIndex":0}"#
            .write(to: f2.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        do {
            _ = try await TrashStore(projectURL: p2).restore(trashId: f2.lastPathComponent)
            show("restore/meta-only", "DID NOT THROW")
        } catch {
            show("restore/meta-only/error", "\(error)")
            show("restore/meta-only/message", error.localizedDescription)
        }

        // 3. Unknown trash id.
        let p3 = try project()
        do {
            _ = try await TrashStore(projectURL: p3).restore(trashId: "nope")
            show("restore/unknown-id", "DID NOT THROW")
        } catch { show("restore/unknown-id/error", "\(type(of: error))") }

        // 4. Malformed folder name but valid contents: does the file move before the throw?
        let p4 = try project()
        let f4 = p4.appendingPathComponent(".trash/totally-malformed")
        try fm.createDirectory(at: f4, withIntermediateDirectories: true)
        try #"{"originalRelativePath":"manuscript/m.md","displayTitle":"M","itemMetadata":"","originalParentId":null,"originalIndex":0}"#
            .write(to: f4.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        try "words".write(to: f4.appendingPathComponent("m.md"), atomically: true, encoding: .utf8)
        do {
            _ = try await TrashStore(projectURL: p4).restore(trashId: "totally-malformed")
            show("restore/malformed-id", "DID NOT THROW")
        } catch { show("restore/malformed-id/error", "\(error)") }
        show("restore/malformed-id/file-restored-anyway",
             fm.fileExists(atPath: p4.appendingPathComponent("manuscript/m.md").path))
        show("restore/malformed-id/entry-folder-gone", !fm.fileExists(atPath: f4.path))

        // 5. Hostile originalRelativePath in meta.json.
        let p5 = try project()
        let f5 = p5.appendingPathComponent(".trash/\(TrashStore.timestampPrefix(for: Date()))-eek")
        try fm.createDirectory(at: f5, withIntermediateDirectories: true)
        try #"{"originalRelativePath":"../../escaped.md","displayTitle":"E","itemMetadata":"","originalParentId":null,"originalIndex":0}"#
            .write(to: f5.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        try "words".write(to: f5.appendingPathComponent("e.md"), atomically: true, encoding: .utf8)
        do {
            _ = try await TrashStore(projectURL: p5).restore(trashId: f5.lastPathComponent)
            show("restore/escaping-meta-path", "DID NOT THROW")
        } catch { show("restore/escaping-meta-path/error", "\(error)") }
        show("restore/escaping-meta-path/entry-survives", fm.fileExists(atPath: f5.path))

        // 6. Missing intermediate directory — is it recreated?
        let p6 = try project()
        _ = try write("ch", at: "manuscript/act-one/ch.md", in: p6)
        let s6 = TrashStore(projectURL: p6)
        let e6 = try await s6.moveToTrash(
            fileRelativePath: "manuscript/act-one/ch.md",
            itemMetadata: Data(#"{"id":"ch"}"#.utf8),
            originalParentId: "grp", originalIndex: 2, displayTitle: "Ch")
        try fm.removeItem(at: p6.appendingPathComponent("manuscript/act-one"))
        show("restore/parent-folder-deleted/before", tree(p6))
        let r6 = try await s6.restore(trashId: e6.id)
        show("restore/parent-folder-deleted/after", tree(p6))
        show("restore/returned.originalParentId", String(describing: r6.originalParentId))
        show("restore/returned.originalIndex", r6.originalIndex)
    }

    // MARK: - ProjectStore: the writer-facing verbs

    func test_probe_projectStore() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let fm = FileManager.default

        // A stand-in op log for the trashed doc — nothing in this module touches it.
        let opsDir = url.appendingPathComponent(".maugham/ops")
        try fm.createDirectory(at: opsDir, withIntermediateDirectories: true)
        try "{\"op\":\"insert\",\"text\":\"every word the writer typed\"}\n"
            .write(to: opsDir.appendingPathComponent("doc-ch2.jsonl"),
                   atomically: true, encoding: .utf8)

        let actOne = store.manifest.structure.first { $0.title == "Act One" }!
        let ch2 = actOne.children!.first { $0.title == "Chapter 2" }!

        try await store.deleteStructureItem(id: ch2.id)
        show("delete/lastDeletedTrashId-set", store.lastDeletedTrashId != nil)
        show("delete/trashEntries-count", store.trashEntries.count)

        // Permanent delete: does the op log go too?
        try await store.permanentlyDeleteTrashEntry(id: store.trashEntries.first!.id)
        show("permanentlyDelete/oplog-survives",
             fm.fileExists(atPath: opsDir.appendingPathComponent("doc-ch2.jsonl").path))
        show("permanentlyDelete/lastDeletedTrashId-cleared", store.lastDeletedTrashId == nil)
        show("permanentlyDelete/trashEntries", store.trashEntries.count)

        do {
            try await store.permanentlyDeleteTrashEntry(id: "no-such-entry")
            show("permanentlyDelete/unknown-id", "DID NOT THROW")
        } catch { show("permanentlyDelete/unknown-id/error", "\(type(of: error))") }

        // restoreLastDeleted with nothing to restore.
        do {
            try await store.restoreLastDeleted()
            show("restoreLastDeleted/nil-token", "silent no-op, did not throw")
        } catch { show("restoreLastDeleted/nil-token/error", "\(error)") }

        // emptyTrash with an on-disk entry NOT in the cached array.
        let url2 = try makeNestedProject()
        let store2 = try await ProjectStore.load(from: url2)
        let a1 = store2.manifest.structure.first { $0.title == "Act One" }!
        try await store2.deleteStructureItem(id: a1.children!.first { $0.title == "Chapter 1" }!.id)
        show("emptyTrash/cached-before", store2.trashEntries.count)
        // Behind ProjectStore's back — exactly what MCP set_piece_style does.
        _ = try write("style", at: ".maugham/publish/pieces/x.tex", in: url2)
        let sideEntry = try await store2.trashStore.moveToTrash(
            fileRelativePath: ".maugham/publish/pieces/x.tex",
            itemMetadata: Data(#"{"id":"style-x"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "x.tex")
        show("emptyTrash/on-disk-count-before",
             (try await store2.trashStore.list()).count)
        try await store2.emptyTrash()
        show("emptyTrash/cached-after", store2.trashEntries.count)
        show("emptyTrash/on-disk-after", (try await store2.trashStore.list()).map(\.id))
        show("emptyTrash/side-entry-survives",
             fm.fileExists(atPath: url2.appendingPathComponent(".trash/\(sideEntry.id)").path))

        // Restoring a trash entry whose metadata is neither Structure nor Research.
        let url3 = try makeNestedProject()
        let store3 = try await ProjectStore.load(from: url3)
        _ = try write("style", at: ".maugham/publish/pieces/y.tex", in: url3)
        let styleEntry = try await store3.trashStore.moveToTrash(
            fileRelativePath: ".maugham/publish/pieces/y.tex",
            itemMetadata: Data(#"{"id":"style-y"}"#.utf8),
            originalParentId: nil, originalIndex: 0, displayTitle: "y.tex")
        let structureBefore = store3.manifest.structure.count
        do {
            try await store3.restoreTrashEntry(id: styleEntry.id)
            show("restoreTrashEntry/undecodable-metadata", "returned normally")
        } catch { show("restoreTrashEntry/undecodable-metadata/error", "\(error)") }
        show("restoreTrashEntry/undecodable/structure-unchanged",
             store3.manifest.structure.count == structureBefore)
        show("restoreTrashEntry/undecodable/file-back",
             fm.fileExists(atPath: url3.appendingPathComponent(".maugham/publish/pieces/y.tex").path))

        // A structure item with an EMPTY path.
        let url4 = try makeNestedProject()
        let store4 = try await ProjectStore.load(from: url4)
        show("delete/pathless-item/present",
             store4.manifest.structure.contains { $0.id == "doc-pathless" })
        do {
            try await store4.deleteStructureItem(id: "doc-pathless")
            show("delete/pathless-item", "DID NOT THROW")
        } catch { show("delete/pathless-item/error", "\(error)") }
        show("delete/pathless-item/row-survives",
             store4.manifest.structure.contains { $0.id == "doc-pathless" })
        show("delete/pathless-item/trash-tree", tree(url4.appendingPathComponent(".trash")))
    }

    func test_probe_research() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        // 1. Delete a file-backed note, then a LINK. What does ⌘⌥Z point at?
        try await store.deleteResearchItem(id: "res-note")
        let tokenAfterNote = store.lastDeletedTrashId
        show("research/token-after-note", String(describing: tokenAfterNote))
        try await store.deleteResearchItem(id: "res-link")
        show("research/link-made-a-trash-entry",
             store.trashEntries.contains { $0.displayTitle == "A Link" })
        show("research/token-after-link", String(describing: store.lastDeletedTrashId))
        show("research/token-unchanged-by-link-delete",
             store.lastDeletedTrashId == tokenAfterNote)
        show("research/link-gone-from-manifest",
             !store.manifest.research.contains { $0.id == "res-link" })

        try await store.restoreLastDeleted()
        show("research/what-came-back",
             store.manifest.research.map { "\($0.id):\($0.title)" })

        // 2. Batch delete: how many does one ⌘⌥Z bring back?
        let url2 = try makeResearchProject()
        let store2 = try await ProjectStore.load(from: url2)
        try await store2.deleteResearchItems(ids: ["res-note", "res-note2", "res-note3"])
        show("research/batch/trash-entries", store2.trashEntries.map(\.displayTitle))
        show("research/batch/research-left", store2.manifest.research.map(\.id))
        try await store2.restoreLastDeleted()
        show("research/batch/after-one-undo", store2.manifest.research.map(\.id))
        show("research/batch/token-after-undo", String(describing: store2.lastDeletedTrashId))
    }

    // MARK: - restore into the manifest

    func test_probe_restorePlacement() async throws {
        let url = try makeNestedProject()
        let store = try await ProjectStore.load(from: url)
        let fm = FileManager.default

        let actOne = store.manifest.structure.first { $0.title == "Act One" }!
        let ch2 = actOne.children!.first { $0.title == "Chapter 2" }!
        try await store.deleteStructureItem(id: ch2.id)
        // Remove a sibling so the clamp has something to do.
        let ch3 = store.manifest.structure.first { $0.title == "Act One" }!
            .children!.first { $0.title == "Chapter 3" }!
        try await store.deleteStructureItem(id: ch3.id)
        let ch2Entry = store.trashEntries.first { $0.displayTitle == "Chapter 2" }!
        try await store.restoreTrashEntry(id: ch2Entry.id)
        let restoredActOne = store.manifest.structure.first { $0.title == "Act One" }!
        show("restorePlacement/act-one-children",
             restoredActOne.children!.map(\.title))

        // Prune: restore a group after a descendant's file vanished from the trash copy.
        let url2 = try makeNestedProject()
        let store2 = try await ProjectStore.load(from: url2)
        let a2 = store2.manifest.structure.first { $0.title == "Act One" }!
        try await store2.deleteStructureItem(id: a2.id)
        let entry = store2.trashEntries.first { $0.displayTitle == "Act One" }!
        let folder = url2.appendingPathComponent(".trash/\(entry.id)/01-act-one")
        try fm.removeItem(at: folder.appendingPathComponent("02-chapter-2.md"))
        try await store2.restoreTrashEntry(id: entry.id)
        let back = store2.manifest.structure.first { $0.title == "Act One" }!
        show("restorePlacement/pruned-children", back.children!.map(\.title))
        show("restorePlacement/pruned-silently", "no error thrown, no report returned")

        // Parent gone: where does the ROW go, and where does the FILE go?
        let url3 = try makeNestedProject()
        let store3 = try await ProjectStore.load(from: url3)
        let a3 = store3.manifest.structure.first { $0.title == "Act One" }!
        let c1 = a3.children!.first { $0.title == "Chapter 1" }!
        try await store3.deleteStructureItem(id: c1.id)
        let c1Entry = store3.trashEntries.first { $0.displayTitle == "Chapter 1" }!
        try await store3.deleteStructureItem(id: a3.id)
        show("restorePlacement/orphan/disk-before", tree(url3.appendingPathComponent("manuscript")))
        try await store3.restoreTrashEntry(id: c1Entry.id)
        show("restorePlacement/orphan/root-rows", store3.manifest.structure.map(\.title))
        show("restorePlacement/orphan/restored-row-path",
             String(describing: store3.manifest.structure.first { $0.title == "Chapter 1" }?.path))
        show("restorePlacement/orphan/disk-after", tree(url3.appendingPathComponent("manuscript")))
    }

    // MARK: - Fixtures

    private func makeNestedProject() throws -> URL {
        let fm = FileManager.default
        let url = try project("Nest")
        let ms = url.appendingPathComponent("manuscript")
        let act = ms.appendingPathComponent("01-act-one")
        try fm.createDirectory(at: act, withIntermediateDirectories: true)
        try "Chapter 1".write(to: act.appendingPathComponent("01-chapter-1.md"),
                              atomically: true, encoding: .utf8)
        try "Chapter 2".write(to: act.appendingPathComponent("02-chapter-2.md"),
                              atomically: true, encoding: .utf8)
        try "Chapter 3".write(to: act.appendingPathComponent("03-chapter-3.md"),
                              atomically: true, encoding: .utf8)
        try "Epilogue".write(to: ms.appendingPathComponent("02-epilogue.md"),
                             atomically: true, encoding: .utf8)

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
        let epilogue = StructureItem(id: "doc-epilogue", title: "Epilogue", type: .document,
                                     path: "manuscript/02-epilogue.md")
        let pathless = StructureItem(id: "doc-pathless", title: "Pathless", type: .document,
                                     path: nil)

        let manifest = ProjectManifest(
            type: .novel, title: "Nest", author: "T",
            created: Date(), modified: Date(),
            structure: [actOne, epilogue, pathless], research: [])
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: url.appendingPathComponent(ProjectManifest.fileName))
        return url
    }

    private func makeResearchProject() throws -> URL {
        let fm = FileManager.default
        let url = try project("Res")
        let res = url.appendingPathComponent("research")
        try fm.createDirectory(at: res, withIntermediateDirectories: true)
        for (file, body) in [("note.md", "A note"), ("note2.md", "Two"), ("note3.md", "Three")] {
            try body.write(to: res.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        let items: [ResearchItem] = [
            ResearchItem(id: "res-note", title: "A Note", type: .asset,
                         kind: .document, path: "research/note.md"),
            ResearchItem(id: "res-note2", title: "Note Two", type: .asset,
                         kind: .document, path: "research/note2.md"),
            ResearchItem(id: "res-note3", title: "Note Three", type: .asset,
                         kind: .document, path: "research/note3.md"),
            ResearchItem(id: "res-link", title: "A Link", type: .asset,
                         kind: .link, path: "research/a-link.link",
                         url: "https://example.com"),
        ]
        let manifest = ProjectManifest(
            type: .novel, title: "Res", author: "T",
            created: Date(), modified: Date(),
            structure: [], research: items)
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: url.appendingPathComponent(ProjectManifest.fileName))
        return url
    }
}
