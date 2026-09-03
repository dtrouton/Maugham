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
        id: String = "run-1", passId: String? = nil, round: Int? = nil,
        stage: DraftStage? = nil
    ) -> CompilerRun {
        var letter = self.letter
        letter.stage = stage?.rawValue
        return CompilerRun(id: id, at: Date(timeIntervalSince1970: 1_788_000_000),
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
    /// **This test measures the STORE's refusal, not `LetterKeep`'s own.**
    /// Both writes land in the same folder, so with it read-only the throw
    /// arrives from `addResearchTextNote`'s empty-file write and `keep` never
    /// reaches its body write at all. What pins `keep`'s own `try` is
    /// `test_aRefusedBodyWriteRefusesTheWholeKeep` below, through the injected
    /// `write` seam — the positive case cannot do it, because a `try?` there
    /// still writes the body successfully and stays green.
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

    /// **A refused BODY WRITE refuses the whole keep** — `keep`'s own `try`,
    /// pinned (fix round 1, Important 1).
    ///
    /// The note's file exists by then: `createResearchNote` made it, empty,
    /// and this verb cannot un-make it. What must never happen is that an
    /// empty note is REPORTED as a kept letter — so the throw propagates, no
    /// `ResearchItem` comes back, and the file on disk still has none of the
    /// letter's words in it. Falsified by softening the `try` to `try?`: the
    /// keep then returns the empty note as a success.
    func test_aRefusedBodyWriteRefusesTheWholeKeep() async throws {
        struct WriteRefused: Error {}
        let (_, store) = try await makeNovel()

        var returned: ResearchItem?
        do {
            returned = try await LetterKeep.keep(
                letter, run: makeRun(), docId: "ch-1", editorName: "Le Guin",
                store: store, write: { _, _ in throw WriteRefused() })
            XCTFail("a refused body write reported a kept letter")
        } catch is WriteRefused {
            // The refusal the seam injected, arriving unswallowed.
        }
        XCTAssertNil(returned, "nothing may be reported kept")

        let note = try XCTUnwrap(store.manifest.research.first,
                                 "premise: the store did make the note before the write")
        XCTAssertEqual(try body(of: note, in: store), "",
                       "the letter's words never reached the file, which is exactly "
                       + "what a reported success would have hidden")
    }

    /// **And no confirmation is shown**, which is the writer-visible half of
    /// the same contract: the shared handler both hosts press must send the
    /// refusal to its failure channel and leave `onKept` untouched.
    func test_aRefusedKeepConfirmsNothingAndSaysWhyInstead() async throws {
        struct WriteRefused: LocalizedError {
            var errorDescription: String? { "The disk said no." }
        }
        let (_, store) = try await makeNovel()
        var kept: [LetterKeep.Kept] = []
        var failures: [String?] = []

        let press = LetterKeep.handler(
            letter: letter, run: makeRun(), docId: "ch-1", store: store,
            editorName: "Le Guin", write: { _, _ in throw WriteRefused() },
            onKept: { kept.append($0) }, onFailure: { failures.append($0) })
        press()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, failures.count < 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(kept.isEmpty, "a refused keep must confirm nothing: \(kept)")
        XCTAssertEqual(failures.first ?? "unset", String?.none,
                       "the press clears the previous refusal first")
        XCTAssertEqual(failures.last, "The disk said no.",
                       "and says what happened: \(failures)")
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

    /// **The stage rides the lane the kept letter is headed with** (P3 Task 5,
    /// global constraint 28) — read off the letter's own stamp, so a note kept
    /// six months later still names the stage the run derived rather than
    /// whatever the document has become since.
    func test_aKeptLettersLaneNamesTheStageItsRunDerived() async throws {
        let (_, store) = try await makeNovel()
        XCTAssertEqual(
            LetterKeep.laneLine(
                for: makeRun(passId: ReviewPass.coachPreset.id, round: 2,
                             stage: .drafting),
                store: store),
            "Le Guin \u{00b7} round 2 \u{00b7} drafting")
        XCTAssertEqual(
            LetterKeep.laneLine(
                for: makeRun(passId: "line", round: 3, stage: .revising),
                store: store),
            ReviewRoundCockpit.laneLine(
                pass: try XCTUnwrap(ReviewPass.pass(
                    id: "line", in: store.manifest.effectiveReviewPasses)),
                round: 3, stage: .revising),
            "a stage's lane says it the cockpit's way, with the word on the end")
    }

    /// **A caller holding a NOTE rather than a run passes no stage, and the
    /// line is what it always was** — the queue's own door
    /// (`QueueLedgerVerbs.provenance`). An annotation carries a pass and a
    /// round; it carries nothing about the writer's delta.
    func test_aLaneBuiltWithoutAStageIsUnmoved() async throws {
        let (_, store) = try await makeNovel()
        XCTAssertEqual(
            LetterKeep.laneLine(
                passId: "line", round: 3, stage: nil, store: store),
            LetterKeep.laneLine(
                for: makeRun(passId: "line", round: 3), store: store),
            "no stage on either side, so the two lines agree exactly")
        XCTAssertEqual(
            LetterKeep.laneLine(passId: "line", round: 3, stage: nil, store: store),
            "Line \u{00b7} Lish \u{00b7} round 3")
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
