// MaughamTests/PracticeSectionTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The Practice section on screen** (editorial letter P3 Task 7, spec
/// `2026-08-29-the-editorial-letter-design.md` §5 surface 1).
///
/// Two kinds of test, the house shape the mounted suites here already keep:
///
/// - **Pure**, for every line the section writes — the frontier, forward
///   motion, a churn hotspot, the unreadable notice. These are the copy the
///   writer reads, so they are asserted as whole strings rather than as
///   substrings: a line that lost its excerpt or its count would still contain
///   the chapter's name.
/// - **Mounted**, headless through `TestWindow.mount` (global constraint 9),
///   over a REAL on-disk project whose op logs `Document` itself wrote — the
///   fixture `ProjectPracticeTests` uses, for its reason: the section's whole
///   input is a walk over closed documents, and a hand-built value would stub
///   out the two things that can actually go wrong.
///
/// `press` (`accessibilityPerformPress`) is the delivery path rather than a
/// synthetic click: the Statistics window is its own scene and is never the key
/// window, and a click needs this host to be the active app besides.
@MainActor
final class PracticeSectionTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var foldersToRemove: [URL] = []

    override func setUp() {
        super.setUp()
        warmUpAccessibility()
    }

    override func tearDown() {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for url in foldersToRemove { try? FileManager.default.removeItem(at: url) }
        foldersToRemove = []
        super.tearDown()
    }

    // MARK: - Pure fixtures

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeOp(
        opId: String, at: Date, session: String = "s1",
        changes: [Op.ParagraphChange]
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: at, device: "macA",
           session: session, kind: .typingBurst, changes: changes, sequence: nil)
    }

    /// Signals with a frontier on `frontierId`, moved `sessionsAgo` sessions
    /// back, plus one rewrite apiece on `rewritten`. Built from ops rather than
    /// by hand because `ProcessSignals` declares its own initialiser, which is
    /// the point: the section is fed exactly what the window feeds it.
    private func signals(
        frontierId: String, sessionsAgo: Int, sequence: [String]
    ) -> ProcessSignals {
        var ops: [Op] = [
            makeOp(opId: "op-0", at: base, session: "s0",
                   changes: [.init(paragraphId: frontierId, prior: nil, next: "New.")]),
        ]
        // One later session per step, each a session of its own (a fresh
        // `Op.session` splits at zero gap) so the count is exact.
        for step in 1...max(1, sessionsAgo) where sessionsAgo > 0 {
            ops.append(makeOp(
                opId: "op-\(step)", at: base.addingTimeInterval(Double(step) * 60),
                session: "s\(step)",
                changes: [.init(paragraphId: "keep", prior: "Was.", next: "Now.")]))
        }
        return ProcessSignals(ops: ops, sequence: sequence, now: base)
    }

    private func row(
        id: String = "ch-3", title: String = "Chapter Three",
        signals: ProcessSignals,
        excerpts: [String: String] = [:],
        sceneCaptions: [String: String] = [:]
    ) -> ProjectPractice.DocumentRow {
        ProjectPractice.DocumentRow(
            id: id, title: title, signals: signals,
            excerpts: excerpts, sceneCaptions: sceneCaptions)
    }

    /// A practice whose single row holds a frontier `sessionsAgo` sessions old,
    /// with `excerpt` as that paragraph's words.
    private func practice(
        sessionsAgo: Int, excerpt: String?, caption: String? = nil,
        title: String = "Chapter Three", isScreenplay: Bool = false
    ) -> ProjectPractice {
        let id = "p1q2"
        let signals = signals(
            frontierId: id, sessionsAgo: sessionsAgo, sequence: [id, "keep"])
        return ProjectPractice(
            rows: [row(
                title: title, signals: signals,
                excerpts: excerpt.map { [id: $0] } ?? [:],
                sceneCaptions: caption.map { [id: $0] } ?? [:])],
            unreadableDocIds: [], isScreenplay: isScreenplay)
    }

    private func emptyPractice() -> ProjectPractice {
        ProjectPractice(rows: [], unreadableDocIds: [], isScreenplay: false)
    }

    // MARK: - The frontier line

    /// **Where the writing stands, in one line.** The chapter, the paragraph's
    /// own words and how long ago it moved — the excerpt is there because the
    /// jump opens the chapter and cannot scroll to the paragraph (global
    /// constraint 31), so the words are what say which one is meant.
    func test_theFrontierLineNamesTheChapterItsWordsAndHowLongAgo() {
        XCTAssertEqual(
            PracticeSection.frontierLine(
                practice(sessionsAgo: 2, excerpt: "The rain had")),
            "Frontier: Chapter Three \u{2014} \u{201C}The rain had\u{201D} "
            + "\u{00b7} moved 2 sessions ago")
    }

    /// A capped excerpt ends in an ellipsis, so a line that stops mid-sentence
    /// reads as a quotation cut short rather than as the paragraph's whole
    /// text. Only when it was actually cut: a short paragraph is quoted whole.
    func test_aCappedExcerptIsQuotedWithAnEllipsis() {
        let long = String(repeating: "a", count: ProjectPractice.excerptCharacterLimit)
        let line = PracticeSection.frontierLine(practice(sessionsAgo: 0, excerpt: long))
        XCTAssertTrue(line.contains("\u{201C}" + long + "\u{2026}\u{201D}"), line)
        XCTAssertFalse(
            PracticeSection.frontierLine(
                practice(sessionsAgo: 0, excerpt: "Short.")).contains("\u{2026}"),
            "a paragraph shorter than the cap was not cut, so nothing was left out")
    }

    /// A project nobody has typed a new paragraph in says so plainly. Not a
    /// zero, not an empty line — the writer's register (global constraint 12).
    func test_aProjectWithNoFrontierSaysSo() {
        XCTAssertEqual(
            PracticeSection.frontierLine(emptyPractice()),
            PracticeSection.noFrontierLine)
        XCTAssertEqual(PracticeSection.noFrontierLine, "No new paragraphs typed yet")
    }

    /// **A screenplay says the SCENE.** A slugline is how a screenwriter
    /// navigates, and "Script \u{2014} \u{201C}He stands at the sink\u{201D}"
    /// names no place at all (spec §5 surface 1: screenplay-shaped where the
    /// project is a screenplay).
    ///
    /// Disable experiment (run): making `place(of:in:)` answer `row.title`
    /// unconditionally \u{2014} `PracticeSectionTests.swift:<this line>:
    /// XCTAssertEqual failed: ("Frontier: Script \u{2014} \u{201C}He stands at
    /// the sink\u{201D} \u{00b7} moved in this session") is not equal to
    /// ("Frontier: INT. KITCHEN \u{2014} DAY \u{2014} \u{201C}He stands at the
    /// sink\u{201D} \u{00b7} moved in this session")`.
    func test_aScreenplayFrontierNamesTheSceneRatherThanTheFile() {
        XCTAssertEqual(
            PracticeSection.frontierLine(practice(
                sessionsAgo: 0, excerpt: "He stands at the sink",
                caption: "INT. KITCHEN \u{2014} DAY", title: "Script",
                isScreenplay: true)),
            "Frontier: INT. KITCHEN \u{2014} DAY \u{2014} "
            + "\u{201C}He stands at the sink\u{201D} \u{00b7} moved in this session")
    }

    /// A paragraph above the first slugline belongs to no scene, so the row
    /// falls back to the file's own title rather than drawing a blank place.
    func test_aScreenplayParagraphWithNoSceneFallsBackToTheFilesTitle() {
        XCTAssertEqual(
            PracticeSection.frontierLine(practice(
                sessionsAgo: 0, excerpt: "FADE IN.", caption: nil,
                title: "Script", isScreenplay: true)),
            "Frontier: Script \u{2014} \u{201C}FADE IN.\u{201D} "
            + "\u{00b7} moved in this session")
    }

    // MARK: - Forward motion

    /// Forward motion at 0, 1 and N. Singular and plural are separate arms
    /// because "moved 1 sessions ago" is not English, and the section's whole
    /// job is to read as a sentence.
    func test_theForwardMotionLineCountsSessionsInWords() {
        XCTAssertEqual(
            PracticeSection.forwardMotionLine(practice(sessionsAgo: 0, excerpt: "A.")),
            "moved in this session")
        XCTAssertEqual(
            PracticeSection.forwardMotionLine(practice(sessionsAgo: 1, excerpt: "A.")),
            "moved 1 session ago")
        XCTAssertEqual(
            PracticeSection.forwardMotionLine(practice(sessionsAgo: 4, excerpt: "A.")),
            "moved 4 sessions ago")
    }

    /// No frontier, no forward motion — `nil` rather than "moved 0 sessions
    /// ago", which would claim the writer had just been at a desk they have
    /// never sat at.
    func test_thereIsNoForwardMotionWithoutAFrontier() {
        XCTAssertNil(PracticeSection.forwardMotionLine(emptyPractice()))
    }

    // MARK: - Hotspots

    /// A churn row: where it is, what it says, how many times it has been
    /// rewritten.
    func test_aHotspotLineNamesThePlaceTheWordsAndTheCount() {
        let hotspot = ProcessSignals.Hotspot(
            paragraphId: "p1q2", position: 3, rewrites: 7)
        let subject = row(
            title: "Chapter Three",
            signals: signals(frontierId: "p1q2", sessionsAgo: 0, sequence: ["p1q2"]),
            excerpts: ["p1q2": "The rain had"])

        XCTAssertEqual(
            PracticeSection.hotspotLine(subject, hotspot),
            "Chapter Three \u{00b7} \u{201C}The rain had\u{201D} "
            + "\u{00b7} rewritten 7 times")
    }

    /// One rewrite is "once", not "1 times".
    func test_aSingleRewriteReadsAsOnce() {
        let hotspot = ProcessSignals.Hotspot(
            paragraphId: "p1q2", position: 0, rewrites: 1)
        let subject = row(
            signals: signals(frontierId: "p1q2", sessionsAgo: 0, sequence: ["p1q2"]),
            excerpts: ["p1q2": "The rain had"])

        XCTAssertTrue(
            PracticeSection.hotspotLine(subject, hotspot).hasSuffix("rewritten once"),
            PracticeSection.hotspotLine(subject, hotspot))
    }

    /// A screenplay hotspot names its scene, on the same rule as the frontier —
    /// and the discriminator is the row's own caption map, which
    /// `ProjectPractice` fills for a screenplay and leaves empty for prose.
    func test_aScreenplayHotspotNamesItsScene() {
        let hotspot = ProcessSignals.Hotspot(
            paragraphId: "p1q2", position: 2, rewrites: 5)
        let subject = row(
            title: "Script",
            signals: signals(frontierId: "p1q2", sessionsAgo: 0, sequence: ["p1q2"]),
            excerpts: ["p1q2": "He stands at the sink"],
            sceneCaptions: ["p1q2": "INT. KITCHEN \u{2014} DAY"])

        XCTAssertEqual(
            PracticeSection.hotspotLine(subject, hotspot),
            "INT. KITCHEN \u{2014} DAY \u{00b7} "
            + "\u{201C}He stands at the sink\u{201D} \u{00b7} rewritten 5 times")
    }

    // MARK: - The unreadable notice

    /// A document whose history could not be read is NAMED by count, so the
    /// writer knows the book's numbers are short rather than wrong
    /// (`ProjectPractice.unreadableDocIds`, RULING-54 lenient).
    func test_theUnreadableNoticeSaysHowManyAndWhyItMatters() {
        XCTAssertEqual(
            PracticeSection.unreadableNotice(1),
            "One file\u{2019}s history couldn\u{2019}t be read, so these numbers "
            + "are short.")
        XCTAssertEqual(
            PracticeSection.unreadableNotice(3),
            "3 files\u{2019} history couldn\u{2019}t be read, so these numbers "
            + "are short.")
    }

    // MARK: - What the row promises

    /// **The copy never promises a scroll** (global constraint 31). The stats
    /// window's jump is a project-scoped `.maughamNavigateToDocument`, whose
    /// receiver ignores `paragraph_id` today, so a row that said "Goes to this
    /// paragraph" would be a lie the excerpt exists to make unnecessary.
    func test_theRowsHelpPromisesTheChapterAndNeverAScroll() {
        XCTAssertEqual(PracticeSection.opensTheChapter, "Opens the chapter")
        XCTAssertEqual(PracticeSection.opensTheScene, "Opens the scene\u{2019}s file")
        for promise in [PracticeSection.opensTheChapter, PracticeSection.opensTheScene] {
            XCTAssertFalse(promise.lowercased().contains("scroll"), promise)
            XCTAssertFalse(promise.lowercased().contains("paragraph"), promise)
        }
    }

    // MARK: - On-disk fixture

    private struct Fixture {
        let url: URL
        let store: ProjectStore
        let ds: DocumentStore
    }

    private struct Doc {
        let id: String
        let title: String
        let path: String
    }

    private let chapterOne = Doc(id: "ch-1", title: "Chapter One", path: "manuscript/c1.md")
    private let chapterTwo = Doc(id: "ch-2", title: "Chapter Two", path: "manuscript/c2.md")

    private func makeProject(docs: [Doc]) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PracticeSection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        foldersToRemove.append(tmp)

        for doc in docs {
            try "".write(to: tmp.appendingPathComponent(doc.path),
                         atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: docs.map {
                StructureItem(id: $0.id, title: $0.title, type: .document, path: $0.path)
            },
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        return Fixture(url: tmp, store: store, ds: ds)
    }

    /// Open, edit, flush the burst to disk, close — closed is the state the
    /// Statistics window reads in (global constraint 30).
    private func write(
        _ fixture: Fixture, _ doc: Doc, _ body: (Document) throws -> Void
    ) async throws {
        let document = try await Document.load(
            url: fixture.url.appendingPathComponent(doc.path),
            device: "test", session: "s1", presenter: nil)
        try body(document)
        try await document.flushBurstNow()
        await document.close()
    }

    /// Two chapters, four churned paragraphs and a frontier in the second —
    /// `ProjectPracticeTests`' own merge fixture, so the section is mounted
    /// over numbers a real op log produced.
    private func twoChapterPractice() async throws -> ProjectPractice {
        let fixture = try await makeProject(docs: [chapterOne, chapterTwo])
        var oneA = "", oneB = "", oneC = ""
        try await write(fixture, chapterOne) {
            oneA = $0.insertParagraph(after: nil, text: "A.")
            oneB = $0.insertParagraph(after: oneA, text: "B.")
            oneC = $0.insertParagraph(after: oneB, text: "C.")
        }
        for round in 1...4 {
            try await write(fixture, chapterOne) { $0.setParagraph(id: oneA, text: "A\(round).") }
        }
        for round in 1...3 {
            try await write(fixture, chapterOne) { $0.setParagraph(id: oneB, text: "B\(round).") }
        }
        try await write(fixture, chapterOne) { $0.setParagraph(id: oneC, text: "C1.") }

        var twoA = ""
        try await write(fixture, chapterTwo) {
            twoA = $0.insertParagraph(after: nil, text: "The rain had come in off the water.")
        }
        for round in 1...2 {
            try await write(fixture, chapterTwo) { $0.setParagraph(id: twoA, text: "D\(round).") }
        }

        return ProjectPractice.derive(
            store: fixture.store, projectURL: fixture.url, now: Date())
    }

    // MARK: - Mounted

    /// **What the writer reads.** The frontier line and the book's top three
    /// churn rows, over a real project's op logs.
    func test_theSectionDrawsTheFrontierAndTheBooksThreeHotspots() async throws {
        let practice = try await twoChapterPractice()
        XCTAssertEqual(practice.hotspots.count, 3, "the fixture's own premise")

        let texts = try axTexts(in: mount(practice))

        // Uppercased because the section reuses the statistics window's own
        // `sectionHeader`, which sets `.textCase(.uppercase)` — the writer
        // reads "PRACTICE", so that is what is asserted.
        XCTAssertTrue(
            texts.contains(PracticeSection.title.uppercased()),
            "the section header never reached the surface. Read: \(texts)")
        XCTAssertTrue(
            texts.contains(PracticeSection.frontierLine(practice)),
            "the frontier line never reached the surface. Read: \(texts)")
        for entry in practice.hotspots {
            XCTAssertTrue(
                texts.contains(PracticeSection.hotspotLine(entry.row, entry.hotspot)),
                "a hotspot row never reached the surface. Read: \(texts)")
        }
    }

    /// **The press opens the chapter the frontier is in** — the window's own
    /// `onSelectChapter`, which posts a project-scoped
    /// `.maughamNavigateToDocument` (global constraint 31). Pressed through the
    /// accessibility tree: the Statistics window is its own scene and is never
    /// the key window, so a synthetic click has no premise here.
    func test_pressingTheFrontierRowOpensItsChapter() async throws {
        let practice = try await twoChapterPractice()
        let frontier = try XCTUnwrap(practice.frontier)
        XCTAssertEqual(frontier.row.id, "ch-2", "the fixture's own premise")

        var opened: [String] = []
        let window = mount(practice, onSelectChapter: { opened.append($0) })
        let labels = try axButtonLabels(in: window)
        let button = try XCTUnwrap(
            axButtons(labelled: PracticeSection.frontierLine(practice), in: window).first,
            "no frontier button. Buttons: \(labels)")
        press(button)
        pump()

        XCTAssertEqual(opened, ["ch-2"])
    }

    /// A hotspot row opens ITS OWN chapter, not the frontier's — the book's
    /// churn is merged across documents, so the third row belongs to a
    /// different file than the first two.
    func test_pressingAHotspotRowOpensThatRowsOwnChapter() async throws {
        let practice = try await twoChapterPractice()
        let last = try XCTUnwrap(practice.hotspots.last)
        XCTAssertEqual(last.row.id, "ch-2", "the fixture's own premise")

        var opened: [String] = []
        let window = mount(practice, onSelectChapter: { opened.append($0) })
        let labels = try axButtonLabels(in: window)
        let button = try XCTUnwrap(
            axButtons(
                labelled: PracticeSection.hotspotLine(last.row, last.hotspot),
                in: window).first,
            "no hotspot button. Buttons: \(labels)")
        press(button)
        pump()

        XCTAssertEqual(opened, ["ch-2"])
    }

    /// While the window is still walking the op logs the section says so, so
    /// an empty column never reads as "you have done nothing".
    ///
    /// Disable experiment (run): answering the nothing-typed empty state for a
    /// `nil` practice as well — `PracticeSectionTests.swift:<this line>:
    /// XCTAssertTrue failed - the deriving placeholder never reached the
    /// surface. Read: ["Practice", "No practice yet", "Type a paragraph and
    /// Maugham starts noticing where you're working."]`.
    func test_aNilPracticeShowsTheDerivingPlaceholder() throws {
        let texts = try axTexts(in: mount(nil))

        XCTAssertTrue(
            texts.contains(PracticeSection.derivingTitle),
            "the deriving placeholder never reached the surface. Read: \(texts)")
        XCTAssertFalse(
            texts.contains(PracticeSection.nothingYetTitle),
            "a window still reading the logs must not claim the writer has "
            + "done nothing. Read: \(texts)")
    }

    /// A project with nothing typed in it gets the empty state rather than a
    /// bare "No new paragraphs typed yet" over an empty column.
    func test_aProjectWithNothingToObserveShowsTheEmptyState() throws {
        let texts = try axTexts(in: mount(emptyPractice()))

        XCTAssertTrue(
            texts.contains(PracticeSection.nothingYetTitle), "read: \(texts)")
        XCTAssertFalse(
            texts.contains(PracticeSection.derivingTitle), "read: \(texts)")
    }

    /// An unreadable log is said out loud, beside the numbers it made short.
    func test_anUnreadableLogIsNamedOnTheSurface() throws {
        let short = ProjectPractice(
            rows: practice(sessionsAgo: 1, excerpt: "The rain had").rows,
            unreadableDocIds: ["ch-9"], isScreenplay: false)

        let texts = try axTexts(in: mount(short))

        XCTAssertTrue(
            texts.contains(PracticeSection.unreadableNotice(1)), "read: \(texts)")
        let whole = try axTexts(
            in: mount(practice(sessionsAgo: 1, excerpt: "The rain had")))
        XCTAssertFalse(
            whole.contains(PracticeSection.unreadableNotice(1)),
            "CONTROL: a book that read whole says nothing about short numbers")
    }

    // MARK: - Mounting

    private func mount(
        _ practice: ProjectPractice?,
        onSelectChapter: @escaping (String) -> Void = { _ in }
    ) -> NSWindow {
        mount(AnyView(PracticeSection(
            practice: practice, onSelectChapter: onSelectChapter)))
    }

    private func mount(_ view: AnyView) -> NSWindow {
        let window = TestWindow.mount(view, size: CGSize(width: 640, height: 480))
        windows.append(window)
        pump()
        return window
    }

    /// `DiagnosticsPaneTests`' own warm-up: the FIRST accessibility query
    /// against a freshly-launched host can succeed once and then report an
    /// empty tree for several seconds.
    private func warmUpAccessibility() {
        let window = mount(AnyView(Button("Warmup") {}))
        for _ in 0..<20 {
            if (try? axElements(in: window))?.isEmpty == false { break }
            pump(0.1)
        }
        window.contentView = NSView(frame: .zero)
        pump(0.05)
    }
}
