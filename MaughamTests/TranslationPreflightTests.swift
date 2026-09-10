import XCTest
import MaughamCore
@testable import Maugham

final class TranslationPreflightTests: XCTestCase {

    func test_wordCountSplitsOnWhitespaceLikeTheCheckpointsOwnCount() {
        XCTAssertEqual(TranslationPreflight.wordCount("The fog came in."), 4)
        XCTAssertEqual(TranslationPreflight.wordCount("one\n\ntwo   three\tfour"), 4)
        XCTAssertEqual(TranslationPreflight.wordCount(""), 0)
        XCTAssertEqual(TranslationPreflight.wordCount("   "), 0)
    }

    /// The budget is source words plus translated words of every document in
    /// the set — the two texts every leg is briefed with.
    func test_theBudgetSumsSourceAndTranslationAcrossTheSet() throws {
        XCTAssertEqual(TranslationPreflight.sum(source: ["a b c", "d e"], translations: ["x y", nil]), 7)
        XCTAssertEqual(TranslationPreflight.sum(source: [], translations: []), 0)
    }

    /// **Every edition gets its own figure from one opening of the document**
    /// (translation pipeline P4, review finding 1).
    ///
    /// The desk asks this once for a whole book of rows, and the expensive
    /// half is `currentParagraphState` — for a closed chapter, the whole
    /// manuscript derived off the op log. Asked per pair it was paid for once
    /// per language; this pins that both languages still come back, and that
    /// they come back with the DIFFERENT figures their own translation files
    /// earn — a loop that leaked one language's records into another's total
    /// would give them the same answer.
    @MainActor
    func test_budgetsAnswersEveryLanguageFromOneOpeningOfTheDocument() async throws {
        let fixture = try await makeProject()
        defer { Task { await fixture.documentStore.close() } }

        let paragraph = try XCTUnwrap(fixture.document.sequence.first,
                                      "premise: the loaded chapter has no paragraphs")
        try await TranslationStore.append(
            TranslationRecord(paragraphId: paragraph, language: "es",
                              text: "uno dos tres cuatro cinco",
                              sourceHash: TranslationHash.hash(
                                  fixture.document.paragraphs[paragraph] ?? "")),
            forDocId: "doc-1", identity: LocalIdentities.current.translator, identities: .current,
            in: fixture.projectURL)

        let both = try TranslationPreflight.budgets(
            documentIds: ["doc-1"], languages: ["es", "fr"],
            store: fixture.projectStore, documentStore: fixture.documentStore,
            projectURL: fixture.projectURL)

        XCTAssertEqual(Set(both.keys), ["es", "fr"],
                       "every language asked for gets an answer")
        let source = try XCTUnwrap(both["fr"], "the untranslated edition's own source words")
        XCTAssertGreaterThan(source, 0, "premise: the chapter has words in it")
        XCTAssertEqual(both["es"], source + 5,
                       "the Spanish edition's five translated words are on top of "
                       + "the same source, and are NOT counted against French")

        // …and the single-language door answers exactly what the plural one does.
        XCTAssertEqual(
            try TranslationPreflight.budget(
                documentIds: ["doc-1"], language: "es", store: fixture.projectStore,
                documentStore: fixture.documentStore, projectURL: fixture.projectURL),
            both["es"])
    }

    /// Nothing readable in the set is an absence rather than a zero — the
    /// distinction `detailLine` needs to draw no pre-flight at all.
    @MainActor
    func test_budgetsIsEmptyWhenNothingInTheSetCouldBeRead() async throws {
        let fixture = try await makeProject()
        defer { Task { await fixture.documentStore.close() } }

        XCTAssertTrue(try TranslationPreflight.budgets(
            documentIds: ["no-such-doc"], languages: ["es"],
            store: fixture.projectStore, documentStore: fixture.documentStore,
            projectURL: fixture.projectURL).isEmpty)
        XCTAssertNil(try TranslationPreflight.budget(
            documentIds: ["no-such-doc"], language: "es",
            store: fixture.projectStore, documentStore: fixture.documentStore,
            projectURL: fixture.projectURL))
    }

    // MARK: - Helpers

    private struct Fixture {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let document: Document
    }

    /// **A pre-flight over an unreadable translation file refuses** (P2a D0).
    ///
    /// The figure is "~N words briefed", which the writer weighs a click
    /// against, and a skipped actor file makes it too LARGE: every paragraph
    /// that file holds reads as untranslated and so as words still to send.
    /// The desk draws no figure over the refusal, beside the Couldn't-read
    /// line `EditionStatus` puts up in the same pass.
    @MainActor
    func test_anUnreadableTranslationFileRefusesThePreflight() async throws {
        let fixture = try await makeProject()
        defer { Task { await fixture.documentStore.close() } }

        let squat = TranslationStore.fileURL(
            forDocId: fixture.document.docId, language: "es",
            deviceSlug: DeviceSlug.make(from: "bad"), in: fixture.projectURL)
        try FileManager.default.createDirectory(
            at: squat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: squat, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try TranslationPreflight.budgets(
                documentIds: ["doc-1"], languages: ["es"],
                store: fixture.projectStore, documentStore: fixture.documentStore,
                projectURL: fixture.projectURL)
        ) { error in
            guard case OpLogStore.ReadError.unreadableFile(let name, _, _) = error else {
                return XCTFail("expected OpLogStore.ReadError.unreadableFile, got \(error)")
            }
            XCTAssertEqual(name, squat.lastPathComponent)
        }
    }

    /// **The desk's own answer carries the refusal, in words** (P2a D0, fix
    /// round 1).
    ///
    /// The throwing door above is for callers that propagate. This is the one
    /// the department desk asks, and the whole point of its third state is
    /// that the sentence reaches the row: caught and turned into an empty
    /// dictionary, the writer watched the "~N words briefed" clause vanish
    /// with nothing said, and the only thing naming the file was
    /// `EditionStatus` happening to be derived on the same pass.
    @MainActor
    func test_theDesksAnswerCarriesTheRefusalNamingTheFile() async throws {
        let fixture = try await makeProject()
        defer { Task { await fixture.documentStore.close() } }

        let squat = TranslationStore.fileURL(
            forDocId: fixture.document.docId, language: "es",
            deviceSlug: DeviceSlug.make(from: "bad"), in: fixture.projectURL)
        try FileManager.default.createDirectory(
            at: squat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: squat, withIntermediateDirectories: true)

        let budgets = TranslationPreflight.Budgets.over(
            documentIds: ["doc-1"], languages: ["es"],
            store: fixture.projectStore, documentStore: fixture.documentStore,
            projectURL: fixture.projectURL)

        guard case .unreadable(let sentence) = budgets else {
            return XCTFail("expected .unreadable, got \(budgets)")
        }
        XCTAssertTrue(sentence.contains(squat.lastPathComponent),
                      "the sentence the row draws names the file: \(sentence)")
        XCTAssertTrue(sentence.contains("translation file"),
                      "…and calls it what it is: \(sentence)")

        // …and that is what the row draws where the figure would have been.
        XCTAssertEqual(DepartmentRunState.preflightLine(budgets.answer(for: "es")), sentence)
    }

    /// The control: a readable set answers with figures, and the row draws the
    /// pre-flight clause — so the assertion above is about the unreadable file
    /// rather than about the fixture.
    @MainActor
    func test_aReadableSetAnswersWithFiguresTheRowCanDraw() async throws {
        let fixture = try await makeProject()
        defer { Task { await fixture.documentStore.close() } }

        let budgets = TranslationPreflight.Budgets.over(
            documentIds: ["doc-1"], languages: ["es"],
            store: fixture.projectStore, documentStore: fixture.documentStore,
            projectURL: fixture.projectURL)

        guard case .counted(let byLanguage) = budgets else {
            return XCTFail("expected .counted, got \(budgets)")
        }
        let words = try XCTUnwrap(byLanguage["es"])
        XCTAssertGreaterThan(words, 0, "premise: the chapter has words in it")
        XCTAssertEqual(budgets.answer(for: "es"), .words(words))
        XCTAssertEqual(DepartmentRunState.preflightLine(budgets.answer(for: "es")),
                       "7 legs · ~\(words.formatted(.number)) words briefed")
    }

    /// **A scope with nothing to say falls through to the next one** (P2a D0,
    /// fix round 1) — the rule `detailLine`'s `chapter ?? book` depends on. A
    /// chapter that REFUSED is not papered over with the book's figure, and a
    /// chapter that counted is not reported through the book's refusal.
    func test_aScopesAnswerIsWholeAndOnlyAnAbsentOneFallsThrough() {
        let counted = TranslationPreflight.Budgets.counted(["es": 40])
        let refused = TranslationPreflight.Budgets.unreadable("c1.es.bad.jsonl can't be read.")

        XCTAssertNil(TranslationPreflight.Budgets.none.answer(for: "es"),
                     "nothing asked falls through")
        XCTAssertNil(counted.answer(for: "fr"),
                     "a language this scope counted nothing for falls through")
        XCTAssertEqual(counted.answer(for: "es"), .words(40))
        XCTAssertEqual(refused.answer(for: "es"),
                       .unreadable("c1.es.bad.jsonl can't be read."))
        XCTAssertEqual(refused.answer(for: "fr"), refused.answer(for: "es"),
                       "the file that would not open is not one language's problem")
    }

    /// One open, registered chapter — `DepartmentRunTests.makeProject`'s shape,
    /// private here for the same reason its own copy is private there.
    @MainActor
    private func makeProject() async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TPF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let path = "manuscript/c1.md"
        try "The fog came in.\n\nShe closed the door."
            .write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8)

        let manifest = ProjectManifest(
            type: .novel, title: "The Project", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-1", title: "Chapter 1", type: .document, path: path),
            ],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: tmp)
        let documentStore = try await DocumentStore.open(url: tmp)
        projectStore.documentStore = documentStore

        let doc = try await Document.load(
            url: tmp.appendingPathComponent(path),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc, for: path)

        return Fixture(projectURL: tmp, projectStore: projectStore,
                       documentStore: documentStore, document: doc)
    }
}
