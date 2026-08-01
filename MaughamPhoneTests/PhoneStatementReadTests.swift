import XCTest
@testable import MaughamPhone
import MaughamCore

/// `UbiquitousDownloader` that treats every URL as already-local — the temp
/// files these tests write are real local files, not ubiquitous items. Mirrors
/// the private fake in `ProjectsBrowserTests`/`ColdLaunchDownloaderTests`
/// (each suite keeps its own so a change to one test's fake can't silently
/// retune another's).
private struct AlwaysLocalDownloader: UbiquitousDownloader {
    func fileSize(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
    }

    func download(at url: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(1.0)
            continuation.finish()
        }
    }
}

/// M1A Task 11 (spec §6.2): the Read tab's intent row reads the manifest's
/// `statements` section FIRST and falls back to the legacy craft-intent
/// research note.
///
/// **The fallback is the load-bearing half, not a courtesy.** Adoption is
/// Mac-only — it runs from `ProjectStore.load`, and the phone has no
/// `ProjectStore` and never writes a manifest — so a writer who has updated the
/// phone but has not opened the project on the Mac since still holds a schema-3
/// manifest, a `research/craft-intent.md` note, and no `statements` section at
/// all. Swapping the lookup instead of layering it shows that writer *nothing*,
/// which is the second of §2.5's two reasons for the paired release, re-created
/// by the fix for it. `test_theReadTabStillShowsAnUnadoptedNote` is the
/// assertion a straight swap falsifies.
final class PhoneStatementReadTests: XCTestCase {

    // MARK: - Builders

    private func legacyNote(
        id: String = "res-legacy",
        title: String = "Craft Intent",
        path: String? = "research/craft-intent.md",
        role: ResearchRole? = .craftIntent
    ) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .asset, kind: .document, path: path, role: role)
    }

    private func projectIntent(
        id: String = "stmt-a1b2c3d4", path: String = StatementConvention.projectIntentPath
    ) -> Statement {
        Statement(id: id, kind: .intent, scope: .project, path: path)
    }

    // MARK: - The row

    func test_theReadTabShowsAnAdoptedIntent() {
        let row = StatementLoading.intentRow(
            statements: [projectIntent()], research: [])
        XCTAssertEqual(row?.origin, .statement)
        // A statement lives at the project ROOT, not under `research/`.
        XCTAssertEqual(row?.relativePath, "intent.md")
        XCTAssertEqual(row?.title, StatementLoading.intentRowTitle)
    }

    /// Contract 1. Falsified by the straight swap — which is why it exists.
    func test_theReadTabStillShowsAnUnadoptedNote() {
        let row = StatementLoading.intentRow(
            statements: [], research: [legacyNote(title: "Craft Intent")])
        XCTAssertEqual(row?.origin, .legacyNote(id: "res-legacy"))
        XCTAssertEqual(row?.relativePath, "research/craft-intent.md")
        XCTAssertEqual(row?.title, "Craft Intent",
            "the legacy arm keeps the note's own title — an un-adopted project reads exactly as it shipped")
    }

    func test_aProjectWithNeitherShowsNoIntentRow() {
        let ordinary = ResearchItem(
            id: "res-wb", title: "World Bible", type: .asset, kind: .document,
            path: "research/world-bible.md")
        XCTAssertNil(StatementLoading.intentRow(statements: [], research: [ordinary]))
    }

    func test_theStatementWinsWhenBothExist() {
        let row = StatementLoading.intentRow(
            statements: [projectIntent()], research: [legacyNote()])
        XCTAssertEqual(row?.origin, .statement,
            "an adopted project reads its statement, never the note adoption left behind")
        XCTAssertEqual(row?.relativePath, "intent.md")
    }

    /// Scope filter. Per-document intent is a Mac surface in this milestone —
    /// a chapter's statement must not be drawn as the project's.
    func test_aDocumentScopedIntentIsNotTheProjectRow() {
        let chapter = Statement(
            id: "stmt-b2c3d4e5", kind: .intent, scope: .document("doc-a1b2c3d4"),
            path: "intent/chapter-one.md")
        XCTAssertNil(StatementLoading.intentRow(statements: [chapter], research: []))
    }

    /// Kind filter. Visual language is project-scope too, and is not intent.
    func test_visualLanguageIsNotTheIntentRow() {
        let visual = Statement(
            id: "stmt-c3d4e5f6", kind: .visualLanguage, scope: .project,
            path: StatementConvention.visualLanguagePath)
        XCTAssertNil(StatementLoading.intentRow(statements: [visual], research: []))
    }

    /// The legacy arm is project-scope too. A Collection loose piece keeps its
    /// craft intent inside its OWN research folder, and that note is not the
    /// project's — the phone passes `researchPrefix: "research"` and the shared
    /// lookup scopes by it.
    ///
    /// (There is deliberately no test for a note with no path: `craftIntentItem`
    /// filters on the prefix, so a pathless note never reaches the phone's
    /// guard and an assertion about it could not fail.)
    func test_aPieceScopedLegacyNoteIsNotTheProjectRow() {
        let piece = legacyNote(
            id: "res-piece", path: "pieces/the-flat/research/craft-intent.md")
        XCTAssertNil(StatementLoading.intentRow(statements: [], research: [piece]))
    }

    /// The fallback is `PaletteLookup`'s two-tier lookup, not a filename test:
    /// a note the writer renamed away from `craft-intent.md` still carries the
    /// durable role, and the phone must find it through the same shared rule
    /// the Mac uses (tripwire 19).
    func test_aRenamedLegacyNoteIsStillFoundByItsRole() {
        let renamed = legacyNote(
            id: "res-renamed", title: "What this book is for",
            path: "research/what-this-book-is-for.md", role: .craftIntent)
        let row = StatementLoading.intentRow(statements: [], research: [renamed])
        XCTAssertEqual(row?.origin, .legacyNote(id: "res-renamed"))
        XCTAssertEqual(row?.relativePath, "research/what-this-book-is-for.md")
    }

    // MARK: - The Research section (contract 4)

    /// The exclusion follows the ROW, not the note's existence. An adopted
    /// project whose legacy note is still in the tree shows the statement in
    /// the Palette section — so hiding the note from Research too would cost
    /// the writer a research row that is drawn nowhere else.
    func test_theLegacyNoteLeavesResearchOnlyWhenItIsTheRowShown() {
        let note = legacyNote()
        let ordinary = ResearchItem(
            id: "res-wb", title: "World Bible", type: .asset, kind: .document,
            path: "research/world-bible.md")
        let leaves = [note, ordinary]

        XCTAssertEqual(
            PaletteLoading.excludingPalette(leaves, research: leaves, statements: []).map(\.id),
            ["res-wb"],
            "un-adopted: the note IS the Craft Intent row, so it must not appear twice")

        XCTAssertEqual(
            PaletteLoading.excludingPalette(
                leaves, research: leaves, statements: [projectIntent()]).map(\.id),
            ["res-legacy", "res-wb"],
            "adopted: the row shows the statement, so the leftover note stays visible in Research")
    }

    /// The palette group's descendants leave Research either way — that arm is
    /// unrelated to statements, and a control here keeps the assertion above
    /// from passing for the wrong reason.
    func test_paletteDescendantsAreExcludedRegardlessOfAdoption() {
        let card = ResearchItem(
            id: "c1", title: "The Flat", type: .asset, kind: .document,
            path: "research/palette/the-flat.md")
        let research = [
            ResearchItem(id: "pg", title: "Palette", type: .group,
                         path: "research/palette", children: [card], role: .paletteGroup),
            legacyNote(),
        ]
        let leaves = [card, legacyNote()]
        XCTAssertEqual(
            PaletteLoading.excludingPalette(
                leaves, research: research, statements: [projectIntent()]).map(\.id),
            ["res-legacy"],
            "adopted: the card goes; the un-shown legacy note stays")
        XCTAssertEqual(
            PaletteLoading.excludingPalette(
                leaves, research: research, statements: []).map(\.id),
            [],
            "un-adopted: the card goes for the same reason, and the note goes as the row")
    }

    // MARK: - Round trip: a manifest the Mac wrote, read by the phone's own loader

    private func makeProjectFolder(_ name: String, json: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneStatementRead-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try json.write(to: dir.appendingPathComponent(ProjectManifest.fileName), options: [.atomic])
        return root
    }

    /// Contract 2, and the net the reach-around greps are not. The greps catch
    /// known bad spellings in phone source; only this catches the phone failing
    /// to *read* what the Mac actually writes — a `statements` key the phone's
    /// decoder never sees, a `scope` string grammar the two sides spell
    /// differently, or the schema-4 gate refusing the project outright.
    ///
    /// The statement is built from the same three shared ingredients
    /// `ProjectStore.createStatement` uses — `StatementConvention.newPath`, the
    /// `Statement` type, and `ProjectManifest.makeEncoder()` — and the read side
    /// is the phone's real loader (`ProjectsBrowser` → `CoordinatedFileIO` →
    /// `decodeGuardingSchema`), not a hand-decode.
    @MainActor
    func test_aMacWrittenStatementManifestRoundTripsIntoTheIntentRow() async throws {
        let path = try XCTUnwrap(StatementConvention.newPath(
            kind: .intent, scope: .project, documentSlug: nil))
        let statementId = "stmt-a1b2c3d4"
        XCTAssertTrue(DocIdShape.isValid(statementId),
            "the fixture id must match the shape ProjectStore.newId(prefix:) really mints")

        let manifest = ProjectManifest(
            id: "PRJ-ROUNDTRIP", type: .novel, title: "Round Trip", author: "Tester",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            modified: Date(timeIntervalSince1970: 1_700_000_500),
            structure: [], research: [],
            statements: [Statement(id: statementId, kind: .intent, scope: .project, path: path)])
        let root = try makeProjectFolder(
            "round-trip", json: try ProjectManifest.makeEncoder().encode(manifest))

        let browser = ProjectsBrowser(downloads: DownloadCoordinator(downloader: AlwaysLocalDownloader()))
        await browser.refresh(root: root)
        XCTAssertNil(browser.loadError)
        XCTAssertTrue(browser.failures.isEmpty,
            "a schema-4 manifest must not be refused by the phone's own gate: \(browser.failures)")

        let browsed = try XCTUnwrap(browser.project(id: "PRJ-ROUNDTRIP"))
        let row = try XCTUnwrap(StatementLoading.intentRow(
            statements: browsed.manifest.statements, research: browsed.manifest.research))
        XCTAssertEqual(row.origin, .statement)
        XCTAssertEqual(row.relativePath, "intent.md")
        // The URL the binder row hands the reader.
        XCTAssertEqual(
            browsed.url.appendingPathComponent(row.relativePath).lastPathComponent, "intent.md")
    }

    /// The un-migrated writer, through the same real loader — and from bytes an
    /// OLDER Mac wrote, so nothing in the fixture can drift with this build:
    /// `"schemaVersion": 3` and no `statements` key at all.
    @MainActor
    func test_aSchema3ManifestFromAnOlderMacStillShowsItsNote() async throws {
        let json = """
        {
          "author" : "Tester",
          "created" : "2023-11-14T22:13:20Z",
          "id" : "PRJ-LEGACY",
          "modified" : "2023-11-14T22:21:40Z",
          "research" : [
            {
              "id" : "res-legacy",
              "kind" : "document",
              "path" : "research/craft-intent.md",
              "role" : "craft_intent",
              "title" : "Craft Intent",
              "type" : "asset"
            }
          ],
          "schemaVersion" : 3,
          "structure" : [],
          "title" : "Legacy",
          "type" : "novel"
        }
        """
        let root = try makeProjectFolder("legacy", json: Data(json.utf8))

        let browser = ProjectsBrowser(downloads: DownloadCoordinator(downloader: AlwaysLocalDownloader()))
        await browser.refresh(root: root)
        XCTAssertTrue(browser.failures.isEmpty, "\(browser.failures)")

        let browsed = try XCTUnwrap(browser.project(id: "PRJ-LEGACY"))
        XCTAssertTrue(browsed.manifest.statements.isEmpty,
            "the fixture must have no statements section, or it isn't testing the un-migrated case")

        let row = try XCTUnwrap(StatementLoading.intentRow(
            statements: browsed.manifest.statements, research: browsed.manifest.research))
        XCTAssertEqual(row.origin, .legacyNote(id: "res-legacy"))
        XCTAssertEqual(row.relativePath, "research/craft-intent.md")
        XCTAssertEqual(row.title, "Craft Intent")
    }
}
