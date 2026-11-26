import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class AddResearchTextNoteTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "TestNote", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_addNote_atRoot_writesFileAndManifestEntry() async throws {
        let (url, store, ds) = try await makeNovel()
        let note = try await store.addResearchTextNote(parentId: nil)

        XCTAssertEqual(note.kind, .document)
        XCTAssertEqual(note.type, .asset)
        XCTAssertEqual(note.title, "Untitled Note")
        XCTAssertTrue(note.path?.hasSuffix(".md") ?? false)

        let fileURL = url.appendingPathComponent(note.path ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "")
        await ds.close()
    }

    func test_addNote_titleCollision_dedupesNumerically() async throws {
        let (_, store, ds) = try await makeNovel()
        let first = try await store.addResearchTextNote(parentId: nil)
        let second = try await store.addResearchTextNote(parentId: nil)
        XCTAssertEqual(first.title, "Untitled Note")
        XCTAssertEqual(second.title, "Untitled Note 2")
        XCTAssertNotEqual(first.path, second.path)
        await ds.close()
    }

    func test_addNote_intoGroup_createsInsideGroupFolder() async throws {
        let (_, store, ds) = try await makeNovel()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Characters", kind: nil)
        let note = try await store.addResearchTextNote(parentId: group.id)
        XCTAssertTrue(note.path?.contains("characters/") ?? false,
                      "expected note inside characters group; got \(note.path ?? "<nil>")")
        await ds.close()
    }

    // MARK: - The folder is the group's recorded one (#148 D4, F9)
    //
    // A group records its own folder (`path`), and rename and move keep it
    // current; a new note lands there, never in a folder re-derived from the
    // group's title.

    /// "Other" holds a note, then is renamed "Notes" beside an existing
    /// `notes/`: its folder becomes `notes-2/` and the next note goes there.
    func test_aNoteInAGroupWhoseFolderWasDedupedOnRenameLandsInThatFolder() async throws {
        let (url, store, ds) = try await makeNovel()
        _ = try await store.addResearchItem(parentId: nil, title: "Notes", kind: nil)
        let group = try await store.addResearchItem(parentId: nil, title: "Other", kind: nil)
        let first = try await store.addResearchTextNote(parentId: group.id, title: "First")
        XCTAssertEqual(first.path, "research/other/first.md")
        try await store.updateResearchItem(id: group.id, title: "Notes")
        let renamed = try XCTUnwrap(store.findResearchItem(id: group.id, in: store.manifest.research))
        XCTAssertEqual(renamed.path, "research/notes-2", "premise: the rename deduped the folder")

        let note = try await store.addResearchTextNote(parentId: group.id, title: "Second")

        XCTAssertEqual(note.path, "research/notes-2/second.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/notes-2/second.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/notes/second.md").path),
            "nothing lands in the other group's folder")
        await ds.close()
    }

    /// The group's children sit in two folders (two synced rows name another
    /// one, so most of them are elsewhere): the group's own recorded folder
    /// wins, since a child's path says where that child is, not where the
    /// group is. The folder is a deduped one, so its title's slug is wrong too.
    func test_aGroupWhoseChildrenAreInTwoFoldersTakesTheNoteInItsOwnFolder() async throws {
        let (url, store, ds) = try await makeNovel()
        _ = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
        let group = try await store.addResearchItem(parentId: nil, title: "Towns", kind: nil)
        _ = try await store.addResearchTextNote(parentId: group.id, title: "Harbour")
        try await store.updateResearchItem(id: group.id, title: "Places")
        store.mutateResearchItem(id: group.id) { group in
            for n in 1...2 {
                group.children?.append(ResearchItem(
                    id: "res-elsewhere\(n)", title: "Elsewhere \(n)", type: .asset, kind: .document,
                    path: "research/elsewhere/elsewhere-\(n).md"))
            }
        }
        XCTAssertEqual(store.findResearchItem(id: group.id, in: store.manifest.research)?.path,
                       "research/places-2", "premise")

        let note = try await store.addResearchTextNote(parentId: group.id, title: "Market")

        XCTAssertEqual(note.path, "research/places-2/market.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(note.path!).path))
        await ds.close()
    }

    /// A group with no child yet takes the note in its folder, which for a
    /// group never renamed is its title's slug, as before.
    func test_anEmptyGroupTakesTheNoteInItsTitleSlugFolder() async throws {
        let (url, store, ds) = try await makeNovel()
        let group = try await store.addResearchItem(parentId: nil, title: "Old Letters", kind: nil)

        let note = try await store.addResearchTextNote(parentId: group.id, title: "First")

        XCTAssertEqual(note.path, "research/old-letters/first.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(note.path!).path))
        await ds.close()
    }

    /// A group row that records no folder (an older or hand-written
    /// manifest) falls back to its title's slug under `research/`.
    func test_aGroupThatRecordsNoFolderTakesTheNoteInItsTitleSlugFolder() async throws {
        let (url, store, ds) = try await makeNovel()
        store.manifest.research.append(ResearchItem(
            id: "res-grp-nopath1", title: "Loose Ends", type: .group, kind: nil, path: nil, children: []))

        let note = try await store.addResearchTextNote(parentId: "res-grp-nopath1", title: "First")

        XCTAssertEqual(note.path, "research/loose-ends/first.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(note.path!).path))
        await ds.close()
    }

    /// A subgroup beneath the Palette lives in `research/palette/<slug>/`;
    /// its note goes there, not to a top-level `research/<slug>/`.
    func test_aNoteInASubgroupBeneathThePaletteLandsInThatSubgroupsFolder() async throws {
        let (url, store, ds) = try await makeNovel()
        let palette = try await store.ensurePaletteGroup()
        let subgroup = try await store.addResearchItem(parentId: palette.id, title: "Harbours", kind: nil)
        XCTAssertEqual(subgroup.path, "\(try XCTUnwrap(palette.path))/harbours", "premise")

        let note = try await store.addResearchTextNote(parentId: subgroup.id, title: "Breakwater")

        XCTAssertEqual(note.path, "\(subgroup.path!)/breakwater.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(note.path!).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/harbours").path),
            "no top-level folder is made for the subgroup's title")
        await ds.close()
    }

    /// A group whose recorded folder is outside every research root (a
    /// synced manifest naming the manuscript) takes no note: refused as
    /// outside Research before anything is made, as a move into it is.
    func test_aGroupWhoseFolderIsOutsideResearchTakesNoNote() async throws {
        let (url, store, ds) = try await makeNovel()
        store.manifest.research.append(ResearchItem(
            id: "res-grp-outside", title: "Stray", type: .group, kind: nil, path: "manuscript", children: []))
        let before = try FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("manuscript").path).sorted()

        do {
            _ = try await store.addResearchTextNote(parentId: "res-grp-outside", title: "Nope")
            XCTFail("expected outsideResearch")
        } catch ProjectStoreError.outsideResearch(let title) {
            XCTAssertEqual(title, "Stray")
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: url.appendingPathComponent("manuscript").path).sorted(), before)
        let group = try XCTUnwrap(store.findResearchItem(id: "res-grp-outside", in: store.manifest.research))
        XCTAssertEqual(group.children ?? [], [])
        await ds.close()
    }
}
