import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 3, Task 6 — answering moves an item across: each verb that
/// files what the writer decided says where it went (`FiledUnder`,
/// `FiledNotice`), from the destination the write itself returned.
@MainActor
final class FiledUnderTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func loadedNovel(named name: String) async throws -> (URL, ProjectStore, StructureItem) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let chapter = try XCTUnwrap(store.manifest.structure.first, "the novel fixture has no chapter")
        return (url, store, chapter)
    }

    private func strain(on docId: String, quote: String = "Kelly never lies.") -> Diagnostic {
        Diagnostic(id: ULID.generate(), docId: docId, anchor: nil, body: "pulls",
                   category: nil, runId: ULID.generate(), kind: .conformanceStrain,
                   refs: [], clauseQuote: quote)
    }

    private let structure: [StructureItem] = [
        StructureItem(id: "doc-a", title: "Arrival", type: .document, path: "manuscript/a.md"),
        StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "doc-b", title: "Breakfast", type: .document, path: "manuscript/b.md"),
        ]),
    ]

    private func sentence(_ destination: FiledDestination, faces: BinderSubject,
                          projectType: ProjectType = .novel, reader: String? = nil) -> String {
        FiledUnder.sentence(destination, faces: faces, structure: structure,
                            projectType: projectType, firstReaderName: reader)
    }

    // MARK: - The sentence, from the write that happened

    /// A finding's Answer files under the piece's intent, and from that
    /// piece's own list the line says "Filed in Brief" (Task 6a).
    func test_aFindingsAnswerSaysItFiledInBrief() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "FiledThisChapter")
        let diagnostics = DiagnosticsStore(projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let finding = strain(on: chapter.id)
        var filed: [FiledDestination] = []
        let failure = await CheckNarrative.commitAnswer(
            "It is deliberate.", to: finding, docId: chapter.id, store: store, world: nil,
            diagnostics: diagnostics, filedUnder: { filed.append($0) })
        XCTAssertNil(failure)
        XCTAssertEqual(filed, [FiledDestination(kind: .intent, scope: .document(chapter.id))],
                       "the destination is the statement the ruling was written to, said once")
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .document(chapter.id)))
        XCTAssertEqual(filed.first, FiledDestination(kind: statement.kind, scope: statement.scope))
        XCTAssertEqual(
            FiledUnder.filing(try XCTUnwrap(filed.first), faces: .item(chapter.id), store: store).sentence,
            FiledUnder.inBrief)
        XCTAssertEqual(FiledUnder.inBrief, "Filed in Brief")
        XCTAssertEqual(
            FiledUnder.filing(try XCTUnwrap(filed.first), faces: .item(chapter.id), store: store).brief,
            .item(chapter.id), "the line shows Brief for the piece it was filed on")
    }

    /// The same answer pressed from the Book's list names the piece.
    func test_answeringFromTheBookNamesThePiece() {
        let destination = FiledDestination(kind: .intent, scope: .document("doc-b"))
        XCTAssertEqual(sentence(destination, faces: .project),
                       "Filed in \u{201C}Breakfast\u{201D}'s Brief")
        XCTAssertEqual(sentence(destination, faces: .item("part-1")),
                       "Filed in \u{201C}Breakfast\u{201D}'s Brief", "a Part names its piece too")
        XCTAssertEqual(sentence(destination, faces: .item("doc-a")),
                       "Filed in \u{201C}Breakfast\u{201D}'s Brief", "another piece is named")
        XCTAssertEqual(sentence(destination, faces: .item("doc-b")), "Filed in Brief")
        // **Review M3.** A piece the structure no longer names is never
        // "“chapter”'s Brief".
        XCTAssertEqual(sentence(FiledDestination(kind: .intent, scope: .document("doc-gone")), faces: .project),
                       "Filed in Brief")
        // Already standing says so, in the same family.
        XCTAssertEqual(sentence(FiledDestination(kind: .intent, scope: .document("doc-b"), alreadyStood: true),
                                faces: .item("doc-b")), "Already in Brief")
    }

    /// Every kind the verbs file to has its sentence; none carries the
    /// check's words.
    func test_eachDestinationHasItsSentence() {
        let faces = BinderSubject.item("doc-a")
        XCTAssertEqual(sentence(FiledDestination(kind: .intent, scope: .project), faces: faces),
                       "Filed in the Book's Brief")
        XCTAssertEqual(sentence(FiledDestination(kind: .intent, scope: .project), faces: .project),
                       "Filed in Brief", "from the Book's own list")
        XCTAssertEqual(sentence(FiledDestination(kind: .lessons, scope: .project), faces: faces),
                       "Filed under What I've Learned")
        XCTAssertEqual(sentence(FiledDestination(kind: .firstReader, scope: .project), faces: faces,
                                reader: "Maud"),
                       "Filed under Maud's instructions")
        XCTAssertEqual(sentence(FiledDestination(kind: .firstReader, scope: .project), faces: faces),
                       "Filed under First Reader")
        XCTAssertEqual(sentence(FiledDestination(kind: .firstReader, scope: .project), faces: faces,
                                reader: "  "),
                       "Filed under First Reader", "a blank name is no name")
        XCTAssertEqual(sentence(FiledDestination(kind: .editionBrief("es"), scope: .project), faces: faces),
                       "Filed under the "
                       + TranslationReviewIndicator.displayLabel(forLanguageTag: "es")
                       + " edition brief",
                       "the language as QueryRuling.confirmation spells it")
        XCTAssertTrue(QueryRuling.confirmation(language: "es")
            .contains(TranslationReviewIndicator.displayLabel(forLanguageTag: "es") + " edition brief"))
        // Where each line's click would take the faces (Task 9 wires it).
        XCTAssertEqual(FiledUnder.brief(of: FiledDestination(kind: .intent, scope: .document("doc-b"))),
                       .item("doc-b"))
        XCTAssertEqual(FiledUnder.brief(of: FiledDestination(kind: .intent, scope: .project)), .project)
        XCTAssertEqual(FiledUnder.brief(of: FiledDestination(kind: .lessons, scope: .project)), .project)
        XCTAssertEqual(FiledUnder.brief(of: FiledDestination(kind: .editionBrief("es"), scope: .project)),
                       .edition(language: "es"))
    }

    /// A screenplay's piece is its script, and its Book is that script.
    func test_aScreenplaySaysScript() {
        let script: [StructureItem] = [
            StructureItem(id: "doc-s", title: "The Film", type: .document, path: "manuscript/film.fountain"),
        ]
        let destination = FiledDestination(kind: .intent, scope: .document("doc-s"))
        XCTAssertEqual(FiledUnder.sentence(destination, faces: .project, structure: script,
                                           projectType: .screenplay, firstReaderName: nil),
                       "Filed in Brief", "a screenplay's Book is its script, so its Brief is the faces'")
        XCTAssertEqual(FiledUnder.sentence(destination, faces: .item("doc-s"), structure: script,
                                           projectType: .screenplay, firstReaderName: nil),
                       "Filed in Brief")
        XCTAssertEqual(FiledUnder.sentence(FiledDestination(kind: .intent, scope: .document("doc-a")),
                                           faces: .item("doc-a"), structure: structure,
                                           projectType: .collection, firstReaderName: nil),
                       "Filed in Brief")
    }

    // MARK: - The line's life

    /// The line is the writer's act, not the row's: a change of the list
    /// (the row the next read removes) leaves it; only its own linger, or
    /// the next filing, ends it.
    func test_theNoticeOutlivesTheRow() {
        let first = FiledNotice.Filing(sentence: "Filed under the book's intent", brief: .project)
        var line = FiledNotice.after(.filed(first), current: nil)
        XCTAssertEqual(line, first)
        line = FiledNotice.after(.listChanged, current: line)
        XCTAssertEqual(line, first, "the row leaving the list does not take the line with it")
        let second = FiledNotice.Filing(sentence: "Filed under What I've Learned", brief: .project)
        line = FiledNotice.after(.filed(second), current: line)
        XCTAssertEqual(line, second, "the next filing replaces it")
        line = FiledNotice.after(.lingered(first.id), current: line)
        XCTAssertEqual(line, second, "the first line's linger does not end the second")
        line = FiledNotice.after(.lingered(second.id), current: line)
        XCTAssertNil(line, "its own linger ends it")
        XCTAssertEqual(FiledUnder.lingers, .seconds(6))
    }

    /// **To resolve's line stands until the writer's next act in the list**
    /// (Task 6a), never on a timer: a press that began over the line ends
    /// it; a press that itself filed (the line replaced mid-press) keeps the
    /// new one; a press with no line standing changes nothing.
    func test_toResolvesLineEndsAtTheNextActInTheList() throws {
        let first = FiledNotice.Filing(sentence: FiledUnder.inBrief, brief: .item("doc-a"))
        XCTAssertNil(FiledNotice.after(.listPressed(over: first.id), current: first),
                     "the next press in the list ends the line")
        let second = FiledNotice.Filing(sentence: "Filed under What I've Learned", brief: .project)
        XCTAssertEqual(FiledNotice.after(.listPressed(over: first.id), current: second), second,
                       "a press that filed keeps the line it made")
        XCTAssertEqual(FiledNotice.after(.listPressed(over: nil), current: second), second,
                       "a press that began with no line ends nothing")
        XCTAssertNil(FiledNotice.after(.listPressed(over: nil), current: nil))

        // Wired: To resolve's line does not linger, and the list's presses
        // end it — simultaneously, so every control still takes its press.
        let pane = Self.flattened(try Self.source(of: "Views/Resolve/ResolvePane.swift"))
        XCTAssertTrue(pane.contains("FiledNotice(filing: $filedNotice, onOpenBrief: onOpenBrief, lingers: false)"))
        XCTAssertTrue(pane.contains(".simultaneousGesture(DragGesture(minimumDistance: 0)"))
        XCTAssertTrue(pane.contains(".listPressed(over: filedLineAtPress ?? nil), current: filedNotice)"))
        let notice = Self.flattened(try Self.source(of: "Views/Brief/FiledUnder.swift"))
        XCTAssertTrue(notice.contains("guard lingers else { return }"), "no timer where it does not linger")
    }

    /// **The line's button shows Brief and does nothing else** (Task 6a):
    /// its action is `onOpenBrief(brief)`, and the window's `openBrief`
    /// writes the faces, the column's visibility and its position — no
    /// statement, no list, no other state.
    func test_theFiledLinesButtonOnlyShowsBrief() throws {
        let notice = Self.flattened(try Self.source(of: "Views/Brief/FiledUnder.swift"))
        let actions = notice.components(separatedBy: "Button {").dropFirst()
            .map { String($0.prefix(while: { $0 != "}" })) }
        XCTAssertEqual(actions.map { $0.trimmingCharacters(in: .whitespaces) }, ["onOpenBrief(brief)"],
                       "the line's one button")
        let window = Self.flattened(try Self.source(of: "Views/ProjectWindow.swift"))
        let body = try XCTUnwrap(Self.body(of: "func openBrief(", in: window))
        let statements = body.dropFirst("func openBrief(_ target: BinderSubject) {".count).dropLast()
            .trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(statements,
                       "let next = Self.facesForABrief(target, subject: subject) if next != subject { subject = next } "
                       + "showInspector = true rightColumnPosition = .brief",
                       "openBrief moves the faces and shows Brief, and writes nothing else")
        // To resolve's line is wired to it.
        let column = Self.flattened(try Self.source(of: "Views/RightColumn.swift"))
        XCTAssertTrue(column.contains("onOpenBrief: openBrief,"))
    }

    // MARK: - Every filing verb says where it filed

    /// One `file → function → what it must contain` row per verb that files
    /// what the writer decided. Each success path takes its destination from
    /// the write (`RulingPerformer.rule`, or the ledger verb that wraps it)
    /// and hands THAT value to its caller.
    static let filingVerbs: [(file: String, function: String, mustContain: [String])] = [
        ("Views/Resolve/CheckNarrativeVerbs.swift", "static func commitAnswer(",
         ["destination = try await RulingPerformer.rule(", "filedUnder(destination)"]),
        ("Views/QueryRuling.swift", "static func commit(",
         ["destination = try await RulingPerformer.rule(", "filedUnder(destination)"]),
        ("Views/FirstReaderRuling.swift", "static func commit(",
         ["destination = try await RulingPerformer.rule(", "filedUnder(destination)"]),
        ("Views/QueueLedgerVerbs.swift", "static func makeChoice(",
         ["destination = try await LessonLedgerVerbs.makeChoice(", "filedUnder(destination)"]),
        ("Views/QueueLedgerVerbs.swift", "static func keepAsLesson(",
         ["filedUnder(try await LessonLedgerVerbs.keepAsLesson("]),
        ("Views/TurnClauseOffer.swift", "static func handler(",
         ["let filed = try await RulingPerformer.rule(", "filedUnder(filed)"]),
        ("Views/LessonLedgerVerbs.swift", "static func handlers(",
         ["let destination = try await write()", "if let destination { filedUnder(destination) }",
          "return try await LessonLedgerVerbs.keepAsLesson(",
          "return try await LessonLedgerVerbs.makeChoices("]),
        ("Views/Publish/TranslationRoundActions.swift", "actions.makeRule = {",
         ["destination = try await RulingPerformer.rule(", "FiledUnder.sentence(destination,"]),
        ("Views/BibleStratum.swift", "private static func graduate(",
         ["destination = try await RulingPerformer.rule(", "return destination"]),
    ]

    /// And each host hands the destination on to its line.
    static let hosts: [(file: String, mustContain: [String])] = [
        ("Views/Resolve/ResolvePane.swift",
         ["diagnostics: diagnostics, filedUnder: { filed($0) })",
          "onFiledUnder: { filed($0) })",
          "FiledNotice(filing: $filedNotice, onOpenBrief: onOpenBrief, lingers: false)"]),
        ("Views/Resolve/ResolveNoteVerbs.swift",
         ["undoManager: undoManager, filedUnder: onFiledUnder)",
          "filedUnder: onFiledUnder)"]),
        ("Views/Resolve/ResolveHead.swift",
         ["onFailure: { ledgerFailure = $0 }, filedUnder: onFiledUnder)",
          "onFailure: { offerFailure = $0 }, filedUnder: onFiledUnder)"]),
        ("Views/BibleStratum.swift", ["onFiled(filed)"]),
        ("Views/Brief/BriefPieceView.swift", ["onFiled: { destination in",
                                              "FiledNotice(filing: $filedNotice, onOpenBrief: onOpenBrief)"]),
        ("Views/Brief/BriefBookView.swift", ["FiledNotice(filing: $filedNotice, onOpenBrief: onOpenBrief)"]),
        // Shell p4 Task 6: To resolve's call also hands the publish centre on.
        ("Views/RightColumn.swift", ["onOpenBrief: openBrief,", "publishCentre: publishCentre)"]),
        ("Views/Resolve/ResolvePane.swift", ["onFiled: { filed($0) })"]),
        ("Views/Publish/TranslationRoundReportView.swift",
         ["run(settling: id, filedIn: ruleSection(of: id))",
          "FiledNotice(filing: $filedNotice, onOpenBrief: onOpenBrief)"]),
        ("Views/Publish/TranslationRoundReportHost.swift", ["onOpenBrief: onOpenBrief)"]),
        ("Views/CentreColumn.swift", ["onOpenBrief: openBrief)"]),
    ]

    func test_everyFilingVerbReportsWhereItFiled() throws {
        var failures: [String] = []
        for verb in Self.filingVerbs {
            let source = Self.flattened(try Self.source(of: verb.file))
            guard let body = Self.body(of: verb.function, in: source) else {
                failures.append("\(verb.file): \(verb.function) is gone")
                continue
            }
            for needle in verb.mustContain where !body.contains(needle) {
                failures.append("\(verb.file) \(verb.function) lacks `\(needle)`")
            }
        }
        for host in Self.hosts {
            let source = Self.flattened(try Self.source(of: host.file))
            for needle in host.mustContain where !source.contains(needle) {
                failures.append("\(host.file) lacks `\(needle)`")
            }
        }
        XCTAssertEqual(failures, [])

        // The census reads what it claims to: a function that drops its
        // report is caught.
        let planted = Self.flattened("""
            static func commitAnswer(x: Int) async -> String? {
                do {
                    destination = try await RulingPerformer.rule(x)
                } catch { return nil }
                return nil
            }
            """)
        let body = try XCTUnwrap(Self.body(of: "static func commitAnswer(", in: planted))
        XCTAssertFalse(body.contains("filedUnder(destination)"), "the planted offender must be caught")
    }

    /// The Keep as lesson verb hands back the ledger, and the ledger's
    /// line names it — including a heading that already stood there.
    func test_keepAsLessonSaysWhatIveLearned() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "FiledLesson")
        let note = Annotation(
            id: "n1", kind: .comment, paragraphId: nil, body: "Too many adverbs.",
            suggestedText: nil, priorText: nil, createdAt: Date(), createdBySession: nil,
            status: .accepted, userResponse: nil, resolvedAt: nil, isStale: false)
        var filed: [FiledDestination] = []
        for _ in 0..<2 {
            let refusal = await QueueLedgerVerbs.keepAsLesson(
                "Cut the adverbs.", from: note, store: store, world: nil,
                filedUnder: { filed.append($0) })
            XCTAssertNil(refusal)
        }
        XCTAssertEqual(filed, [FiledDestination(kind: .lessons, scope: .project),
                               FiledDestination(kind: .lessons, scope: .project, alreadyStood: true)],
                       "the second press found the heading standing and wrote nothing")
        XCTAssertEqual(FiledUnder.filing(filed[0], faces: .item(chapter.id), store: store).sentence,
                       "Filed under What I've Learned")
        // **Review M2.** Derived from the write's own answer.
        XCTAssertEqual(FiledUnder.filing(filed[1], faces: .item(chapter.id), store: store).sentence,
                       "Already in What I've Learned")
    }

    // MARK: - Source helpers

    static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Brief/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Comment lines dropped, whitespace runs collapsed — so a census needle
    /// matches across line breaks and never matches a comment.
    static func flattened(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
    }

    /// The text from `signature` to the brace that closes it.
    static func body(of signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        // Braces count only outside parentheses: a defaulted closure in the
        // parameter list (`= { _ in }`) is not the body.
        var depth = 0, parens = 0
        var opened = false
        var index = source.index(start.lowerBound, offsetBy: signature.count - 1)
        if signature.hasSuffix("(") { parens = 1; index = source.index(after: index) }
        while index < source.endIndex {
            let c = source[index]
            if c == "(" { parens += 1 }
            if c == ")" { parens -= 1 }
            if parens == 0 {
                if c == "{" { depth += 1; opened = true }
                if c == "}" {
                    depth -= 1
                    if opened && depth == 0 { return String(source[start.lowerBound...index]) }
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
