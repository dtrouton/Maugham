import XCTest
import MaughamCore
@testable import Maugham

/// **The first annotation-change event** (M3 P2 Task 9) — the channel that says
/// "this document's notes are not what they were".
///
/// Until now nothing announced an annotation change beyond the `Document`
/// itself: `annotationsVersion` is an observable counter, so a surface holding
/// that document re-renders, and every surface that does NOT hold it —
/// the review board's open-notes column, the queue in project scope, a second
/// window — heard nothing at all. That is fine while every reader is looking at
/// the one open document and false the moment a count is drawn over a project.
///
/// So `.maughamAnnotationsChanged` carries the doc id, project-scoped, and it is
/// posted from exactly the places an annotation op is really appended:
///
/// - the four LOCAL append sites in `Document+Annotations.swift` (the two
///   funnels, plus `addAnnotation` and the accept/revert arm that reach
///   `opStore.append` directly),
/// - a MERGE that brought foreign annotation ops in
///   (`handleExternalLogChange`, past its echo guard), and
/// - `DocumentStore.presenterDidChangeSubitem`'s `.opLog` arm for a document
///   that is NOT open — the cross-device gap, where no `Document` exists to
///   notice anything.
///
/// **What must NOT post is as load-bearing as what must.** `invalidateAnnotations
/// Cache` fires on keystroke-adjacent paths, and the presenter fires on our own
/// writes (the echo the merge path guards against) — a post from either turns a
/// project-wide walk into something that runs while the writer types.
@MainActor
final class AnnotationChangeEventTests: XCTestCase {

    // MARK: - Listening

    /// One announcement, as the receiver sees it.
    private struct Announcement: Equatable {
        let docId: String?
        let scopeKind: String?
        let scopeId: String?
    }

    /// Collects every `.maughamAnnotationsChanged` posted while the block runs.
    private func announcements(
        during body: () async throws -> Void
    ) async rethrows -> [Announcement] {
        var seen: [Announcement] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamAnnotationsChanged, object: nil, queue: nil
        ) { note in
            seen.append(Announcement(
                docId: note.userInfo?[MaughamEvent.annotationDocIdKey] as? String,
                scopeKind: note.userInfo?[MaughamEvent.scopeKindKey] as? String,
                scopeId: note.userInfo?[MaughamEvent.scopeIdKey] as? String))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    /// The same, for the presenter's arm — which hops through a `Task`, so the
    /// post lands after the call returns.
    private func announcementsSettling(
        expecting count: Int,
        during body: () async throws -> Void
    ) async rethrows -> [Announcement] {
        var seen: [Announcement] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamAnnotationsChanged, object: nil, queue: nil
        ) { note in
            seen.append(Announcement(
                docId: note.userInfo?[MaughamEvent.annotationDocIdKey] as? String,
                scopeKind: note.userInfo?[MaughamEvent.scopeKindKey] as? String,
                scopeId: note.userInfo?[MaughamEvent.scopeIdKey] as? String))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        // A bounded settle rather than a fixed sleep: the arm's work is a main-
        // actor `Task`, so it lands within a turn or two of the runloop. The
        // "expecting none" callers wait the whole deadline out on purpose.
        let deadline = Date().addingTimeInterval(2)
        while seen.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if count == 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
        return seen
    }

    // MARK: - Fixtures

    private func loadedDoc(
        _ prefix: String, md: String = "One.\n\nTwo.\n"
    ) async throws -> (dir: URL, doc: Document) {
        let (dir, docURL) = try makeTestProject(prefix: prefix, initialMd: md)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        return (dir, doc)
    }

    private func noteOn(_ doc: Document, kind: AnnotationKind = .comment) async throws -> String {
        let pid = try XCTUnwrap(doc.sequence.first)
        return try await doc.addAnnotation(
            kind: kind, paragraphId: pid, body: "a note",
            suggestedText: kind == .suggestedChange ? "Replaced." : nil)
    }

    // MARK: - Creation

    /// The first half of the contract: making a note says so, once, naming the
    /// document it landed in.
    func test_addingANoteAnnouncesItOnceAndNamesTheDocument() async throws {
        let (_, doc) = try await loadedDoc("AnnEvent-Add")

        let said = try await announcements { _ = try await self.noteOn(doc) }

        XCTAssertEqual(said.count, 1, "one note, one announcement")
        XCTAssertEqual(said.first?.docId, doc.docId,
                       "the announcement must name the document whose notes "
                       + "changed — a receiver holding several projects' worth "
                       + "of counts has nothing else to key on")
    }

    /// Project-scoped, like every other data event a `Document` posts
    /// (`maughamDocumentNotice`): a window on another project must not
    /// re-walk its own manuscript because this one gained a note, and a
    /// CLOSED window must not walk at all — the liveness guard the
    /// `.onProjectEvent` helper owns and `.allWindows` deliberately does not.
    func test_theAnnouncementCarriesTheProjectScope() async throws {
        let (dir, doc) = try await loadedDoc("AnnEvent-Scope")

        let said = try await announcements { _ = try await self.noteOn(doc) }
        let one = try XCTUnwrap(said.first)

        XCTAssertEqual(one.scopeKind, "project")
        XCTAssertEqual(one.scopeId, ProjectIdentifier.id(for: dir),
                       "the scope id is the project's identity, not a URL "
                       + "string and not the doc id")
    }

    /// The scope is not decoration: the filter every receive helper funnels
    /// through must DROP this announcement for a window on another project.
    func test_aWindowOnAnotherProjectDropsIt() async throws {
        let (dir, doc) = try await loadedDoc("AnnEvent-Drop")
        var received: Notification?
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamAnnotationsChanged, object: nil, queue: nil
        ) { received = $0 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await noteOn(doc)
        let note = try XCTUnwrap(received)

        XCTAssertTrue(MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
            kind: .project(id: ProjectIdentifier.id(for: dir)),
            isWindowLive: true, isWindowKey: false)),
                      "premise: a live window on this project takes it")
        XCTAssertFalse(MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
            kind: .project(id: "some-other-project"),
            isWindowLive: true, isWindowKey: false)),
                       "a window on another project must not re-walk its own "
                       + "manuscript because this one gained a note")
        XCTAssertFalse(MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
            kind: .project(id: ProjectIdentifier.id(for: dir)),
            isWindowLive: false, isWindowKey: false)),
                       "and a closed window walks nothing at all")
    }

    // MARK: - Every verb

    /// **Every resolution and every mark announces itself, exactly once.** The
    /// verbs reach the op log by three different routes — the lifecycle funnel,
    /// the annotation-op funnel and accept's own direct append — and a route
    /// that forgot to announce is a count that stays wrong until the writer
    /// reopens the project.
    func test_everyVerbAnnouncesExactlyOnce() async throws {
        let (_, doc) = try await loadedDoc("AnnEvent-Verbs")

        for (name, verb) in try await verbs(on: doc) {
            let said = try await announcements { try await verb() }
            XCTAssertEqual(said.count, 1,
                           "`\(name)` announced \(said.count) times, not once")
            XCTAssertEqual(said.first?.docId, doc.docId,
                           "`\(name)` announced the wrong document")
        }
    }

    /// One fresh annotation per verb, so no verb is refused for the state a
    /// previous one left the note in.
    private func verbs(
        on doc: Document
    ) async throws -> [(String, () async throws -> Void)] {
        let toReject = try await noteOn(doc)
        let toStet = try await noteOn(doc)
        let toArchive = try await noteOn(doc)
        let toTriage = try await noteOn(doc)
        let toEdit = try await noteOn(doc)
        let toWithdraw = try await noteOn(doc)
        let toReopen = try await noteOn(doc)
        try await doc.archiveAnnotation(id: toReopen)
        let toAccept = try await noteOn(doc, kind: .suggestedChange)

        return [
            ("addAnnotation", { _ = try await self.noteOn(doc) }),
            ("rejectAnnotation", { try await doc.rejectAnnotation(id: toReject) }),
            ("stetAnnotation", { try await doc.stetAnnotation(id: toStet) }),
            ("archiveAnnotation", { try await doc.archiveAnnotation(id: toArchive) }),
            ("triageAnnotation", { try await doc.triageAnnotation(id: toTriage, mark: .do) }),
            ("reopenAnnotation", { try await doc.reopenAnnotation(id: toReopen) }),
            ("editReviewerAnnotation", {
                try await doc.editReviewerAnnotation(
                    id: toEdit, newBody: "edited", newSuggestedText: nil,
                    authorName: "Denver")
            }),
            ("withdrawReviewerAnnotation", {
                try await doc.withdrawReviewerAnnotation(
                    id: toWithdraw, authorName: "Denver")
            }),
            ("acceptAnnotation", { try await doc.acceptAnnotation(id: toAccept) }),
            ("revertAcceptedAnnotation", {
                try await doc.revertAcceptedAnnotation(id: toAccept)
            }),
        ]
    }

    // MARK: - What must stay quiet

    /// **Typing announces nothing.** The event's readers walk every document in
    /// the project; hanging that off the keystroke path is the defect this task
    /// would be introducing rather than the one it is closing — which is why the
    /// post sites are the APPEND sites and not `invalidateAnnotationsCache`,
    /// whose callers include the burst flush.
    func test_typingAnnouncesNothing() async throws {
        let (_, doc) = try await loadedDoc("AnnEvent-Typing")

        let said = try await announcements {
            doc.setFullText("One.\n\nTwo, at greater length.\n")
            try await doc.flushBurstNow()
        }

        XCTAssertEqual(said, [],
                       "a typing burst announced an annotation change, so every "
                       + "open-notes count in the project re-walks the manuscript "
                       + "while the writer types")
    }

    /// The census behind it: the two hot invalidators must not be post sites.
    /// A behavioural test can only catch the paths it happens to drive; this
    /// catches the post being MOVED into the funnel that looks convenient.
    func test_theHotInvalidatorIsNotAPostSite() throws {
        let source = try Self.source(of: "OpLog/Document+Annotations.swift")
        let invalidate = try XCTUnwrap(
            Self.declaration(named: "internal func invalidateAnnotationsCache()",
                             in: source),
            "the invalidator is gone or renamed — this census is stale")

        XCTAssertFalse(invalidate.contains("announceAnnotationsChanged"),
                       "`invalidateAnnotationsCache` fires on keystroke-adjacent "
                       + "paths; announcing from it puts a project-wide walk on "
                       + "the typing path")
        XCTAssertTrue(source.contains("announceAnnotationsChanged"),
                      "premise: the file really does announce somewhere")
    }

    /// **Every local append site announces.** The verbs above drive the ones
    /// that exist today; this is the guard for the one added tomorrow, and it is
    /// a census over the file's own `opStore.append(` calls rather than a list
    /// of verb names that can silently fall behind (`AnnotationScopeTests`'
    /// refresh-token census, same shape and the same reason).
    func test_everyAppendSiteInTheFileAnnounces() throws {
        let source = try Self.source(of: "OpLog/Document+Annotations.swift")
        let appenders = [
            "public func addAnnotation(",
            "public func acceptAnnotation(",
            "public func revertAcceptedAnnotation(",
            "internal func appendAnnotationOpInternal(",
            "internal func appendLifecycleOp(",
        ]
        for header in appenders {
            let body = try XCTUnwrap(
                Self.declaration(named: header, in: source),
                "\(header) is gone or renamed — this census is stale and must "
                + "be updated deliberately")
            XCTAssertTrue(body.contains("announceAnnotationsChanged()"),
                          "\(header) appends an op and announces nothing, so "
                          + "every count drawn over this project stays wrong "
                          + "until it is reopened")
        }

        // And the list is checked against the file, so a sixth append site
        // cannot pass by omission.
        let appendLines = source.split(separator: "\n").map(String.init)
            .filter { $0.contains("opStore.append(") }
        XCTAssertFalse(appendLines.isEmpty,
                       "the scan found no append sites at all — it has stopped "
                       + "reading the file it is about")
        let covered = appenders.compactMap { Self.declaration(named: $0, in: source) }
        for line in appendLines {
            XCTAssertTrue(covered.contains { $0.contains(line) },
                          "an op append lives outside every member this census "
                          + "names: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// **The exemptions from the census above, named.** Both funnels announce
    /// by default; `announcing: false` exists for a caller that appends N ops
    /// for ONE writer-visible event and takes the announce on itself. Every
    /// such caller is the same shape: the deletion sweep (a burst of paragraph
    /// deletions orphaning a dozen notes), the compiler's mint (M4 P1 — one
    /// finished round writing a whole report's worth of questions and reports
    /// at once), the translator's query mint, and the pipeline's declined-note
    /// mint. **Count the array at the foot of this test, not this sentence.**
    ///
    /// The census would otherwise be satisfied by a funnel that CAN be silenced
    /// from anywhere: `if announcing { announce… }` still contains the literal
    /// the loop above looks for, so a further caller could quietly pass `false`
    /// and post nothing at all. This pins the exemptions to their sites and
    /// checks that each one really does pay the announce back.
    func test_theOnlySitesThatSuppressTheAnnounceBatchItInstead() throws {
        let source = try Self.source(of: "OpLog/Document+Annotations.swift")
        for header in ["internal func appendLifecycleOp(", "public func addAnnotation("] {
            let funnel = try XCTUnwrap(
                Self.declaration(named: header, in: source),
                "\(header) is gone or renamed — this census is stale")
            XCTAssertTrue(funnel.contains("announcing: Bool = true"),
                          "\(header): the suppression must DEFAULT to announcing "
                          + "— a funnel whose quiet form is the default announces "
                          + "nothing the day a caller forgets the argument")
            XCTAssertTrue(funnel.contains("if announcing { announceAnnotationsChanged() }"),
                          "\(header): the announce is no longer the guarded form "
                          + "this census is about")
        }

        let sweep = try XCTUnwrap(
            Self.declaration(named: "internal func sweepOrphanedAnnotations(", in: source),
            "the sweep is gone or renamed — this census is stale")
        // The CALL, not the word: the sweep's own comment says
        // `announcing: false` too, and a premise satisfied by a comment is no
        // premise at all (measured — flipping the argument to `true` left this
        // assertion green until it was pinned to the closing paren).
        XCTAssertTrue(sweep.contains("announcing: false)"),
                      "premise: the sweep is the batching caller")
        XCTAssertTrue(sweep.contains("announceAnnotationsChanged()"),
                      "the sweep suppresses the per-op announce and never pays "
                      + "it back, so a burst of deletions archives notes that "
                      + "no count outside this document hears about")

        // The second batching caller, on the same two halves.
        let mint = try Self.source(of: "Compiler/CompilerEnvironment+Project.swift")
        XCTAssertTrue(mint.contains("announcing: false)"),
                      "premise: the compiler's mint is the second batching "
                      + "caller — one round is one event")
        XCTAssertTrue(mint.contains("document.announceAnnotationsChanged()"),
                      "the mint suppresses the per-note announce and never pays "
                      + "it back, so a whole round of findings lands with no "
                      + "count outside this document hearing about it")

        // The third, and the same two halves again: a translation round's
        // questions are one act, however many it asked.
        let queries = try Self.source(of: "Compiler/TranslatorEnvironment+Project.swift")
        XCTAssertTrue(queries.contains("announcing: false)"),
                      "premise: the translator's query mint is the third "
                      + "batching caller — one round is one event")
        XCTAssertTrue(queries.contains("document.announceAnnotationsChanged()"),
                      "the translator's mint suppresses the per-query announce "
                      + "and never pays it back, so a round's questions land "
                      + "with no count outside this document hearing about it")

        // The fourth, same two halves: a translation ROUND's declined notes are
        // one act too — the pipeline mints a query per note the translator
        // refused, in one leg, on the writer's one ⌘-press.
        let declined = try Self.source(of: "Compiler/TranslationPipelineEnvironment+Project.swift")
        XCTAssertTrue(declined.contains("announcing: false)"),
                      "premise: the pipeline's declined-note mint is the fourth "
                      + "batching caller — one leg is one event")
        XCTAssertTrue(declined.contains("document.announceAnnotationsChanged()"),
                      "the declined mint suppresses the per-note announce and "
                      + "never pays it back, so a leg's refusals land with no "
                      + "count outside this document hearing about it")

        // Whole-tree: nobody else silences the funnels. A new batching caller
        // is welcome — it just has to arrive here, next to the reason.
        let tree = try Self.swiftSources(under: "Maugham")
        var suppressors: [String] = []
        for (path, text) in tree where text.contains("announcing: false") {
            suppressors.append(path)
        }
        XCTAssertEqual(suppressors,
                       ["Compiler/CompilerEnvironment+Project.swift",
                        "Compiler/TranslationPipelineEnvironment+Project.swift",
                        "Compiler/TranslatorEnvironment+Project.swift",
                        "OpLog/Document+Annotations.swift"],
                       "a production site outside the sweep and the three mints "
                       + "suppresses the annotation announce: \(suppressors)")
    }

    /// …and the behaviour the census stands in front of: **one deletion burst,
    /// one announcement**, however many notes it took with it. Every receiver
    /// walks the whole project, so three archives posting three times is three
    /// project walks for a single act of the writer's.
    func test_aSweepArchivingSeveralNotesAnnouncesExactlyOnce() async throws {
        let (_, doc) = try await loadedDoc(
            "AnnEvent-Sweep", md: "One.\n\nTwo.\n\nThree.\n\nFour.\n")
        // A note on each of the three paragraphs that are about to go.
        let doomed = Array(doc.sequence.prefix(3))
        XCTAssertEqual(doomed.count, 3, "premise: three paragraphs to orphan")
        for pid in doomed {
            _ = try await doc.addAnnotation(
                kind: .comment, paragraphId: pid, body: "a note")
        }

        let said = try await announcements {
            await doc.sweepOrphanedAnnotations(
                reason: SweepReason(removed: Set(doomed), cause: .paragraphDeleted))
        }

        XCTAssertEqual(said.count, 1,
                       "three notes archived by one deletion burst announced "
                       + "\(said.count) times — every receiver walks the whole "
                       + "project, so this is \(said.count) project walks for "
                       + "one act")
        XCTAssertEqual(said.first?.docId, doc.docId)
    }

    /// A sweep that archives NOTHING says nothing — the same rule
    /// `_sweptSinceLastReport` follows, and the control that keeps the test
    /// above from passing on an unconditional post.
    func test_aSweepThatArchivesNothingAnnouncesNothing() async throws {
        let (_, doc) = try await loadedDoc("AnnEvent-SweepEmpty")
        let pid = try XCTUnwrap(doc.sequence.first)
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "a note")

        let said = try await announcements {
            // A paragraph id no annotation is anchored to.
            await doc.sweepOrphanedAnnotations(
                reason: SweepReason(removed: ["zzzz"], cause: .paragraphDeleted))
        }

        XCTAssertEqual(said, [],
                       "a sweep that archived nothing announced a change")
    }

    // MARK: - The cross-device gap

    /// **A closed document's op log changed under us** — a peer device's note
    /// arriving through sync. No `Document` exists to notice it, which is
    /// precisely why this arm is the gap: before Task 9 the presenter resolved
    /// the doc, found nothing open, and returned.
    func test_aClosedDocsOpLogChangeIsAnnounced() async throws {
        let (dir, _) = try makeTestProject(
            prefix: "AnnEvent-Closed", initialMd: "One.\n")
        let ds = try await DocumentStore.open(url: dir)
        defer { Task { await ds.close() } }

        let said = try await announcementsSettling(expecting: 1) {
            ds.presenterDidChangeSubitem(
                at: dir.appendingPathComponent(".maugham/ops/doc-test.jsonl"))
        }

        XCTAssertEqual(said.count, 1)
        XCTAssertEqual(said.first?.docId, "doc-test")
        XCTAssertEqual(said.first?.scopeId, ProjectIdentifier.id(for: dir))
    }

    /// **An OPEN document's own write announces nothing from the presenter.**
    /// `NSFilePresenter` fires on our own appends — that is the echo
    /// `handleExternalLogChange` has guarded against since the op log shipped —
    /// so an unconditional post here would announce once per typing burst,
    /// which is the very thing `test_typingAnnouncesNothing` forbids one layer
    /// down. The open arm therefore routes through the merge, and the merge
    /// announces only what it actually merged.
    func test_anOpenDocsEchoOfItsOwnWriteAnnouncesNothing() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "AnnEvent-Echo", initialMd: "One.\n")
        let ds = try await DocumentStore.open(url: dir)
        defer { Task { await ds.close() } }
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: "manuscript/c1.md")

        let said = try await announcementsSettling(expecting: 0) {
            ds.presenterDidChangeSubitem(
                at: dir.appendingPathComponent(".maugham/ops/doc-test.jsonl"))
        }

        XCTAssertEqual(said, [],
                       "the presenter fires on our own writes; announcing them "
                       + "puts a project-wide walk on every typing burst")
    }

    /// The same guard, with the echo it is actually named for. The test above
    /// fires the presenter over a document that has written **nothing**, so it
    /// would pass against a merge path that simply found no new ops; this one
    /// makes the writer's own annotation op the thing being echoed back, which
    /// is the literal sequence in production — append, `NSFilePresenter` fires
    /// on our own write, the merge sees ops it already has.
    ///
    /// The append's own announcement is consumed first, so what the assertion
    /// sees is the echo alone rather than the write plus the echo.
    func test_anOpenDocsPresenterEchoOfARealAppendAnnouncesNothingFurther() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "AnnEvent-EchoReal", initialMd: "One.\n")
        let ds = try await DocumentStore.open(url: dir)
        defer { Task { await ds.close() } }
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: "manuscript/c1.md")

        let onTheWrite = try await announcements { _ = try await self.noteOn(doc) }
        XCTAssertEqual(onTheWrite.count, 1,
                       "premise: the append itself announced, exactly once")

        let echo = try await announcementsSettling(expecting: 0) {
            ds.presenterDidChangeSubitem(
                at: dir.appendingPathComponent(".maugham/ops/\(doc.docId).jsonl"))
        }

        XCTAssertEqual(echo, [],
                       "the presenter echoed the writer's own annotation op "
                       + "back and it was announced a second time — every "
                       + "receiver walks the whole project, so each of our own "
                       + "writes would cost two of those walks")
    }

    /// …and the other side of that guard: a FOREIGN annotation op merged into an
    /// open document is announced, because the surfaces that are not holding
    /// this document have no other way to hear about it.
    func test_aForeignAnnotationOpMergedIntoAnOpenDocIsAnnounced() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "AnnEvent-Merge", initialMd: "One.\n")
        let ds = try await DocumentStore.open(url: dir)
        defer { Task { await ds.close() } }
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: "manuscript/c1.md")
        let pid = try XCTUnwrap(doc.sequence.first)

        // A peer's comment, appended straight to the log the way sync delivers
        // it — never through this Document.
        let peer = Op(
            opId: "01ZZZZ", docId: doc.docId, at: Date(),
            device: "other-mac", session: "peer", kind: .claudeComment,
            changes: [.init(paragraphId: pid, prior: "One.", next: "")],
            provenance: Op.Provenance(sessionId: "peer", annotationBody: "peer note"))

        let said = try await announcementsSettling(expecting: 1) {
            try await OpLogStore(projectURL: dir).append(peer)
            ds.presenterDidChangeSubitem(
                at: dir.appendingPathComponent(".maugham/ops/doc-test.jsonl"))
        }

        XCTAssertEqual(said.count, 1,
                       "a peer's note reached an open document and no surface "
                       + "outside that document was told")
        XCTAssertEqual(said.first?.docId, doc.docId)
    }

    // MARK: - Source access

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    /// Every Swift file under a target directory, keyed by its path relative to
    /// that directory — so a census can say "nowhere else in the app" and mean
    /// it, rather than trusting a list of files someone remembered to extend.
    private static func swiftSources(under target: String) throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(target, isDirectory: true)
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(String, String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(
                of: root.path + "/", with: "")
            out.append((relative, text))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// A member declaration, from its opening line to the closing brace at
    /// member indentation — bounded, or a scan over it is a scan over the rest
    /// of the file (`AnnotationScopeTests`' own helper).
    private static func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }
}
