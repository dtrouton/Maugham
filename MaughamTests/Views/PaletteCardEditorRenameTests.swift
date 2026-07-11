import XCTest
import AppKit
@testable import Maugham
import MaughamCore

/// Regression coverage for finding E2: editing a palette card after renaming it
/// from the research tree must NOT revert the rename. The editor seeds its draft
/// once per `cardId`; a rename changes title/path but not id, so the draft title
/// goes stale. `persist` must treat that stale title as a value the store owns,
/// not a rename intent — the store's current title wins unless the *user* edited
/// the title in-editor. These drive the editor's testable persist core against a
/// real `ProjectStore` (no UI).
@MainActor
final class PaletteCardEditorRenameTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(named: "PaletteRename", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    private func cardItemPath(_ store: ProjectStore, id: String) -> String? {
        store.paletteCardItems().first { $0.id == id }?.path
    }

    // The editor's `with(...)` copy helper is file-private; rebuild cards here
    // via the public initializer.
    private func withBody(_ card: PaletteCard, _ body: String) -> PaletteCard {
        PaletteCard(
            researchItemId: card.researchItemId, title: card.title, kind: card.kind,
            swatches: card.swatches, notes: card.notes, imagePaths: card.imagePaths, body: body)
    }

    private func withTitle(_ card: PaletteCard, _ title: String) -> PaletteCard {
        PaletteCard(
            researchItemId: card.researchItemId, title: title, kind: card.kind,
            swatches: card.swatches, notes: card.notes, imagePaths: card.imagePaths, body: card.body)
    }

    // MARK: - E2 core: external rename survives an in-editor body save

    func test_externalRename_thenBodySave_keepsRenamedTitleAndSlug() async throws {
        let (url, store, ds) = try await makeNovel()
        let item = try await store.addPaletteCard(title: "Old", kind: .location)
        let cardId = item.id

        // Editor mounts and seeds — draft + baseline capture "Old".
        let seeded = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == cardId })
        let baselineAtSeed = seeded.title   // "Old"

        // The writer renames the card from the research tree (id unchanged).
        try await store.updateResearchItem(id: cardId, title: "New")
        XCTAssertEqual(cardItemPath(store, id: cardId), "research/palette/new.md")

        // The still-mounted editor now edits the BODY. Its draft title is stale.
        let staleDraft = withBody(seeded, "A late-afternoon light.")
        XCTAssertEqual(staleDraft.title, "Old")   // stale seed

        let newBaseline = await PaletteCardEditor.persistDraft(
            staleDraft, baselineTitle: baselineAtSeed, in: store)

        // The rename must survive: title stays "New", file stays at the new slug,
        // no phantom file resurrected at the old slug — and the body persisted.
        let reloaded = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == cardId })
        XCTAssertEqual(reloaded.title, "New")
        XCTAssertEqual(reloaded.body, "A late-afternoon light.")
        XCTAssertEqual(cardItemPath(store, id: cardId), "research/palette/new.md")
        XCTAssertEqual(newBaseline, "New")   // caller re-syncs baseline to the store
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/palette/new.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/palette/old.md").path))
        await ds.close()
    }

    // MARK: - A genuine in-editor rename still works

    func test_inEditorRename_appliesNewTitleAndMovesFile() async throws {
        let (url, store, ds) = try await makeNovel()
        let item = try await store.addPaletteCard(title: "Old", kind: .character)
        let cardId = item.id
        let seeded = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == cardId })

        // The user deliberately types a new title in the editor: draft title now
        // diverges from the baseline captured at seed.
        let renamedDraft = withTitle(seeded, "Renamed")
        let newBaseline = await PaletteCardEditor.persistDraft(
            renamedDraft, baselineTitle: seeded.title, in: store)

        let reloaded = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == cardId })
        XCTAssertEqual(reloaded.title, "Renamed")
        XCTAssertEqual(newBaseline, "Renamed")
        XCTAssertEqual(cardItemPath(store, id: cardId), "research/palette/renamed.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/palette/renamed.md").path))
        await ds.close()
    }

    // MARK: - Debounce race: rename lands while a save is already queued

    func test_renameLandsWhileSavePending_keepsRename() async throws {
        let (_, store, ds) = try await makeNovel()
        let item = try await store.addPaletteCard(title: "Old", kind: .motif)
        let cardId = item.id
        let seeded = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == cardId })

        // A body edit schedules a save (snapshot title "Old", baseline "Old")…
        let pendingSnapshot = withBody(seeded, "queued edit")
        // …and the 500ms rename via the tree lands BEFORE the debounced save fires.
        try await store.updateResearchItem(id: cardId, title: "New")

        // When the queued save finally runs it must not revert the rename.
        let newBaseline = await PaletteCardEditor.persistDraft(
            pendingSnapshot, baselineTitle: seeded.title, in: store)

        let reloaded = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == cardId })
        XCTAssertEqual(reloaded.title, "New")
        XCTAssertEqual(reloaded.body, "queued edit")
        XCTAssertEqual(newBaseline, "New")
        XCTAssertEqual(cardItemPath(store, id: cardId), "research/palette/new.md")
        await ds.close()
    }

    // MARK: - Pure reconciliation decision (no store)

    func test_reconciledTitle_noInEditorEdit_onDiskWins() {
        // Draft title equals baseline → user didn't touch the title → external
        // rename ("New" on disk) wins.
        XCTAssertEqual(
            PaletteCardEditor.reconciledTitle(
                draftTitle: "Old", baselineTitle: "Old", onDiskTitle: "New"),
            "New")
    }

    func test_reconciledTitle_userRenamedInEditor_draftWins() {
        // Draft title diverged from baseline → honour the user's in-editor rename.
        XCTAssertEqual(
            PaletteCardEditor.reconciledTitle(
                draftTitle: "Renamed", baselineTitle: "Old", onDiskTitle: "Old"),
            "Renamed")
    }

    func test_reconciledTitle_userClearedTitle_fallsBackToOnDisk() {
        // User blanked the field in-editor (diverged from baseline) → keep the
        // slug valid by falling back to the on-disk title.
        XCTAssertEqual(
            PaletteCardEditor.reconciledTitle(
                draftTitle: "   ", baselineTitle: "Old", onDiskTitle: "New"),
            "New")
    }

    func test_reconciledTitle_noBaselineYet_onDiskWins() {
        // No baseline captured (pre-seed) and no in-editor edit signal → prefer
        // the on-disk title when present.
        XCTAssertEqual(
            PaletteCardEditor.reconciledTitle(
                draftTitle: "Old", baselineTitle: nil, onDiskTitle: nil),
            "Old")
    }
}
