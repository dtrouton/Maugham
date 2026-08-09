import XCTest
import MaughamCore
@testable import Maugham

/// Second probe pass. Round 1 showed a deleted research NOTE did not come back
/// to the research tree on ⌘⌥Z. This pass finds out where it went, and pins the
/// remaining unobserved edges (load-time sweep, op-log survival).
@MainActor
final class TrashObservationProbe2: XCTestCase {

    private var temp: TempDirectory!
    override func setUp() { super.setUp(); temp = TempDirectory() }
    override func tearDown() { temp = nil; super.tearDown() }

    private func show(_ label: String, _ value: Any) { print("PROBE2 | \(label) = \(value)") }

    private func project(_ name: String = "P") throws -> URL {
        let url = temp.url.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Does a ResearchItem's metadata decode as a StructureItem?

    func test_probe_metadataDecodeOrder() throws {
        let note = ResearchItem(id: "res-note", title: "A Note", type: .asset,
                                kind: .document, path: "research/note.md")
        let noteData = try JSONEncoder().encode(note)
        show("researchItem-json", String(data: noteData, encoding: .utf8)!)
        let asStructure = try? JSONDecoder().decode(StructureItem.self, from: noteData)
        show("researchItem-decodes-as-StructureItem", asStructure != nil)
        if let s = asStructure {
            show("...as.id", s.id)
            show("...as.title", s.title)
            show("...as.type", "\(s.type)")
            show("...as.path", String(describing: s.path))
        }

        let group = ResearchItem(id: "res-grp", title: "Folder", type: .group,
                                 path: "research/folder",
                                 children: [ResearchItem(id: "res-kid", title: "Kid",
                                                         type: .asset, kind: .document,
                                                         path: "research/folder/kid.md")])
        let groupData = try JSONEncoder().encode(group)
        let groupAsStructure = try? JSONDecoder().decode(StructureItem.self, from: groupData)
        show("researchGroup-decodes-as-StructureItem", groupAsStructure != nil)
        show("researchGroup-as.type", groupAsStructure.map { "\($0.type)" } ?? "nil")
        show("researchGroup-as.children",
             groupAsStructure?.children?.map(\.title) ?? [])

        // And the other direction, for completeness.
        let doc = StructureItem(id: "doc-1", title: "Chapter", type: .document,
                                path: "manuscript/01.md")
        let docData = try JSONEncoder().encode(doc)
        show("structureItem-json", String(data: docData, encoding: .utf8)!)
        show("structureItem-decodes-as-ResearchItem",
             (try? JSONDecoder().decode(ResearchItem.self, from: docData)) != nil)
    }

    // MARK: - Where does a restored research note actually land?

    func test_probe_researchRestoreDestination() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)

        try await store.deleteResearchItem(id: "res-note")
        show("before-restore/research", store.manifest.research.map(\.id))
        show("before-restore/structure", store.manifest.structure.map(\.id))

        try await store.restoreLastDeleted()
        show("after-restore/research", store.manifest.research.map { "\($0.id):\($0.type)" })
        show("after-restore/structure", store.manifest.structure.map {
            "\($0.id):\($0.title):\($0.type):\(String(describing: $0.path))"
        })
        show("after-restore/file-on-disk",
             FileManager.default.fileExists(
                atPath: url.appendingPathComponent("research/note.md").path))

        // A research GROUP with children.
        let url2 = try makeResearchProject()
        let store2 = try await ProjectStore.load(from: url2)
        try await store2.deleteResearchItem(id: "res-grp")
        let e = store2.trashEntries.first { $0.displayTitle == "A Folder" }!
        try await store2.restoreTrashEntry(id: e.id)
        show("group/after-restore/research", store2.manifest.research.map(\.id))
        show("group/after-restore/structure", store2.manifest.structure.map {
            "\($0.id):\($0.title):\($0.type)"
        })
        show("group/after-restore/structure-children",
             store2.manifest.structure.first { $0.id == "res-grp" }?.children?.map(\.title) ?? [])
    }

    // MARK: - Load-time sweep and op-log survival

    func test_probe_loadSweepAndOpLog() async throws {
        let fm = FileManager.default
        let url = try makeResearchProject()

        // Plant an expired trash entry and an op log, then LOAD.
        let trash = url.appendingPathComponent(".trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let old = trash.appendingPathComponent(
            "\(TrashStore.timestampPrefix(for: Date().addingTimeInterval(-31 * 86_400)))-old")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try "the writer's chapter".write(to: old.appendingPathComponent("gone.md"),
                                         atomically: true, encoding: .utf8)
        try #"{"originalRelativePath":"research/gone.md","displayTitle":"Gone","itemMetadata":"","originalParentId":null,"originalIndex":0}"#
            .write(to: old.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        let ops = url.appendingPathComponent(".maugham/ops")
        try fm.createDirectory(at: ops, withIntermediateDirectories: true)
        try "{\"text\":\"every word\"}\n".write(to: ops.appendingPathComponent("res-note.jsonl"),
                                                atomically: true, encoding: .utf8)

        let store = try await ProjectStore.load(from: url)
        show("load/expired-entry-destroyed", !fm.fileExists(atPath: old.path))
        show("load/trashEntries", store.trashEntries.map(\.id))
        show("load/lastDeletedTrashId", String(describing: store.lastDeletedTrashId))

        // Delete + empty trash: op log?
        try await store.deleteResearchItem(id: "res-note")
        try await store.emptyTrash()
        show("emptyTrash/oplog-survives",
             fm.fileExists(atPath: ops.appendingPathComponent("res-note.jsonl").path))
        show("emptyTrash/oplog-content",
             (try? String(contentsOf: ops.appendingPathComponent("res-note.jsonl"),
                          encoding: .utf8)) ?? "GONE")
        show("emptyTrash/trash-dir-contents",
             (try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil))?
                .map(\.lastPathComponent) ?? [])

        // A second load after the sweep destroyed the entry: any record?
        let store2 = try await ProjectStore.load(from: url)
        show("reload/trashEntries", store2.trashEntries.count)
    }

    // MARK: - emptyTrash / permanentlyDelete cannot report a failure

    func test_probe_emptyTrashSignature() async throws {
        let url = try makeResearchProject()
        let store = try await ProjectStore.load(from: url)
        try await store.deleteResearchItem(id: "res-note")
        let id = store.trashEntries.first!.id

        // Remove the folder behind ProjectStore's back, then empty.
        try FileManager.default.removeItem(
            at: url.appendingPathComponent(".trash/\(id)"))
        do {
            try await store.emptyTrash()
            show("emptyTrash/every-entry-already-gone", "returned normally")
        } catch { show("emptyTrash/every-entry-already-gone/error", "\(error)") }
        show("emptyTrash/cached-cleared", store.trashEntries.isEmpty)

        // The single-entry path, same situation.
        let url2 = try makeResearchProject()
        let store2 = try await ProjectStore.load(from: url2)
        try await store2.deleteResearchItem(id: "res-note")
        let id2 = store2.trashEntries.first!.id
        try FileManager.default.removeItem(at: url2.appendingPathComponent(".trash/\(id2)"))
        do {
            try await store2.permanentlyDeleteTrashEntry(id: id2)
            show("permanentlyDelete/already-gone", "returned normally")
        } catch { show("permanentlyDelete/already-gone/error", "\(type(of: error))") }
    }

    // MARK: - Fixture

    private func makeResearchProject() throws -> URL {
        let fm = FileManager.default
        let url = try project("Res")
        let res = url.appendingPathComponent("research")
        try fm.createDirectory(at: res, withIntermediateDirectories: true)
        try "A note".write(to: res.appendingPathComponent("note.md"),
                           atomically: true, encoding: .utf8)
        let folder = res.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Kid".write(to: folder.appendingPathComponent("kid.md"),
                        atomically: true, encoding: .utf8)

        let items: [ResearchItem] = [
            ResearchItem(id: "res-note", title: "A Note", type: .asset,
                         kind: .document, path: "research/note.md"),
            ResearchItem(id: "res-grp", title: "A Folder", type: .group,
                         path: "research/folder",
                         children: [ResearchItem(id: "res-kid", title: "Kid", type: .asset,
                                                 kind: .document,
                                                 path: "research/folder/kid.md")]),
        ]
        let manifest = ProjectManifest(
            type: .novel, title: "Res", author: "T",
            created: Date(), modified: Date(), structure: [], research: items)
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: url.appendingPathComponent(ProjectManifest.fileName))
        return url
    }
}
