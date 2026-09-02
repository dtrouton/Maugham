import XCTest
import MaughamCore
@testable import Maugham

/// **Keep this letter** (editorial letter P1 Task 10, spec §3.6). A letter is
/// derived and ages out with its run's place in the rounds ring; Keep is how
/// one becomes a durable research note the writer owns.
///
/// Driven against a REAL `ProjectStore` over a temp project, because the whole
/// point of the verb is where the note lands, and the router that decides that
/// (`ResearchScope.route`) is exactly what a fake would stub out.
@MainActor
final class LetterKeepTests: XCTestCase {

    // MARK: - Fixtures (ResearchScopeTests' harness)

    private func makeNovel() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetterKeep-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "Chapter 1 content\n".write(
            to: tmp.appendingPathComponent("manuscript/c1.md"),
            atomically: true, encoding: .utf8)
        let chapter = StructureItem(
            id: "ch-1", title: "Chapter 1", type: .document, path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, try await ProjectStore.load(from: tmp))
    }

    private func makeCollection() async throws -> (URL, ProjectStore, StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetterKeepColl-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, piece)
    }

    private var letter: Letter {
        Letter(about: "You are writing about a house nobody lives in.",
               oneThing: "Let the second scene end before it explains itself.",
               working: [Letter.Working(
                    refs: [Diagnostic.Ref(paragraphId: "ab3d", excerpt: "The rain held.")],
                    what: "The weather never explains itself.",
                    why: "It leaves the reader looking.")],
               habits: [], questions: [], scenes: nil, scenePosition: nil)
    }

    private func makeRun(
        id: String = "run-1", passId: String? = nil, round: Int? = nil
    ) -> CompilerRun {
        CompilerRun(id: id, at: Date(timeIntervalSince1970: 1_788_000_000),
                    model: "sonnet", lastOpId: nil, deltaSummary: "d",
                    intentSnapshot: nil, passId: passId, round: round,
                    letter: letter)
    }

    private func body(of item: ResearchItem, in store: ProjectStore) throws -> String {
        let path = try XCTUnwrap(item.path)
        return try String(contentsOf: store.url.appendingPathComponent(path),
                          encoding: .utf8)
    }

    // MARK: - Where the note lands — the router's two arms

    /// **A novel chapter's letter goes to shared research WITH a link** —
    /// `ResearchScope.route`'s `.sharedPlusLink` arm. Keep names the scope and
    /// the router decides; a `switch manifest.type` here would be a second
    /// copy of that table (`PromotionPerformer`'s own rule, spec §6.2).
    func test_aNovelChaptersLetterLandsInSharedResearchWithALink() async throws {
        let (_, store) = try await makeNovel()
        let kept = try await LetterKeep.keep(
            letter, run: makeRun(), docId: "ch-1", editorName: "Le Guin", store: store)
        XCTAssertTrue(kept.path?.hasPrefix("research/") == true, kept.path ?? "nil")
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: "ch-1").contains(kept.id),
                      "the novel arm links what it files")
    }

    /// **A loose collection piece's letter lands in that piece's own folder,
    /// and is not also linked** — the `.pieceFolder` arm. Containment and a
    /// link are two different relationships and writing both is the defect
    /// `ResearchScopeTests` already pins one layer down.
    func test_aLoosePiecesLetterLandsInThePiecesOwnFolder() async throws {
        let (_, store, piece) = try await makeCollection()
        let kept = try await LetterKeep.keep(
            letter, run: makeRun(), docId: piece.id, editorName: "Le Guin", store: store)
        XCTAssertTrue(kept.path?.hasPrefix("pieces/01-story-a/research/") == true,
                      kept.path ?? "nil")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: piece.id), [],
                       "containment must not also write a link")
    }

    // MARK: - What the note says

    /// The note's body is `LetterMarkdown.render`'s, byte for byte, and its
    /// title is that render's title. One renderer, so the kept note and any
    /// other reading of the same letter cannot disagree.
    func test_theNoteCarriesTheRenderedLetterAndItsTitle() async throws {
        let (_, store) = try await makeNovel()
        let record = makeRun()
        let kept = try await LetterKeep.keep(
            letter, run: record, docId: "ch-1", editorName: "Le Guin", store: store)
        let expected = LetterMarkdown.render(
            letter, editorName: "Le Guin",
            laneLine: LetterKeep.laneLine(for: record, store: store), at: record.at)
        XCTAssertEqual(try body(of: kept, in: store), expected.body)
        XCTAssertEqual(kept.title, expected.title)
    }

    /// **Keep is a COPY** (spec §3.6). The run's own letter is untouched, so
    /// the section on screen still draws and a second Keep is still possible.
    func test_keepLeavesTheRunsOwnLetterWhereItWas() async throws {
        let (_, store) = try await makeNovel()
        let diagnostics = DiagnosticsStore(
            projectRoot: store.url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(run: makeRun(), diagnostics: [], docId: "ch-1")
        let before = diagnostics.lastRun(docId: "ch-1")?.letter
        XCTAssertEqual(before, letter, "premise: the run carries the letter")

        _ = try await LetterKeep.keep(
            letter, run: makeRun(), docId: "ch-1", editorName: "Le Guin", store: store)
        XCTAssertEqual(diagnostics.lastRun(docId: "ch-1")?.letter, before,
                       "keeping a letter must not move the run's own copy")
    }

    /// **A second Keep of the same run makes a second note.** No dedupe: §3.6
    /// says a copy, and a writer who kept a letter, edited the note, and wants
    /// the original back is entitled to it. The store's own sibling-title
    /// dedupe is what keeps the two apart on disk.
    func test_asecondKeepOfTheSameRunMakesASecondNote() async throws {
        let (_, store) = try await makeNovel()
        let record = makeRun()
        let first = try await LetterKeep.keep(
            letter, run: record, docId: "ch-1", editorName: "Le Guin", store: store)
        let second = try await LetterKeep.keep(
            letter, run: record, docId: "ch-1", editorName: "Le Guin", store: store)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(second.title, first.title + " 2",
                       "the store's sibling dedupe names the second one")
        XCTAssertEqual(try body(of: second, in: store), try body(of: first, in: store))
    }

    // MARK: - The refusal

    /// **An unwritable destination throws, and nothing reports a kept
    /// letter** (RULING-7: every fallible write happens before anything
    /// reports success). Measured by taking write permission off the folder
    /// the note has to land in.
    ///
    /// **Which of the two writes refuses is the store's business, and this
    /// test pins the outer contract rather than the inner one.** With the
    /// folder read-only the refusal arrives from `addResearchTextNote`'s own
    /// empty-file write, before `LetterKeep` ever reaches the body — there is
    /// no way through the public verb to make the note's creation succeed and
    /// its body write fail, because both land in the same folder. The body
    /// write's `try` (never `try?`) is the discipline `InboxStore.promote`
    /// carries for the same reason, and what pins it here is the positive
    /// case: `test_theNoteCarriesTheRenderedLetterAndItsTitle` reads the file
    /// back off disk, so a keep that returned before writing is red.
    func test_anUnwritableResearchFolderRefusesTheKeep() async throws {
        let (url, store) = try await makeNovel()
        let research = url.appendingPathComponent("research")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: research.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: research.path)
        }
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: research.path),
                       "premise: the folder the note must land in is unwritable")
        let before = store.manifest.research.count

        do {
            let kept = try await LetterKeep.keep(
                letter, run: makeRun(), docId: "ch-1", editorName: "Le Guin", store: store)
            XCTFail("an unwritable destination reported a kept letter: \(kept.path ?? "nil")")
        } catch {
            // The refusal is the contract; which error it is belongs to the store.
        }
        XCTAssertEqual(store.manifest.research.count, before,
                       "a refused keep leaves the research list where it was")
    }

    // MARK: - The lane line

    /// A stage's round names the lane the way the cockpit's own line does.
    func test_aStagesRoundNamesItsLane() async throws {
        let (_, store) = try await makeNovel()
        XCTAssertEqual(
            LetterKeep.laneLine(for: makeRun(passId: "line", round: 3), store: store),
            ReviewRoundCockpit.laneLine(
                pass: try XCTUnwrap(ReviewPass.pass(
                    id: "line", in: store.manifest.effectiveReviewPasses)),
                round: 3))
    }

    /// **The coach's round names HER, never her pass.** "Workshop" appears on
    /// no surface a writer has ever seen, so `coachLine` is the right builder
    /// and `laneLine` is not — the same split `ReviewRoundCockpit.laneLabel`
    /// makes on screen.
    func test_theCoachsRoundNamesHerAndNeverHerPass() async throws {
        let (_, store) = try await makeNovel()
        let line = LetterKeep.laneLine(
            for: makeRun(passId: ReviewPass.coachPreset.id, round: 2), store: store)
        XCTAssertEqual(line, "Le Guin \u{00b7} round 2")
        XCTAssertFalse(line.contains(ReviewPass.coachPreset.name), line)
    }

    /// A passless run has no lane, so the letter's heading carries none —
    /// naming one would invent a lane no round was filed in.
    func test_aPasslessRunHasNoLaneLine() async throws {
        let (_, store) = try await makeNovel()
        XCTAssertEqual(LetterKeep.laneLine(for: makeRun(), store: store), "")
    }

    // MARK: - The confirmation

    /// The confirmation names the note's own title — the one the store
    /// resolved, so a second keep says *Kept as “… 2”* rather than repeating
    /// the first one's name.
    func test_theConfirmationNamesTheNotesResolvedTitle() {
        XCTAssertEqual(LetterKeep.confirmation("Letter from Le Guin \u{2014} 2 September 2026"),
                       "Kept as \u{201C}Letter from Le Guin \u{2014} 2 September 2026\u{201D}")
    }

    /// **The confirmation belongs to the run it was kept from.** A new round
    /// replaces the letter on screen, and a line still saying what the
    /// previous round's letter was filed as would name a note about different
    /// prose.
    func test_theConfirmationIsScopedToItsOwnRun() {
        let kept = LetterKeep.Kept(runId: "run-1", title: "A Letter")
        XCTAssertEqual(LetterKeep.confirmation(for: kept, run: makeRun(id: "run-1")),
                       LetterKeep.confirmation("A Letter"))
        XCTAssertNil(LetterKeep.confirmation(for: kept, run: makeRun(id: "run-2")))
        XCTAssertNil(LetterKeep.confirmation(for: nil, run: makeRun(id: "run-1")))
    }
}
