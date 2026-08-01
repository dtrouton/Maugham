import XCTest
@testable import Maugham
import MaughamCore

/// Adoption (M1A Task 4): a writer's existing craft-intent research notes become
/// the project's intent `Statement`, **once**, on the first open by a build that
/// has statements.
///
/// This is the only task in the milestone that touches prose the writer already
/// wrote, so every assertion here is about not losing a word of it.
@MainActor
final class StatementAdoptionTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// One legacy craft-intent note as a writer's project would carry it.
    private struct LegacyNote {
        var title: String = PaletteConvention.craftIntentTitle
        var body: String
        /// `ResearchItem.addedAt` — the only recorded age, and what "oldest
        /// first" is measured on.
        var addedAt: Date
        /// When false the note carries no `role`, so only the legacy FILENAME
        /// can find it (the second tier of the two-tier lookup).
        var stampRole: Bool = true
    }

    /// A project as it exists on disk BEFORE this milestone: `schemaVersion` 3,
    /// no `statements` section, craft intent living in the research tree.
    ///
    /// Built through the real store APIs rather than hand-written JSON so the
    /// fixture can't drift from what the shipped craft-intent seam actually
    /// produces; the manifest is downgraded to schema 3 at the end, which is the
    /// one thing this build can no longer write.
    private func legacyNovel(
        named name: String, notes: [LegacyNote],
        configure: ((ProjectStore, [ResearchItem]) async throws -> Void)? = nil
    ) async throws -> URL {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        var created: [ResearchItem] = []
        for note in notes {
            let item = try await store.addResearchTextNote(parentId: nil, title: note.title)
            try note.body.write(
                to: url.appendingPathComponent(try XCTUnwrap(item.path)),
                atomically: true, encoding: .utf8)
            if note.stampRole {
                try await store.stampRole(itemId: item.id, role: .craftIntent)
            }
            store.mutateResearchItem(id: item.id) { $0.addedAt = note.addedAt }
            created.append(item)
        }
        try await configure?(store, created)
        try await store.saveManifest()
        try downgradeManifestToSchema3(at: url)
        return url
    }

    /// Rewrite the on-disk manifest as a schema-3 build would have left it: the
    /// version back to 3 and the `statements` section absent entirely.
    private func downgradeManifestToSchema3(at projectURL: URL) throws {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        let raw = try Data(contentsOf: manifestURL)
        guard var json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw XCTSkip("manifest is not a JSON object")
        }
        json["schemaVersion"] = 3
        json.removeValue(forKey: "statements")
        let out = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: manifestURL, options: .atomic)
    }

    /// The `schemaVersion` and `modified` fields as they sit ON DISK — the
    /// in-memory manifest is not evidence about what a future open will read.
    private func onDisk(_ projectURL: URL) throws -> (schemaVersion: Int, modified: String) {
        let raw = try Data(contentsOf:
            projectURL.appendingPathComponent(ProjectManifest.fileName))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return (try XCTUnwrap(json["schemaVersion"] as? Int),
                try XCTUnwrap(json["modified"] as? String))
    }

    /// The text the statement's op log derives to — NOT what its `.md` says.
    private func derivedText(
        of statement: Statement, in projectURL: URL
    ) async throws -> String {
        let ops = try await OpLogStore(projectURL: projectURL).load(docId: statement.id)
        let state = Deriver.deriveWithSequenceFallback(ops: ops)
        return state.sequence.compactMap { state.paragraphs[$0] }.joined(separator: "\n\n")
    }

    /// Wait until the wall clock has crossed a whole-second boundary.
    ///
    /// `ProjectManifest.modified` round-trips through whole-second ISO8601, so
    /// a fixture built and re-opened inside one second produces the same string
    /// whether or not `modified` was touched. **Without this, both directions of
    /// the `modified` ruling below assert something that cannot fail** — the
    /// shift test passes on a build that never shifts it, and the no-shift test
    /// passes on a build that shifts it on every open.
    private func waitPastTheSecondBoundary() async throws {
        try await Task.sleep(nanoseconds: 1_100_000_000)
    }

    private func filesMatching(_ prefix: String, in projectURL: URL) -> [String] {
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: projectURL.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted()
    }

    // MARK: - The migration itself

    /// The whole point, end to end: prose written under the old seam is the
    /// project's intent statement after one open, and the note has left the
    /// research tree.
    func test_aLegacyCraftIntentNoteBecomesTheProjectsIntent() async throws {
        let url = try await legacyNovel(named: "Adopted", notes: [
            LegacyNote(body: "The weather is a character.", addedAt: Date())
        ])

        let store = try await ProjectStore.load(from: url)
        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .project),
            "a project with craft intent must come out of load with an intent statement")
        XCTAssertEqual(statement.path, "intent.md")
        let adopted = try await derivedText(of: statement, in: url)
        XCTAssertEqual(adopted, "The weather is a character.")

        XCTAssertTrue(
            TreeWalk.collect(in: store.manifest.research) { $0.role == .craftIntent }.isEmpty,
            "the adopted note must leave the research tree")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("research/craft-intent.md").path),
            "the adopted note's file must not be left behind at its old path")
    }

    /// A note the writer RENAMED away from `craft-intent.md` still carries the
    /// durable role, and adoption must find it by that role — the first of
    /// `PaletteLookup.craftIntentItem`'s two tiers.
    func test_aRenamedNoteIsStillFoundByItsRole() async throws {
        let url = try await legacyNovel(named: "RenamedIntent", notes: [
            LegacyNote(title: "What This Book Is For",
                       body: "Cold, and funny about it.", addedAt: Date())
        ])

        let store = try await ProjectStore.load(from: url)
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .project))
        let adopted = try await derivedText(of: statement, in: url)
        XCTAssertEqual(adopted, "Cold, and funny about it.")
    }

    /// The second tier: a note whose `role` was never stamped is found by the
    /// legacy FILENAME.
    ///
    /// **Driven directly rather than through `ProjectStore.load`, and that is
    /// the point of it.** On the real load path `healPaletteRolesEagerly` runs
    /// immediately before adoption and stamps `.craftIntent` onto exactly the
    /// notes this tier would catch, so no open of a real project can distinguish
    /// a two-tier detection from a role-only one — verified with a planted
    /// role-only offender, which the whole suite passed.
    ///
    /// The tier is kept anyway, and it earns its keep going FORWARD: after Task
    /// 7 deletes the craft-intent seam, adoption is the last reader of
    /// `ResearchRole.craftIntent`, and the craft-intent half of that palette
    /// heal becomes exactly the kind of thing a tidying pass removes. This test
    /// is what stops that from silently costing a writer their intent — so it
    /// exercises detection where the confound is absent.
    func test_anUnstampedNoteIsStillFoundByItsFilename() async throws {
        // A CURRENT-schema project, so `load`'s gate holds and its eager heal
        // never sees this note: it is added afterwards and carries no role.
        let url = try await ProjectFactory.createNovelProject(
            named: "UnstampedIntent", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let note = try await store.addResearchTextNote(
            parentId: nil, title: PaletteConvention.craftIntentTitle)
        XCTAssertNil(note.role, "the fixture must reach adoption with no durable role")
        try "Nobody stamped me.".write(
            to: url.appendingPathComponent(try XCTUnwrap(note.path)),
            atomically: true, encoding: .utf8)

        store.manifest.schemaVersion = 3
        try await store.saveManifest()
        await store.adoptLegacyCraftIntentIfNeeded()

        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .project),
            "a note identified only by its filename must still be adopted")
        let adopted = try await derivedText(of: statement, in: url)
        XCTAssertEqual(adopted, "Nobody stamped me.")
    }

    /// **The load-time role heal still runs, and adoption is now its only
    /// reason to.** `healPaletteRolesEagerly`'s craft-intent arm
    /// (`ProjectStore+Palette.swift`) stamps `.craftIntent` onto a legacy note
    /// identified by filename, immediately before adoption reads it. M1A Task 8
    /// deleted the craft-intent seam, so that arm no longer serves any lookup of
    /// its own and reads like dead code — this is what makes removing it fail
    /// rather than quietly cost a writer their renamed intent. (The test above
    /// covers the other half: what adoption does when the stamp did not run.)
    ///
    /// Falsified by deleting the `legacyIntents` loop from `healPaletteRolesEagerly`.
    func test_theLoadTimeRoleHealStillStampsALegacyCraftIntentNote() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "EagerHeal", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        // A v0.19.0-shaped note: at the legacy path, with no durable role. The
        // project is already at the current schema, so adoption's gate holds and
        // the note is still here to be looked at after the reload.
        let legacy = try await store.addResearchTextNote(
            parentId: nil, title: PaletteConvention.craftIntentTitle)
        XCTAssertEqual(legacy.path, "research/\(PaletteConvention.craftIntentFileName)")
        XCTAssertNil(legacy.role, "the fixture must reach the heal with no role")

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(
            TreeWalk.find(id: legacy.id, in: reloaded.manifest.research)?.role,
            .craftIntent,
            "the load-time heal no longer stamps a legacy craft-intent note, so "
            + "adoption's role-first detection misses every note the writer "
            + "renamed away from craft-intent.md")
    }

    // MARK: - Contract 2: the content arrives as a bootstrap op

    /// Adopted intent must have HISTORY, starting at adoption. Writing the
    /// file and skipping `Document.load`'s bootstrap looks identical on screen
    /// and leaves the statement with no op log at all — so this asserts against
    /// `.maugham/ops/`, and then proves the point by emptying the `.md` and
    /// showing the prose is still there.
    func test_adoptedContentArrivesAsOps() async throws {
        let url = try await legacyNovel(named: "AdoptedAsOps", notes: [
            LegacyNote(body: "First line.\n\nSecond line.", addedAt: Date())
        ])

        let store = try await ProjectStore.load(from: url)
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .project))

        let ops = try await OpLogStore(projectURL: url).load(docId: statement.id)
        let bootstraps = ops.filter { $0.kind == .bootstrap }
        XCTAssertEqual(bootstraps.count, 1,
                       "adoption must land exactly one bootstrap op in .maugham/ops/")
        XCTAssertEqual(bootstraps[0].changes.compactMap(\.next),
                       ["First line.", "Second line."],
                       "the writer's prose must be IN the op, paragraph by paragraph")

        // The op log is the source of truth, so the prose survives the `.md`
        // being emptied under it. A statement whose content was only ever
        // written to disk would come back blank here.
        let mdURL = url.appendingPathComponent(statement.path)
        try Data().write(to: mdURL)
        let doc = try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)
        XCTAssertEqual(doc.displayText, "First line.\n\nSecond line.")
        await doc.close()
    }

    // MARK: - Contract 3: duplicates concatenate, oldest first

    /// The live defect's leavings (spec §3): the old seam minted second copies,
    /// so a writer can have two notes for one scope. Picking a winner discards
    /// prose; concatenating is recoverable.
    ///
    /// The fixture puts the NEWER note first in the research tree, so an
    /// implementation that concatenated in manifest order rather than by age
    /// produces the right words in the wrong order — which is what the order
    /// assertion is for.
    func test_twoNotesForOneScopeAreConcatenatedOldestFirst() async throws {
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let url = try await legacyNovel(named: "TwoIntents", notes: [
            LegacyNote(title: "Craft Intent", body: "Written second.", addedAt: newer),
            LegacyNote(title: "Craft Intent 2", body: "Written first.", addedAt: older),
        ])

        let store = try await ProjectStore.load(from: url)
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .project))
        let text = try await derivedText(of: statement, in: url)

        // Both bodies present — nothing was discarded.
        XCTAssertTrue(text.contains("Written first."), "the older note's prose is missing")
        XCTAssertTrue(text.contains("Written second."), "the newer note's prose is missing")
        // …and in the right order. "Both present" alone passes on a reversal.
        let first = try XCTUnwrap(text.range(of: "Written first."))
        let second = try XCTUnwrap(text.range(of: "Written second."))
        XCTAssertTrue(first.lowerBound < second.lowerBound,
                      "oldest first — got:\n\(text)")
        XCTAssertEqual(text, "Written first.\n\nWritten second.",
                       "separated by a blank line, and nothing else added")
        XCTAssertEqual(store.manifest.statements.count, 1,
                       "two notes for one scope make ONE statement, not two")
        XCTAssertEqual(filesMatching("intent", in: url), ["intent.md"])
    }

    // MARK: - Contract 1: the gate is the on-disk schema version

    /// Adoption is once. The hazard the gate guards is not a second pass over
    /// the same notes — those are gone — but a note that exists AFTERWARDS: the
    /// writer restores one from Trash, or titles a new research note "Craft
    /// Intent". Without the gate, the next open swallows it into the statement.
    func test_adoptionRunsOnceAndNotAgain() async throws {
        let url = try await legacyNovel(named: "OnceOnly", notes: [
            LegacyNote(body: "The intent.", addedAt: Date())
        ])

        let first = try await ProjectStore.load(from: url)
        let statement = try XCTUnwrap(first.statement(kind: .intent, scope: .project))
        let adopted = try await derivedText(of: statement, in: url)
        XCTAssertEqual(adopted, "The intent.")
        XCTAssertEqual(try onDisk(url).schemaVersion, 4,
                       "the post-adoption save must write the new schema version")

        // The writer makes a craft-intent-shaped note after the migration. It is
        // theirs; adoption is over and must not touch it.
        let after = try await first.addResearchTextNote(
            parentId: nil, title: PaletteConvention.craftIntentTitle)
        try "Something else entirely.".write(
            to: url.appendingPathComponent(try XCTUnwrap(after.path)),
            atomically: true, encoding: .utf8)
        try await first.stampRole(itemId: after.id, role: .craftIntent)

        let second = try await ProjectStore.load(from: url)
        let again = try XCTUnwrap(second.statement(kind: .intent, scope: .project))
        XCTAssertEqual(again.id, statement.id, "no second statement for the same scope")
        XCTAssertEqual(second.manifest.statements.count, 1)
        let readopted = try await derivedText(of: again, in: url)
        XCTAssertEqual(readopted, "The intent.",
                       "a second open must not adopt again — the statement is unchanged")
        XCTAssertEqual(filesMatching("intent", in: url), ["intent.md"])
        XCTAssertNotNil(
            TreeWalk.collect(in: second.manifest.research) { $0.id == after.id }.first,
            "the writer's post-migration note stays where they put it")
    }

    /// The ambiguity the spec's §5 closed. Gating on "has no `statements`
    /// section" would re-scan a writer who legitimately has no intent on every
    /// single open, forever. The gate is the schema version, so the scan runs
    /// once and then never again.
    func test_aWriterWithNoIntentIsNotRescannedForever() async throws {
        let url = try await legacyNovel(named: "NoIntent", notes: [])
        let before = try onDisk(url)
        XCTAssertEqual(before.schemaVersion, 3)
        try await waitPastTheSecondBoundary()

        let first = try await ProjectStore.load(from: url)
        XCTAssertEqual(first._debugAdoptionScanCount, 1,
                       "a schema-3 project is scanned once")
        XCTAssertTrue(first.manifest.statements.isEmpty, "nothing to adopt, nothing minted")

        let stamped = try onDisk(url)
        XCTAssertEqual(stamped.schemaVersion, 4,
                       "a project with no intent must still be stamped, or it is rescanned forever")
        XCTAssertEqual(stamped.modified, before.modified,
                       "stamping a schema version is not a content edit — `modified` must not shift")

        let second = try await ProjectStore.load(from: url)
        XCTAssertEqual(second._debugAdoptionScanCount, 0,
                       "the second open must not scan at all")
        XCTAssertTrue(second.manifest.statements.isEmpty)
        XCTAssertEqual(try onDisk(url).modified, before.modified)
    }

    /// The other half of the `modified` ruling: adoption MOVES the writer's
    /// prose between files, which is a content edit, so the wall's date shifts.
    func test_adoptingProseShiftsModifiedButAStampAloneDoesNot() async throws {
        let url = try await legacyNovel(named: "ModifiedShift", notes: [
            LegacyNote(body: "Prose that moved.", addedAt: Date())
        ])
        let before = try onDisk(url)
        try await waitPastTheSecondBoundary()

        _ = try await ProjectStore.load(from: url)

        XCTAssertNotEqual(try onDisk(url).modified, before.modified,
                          "a project whose prose was moved between files HAS changed")
    }

    // MARK: - Contract 6: failure must not block the open

    /// A project that cannot be adopted still opens, with the legacy note
    /// untouched. Losing access to a manuscript because an intent note was odd
    /// is far worse than un-adopted intent.
    ///
    /// Two notes, one of them unreadable, because that is what discriminates:
    /// a scope is adopted whole or not at all. An implementation that shrugged
    /// an unreadable body off as an empty one would adopt the readable half and
    /// then trash BOTH notes — quietly losing whichever prose it could not read
    /// on the day it could not read it (an undownloaded iCloud file is the
    /// everyday version of this).
    func test_aFailedAdoptionStillOpensTheProject() async throws {
        let url = try await legacyNovel(named: "BrokenIntent", notes: [
            LegacyNote(body: "Unreadable.", addedAt: Date(timeIntervalSince1970: 1_000_000)),
            LegacyNote(title: "Craft Intent 2", body: "Perfectly readable.",
                       addedAt: Date(timeIntervalSince1970: 2_000_000)),
        ])
        // The note's file is gone while the manifest still points at it — an odd
        // project, not an impossible one (a half-restored backup makes this).
        try FileManager.default.removeItem(
            at: url.appendingPathComponent("research/craft-intent.md"))

        let store = try await ProjectStore.load(from: url)

        XCTAssertEqual(store.manifest.title, "BrokenIntent", "the project still opens")
        XCTAssertEqual(store.manifest.structure.count, 1, "the manuscript is still reachable")
        XCTAssertNil(store.statement(kind: .intent, scope: .project),
                     "a failed adoption mints no half-statement")
        XCTAssertTrue(store.manifest.statements.isEmpty)
        XCTAssertEqual(
            TreeWalk.collect(in: store.manifest.research) { $0.role == .craftIntent }.count, 2,
            "both legacy notes are left exactly where they were")
        XCTAssertEqual(
            try String(contentsOf: url.appendingPathComponent("research/craft-intent-2.md"),
                       encoding: .utf8),
            "Perfectly readable.",
            "the readable note keeps its prose, at its own path")
        XCTAssertEqual(filesMatching("intent", in: url), [],
                       "no orphan statement file for a scope that failed")
    }

    // MARK: - Scope, when the manifest already recorded one

    /// **The population this migration exists for.** Spec §3's defect is a
    /// NOVEL's: `craftIntentItem(forPieceId:)` looks up through
    /// `ResearchScope.pieceResearchPrefix`, which is nil for anything that is
    /// not a Collection loose piece — so a chapter's intent was created through
    /// `.sharedPlusLink` into shared `research/` where the lookup never looked,
    /// and the next call minted a second copy.
    ///
    /// `.sharedPlusLink` writes a `linkedResearchIds` record
    /// (`ResearchScope.swift:57-62`, `ProjectStore+Structure.swift:667`), so
    /// **the manifest knows which chapter that note belongs to.** Sweeping every
    /// craft-intent note in `research/` into one project statement would
    /// concatenate a writer's ten chapter intents into one headingless blob and
    /// then trash the records that said whose was whose.
    ///
    /// The fixture is the shipped seam, in the order that produces the defect.
    func test_aNovelChaptersLinkedIntentAdoptsToThatChapterAndNotTheBook() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "ChapterIntent", in: temp.url)
        let setup = try await ProjectStore.load(from: url)
        await setup.wordCountPopulationTask?.value
        let chapter = try XCTUnwrap(setup.manifest.structure.first)

        // The shipped seam, hand-built: `createCraftIntent(forPieceId:)` was
        // deleted by M1A Task 8, and this fixture is the two calls it made —
        // the project's note straight into shared `research/`, the chapter's
        // through `ResearchScope`, which routes a novel chapter to
        // `.sharedPlusLink` and writes the `linkedResearchIds` record adoption
        // reads. Both stamped, as the seam stamped them on create.
        let bookNote = try await setup.addResearchTextNote(
            parentId: nil, title: PaletteConvention.craftIntentTitle)
        try await setup.stampRole(itemId: bookNote.id, role: .craftIntent)
        let chapterNote = try await setup.createResearchNote(
            scope: .document(chapter.id), title: PaletteConvention.craftIntentTitle)
        try await setup.stampRole(itemId: chapterNote.id, role: .craftIntent)
        // The fixture must actually reproduce the defect, or this test proves
        // nothing about the population it is named for.
        XCTAssertNotEqual(chapterNote.id, bookNote.id,
                          "the shipped seam must mint a SECOND note for the chapter")
        XCTAssertEqual(setup.linkedResearchIds(forDocumentId: chapter.id), [chapterNote.id],
                       "the manifest records the association adoption must honour")
        try "The book is about weather.".write(
            to: url.appendingPathComponent(try XCTUnwrap(bookNote.path)),
            atomically: true, encoding: .utf8)
        try "Chapter one is about the flood.".write(
            to: url.appendingPathComponent(try XCTUnwrap(chapterNote.path)),
            atomically: true, encoding: .utf8)
        try await setup.saveManifest()
        try downgradeManifestToSchema3(at: url)

        let store = try await ProjectStore.load(from: url)

        XCTAssertEqual(store.manifest.statements.count, 2,
                       "the book's intent and the chapter's are two statements, not one")
        let chapterStatement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)),
            "the chapter's intent must adopt to the chapter the manifest named")
        XCTAssertEqual(chapterStatement.path, "intent/chapter-1.md")
        let chapterText = try await derivedText(of: chapterStatement, in: url)
        XCTAssertEqual(chapterText, "Chapter one is about the flood.")

        let bookStatement = try XCTUnwrap(store.statement(kind: .intent, scope: .project))
        let bookText = try await derivedText(of: bookStatement, in: url)
        XCTAssertEqual(bookText, "The book is about weather.")
        XCTAssertFalse(bookText.contains("flood"),
                       "the chapter's prose must not be merged into the book's")
    }

    /// Where the ambiguity is real, the fallback stands. A note listed by TWO
    /// documents names no one document, and guessing between them would put a
    /// writer's intent under a heading the manifest never claimed.
    func test_aNoteLinkedToTwoDocumentsFallsBackToTheProject() async throws {
        var second: StructureItem?
        let url = try await legacyNovel(named: "AmbiguousLink", notes: [
            LegacyNote(body: "Whose is this?", addedAt: Date())
        ]) { store, notes in
            let first = try XCTUnwrap(store.manifest.structure.first)
            second = try await store.addStructureItem(
                parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))
            try await store.linkResearch(researchId: notes[0].id, toDocumentId: first.id)
            try await store.linkResearch(
                researchId: notes[0].id, toDocumentId: try XCTUnwrap(second).id)
        }

        let store = try await ProjectStore.load(from: url)

        XCTAssertEqual(store.manifest.statements.count, 1)
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .project),
                                      "two claimants means no claimant — it is the project's")
        let text = try await derivedText(of: statement, in: url)
        XCTAssertEqual(text, "Whose is this?")
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        XCTAssertNil(store.statement(kind: .intent, scope: .document(chapter.id)))
        XCTAssertNil(store.statement(
            kind: .intent, scope: .document(try XCTUnwrap(second).id)))
    }

    // MARK: - Nothing to adopt

    /// An empty note is not intent. Minting a statement for it would swap one
    /// absence for another and cost the writer a file they never asked for.
    func test_anEmptyNoteMintsNothingAndIsLeftInPlace() async throws {
        let url = try await legacyNovel(named: "EmptyIntent", notes: [
            LegacyNote(body: "   \n\n  \n", addedAt: Date())
        ])

        let store = try await ProjectStore.load(from: url)

        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "no prose, no statement")
        XCTAssertEqual(filesMatching("intent", in: url), [])
        XCTAssertEqual(
            TreeWalk.collect(in: store.manifest.research) { $0.role == .craftIntent }.count, 1,
            "and the note stays where it is — adoption removes nothing it did not adopt")
        XCTAssertEqual(try onDisk(url).schemaVersion, 4, "still stamped, still once")
    }

    /// A craft-intent item with **no file** has no prose to adopt, so adoption
    /// has no business touching it.
    ///
    /// It matters because the removal would be *silent and unrecoverable*:
    /// `trashResearchItemCore` skips the file work for a pathless item and drops
    /// it from the manifest with no trash entry. The real note beside it adopts
    /// normally, so this pins the exclusion rather than an absence of work.
    func test_aPathlessNoteIsNeitherAdoptedNorRemoved() async throws {
        var pathlessId: String?
        let url = try await legacyNovel(named: "PathlessIntent", notes: [
            LegacyNote(body: "Real prose.", addedAt: Date(timeIntervalSince1970: 1_000_000)),
            LegacyNote(title: "Craft Intent 2", body: "",
                       addedAt: Date(timeIntervalSince1970: 2_000_000)),
        ]) { store, notes in
            pathlessId = notes[1].id
            store.mutateResearchItem(id: notes[1].id) { $0.path = nil }
        }

        let store = try await ProjectStore.load(from: url)

        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .project))
        let text = try await derivedText(of: statement, in: url)
        XCTAssertEqual(text, "Real prose.", "the note with a file adopts as usual")
        XCTAssertNotNil(
            TreeWalk.collect(in: store.manifest.research) { $0.id == pathlessId }.first,
            "a pathless item must survive: removing it leaves no trash entry to recover")
    }

    // MARK: - Document scope

    /// The legacy seam scoped intent to the project OR to a Collection's loose
    /// piece. A piece's intent must adopt to `.document(pieceId)` and not be
    /// swept into the book's.
    func test_aLoosePiecesIntentAdoptsToItsOwnDocumentScope() async throws {
        let url = try await ProjectFactory.createCollectionProject(
            named: "PieceIntent", in: temp.url)
        let setup = try await ProjectStore.load(from: url)
        await setup.wordCountPopulationTask?.value
        let piece = try await setup.addLoosePiece(title: "The Fall", mode: .prose)

        let pieceNote = try await setup.addPieceResearchNote(
            pieceId: piece.id, title: PaletteConvention.craftIntentTitle)
        try "This piece is about falling.".write(
            to: url.appendingPathComponent(try XCTUnwrap(pieceNote.path)),
            atomically: true, encoding: .utf8)
        try await setup.stampRole(itemId: pieceNote.id, role: .craftIntent)

        let projectNote = try await setup.addResearchTextNote(
            parentId: nil, title: PaletteConvention.craftIntentTitle)
        try "The book is about weather.".write(
            to: url.appendingPathComponent(try XCTUnwrap(projectNote.path)),
            atomically: true, encoding: .utf8)
        try await setup.stampRole(itemId: projectNote.id, role: .craftIntent)
        try await setup.saveManifest()
        try downgradeManifestToSchema3(at: url)

        let store = try await ProjectStore.load(from: url)

        let pieceStatement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(piece.id)),
            "a loose piece's intent must adopt to its own scope")
        XCTAssertEqual(pieceStatement.path, "intent/the-fall.md")
        let pieceText = try await derivedText(of: pieceStatement, in: url)
        XCTAssertEqual(pieceText, "This piece is about falling.")

        let projectStatement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .project))
        let projectText = try await derivedText(of: projectStatement, in: url)
        XCTAssertEqual(projectText, "The book is about weather.",
                       "the piece's intent must not be swept into the book's")
    }

    // MARK: - The canvas's marks (whole-branch review, I4)

    /// A card promoted to craft intent under 1C-c2 names the legacy note's id.
    /// Adoption trashes that note, taking its manifest entry with it — so
    /// without re-pointing, `ArtifactIndex.over` cannot resolve the mark and its
    /// readers each say something false: `PromotedArtifactSection` reports the
    /// writer's intent as deleted over prose sitting in the new pane, and
    /// `Promotion.hasDanglingMark` refuses a line promotion with "Promote that
    /// card again first" for something that worked.
    func test_adoptionRepointsACanvasMarkThatNamedTheLegacyNote() async throws {
        var legacyNoteId = ""
        let url = try await legacyNovel(
            named: "CanvasMark",
            notes: [LegacyNote(body: "The weather is a character.", addedAt: Date())]
        ) { _, created in
            legacyNoteId = try XCTUnwrap(created.first).id
        }

        // A canvas that promoted a card and a region into that note, plus one
        // card contributing to it and one naming something else entirely.
        var scene = CanvasScene()
        var promoted = CanvasNode(id: CanvasNodeID("n1"), kind: .scrap,
                                  origin: .zero, width: 240)
        promoted.promotedItemID = legacyNoteId
        var contributor = CanvasNode(id: CanvasNodeID("n2"), kind: .scrap,
                                     origin: CGPoint(x: 300, y: 0), width: 240)
        contributor.contributedToItemID = legacyNoteId
        var unrelated = CanvasNode(id: CanvasNodeID("n3"), kind: .scrap,
                                   origin: CGPoint(x: 600, y: 0), width: 240)
        unrelated.promotedItemID = "res-something-else"
        for node in [promoted, contributor, unrelated] { scene.insert(node) }
        scene.insertRegion(CanvasRegion(
            id: CanvasRegionID("r1"), label: "Act One",
            frame: CGRect(x: 0, y: 0, width: 400, height: 400),
            promotedItemID: legacyNoteId))
        CanvasStore(projectRoot: url).save(scene: scene, scraps: [:])

        let store = try await ProjectStore.load(from: url)
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .project))
        XCTAssertNotEqual(statement.id, legacyNoteId,
                          "the statement reused the note's id, so this test "
                          + "cannot tell a re-pointing from doing nothing")

        let reloaded = CanvasStore(projectRoot: url).load().scene
        XCTAssertEqual(reloaded.node(CanvasNodeID("n1"))?.promotedItemID, statement.id,
                       "the promoted card still names the trashed research note, "
                       + "so the inspector reports the writer's intent as deleted")
        XCTAssertEqual(reloaded.node(CanvasNodeID("n2"))?.contributedToItemID, statement.id)
        XCTAssertEqual(reloaded.region(CanvasRegionID("r1"))?.promotedItemID, statement.id)
        XCTAssertEqual(reloaded.node(CanvasNodeID("n3"))?.promotedItemID,
                       "res-something-else",
                       "adoption collected an unrelated promotion into the intent")

        // And `ArtifactIndex` really can resolve it now — the reader that
        // decides what the writer is told.
        let index = ArtifactIndex.over(research: store.manifest.research,
                                       statements: store.manifest.statements,
                                       structure: store.manifest.structure)
        XCTAssertEqual(index.kind(of: statement.id), .craftIntent,
                        "the re-pointed mark must resolve, or it is dangling "
                        + "under a different id")
    }

    /// The control: a project with a canvas and no promoted intent must come out
    /// of adoption with its sidecar untouched, so the assertion above is about
    /// re-pointing rather than about rewriting every canvas that exists.
    func test_adoptionLeavesACanvasWithNoMatchingMarkExactlyAsItWas() async throws {
        let url = try await legacyNovel(
            named: "CanvasUntouched",
            notes: [LegacyNote(body: "The weather is a character.", addedAt: Date())])

        var scene = CanvasScene()
        var node = CanvasNode(id: CanvasNodeID("n1"), kind: .scrap,
                              origin: .zero, width: 240)
        node.promotedItemID = "res-something-else"
        scene.insert(node)
        CanvasStore(projectRoot: url).save(scene: scene, scraps: [:])
        let sidecar = url.appendingPathComponent(CanvasStore.sidecarRelativePath)
        let before = try Data(contentsOf: sidecar)

        _ = try await ProjectStore.load(from: url)

        XCTAssertEqual(try Data(contentsOf: sidecar), before,
                       "adoption rewrote a sidecar it had no reason to touch")
    }
}
