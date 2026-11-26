import XCTest
import MaughamCore
@testable import Maugham

/// **A piece reorder or rename carries the paths of nested Research items**
/// (#145 follow-up, hardening Task 10).
///
/// A Collection piece's `research/` folder moves with the piece's folder;
/// the manifest must name the new place for every Research item under it at
/// any depth, not only the top-level rows. The nested shape is built through
/// the production verbs only: a shared group moved into the piece
/// (`moveResearchItems(.piece)`, the tree's drag), a note added to it
/// (`addResearchTextNote`, the assistant's `add_note`), a group added inside
/// it (`addResearchItem`) and a second note in that.
@MainActor
final class PieceResearchNestedPathTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []

    override func tearDown() async throws {
        for store in stores { await store.close() }
        stores = []
        try await super.tearDown()
    }

    // MARK: - Fixture

    private struct Nest {
        let store: DocumentStore
        let projectStore: ProjectStore
        let alpha: StructureItem
        let beta: StructureItem
        /// "Sources", moved into Alpha's research folder.
        let group: ResearchItem
        /// "Letters", in Sources.
        let note: ResearchItem
        /// "Deeper", in Sources.
        let nested: ResearchItem
        /// "Diary", in Deeper.
        let nestedNote: ResearchItem
    }

    /// A Collection of Alpha (01) and Beta (02); under Alpha's research a
    /// group holding a note and a nested group holding a second note, each
    /// note's text on disk and read by the door.
    private func nest() async throws -> Nest {
        let parent = TestTemp.root.appendingPathComponent("piece-nest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createCollectionProject(named: "Nest", in: parent)
        let projectStore = try await ProjectStore.load(from: projectURL)
        let store = try await DocumentStore.open(url: projectURL)
        stores.append(store)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let alpha = try await projectStore.addLoosePiece(title: "Alpha", format: .markdown)
        let beta = try await projectStore.addLoosePiece(title: "Beta", format: .markdown)

        let shared = try await projectStore.addResearchItem(parentId: nil, title: "Sources", kind: nil)
        try await projectStore.moveResearchItems(ids: [shared.id], to: .piece(alpha.id))
        let group = try item(shared.id, projectStore)
        let alphaPrefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: alpha))
        XCTAssertEqual(group.path, alphaPrefix + "sources", "premise: the group is under Alpha's research")

        let note = try await projectStore.addResearchTextNote(parentId: group.id, title: "Letters")
        let nested = try await projectStore.addResearchItem(parentId: group.id, title: "Deeper", kind: nil)
        let nestedNote = try await projectStore.addResearchTextNote(parentId: nested.id, title: "Diary")
        XCTAssertEqual(nested.path, alphaPrefix + "sources/deeper", "premise")
        XCTAssertEqual(nestedNote.path, alphaPrefix + "sources/deeper/diary.md", "premise")
        for (n, text) in [(note, "Letters."), (nestedNote, "Diary.")] {
            let path = try XCTUnwrap(n.path)
            try Data(text.utf8).write(to: file(path))
            store.researchNoteWasRead(itemId: n.id, bytes: Data(text.utf8))
        }
        return Nest(store: store, projectStore: projectStore, alpha: alpha, beta: beta,
                    group: group, note: note, nested: nested, nestedNote: nestedNote)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: file(path).path) }
    private func contents(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: file(path)), as: UTF8.self)
    }

    private func item(_ id: String, _ projectStore: ProjectStore) throws -> ResearchItem {
        try XCTUnwrap(projectStore.findResearchItem(id: id, in: projectStore.manifest.research), id)
    }

    /// Alpha's research prefix as the manifest names Alpha now.
    private func alphaPrefix(_ n: Nest) throws -> String {
        let alpha = try XCTUnwrap(n.projectStore.manifest.structure.first { $0.id == n.alpha.id })
        return try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: alpha))
    }

    /// Every item of the nest names Alpha's current research folder and is
    /// on disk there, and each note is a note the door writes at that path,
    /// over the text it held (so a version is kept): `then` is its new text.
    private func assertTheNestFollowsAlpha(_ n: Nest, after verb: String, then texts: [String: String],
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let prefix = try alphaPrefix(n)
        let research = n.projectStore.manifest.research
        let structure = n.projectStore.manifest.structure
        for id in [n.group.id, n.note.id, n.nested.id, n.nestedNote.id] {
            let now = try item(id, n.projectStore)
            let path = try XCTUnwrap(now.path, file: file, line: line)
            XCTAssertTrue(path.hasPrefix(prefix),
                "after the \(verb), “\(now.title)” names \(path), not under \(prefix)", file: file, line: line)
            XCTAssertTrue(exists(path), "after the \(verb), nothing is at “\(now.title)”’s path \(path)",
                          file: file, line: line)
        }
        for (id, newText) in texts.sorted(by: { $0.key < $1.key }) {
            let now = try item(id, n.projectStore)
            let path = try XCTUnwrap(now.path, file: file, line: line)
            XCTAssertEqual(ResearchTextRole.of(now, structure: structure, research: research), .note(path: path),
                           "after the \(verb), “\(now.title)” is a note at its path", file: file, line: line)
            let saved = await n.store.saveResearchNote(itemId: id, text: newText, by: .assistant)
            XCTAssertEqual(saved, .saved(keptAVersion: true),
                           "after the \(verb), the door writes “\(now.title)” over its kept text",
                           file: file, line: line)
            XCTAssertEqual(try contents(path), newText, file: file, line: line)
        }
    }

    // MARK: - Reorder, then rename

    func test_aReorderThenARenameCarryEveryNestedResearchPath() async throws {
        let n = try await nest()
        let oldPrefix = try alphaPrefix(n)

        try await n.projectStore.movePiece(pieceId: n.beta.id, toIndex: 0)
        let reordered = try alphaPrefix(n)
        XCTAssertNotEqual(reordered, oldPrefix, "premise: Alpha was renumbered")
        try await assertTheNestFollowsAlpha(n, after: "reorder",
            then: [n.note.id: "Letters, reordered.", n.nestedNote.id: "Diary, reordered."])

        try await n.projectStore.renamePiece(pieceId: n.alpha.id, newTitle: "Omega")
        let renamed = try alphaPrefix(n)
        XCTAssertTrue(renamed.contains("omega"), "premise: \(renamed)")
        try await assertTheNestFollowsAlpha(n, after: "rename",
            then: [n.note.id: "Letters, renamed.", n.nestedNote.id: "Diary, renamed."])
        XCTAssertFalse(exists(oldPrefix), "nothing is left at Alpha's first folder")
        XCTAssertFalse(exists(reordered), "nothing is left at Alpha's renumbered folder")
    }

    // MARK: - A new note in a group under a piece (Task 8's newNoteFolder)

    /// `addResearchTextNote` — what the assistant's `add_note` calls — into a
    /// group under a loose piece's research is accepted and lands in that
    /// group's recorded folder, before and after a reorder and a rename: a
    /// piece's research folder is a research root (`isInsideAResearchRoot`),
    /// for the top-level group and for the one nested in it.
    func test_aNoteAddedToAGroupUnderAPieceLandsInItsFolder_acrossAReorderAndARename() async throws {
        let n = try await nest()
        func addAndCheck(_ label: String) async throws {
            for groupId in [n.group.id, n.nested.id] {
                let group = try item(groupId, n.projectStore)
                let added = try await n.projectStore.addResearchTextNote(parentId: groupId, title: "Added \(label)")
                let path = try XCTUnwrap(added.path)
                XCTAssertEqual((path as NSString).deletingLastPathComponent, group.path,
                               "\(label): the note lands in “\(group.title)”’s recorded folder")
                XCTAssertTrue(path.hasPrefix(try alphaPrefix(n)), "\(label): \(path)")
                XCTAssertTrue(exists(path), "\(label): the note's file is made at \(path)")
                let children = try item(groupId, n.projectStore).children ?? []
                XCTAssertTrue(children.contains { $0.id == added.id },
                              "\(label): the note is a child of “\(group.title)”")
            }
        }
        try await addAndCheck("before")
        try await n.projectStore.movePiece(pieceId: n.beta.id, toIndex: 0)
        try await addAndCheck("reordered")
        try await n.projectStore.renamePiece(pieceId: n.alpha.id, newTitle: "Omega")
        try await addAndCheck("renamed")
    }

    // MARK: - The shared rewrite

    /// Two folders trading names (a synced manifest can hold two pieces of
    /// one slug): each item is rewritten once, by the rewrite its path was
    /// under before either applied, at every depth.
    func test_theRewriteMovesEachItemOnceWhenTwoFoldersTradeNames() {
        func leaf(_ id: String, _ path: String) -> ResearchItem {
            ResearchItem(id: id, title: id, type: .asset, kind: .document, path: path, addedAt: Date())
        }
        func group(_ id: String, _ path: String, _ children: [ResearchItem]) -> ResearchItem {
            ResearchItem(id: id, title: id, type: .group, kind: nil, path: path, url: nil, caption: nil,
                         tags: nil, links: nil, addedAt: Date(), children: children)
        }
        let research = [
            group("g1", "pieces/01-x/research/g", [leaf("n1", "pieces/01-x/research/g/n.md"),
                group("h1", "pieces/01-x/research/g/h", [leaf("m1", "pieces/01-x/research/g/h/m.md")])]),
            group("g2", "pieces/02-x/research/g", [leaf("n2", "pieces/02-x/research/g/n.md")]),
            leaf("shared", "research/s.md"),
        ]
        let after = ProjectStore.researchAfterPieceFoldersMoved(research, [
            (oldRel: "pieces/01-x", newRel: "pieces/02-x"), (oldRel: "pieces/02-x", newRel: "pieces/01-x"),
        ])
        let paths = Dictionary(uniqueKeysWithValues: TreeWalk.collect(in: after, where: { _ in true })
            .map { ($0.id, $0.path ?? "") })
        XCTAssertEqual(paths, [
            "g1": "pieces/02-x/research/g", "n1": "pieces/02-x/research/g/n.md",
            "h1": "pieces/02-x/research/g/h", "m1": "pieces/02-x/research/g/h/m.md",
            "g2": "pieces/01-x/research/g", "n2": "pieces/01-x/research/g/n.md",
            "shared": "research/s.md",
        ])
    }
}
