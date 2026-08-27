import XCTest
@testable import Maugham
import MaughamCore

/// The publish department, Task 5: proving the edition brief — a THIRD
/// `Statement.Kind` (`.editionBrief(String)`, Tasks 1–2) — rides the existing
/// statement machinery end to end with no new store code. `createStatement`
/// walks `StatementConvention.newPath`'s `(.editionBrief(lang), .project)` row
/// straight to `editions/<lang>.md`; the only thing this kind needed that
/// didn't already exist is its writer-facing name in `ArtifactIndex.kindTitle`.
@MainActor
final class EditionBriefStatementTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A loaded novel project with its async load work settled, so a test that
    /// asserts "nothing was written twice" isn't racing `load`'s own tail.
    private func loadedNovel(named name: String) async throws -> (URL, ProjectStore) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return (url, store)
    }

    /// Every file under the project root, project-relative and sorted.
    ///
    /// **The whole tree, not just `editions/`.** The refusal this backs is about
    /// a path that escapes the folder it was supposed to land in, so asserting
    /// only that `editions/` is unchanged would miss precisely the failure —
    /// a file minted somewhere else entirely. Directories are excluded so a
    /// mint that created `editions/` on its way to throwing still reads as
    /// clean; the file it would have put there is what matters.
    private func fileTree(under root: URL) throws -> [String] {
        let prefix = root.standardizedFileURL.path + "/"
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var paths: [String] = []
        for case let url as URL in walk {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            paths.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
        }
        return paths.sorted()
    }

    // MARK: - (a) creation, path, find-or-create

    func test_creatingAnEditionBriefMintsAtEditionsSlashLangDotMd() async throws {
        let (url, store) = try await loadedNovel(named: "EditionBriefCreate")

        let first = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        XCTAssertEqual(first.path, "editions/es.md")
        XCTAssertEqual(first.kind, .editionBrief("es"))
        XCTAssertEqual(first.scope, .project)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("editions/es.md").path))
        XCTAssertEqual(store.manifest.statements.map(\.id), [first.id],
                       "the brief must register in the manifest, same as any other statement")

        let second = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        XCTAssertEqual(second.id, first.id, "find-or-create must find before it creates")
        XCTAssertEqual(second.path, first.path)
        XCTAssertEqual(store.manifest.statements.count, 1,
                       "a second call must not register a second statement")
    }

    /// A different language is a different statement, not a second copy of the
    /// same one — the lang tag is part of the kind's identity.
    func test_twoLanguagesAreTwoDistinctBriefs() async throws {
        let (_, store) = try await loadedNovel(named: "EditionBriefTwoLanguages")

        let es = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        let fr = try await store.createStatement(kind: .editionBrief("fr"), scope: .project)

        XCTAssertNotEqual(es.id, fr.id)
        XCTAssertEqual(es.path, "editions/es.md")
        XCTAssertEqual(fr.path, "editions/fr.md")
        XCTAssertEqual(store.manifest.statements.count, 2)
    }

    // MARK: - (b) statementText on a fresh brief

    func test_statementTextOnAFreshBriefAnswersEmptyWithoutThrowing() async throws {
        let (_, store) = try await loadedNovel(named: "EditionBriefEmptyText")

        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)

        XCTAssertEqual(try store.statementText(of: brief), "",
                       "a fresh mint has no words yet, and reading it must not throw")
    }

    /// The other half of (b): words written through the shared append path come
    /// back out again — the same round trip every other statement kind gets.
    func test_statementTextReflectsWhatWasAppended() async throws {
        let (_, store) = try await loadedNovel(named: "EditionBriefAppendedText")

        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        try await store.appendToStatement(
            "For the Spanish edition, keep October's doctor female.",
            to: brief, session: "test-\(UUID().uuidString)")

        XCTAssertEqual(try store.statementText(of: brief),
                       "For the Spanish edition, keep October's doctor female.")
    }

    // MARK: - (c) kindTitle

    func test_kindTitleSpellsEditionBriefWithTheLanguageTag() {
        XCTAssertEqual(ArtifactIndex.kindTitle(.editionBrief("es")), "Edition Brief · es")
        XCTAssertEqual(ArtifactIndex.kindTitle(.editionBrief("fr")), "Edition Brief · fr",
                       "the language tag is not hardcoded to one language")
    }

    // MARK: - (d) statementTitlePairs

    func test_statementTitlePairsIncludesTheBriefUnderItsTitle() async throws {
        let (_, store) = try await loadedNovel(named: "EditionBriefTitlePairs")

        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)

        let pairs = store.statementTitlePairs()
        XCTAssertTrue(pairs.contains { $0.id == brief.id && $0.title == "Edition Brief · es" },
                     "expected (\(brief.id), \"Edition Brief · es\") among \(pairs)")
    }

    // MARK: - (e) the tag is refused at the choke point (issue #43, F-F)

    /// **`editions/<lang>.md` is a filename, so the tag has to be canonical**
    /// (issue #43, F-F). This gate is STRICTER than the translator store's
    /// deliberately — that one lowercases before it tests, because a role is
    /// matched case-insensitively and normalised on read, while this one is
    /// spelled into a path that the read side then looks for verbatim. `EN` is
    /// an offender here and not there: `editions/EN.md` is a file every
    /// lowercase-tagged reader would miss, so the writer's brief would sit on
    /// disk unread. `../evil` and `en/../../x` are the sharper half — a bare
    /// `appendingPathComponent` would have written them wherever they pointed.
    ///
    /// **Nothing may reach disk on a refusal.** The whole tree is snapshotted,
    /// not just `editions/`, because a path that escapes lands somewhere this
    /// test would otherwise never look.
    func test_anInvalidLanguageTagIsRefusedAndNothingIsCreated() async throws {
        let (url, store) = try await loadedNovel(named: "EditionBriefInvalidTag")
        let before = try fileTree(under: url)
        let statementsBefore = store.manifest.statements

        for tag in ["../evil", "en/../../x", "EN", " ", "a b"] {
            do {
                _ = try await store.createStatement(
                    kind: .editionBrief(tag), scope: .project)
                XCTFail("expected a refusal for \(tag.debugDescription)")
            } catch let error as ProjectStoreError {
                XCTAssertEqual(error, .languageTagInvalid(tag),
                               "the refusal must name the tag as it arrived")
            }
        }

        XCTAssertEqual(store.manifest.statements.map(\.id), statementsBefore.map(\.id),
                       "a refused brief must register no statement")
        XCTAssertEqual(try fileTree(under: url), before,
                       "a refused brief must put no file anywhere under the project")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("editions/EN.md").path),
            "an uppercase tag must not mint a file no lowercase reader would find")
    }

    /// The control: a well-formed tag still mints its file, so the gate above is
    /// refusing its offenders rather than the kind.
    func test_aWellFormedTagStillMintsItsBrief() async throws {
        let (url, store) = try await loadedNovel(named: "EditionBriefValidTag")

        let brief = try await store.createStatement(kind: .editionBrief("fr"), scope: .project)

        XCTAssertEqual(brief.path, "editions/fr.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("editions/fr.md").path))
    }

    /// **The containment gate under every kind, exercised through the one kind
    /// that takes writer-supplied text into its path.** A document's intent
    /// lands at `intent/<slug>.md`, and the slug comes from the writer's own
    /// title — so a title spelled as a path traversal is the closest thing this
    /// store has to a hostile segment.
    ///
    /// It cannot escape, and the reason is `Slugifier.slug`, which keeps only
    /// `[a-z0-9-]` and falls back to `untitled`: dots and slashes are dropped
    /// before `newPath` ever sees them. `SafeRelativePath.resolve` at the mint
    /// is therefore belt-and-braces on this arm rather than load-bearing — it
    /// is here so the NEXT kind, or a future slug rule that forgets, is caught
    /// by the store instead of by the filesystem.
    func test_aDocumentTitledLikeAPathTraversalStillLandsInsideTheProject() async throws {
        let (url, store) = try await loadedNovel(named: "IntentPathTraversal")
        let doc = try await store.addStructureItem(
            parentId: nil, title: "../../evil", kind: .document(extension: "md"))

        let intent = try await store.createStatement(
            kind: .intent, scope: .document(doc.id))

        XCTAssertTrue(intent.path.hasPrefix("intent/"),
                      "expected a path inside intent/, got \(intent.path)")
        XCTAssertFalse(intent.path.contains(".."), "the slug must carry no traversal")
        let resolved = url.appendingPathComponent(intent.path).standardizedFileURL.path
        XCTAssertTrue(resolved.hasPrefix(url.standardizedFileURL.path + "/"),
                      "\(resolved) escaped the project root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved))
    }
}
