// MaughamTests/ProjectPracticeTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// `ProjectPractice` is the Statistics window's Practice section as a value —
/// the writer's process across the whole book, not one document (spec
/// `2026-08-29-the-editorial-letter-design.md` §5, surface 1). `ProcessSignals`
/// answers one document; this merges every document's answer into the project's
/// one frontier and the project's three hotspots, and carries the two strings a
/// row has to draw: the paragraph's own excerpt and, in a screenplay, the
/// slugline it lives under.
///
/// Driven against a REAL on-disk project whose op logs were written by
/// `Document` itself, because the whole task is a walk over closed documents
/// (constraint 30) and a hand-built `[Op]` array would stub out the two things
/// that can actually go wrong: which file the walk opens, and what
/// `Deriver.deriveWithSequenceFallback` hands back from it.
@MainActor
final class ProjectPracticeTests: XCTestCase {

    // MARK: - Fixture

    /// Both stores plus the folder, held together because `documentStore` is a
    /// weak link on `ProjectStore` (`ProjectStoreTasksTests`' `StoreBundle`
    /// reason) and ARC would otherwise drop it as the fixture returns.
    private struct Fixture {
        let url: URL
        let store: ProjectStore
        let ds: DocumentStore
    }

    /// Permissions to put back before the temp folder is removed — a 0o000
    /// op-log file is not deletable by the teardown sweep either.
    private var permissionsToRestore: [(path: String, mode: NSNumber)] = []
    private var foldersToRemove: [URL] = []

    override func tearDown() {
        for entry in permissionsToRestore {
            try? FileManager.default.setAttributes(
                [.posixPermissions: entry.mode], ofItemAtPath: entry.path)
        }
        permissionsToRestore = []
        for url in foldersToRemove { try? FileManager.default.removeItem(at: url) }
        foldersToRemove = []
        super.tearDown()
    }

    private struct Doc {
        let id: String
        let title: String
        let path: String
    }

    /// A project on disk with empty manuscript files — every paragraph in these
    /// tests is INSERTED through the `Document` API, so each one is a
    /// `.typingBurst` mint rather than a `.bootstrap`, which is the difference
    /// `ProcessSignals` turns on.
    private func makeProject(
        type: ProjectType, docs: [Doc], extraStructure: [StructureItem] = []
    ) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectPractice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        foldersToRemove.append(tmp)

        for doc in docs {
            try "".write(to: tmp.appendingPathComponent(doc.path),
                         atomically: true, encoding: .utf8)
        }
        let structure = docs.map {
            StructureItem(id: $0.id, title: $0.title, type: .document, path: $0.path)
        } + extraStructure
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A", created: Date(), modified: Date(),
            structure: structure, research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        return Fixture(url: tmp, store: store, ds: ds)
    }

    /// Open a document, do something to it, flush the burst to disk and close.
    /// Closed is the state the Statistics window reads in (constraint 30).
    private func write(
        _ fixture: Fixture, _ doc: Doc,
        _ body: (Document) throws -> Void
    ) async throws {
        let document = try await Document.load(
            url: fixture.url.appendingPathComponent(doc.path),
            device: "test", session: "s1", presenter: nil)
        try body(document)
        try await document.flushBurstNow()
        await document.close()
    }

    private let chapterOne = Doc(id: "ch-1", title: "Chapter One", path: "manuscript/c1.md")
    private let chapterTwo = Doc(id: "ch-2", title: "Chapter Two", path: "manuscript/c2.md")

    // MARK: - The walk

    /// The rows are the manuscript DOCUMENTS in structure order — a group is
    /// not a row, and a document the manifest lists with no `path` has no op
    /// log to read and is not a row either.
    func test_theRowsAreTheManuscriptDocumentsInStructureOrder() async throws {
        let pathless = StructureItem(
            id: "ghost", title: "Untitled", type: .document, path: nil)
        let group = StructureItem(id: "part-1", title: "Part One", type: .group, path: nil)
        let fixture = try await makeProject(
            type: .novel, docs: [chapterOne, chapterTwo],
            extraStructure: [pathless, group])
        try await write(fixture, chapterOne) { _ = $0.insertParagraph(after: nil, text: "One.") }
        try await write(fixture, chapterTwo) { _ = $0.insertParagraph(after: nil, text: "Two.") }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())

        XCTAssertEqual(practice.rows.map(\.id), ["ch-1", "ch-2"])
        XCTAssertEqual(practice.rows.map(\.title), ["Chapter One", "Chapter Two"])
        XCTAssertTrue(practice.unreadableDocIds.isEmpty)
        XCTAssertFalse(practice.isScreenplay)
    }

    // MARK: - The project's frontier

    /// One frontier for the book: the most recent of the per-document
    /// frontiers. The writer is at the end of whichever chapter they last
    /// opened a paragraph in, and that is what the section names.
    func test_theProjectsFrontierIsTheLaterMintedChapters() async throws {
        let fixture = try await makeProject(type: .novel, docs: [chapterOne, chapterTwo])
        try await write(fixture, chapterOne) {
            _ = $0.insertParagraph(after: nil, text: "An older sentence.")
        }
        var latestId = ""
        try await write(fixture, chapterTwo) {
            latestId = $0.insertParagraph(after: nil, text: "The newest sentence.")
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())

        let frontier = try XCTUnwrap(practice.frontier)
        XCTAssertEqual(frontier.row.id, "ch-2")
        XCTAssertEqual(frontier.frontier.paragraphId, latestId)
        let chapterOneFrontier = try XCTUnwrap(practice.rows.first?.signals.frontier)
        XCTAssertNotEqual(chapterOneFrontier.paragraphId, latestId,
                          "chapter one has a frontier of its own; the project's is the later")
    }

    /// A project nobody has typed in has no frontier and no hotspots — a value
    /// with nothing in it, not a zero.
    func test_aProjectWithNoTypingHasNoFrontier() async throws {
        let fixture = try await makeProject(type: .novel, docs: [chapterOne])

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())

        XCTAssertEqual(practice.rows.count, 1)
        XCTAssertNil(practice.frontier)
        XCTAssertTrue(practice.hotspots.isEmpty)
    }

    // MARK: - Hotspots across the book

    /// Churn is a property of the BOOK here, not of a chapter: the top three
    /// are ranked across every row, so two chapters each holding a hot
    /// paragraph both appear and the coldest of the three drops out.
    func test_hotspotsMergeAcrossChapters() async throws {
        let fixture = try await makeProject(type: .novel, docs: [chapterOne, chapterTwo])
        var oneA = "", oneB = "", oneC = ""
        try await write(fixture, chapterOne) {
            oneA = $0.insertParagraph(after: nil, text: "A.")
            oneB = $0.insertParagraph(after: oneA, text: "B.")
            oneC = $0.insertParagraph(after: oneB, text: "C.")
        }
        // Each flush is one op, and one op touching a paragraph is one rewrite.
        for round in 1...4 {
            try await write(fixture, chapterOne) { $0.setParagraph(id: oneA, text: "A\(round).") }
        }
        for round in 1...3 {
            try await write(fixture, chapterOne) { $0.setParagraph(id: oneB, text: "B\(round).") }
        }
        try await write(fixture, chapterOne) { $0.setParagraph(id: oneC, text: "C1.") }

        var twoA = ""
        try await write(fixture, chapterTwo) {
            twoA = $0.insertParagraph(after: nil, text: "D.")
        }
        for round in 1...2 {
            try await write(fixture, chapterTwo) { $0.setParagraph(id: twoA, text: "D\(round).") }
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())

        XCTAssertEqual(practice.hotspots.count, ProcessSignals.hotspotCount)
        XCTAssertEqual(practice.hotspots.map(\.row.id), ["ch-1", "ch-1", "ch-2"])
        XCTAssertEqual(practice.hotspots.map(\.hotspot.paragraphId), [oneA, oneB, twoA])
        XCTAssertEqual(practice.hotspots.map(\.hotspot.rewrites), [4, 3, 2])
        XCTAssertFalse(practice.hotspots.contains { $0.hotspot.paragraphId == oneC },
                       "the coldest of four drops out of a top-three across the book")
    }

    /// Ties break by ROW ORDER first, then by position — so a book's hotspot
    /// list reads down the manuscript rather than in dictionary order.
    ///
    /// Disable experiment (run): dropping the `a.rowIndex < b.rowIndex` arm
    /// from `ProjectPractice.hotspots`' comparator leaves ties at the mercy of
    /// each paragraph's position inside its OWN chapter, and chapter two's
    /// first paragraph outranks chapter one's second —
    /// `ProjectPracticeTests.swift:243: XCTAssertEqual failed:
    /// ("["ch-2", "ch-1", "ch-2"]") is not equal to ("["ch-1", "ch-2", "ch-2"]")`.
    func test_hotspotTiesBreakByRowOrderThenPosition() async throws {
        let fixture = try await makeProject(type: .novel, docs: [chapterOne, chapterTwo])
        var oneA = "", twoA = "", twoB = ""
        try await write(fixture, chapterOne) {
            _ = $0.insertParagraph(after: nil, text: "Filler one.")
            oneA = $0.insertParagraph(after: nil, text: "A.")
        }
        try await write(fixture, chapterTwo) {
            twoA = $0.insertParagraph(after: nil, text: "B.")
            twoB = $0.insertParagraph(after: twoA, text: "C.")
        }
        // Two rewrites each: three paragraphs, all tied.
        for round in 1...2 {
            try await write(fixture, chapterOne) { $0.setParagraph(id: oneA, text: "A\(round).") }
            try await write(fixture, chapterTwo) {
                $0.setParagraph(id: twoA, text: "B\(round).")
                $0.setParagraph(id: twoB, text: "C\(round).")
            }
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())

        XCTAssertEqual(practice.hotspots.map(\.row.id), ["ch-1", "ch-2", "ch-2"])
        XCTAssertEqual(practice.hotspots.map(\.hotspot.paragraphId), [oneA, twoA, twoB])
    }

    // MARK: - An unreadable log

    /// RULING-54 lenient, in the shape `ProjectStore+Annotations` already uses:
    /// a document whose op log cannot be read is skipped and NAMED, and every
    /// other row still derives. A window that refused the whole section over
    /// one file would tell the writer nothing at all.
    ///
    /// Disable experiment (run): dropping the `unreadable.append(item.id)` from
    /// the skip arm — a silent `continue` — leaves the section unable to say
    /// the book's numbers are short. `ProjectPracticeTests.swift:279:
    /// XCTAssertEqual failed: ("[]") is not equal to ("["ch-1"]")`.
    func test_anUnreadableLogIsNamedAndTheOtherRowsStillDerive() async throws {
        let fixture = try await makeProject(type: .novel, docs: [chapterOne, chapterTwo])
        try await write(fixture, chapterOne) { _ = $0.insertParagraph(after: nil, text: "One.") }
        var twoId = ""
        try await write(fixture, chapterTwo) {
            twoId = $0.insertParagraph(after: nil, text: "Two.")
        }

        // The FILE, not the folder: a read-only folder makes the store throw
        // before the walk under test ever runs.
        let logs = OpLogStore.opLogFileURLs(forDocId: "ch-1", in: fixture.url)
        let log = try XCTUnwrap(logs.first, "chapter one should have written a log")
        let fm = FileManager.default
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber)
        permissionsToRestore.append((log.path, original))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: log.path)

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())

        XCTAssertEqual(practice.unreadableDocIds, ["ch-1"])
        XCTAssertEqual(practice.rows.map(\.id), ["ch-2"])
        XCTAssertEqual(practice.frontier?.frontier.paragraphId, twoId)
    }

    // MARK: - Excerpts

    /// A row draws the paragraph's own words, not its id (constraint 31: the
    /// jump opens the chapter, so the excerpt is what tells the writer WHICH
    /// paragraph). Trimmed, whitespace collapsed onto one line, capped.
    func test_theFrontiersExcerptIsTrimmedCollapsedAndCapped() async throws {
        let fixture = try await makeProject(type: .novel, docs: [chapterOne])
        let long = String(repeating: "wide ", count: 60)
        var id = ""
        try await write(fixture, chapterOne) {
            id = $0.insertParagraph(after: nil, text: "  ragged   text\nwith  breaks  ")
        }
        var longId = ""
        try await write(fixture, chapterOne) {
            longId = $0.insertParagraph(after: id, text: long)
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())
        let row = try XCTUnwrap(practice.rows.first)

        XCTAssertEqual(row.excerpts[longId]?.count, ProjectPractice.excerptCharacterLimit)
        XCTAssertEqual(practice.frontier?.frontier.paragraphId, longId)
        // The ragged paragraph is not the frontier and was never rewritten, so
        // it carries no excerpt — the map holds exactly what a row draws.
        XCTAssertNil(row.excerpts[id])
    }

    /// Every hotspot the section draws carries its own excerpt, so no row ever
    /// has to fall back to printing an id.
    func test_everyHotspotCarriesItsExcerpt() async throws {
        let fixture = try await makeProject(type: .novel, docs: [chapterOne])
        var id = ""
        try await write(fixture, chapterOne) {
            id = $0.insertParagraph(after: nil, text: "Original.")
        }
        try await write(fixture, chapterOne) {
            $0.setParagraph(id: id, text: "  Revised   again  ")
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())
        let hotspot = try XCTUnwrap(practice.hotspots.first)

        XCTAssertEqual(hotspot.hotspot.paragraphId, id)
        XCTAssertEqual(hotspot.row.excerpts[id], "Revised again")
    }

    // MARK: - Scene captions

    /// A screenplay row says which SCENE the paragraph is in, because a
    /// slugline is how a screenwriter navigates and a bare excerpt of an action
    /// line is not a place. The caption is the nearest PRECEDING slugline, and
    /// the slugline predicate is the tokenizer's own — never a second regex.
    func test_aScreenplayCaptionsAParagraphWithTheSluglineAboveIt() async throws {
        let script = Doc(id: "sc-1", title: "Script", path: "manuscript/script.fountain")
        let fixture = try await makeProject(type: .screenplay, docs: [script])
        // Two bursts, not one: `PendingBuffer.snapshot()` sorts a burst's
        // changes by paragraph id, so which of two paragraphs minted in the
        // SAME op reads as the frontier is decided by the ids' alphabet rather
        // than by which was typed second. Op order is what actually carries
        // authoring order, so the fixture types the way a writer does.
        var sluglineId = "", actionId = ""
        try await write(fixture, script) {
            sluglineId = $0.insertParagraph(after: nil, text: "INT. KITCHEN - DAY")
        }
        try await write(fixture, script) {
            actionId = $0.insertParagraph(after: sluglineId, text: "He stands at the sink.")
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())
        let row = try XCTUnwrap(practice.rows.first)

        XCTAssertTrue(practice.isScreenplay)
        XCTAssertEqual(practice.frontier?.frontier.paragraphId, actionId)
        XCTAssertEqual(row.sceneCaptions[actionId], "INT. KITCHEN - DAY")
    }

    /// A slugline that is itself the frontier is captioned by itself — "nearest
    /// preceding, or itself" — so the row never comes up empty for the one
    /// paragraph that IS the scene.
    func test_aSluglineIsItsOwnCaption() async throws {
        let script = Doc(id: "sc-1", title: "Script", path: "manuscript/script.fountain")
        let fixture = try await makeProject(type: .screenplay, docs: [script])
        var sluglineId = ""
        try await write(fixture, script) {
            sluglineId = $0.insertParagraph(after: nil, text: "EXT. ROOFTOP - NIGHT")
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())
        let row = try XCTUnwrap(practice.rows.first)

        XCTAssertEqual(row.sceneCaptions[sluglineId], "EXT. ROOFTOP - NIGHT")
    }

    /// A prose project has no sluglines, so the map is empty and the section
    /// draws novel-shaped (spec §5 surface 1: "screenplay-shaped where the
    /// project is a screenplay").
    ///
    /// Disable experiment (run): removing the `isScreenplay` guard so every
    /// project is captioned makes this fail — a novel paragraph reading
    /// "INT. KITCHEN - DAY" tokenizes as a scene heading like any other, so the
    /// map comes back with one entry instead of none.
    /// `ProjectPracticeTests.swift:407: XCTAssertEqual failed:
    /// ("["<minted id>": "INT. KITCHEN - DAY"]") is not equal to ("[:]")`.
    func test_aNovelIsNeverCaptioned() async throws {
        let fixture = try await makeProject(type: .novel, docs: [chapterOne])
        var slugId = "", actionId = ""
        try await write(fixture, chapterOne) {
            slugId = $0.insertParagraph(after: nil, text: "INT. KITCHEN - DAY")
        }
        try await write(fixture, chapterOne) {
            actionId = $0.insertParagraph(after: slugId, text: "He stands at the sink.")
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())
        let row = try XCTUnwrap(practice.rows.first)

        XCTAssertFalse(practice.isScreenplay)
        XCTAssertEqual(practice.frontier?.frontier.paragraphId, actionId)
        XCTAssertEqual(row.sceneCaptions, [:])
    }

    /// A paragraph ABOVE the first slugline has no scene to belong to, and the
    /// map says so by holding no entry rather than by inventing one.
    func test_aParagraphAboveTheFirstSluglineHasNoCaption() async throws {
        let script = Doc(id: "sc-1", title: "Script", path: "manuscript/script.fountain")
        let fixture = try await makeProject(type: .screenplay, docs: [script])
        var openingId = ""
        try await write(fixture, script) {
            openingId = $0.insertParagraph(after: nil, text: "FADE IN ON A DOOR.")
        }

        let practice = ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())
        let row = try XCTUnwrap(practice.rows.first)

        XCTAssertEqual(practice.frontier?.frontier.paragraphId, openingId)
        XCTAssertNil(row.sceneCaptions[openingId])
    }
}
