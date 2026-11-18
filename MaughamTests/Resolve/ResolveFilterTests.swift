import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 2, Task 3 — `ResolveFilter`: which source an item falls under,
/// the chips, density past twelve, the caret's group, and the keys' requests;
/// plus `ResolveRefreshKey` and `ResolveIncompleteness`. Pure: every item and
/// group is built by hand (or by `ResolveGrouping` once, as a refresh would).
///
/// Paragraph ids are 4-char from `ParagraphID`'s alphabet (tripwire 8).
final class ResolveFilterTests: XCTestCase {

    // MARK: - Builders

    private let t = Date(timeIntervalSince1970: 1_700_000_000)
    private let me = "Denver"

    private func note(_ id: String, on docId: String = "doc-a", pid: String? = nil,
                      author: AnnotationAuthor? = nil, language: String? = nil,
                      pass: String? = nil, runId: String? = nil, round: Int? = nil) -> ResolveItem {
        .note(ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: pid, body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false, author: author,
            language: language, reviewPassId: pass, compilerRunId: runId, compilerRound: round)))
    }

    private var mine: AnnotationAuthor { AnnotationAuthor(sourceKind: .human, displayName: me) }
    private var claude: AnnotationAuthor { AnnotationAuthor(sourceKind: .claude, displayName: "Claude") }
    private var friend: AnnotationAuthor { AnnotationAuthor(sourceKind: .human, displayName: "Ada") }

    private func todo(_ id: String, on docId: String = "doc-a", pid: String? = nil) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated,
                         anchor: TaskAnchor(docId: docId, paragraphId: pid),
                         body: id, status: .open, priority: 0, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    private func finding(_ id: String, on docId: String = "doc-a", pid: String? = nil) -> ResolveItem {
        .finding(docId: docId, Diagnostic(
            id: id, docId: docId,
            anchor: pid.map { .init(paragraphId: $0, anchorText: "x") },
            body: id, category: nil, runId: "run-1", kind: .conformanceStrain))
    }

    private let passes = [ReviewPass(id: "line", name: "Line edit"),
                          ReviewPass(id: "struct", name: "Structure")]

    private func source(_ item: ResolveItem) -> ResolveSource {
        ResolveFilter.source(of: item, localName: me)
    }

    /// `count` notes with no paragraph, all Others.
    private func others(_ count: Int) -> [ResolveItem] {
        (0..<count).map { note("o-\($0)", author: friend) }
    }

    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    /// A valid 4-char paragraph id for index `i` (tripwire 8).
    private func pid(_ i: Int) -> String {
        "aa" + String(Self.alphabet[(i / 32) % 32]) + String(Self.alphabet[i % 32])
    }

    private func group(_ key: ResolveGroup.Key, _ items: [ResolveItem] = []) -> ResolveGroup {
        ResolveGroup(key: key, title: "g", items: items.isEmpty ? [note("x")] : items)
    }

    // MARK: - Sources

    func test_everyItemHasExactlyOneSourceInTheTablesOrder() {
        // Questions beats everything: a language on a check-minted, own, passed note.
        XCTAssertEqual(source(note("q", author: mine, language: "es", pass: "line", runId: "r")),
                       .questions)
        // Checks beats Mine and the pass: a check-minted note (run id, no round).
        XCTAssertEqual(source(note("c", author: mine, pass: "line", runId: "r")), .checks)
        // A round's note (run id AND round) is not a check's: it falls to its pass.
        XCTAssertEqual(source(note("r", author: claude, pass: "line", runId: "r", round: 2)),
                       .pass("line"))
        // Mine beats the pass.
        XCTAssertEqual(source(note("m", author: mine, pass: "line")), .mine)
        XCTAssertEqual(source(note("p", author: friend, pass: "struct")), .pass("struct"))
        XCTAssertEqual(source(note("o", author: friend)), .others)
        XCTAssertEqual(source(note("o2", author: nil)), .others)
        // A strain is a check's; a to-do is the writer's own.
        XCTAssertEqual(source(finding("f")), .checks)
        XCTAssertEqual(source(todo("t")), .mine)
    }

    func test_aWritersOwnNoteDuringAPassIsMine() {
        XCTAssertEqual(source(note("m", author: mine, pass: "line")), .mine)
        // Not own by display name alone: Claude with the writer's name is not her.
        let impostor = AnnotationAuthor(sourceKind: .claude, displayName: me)
        XCTAssertEqual(source(note("i", author: impostor, pass: "line")), .pass("line"))
    }

    func test_aCheckMintedNoteIsAChecksItemNotAPassItem() {
        XCTAssertEqual(source(note("c", author: claude, pass: "line", runId: "run-9")), .checks)
        XCTAssertNotEqual(source(note("c", author: claude, pass: "line", runId: "run-9")),
                          .pass("line"))
    }

    func test_aTranslatorsQuestionIsAQuestion() {
        XCTAssertEqual(source(note("q", author: claude, language: "sr")), .questions)
        XCTAssertEqual(source(note("q2", author: friend, language: "es", pass: "line")), .questions)
    }

    // MARK: - Chips

    func test_chipsAreOnlySourcesWithItemsInTheColumnsOrder() {
        let items = [
            note("o", author: friend),
            todo("t"),
            note("q", language: "es"),
            note("p2", author: friend, pass: "struct"),
            finding("f"),
        ]
        // Passes in effectiveReviewPasses order (Line edit has no items: no chip),
        // then Mine, Checks, Questions, Others.
        XCTAssertEqual(ResolveFilter.chips(items, passes: passes, localName: me),
                       [.pass("struct"), .mine, .checks, .questions, .others])

        XCTAssertEqual(ResolveFilter.chips([note("p1", author: friend, pass: "line"),
                                            note("p2", author: friend, pass: "struct")],
                                           passes: passes, localName: me),
                       [.pass("line"), .pass("struct")])
        XCTAssertEqual(ResolveFilter.chips([], passes: passes, localName: me), [])

        // A pass the manifest no longer lists still gets a chip (after the
        // listed ones), so its notes are never unreachable behind a single choice.
        XCTAssertEqual(ResolveFilter.chips([note("g", author: friend, pass: "gone"),
                                            note("p1", author: friend, pass: "line")],
                                           passes: passes, localName: me),
                       [.pass("line"), .pass("gone"), ])
    }

    // MARK: - Density

    func test_twelveItemsAreNotDenseThirteenAre() {
        XCTAssertEqual(ResolveFilter.singleChoiceThreshold, 12)
        XCTAssertFalse(ResolveFilter.isDense(others(0)))
        XCTAssertFalse(ResolveFilter.isDense(others(12)))
        XCTAssertTrue(ResolveFilter.isDense(others(13)))
    }

    func test_aSmallListAllowsAnySubsetAndEmptyMeansAll() {
        let items = [todo("t"), finding("f"), note("o", author: friend)]
        let chips = ResolveFilter.chips(items, passes: passes, localName: me)
        XCTAssertEqual(chips, [.mine, .checks, .others])

        // Empty means everything.
        XCTAssertEqual(ResolveFilter.normalized([], chips: chips, dense: false), [])
        XCTAssertEqual(ResolveFilter.visible(items, selection: [], localName: me).map(\.id),
                       items.map(\.id))

        // Toggling builds any subset, and toggling back removes.
        var selection: Set<ResolveSource> = []
        selection = ResolveFilter.toggled(selection, .mine, dense: false)
        selection = ResolveFilter.toggled(selection, .others, dense: false)
        XCTAssertEqual(selection, [.mine, .others])
        XCTAssertEqual(ResolveFilter.normalized(selection, chips: chips, dense: false), [.mine, .others])
        XCTAssertEqual(ResolveFilter.visible(items, selection: selection, localName: me).map(\.id),
                       [todo("t").id, note("o").id])
        selection = ResolveFilter.toggled(selection, .mine, dense: false)
        XCTAssertEqual(selection, [.others])

        // A chip whose items have gone drops out of the selection.
        XCTAssertEqual(ResolveFilter.normalized([.questions, .checks], chips: chips, dense: false),
                       [.checks])
    }

    func test_aDenseListKeepsExactlyOneFilter() {
        let items = others(10) + [todo("t"), finding("f"), finding("g")]
        XCTAssertTrue(ResolveFilter.isDense(items))
        let chips = ResolveFilter.chips(items, passes: passes, localName: me)
        XCTAssertEqual(chips, [.mine, .checks, .others])

        // None selected: the first chip.
        XCTAssertEqual(ResolveFilter.normalized([], chips: chips, dense: true), [.mine])
        // Several selected (carried from a small list): the first in chip order.
        XCTAssertEqual(ResolveFilter.normalized([.others, .checks], chips: chips, dense: true),
                       [.checks])
        // A selected chip that has gone: the first chip.
        XCTAssertEqual(ResolveFilter.normalized([.questions], chips: chips, dense: true), [.mine])
        // No chips at all: nothing.
        XCTAssertEqual(ResolveFilter.normalized([.mine], chips: [], dense: true), [])

        // Toggling replaces; toggling the selected chip keeps it (never zero).
        XCTAssertEqual(ResolveFilter.toggled([.mine], .others, dense: true), [.others])
        XCTAssertEqual(ResolveFilter.toggled([.others], .others, dense: true), [.others])

        XCTAssertEqual(ResolveFilter.visible(items, selection: [.checks], localName: me).map(\.id),
                       [finding("f").id, finding("g").id])
    }

    // MARK: - Groups open

    func test_aSmallListOpensEveryGroup() {
        let groups = [group(.wholePiece(docId: "doc-a")),
                      group(.paragraph(docId: "doc-a", paragraphId: "aa11")),
                      group(.removed(docId: "doc-a"))]
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: nil, dense: false),
                       Set(groups.map(\.key)))
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: .removed(docId: "doc-a"), dense: false),
                       Set(groups.map(\.key)))
    }

    func test_aDenseListOpensOnlyTheCaretsGroup() {
        let caret = ResolveGroup.Key.paragraph(docId: "doc-a", paragraphId: "bb22")
        let groups = [group(.wholePiece(docId: "doc-a")),
                      group(.paragraph(docId: "doc-a", paragraphId: "aa11")),
                      group(caret)]
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: caret, dense: true), [caret])
    }

    /// Denver's ruling (supersedes the brief's "the first group"): with no
    /// caret group a dense list opens nothing, and the writer opens what she
    /// wants. Her own choices override the default, both ways.
    func test_aDenseListWithNoCaretOpensNoGroup() {
        let first = ResolveGroup.Key.wholePiece(docId: "doc-a")
        let second = ResolveGroup.Key.paragraph(docId: "doc-a", paragraphId: "aa11")
        let groups = [group(first), group(second)]
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: nil, dense: true), [])
        // A cursor key that names no group here (a paragraph with nothing raised).
        XCTAssertEqual(ResolveFilter.expanded(
            groups, cursor: .paragraph(docId: "doc-a", paragraphId: "zz99"), dense: true), [])

        // The writer's choices win over the default, dense or small.
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: nil, dense: true,
                                              choices: [second: true]), [second])
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: second, dense: true,
                                              choices: [second: false, first: true]), [first])
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: nil, dense: false,
                                              choices: [first: false]), [second])
        // A choice about a group that is not here opens nothing.
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: nil, dense: true,
                                              choices: [.removed(docId: "doc-a"): true]), [])
    }

    /// Review Focus 1: a piece with 300 open notes. One refresh builds the
    /// groups once; past twelve the filter is single-choice and only the
    /// caret's group is open; a caret move asks only the built groups.
    func test_threeHundredNotesCollapseToTheCaretsGroup() {
        let sequence = (0..<30).map(pid)
        let items: [ResolveItem] = (0..<300).map { i in
            note("n-\(i)", pid: sequence[i % 30],
                 author: i % 3 == 0 ? mine : friend, pass: i % 2 == 0 ? "line" : nil)
        }
        let read = ResolveSnapshot(items: items, sequences: ["doc-a": sequence],
                                   paragraphText: Dictionary(uniqueKeysWithValues: sequence.map { ($0, "text \($0)") }),
                                   unreadableDocIds: [])
        let groups = ResolveGrouping.groups(read, scope: .piece(docId: "doc-a", includesBookLevel: false),
                                            structure: [], sceneIndex: nil, sceneTitles: [],
                                            figureNames: [:])
        XCTAssertEqual(groups.count, 30)

        XCTAssertTrue(ResolveFilter.isDense(items))
        let chips = ResolveFilter.chips(items, passes: passes, localName: me)
        XCTAssertEqual(chips, [.pass("line"), .mine, .others])
        let selection = ResolveFilter.normalized([.mine, .others], chips: chips, dense: true)
        XCTAssertEqual(selection.count, 1)

        let caret = ResolveFilter.cursorGroup(paragraphId: sequence[17], docId: "doc-a",
                                              sceneIndex: nil, groups: groups)
        XCTAssertEqual(caret, .paragraph(docId: "doc-a", paragraphId: sequence[17]))
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: caret, dense: true), [caret!])

        // The caret moves: the same built groups answer, nothing is rebuilt.
        let moved = ResolveFilter.cursorGroup(paragraphId: sequence[3], docId: "doc-a",
                                              sceneIndex: nil, groups: groups)
        XCTAssertEqual(ResolveFilter.expanded(groups, cursor: moved, dense: true),
                       [.paragraph(docId: "doc-a", paragraphId: sequence[3])])
    }

    // MARK: - The caret

    func test_theCaretsParagraphNamesItsSceneInAScreenplay() {
        // aa11 before the first scene; bb22 (slugline) + cc33 scene 0; dd44 (slugline) + ee55 scene 1.
        let sceneIndex = ["bb22": 0, "cc33": 0, "dd44": 1, "ee55": 1]
        let groups = [group(.wholePiece(docId: "doc-a")),
                      group(.beforeFirstScene(docId: "doc-a")),
                      group(.scene(docId: "doc-a", headingParagraphId: "bb22")),
                      group(.scene(docId: "doc-a", headingParagraphId: "dd44")),
                      group(.removed(docId: "doc-a"))]
        func caret(_ pid: String?, doc: String = "doc-a") -> ResolveGroup.Key? {
            ResolveFilter.cursorGroup(paragraphId: pid, docId: doc, sceneIndex: sceneIndex, groups: groups)
        }
        XCTAssertEqual(caret("ee55"), .scene(docId: "doc-a", headingParagraphId: "dd44"))
        XCTAssertEqual(caret("dd44"), .scene(docId: "doc-a", headingParagraphId: "dd44"))
        XCTAssertEqual(caret("cc33"), .scene(docId: "doc-a", headingParagraphId: "bb22"))
        XCTAssertEqual(caret("aa11"), .beforeFirstScene(docId: "doc-a"))
        XCTAssertNil(caret(nil))
        // Another document's caret names nothing here.
        XCTAssertNil(caret("ee55", doc: "doc-b"))

        // A scene with nothing raised has no group: no caret group.
        let sparse = [group(.scene(docId: "doc-a", headingParagraphId: "bb22"))]
        XCTAssertNil(ResolveFilter.cursorGroup(paragraphId: "ee55", docId: "doc-a",
                                               sceneIndex: sceneIndex, groups: sparse))
    }

    func test_theCaretsParagraphNamesItsParagraphInProseAndNothingAtBookScope() {
        let groups = [group(.wholePiece(docId: "doc-a")),
                      group(.paragraph(docId: "doc-a", paragraphId: "aa11")),
                      group(.unplaced(docId: "doc-b"), [note("u", on: "doc-b", pid: "cc33")])]
        XCTAssertEqual(ResolveFilter.cursorGroup(paragraphId: "aa11", docId: "doc-a",
                                                 sceneIndex: nil, groups: groups),
                       .paragraph(docId: "doc-a", paragraphId: "aa11"))
        XCTAssertNil(ResolveFilter.cursorGroup(paragraphId: "bb22", docId: "doc-a",
                                               sceneIndex: nil, groups: groups))
        // A piece whose order did not read: the caret's paragraph is found in Position unknown.
        XCTAssertEqual(ResolveFilter.cursorGroup(paragraphId: "cc33", docId: "doc-b",
                                                 sceneIndex: nil, groups: groups),
                       .unplaced(docId: "doc-b"))
        // Book / Part scope: piece groups are never the caret's.
        let book = [group(.bookLevel), group(.piece(docId: "doc-a"), [note("p", pid: "aa11")])]
        XCTAssertNil(ResolveFilter.cursorGroup(paragraphId: "aa11", docId: "doc-a",
                                               sceneIndex: nil, groups: book))
    }

    /// Tripwire 4: per caret move only the caret function runs, and it is
    /// handed groups already built. The signature pins it (it takes groups,
    /// not a snapshot or a store); the census pins that this file never
    /// reaches for the walks, the reader, the grouping or the offsets.
    func test_theCaretFunctionTakesAlreadyBuiltGroups() throws {
        let built: [ResolveGroup] = [group(.paragraph(docId: "doc-a", paragraphId: "aa11"))]
        let answer: ResolveGroup.Key? = ResolveFilter.cursorGroup(
            paragraphId: "aa11", docId: "doc-a", sceneIndex: nil, groups: built)
        XCTAssertNotNil(answer)

        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = repo.appendingPathComponent("Maugham/Views/Resolve/ResolveFilter.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        for forbidden in ["ResolveReader", "ResolveGrouping", "ParagraphOffsets",
                          "listAnnotationsAcrossProject", "listTasksAcrossProject",
                          "Document", "ProjectStore", "sceneSummaries"] {
            let code = source.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }.joined(separator: "\n")
            XCTAssertFalse(code.contains(forbidden),
                           "ResolveFilter.swift must stay pure over built groups; it names \(forbidden)")
        }
    }

    // MARK: - The keys

    func test_eachKeyRequestSelectsItsSource() {
        let items = [note("p1", author: friend, pass: "line"),
                     note("p2", author: friend, pass: "struct"),
                     todo("t"), finding("f"), note("q", language: "es")]
        let chips = ResolveFilter.chips(items, passes: passes, localName: me)
        XCTAssertEqual(chips, [.pass("line"), .pass("struct"), .mine, .checks, .questions])

        // Small.
        XCTAssertEqual(ResolveFilter.selection(for: .rounds, chips: chips, activePassId: "struct", dense: false),
                       [.pass("line"), .pass("struct")])
        XCTAssertEqual(ResolveFilter.selection(for: .checks, chips: chips, activePassId: nil, dense: false),
                       [.checks])
        XCTAssertEqual(ResolveFilter.selection(for: .mine, chips: chips, activePassId: nil, dense: false),
                       [.mine])
        XCTAssertEqual(ResolveFilter.selection(for: .questions, chips: chips, activePassId: nil, dense: false),
                       [.questions])

        // Dense: the active pass's chip, else the first pass chip.
        XCTAssertEqual(ResolveFilter.selection(for: .rounds, chips: chips, activePassId: "struct", dense: true),
                       [.pass("struct")])
        XCTAssertEqual(ResolveFilter.selection(for: .rounds, chips: chips, activePassId: "gone", dense: true),
                       [.pass("line")])
        XCTAssertEqual(ResolveFilter.selection(for: .rounds, chips: chips, activePassId: nil, dense: true),
                       [.pass("line")])
        XCTAssertEqual(ResolveFilter.selection(for: .checks, chips: chips, activePassId: nil, dense: true),
                       [.checks])

    }

    /// A key whose chip is absent is inert: nil, and the view leaves the
    /// writer's selection as it was — small or dense, never the first chip.
    func test_aKeyWhoseChipIsAbsentIsInert() {
        let noChecks: [ResolveSource] = [.mine, .others]
        for dense in [false, true] {
            XCTAssertNil(ResolveFilter.selection(for: .checks, chips: noChecks, activePassId: nil, dense: dense))
            XCTAssertNil(ResolveFilter.selection(for: .questions, chips: noChecks, activePassId: nil, dense: dense))
            XCTAssertNil(ResolveFilter.selection(for: .rounds, chips: noChecks, activePassId: "line", dense: dense))
            XCTAssertEqual(ResolveFilter.selection(for: .mine, chips: noChecks, activePassId: nil, dense: dense),
                           [.mine])
        }
        XCTAssertFalse(ResolveFilter.canRequest(.checks, chips: noChecks))
        XCTAssertFalse(ResolveFilter.canRequest(.rounds, chips: noChecks))
        XCTAssertTrue(ResolveFilter.canRequest(.mine, chips: noChecks))
        XCTAssertTrue(ResolveFilter.canRequest(.rounds, chips: [.pass("line"), .mine]))
        XCTAssertFalse(ResolveFilter.canRequest(.mine, chips: []))
    }

    func test_unreadChecksClearOnlyWhenChecksAreShown() {
        XCTAssertTrue(ResolveFilter.clearsUnreadChecks(selection: []))
        XCTAssertTrue(ResolveFilter.clearsUnreadChecks(selection: [.checks]))
        XCTAssertTrue(ResolveFilter.clearsUnreadChecks(selection: [.mine, .checks]))
        XCTAssertFalse(ResolveFilter.clearsUnreadChecks(selection: [.mine]))
        XCTAssertFalse(ResolveFilter.clearsUnreadChecks(selection: [.pass("line"), .questions]))
    }

    // MARK: - Incomplete

    /// Carried from review: the board shows "unknown" for a piece whose notes
    /// would not read; the list beside it must never look complete.
    func test_anUnreadablePieceSaysTheListMayBeIncompleteAndNamesIt() throws {
        let structure = [
            StructureItem(id: "doc-a", title: "Arrival", type: .document, path: "manuscript/a.md"),
            StructureItem(id: "doc-b", title: "Breakfast", type: .document, path: "manuscript/b.md"),
        ]
        let complete = ResolveSnapshot(items: [note("n")], sequences: [:], paragraphText: [:],
                                       unreadableDocIds: [])
        XCTAssertNil(ResolveIncompleteness.of(complete, structure: structure, figureNames: [:]))

        let partial = ResolveSnapshot(items: [note("n")], sequences: [:], paragraphText: [:],
                                      unreadableDocIds: ["doc-b", "fig-0a1b", "doc-zz"])
        let warning = try XCTUnwrap(ResolveIncompleteness.of(
            partial, structure: structure, figureNames: ["fig-0a1b": "Table 3"]))
        XCTAssertEqual(warning.docIds, ["doc-b", "fig-0a1b", "doc-zz"])
        XCTAssertEqual(warning.names, ["Breakfast", "Table 3", "Untitled"])
        XCTAssertEqual(warning.message,
                       "This list may be incomplete: Breakfast, Table 3 and Untitled could not be read.")

        let one = ResolveSnapshot(items: [], sequences: [:], paragraphText: [:], unreadableDocIds: ["doc-a"])
        XCTAssertEqual(ResolveIncompleteness.of(one, structure: structure, figureNames: [:])?.message,
                       "This list may be incomplete: Arrival could not be read.")
    }

    // MARK: - The read key and the regroup key

    private func readKey(scope: ResolveScope = .piece(docId: "doc-a", includesBookLevel: true),
                         token: Int = 1, open: [(annotations: Int, tasks: Int)] = [(4, 2), (1, 9)],
                         project: Int = 3, diagnostics: Int = 7,
                         passes: [ReviewPass]? = nil, localName: String = "Denver") -> ResolveReadKey {
        ResolveReadKey(scope: scope, annotationsToken: token, openVersions: open,
                       projectTasksVersion: project, diagnosticsVersion: diagnostics,
                       passes: passes ?? self.passes, localName: localName)
    }

    func test_theReadKeyChangesWithEverySnapshotInput() {
        let base = readKey()
        XCTAssertEqual(base, readKey())
        let changes: [(String, ResolveReadKey)] = [
            ("scope", readKey(scope: .piece(docId: "doc-a", includesBookLevel: false))),
            ("annotations event", readKey(token: 2)),
            // A note added in ANY open document, faces' piece or not.
            ("an open document's notes", readKey(open: [(4, 2), (2, 9)])),
            // A to-do typed in an open piece moves a Book or Part list's key
            // (typing a to-do posts no event).
            ("an open document's to-dos", readKey(open: [(4, 3), (1, 9)])),
            ("a document opened", readKey(open: [(4, 2), (1, 9), (1, 1)])),
            ("the Book's own to-dos", readKey(project: 4)),
            ("the diagnostics", readKey(diagnostics: 8)),
            ("a pass added", readKey(passes: passes + [ReviewPass(id: "copy", name: "Copy edit")])),
            ("the passes reordered", readKey(passes: Array(passes.reversed()))),
            ("a pass renamed", readKey(passes: [ReviewPass(id: "line", name: "Lines"), passes[1]])),
            ("the local name", readKey(localName: "Ada")),
        ]
        for (what, changed) in changes {
            XCTAssertNotEqual(base, changed, "\(what) must move the read key")
        }
        // The sums are what count: the same versions spread differently do not move it.
        XCTAssertEqual(readKey(open: [(4, 2), (1, 9)]), readKey(open: [(1, 9), (4, 2)]))
    }

    /// Controller ruling: a new screenplay parse regroups (and re-reads the
    /// open piece's paragraph state) but never re-runs the project walks.
    func test_aScriptOnlyChangeMovesTheRegroupKeyAndNotTheReadKey() {
        let sluglines = FountainTokenizer().parse("INT. KITCHEN - DAY\n\nShe waits.\n\nEXT. YARD - NIGHT\n\nRain.")
        let edited = FountainTokenizer().parse("INT. KITCHEN - DAY\n\nShe waits.\n\nINT. HALL - NIGHT\n\nRain.")
        XCTAssertNotEqual(sluglines, edited)

        let before = ResolveRegroupKey(read: readKey(), script: sluglines)
        let after = ResolveRegroupKey(read: readKey(), script: edited)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.read, after.read)
        XCTAssertNotEqual(before, ResolveRegroupKey(read: readKey(), script: nil))

        // A read input moves both.
        let reread = ResolveRegroupKey(read: readKey(token: 2), script: sluglines)
        XCTAssertNotEqual(before, reread)
        XCTAssertNotEqual(before.read, reread.read)
    }

    /// The re-read on a script change keeps every held item and replaces only
    /// the piece's sequence and text; a piece that will not read is named.
    func test_rereadingKeepsTheHeldItemsAndReplacesOnlyThePiecesText() {
        let held = ResolveSnapshot(items: [note("n", pid: "aa11"), todo("t", pid: "bb22")],
                                   sequences: ["doc-a": ["aa11", "bb22"]],
                                   paragraphText: ["aa11": "INT. OLD", "bb22": "Rain."],
                                   unreadableDocIds: [])
        let fresh = ResolveReader.rereading(held, docId: "doc-a", sequence: ["cc33", "aa11", "bb22"],
                                            paragraphs: ["cc33": "INT. NEW", "aa11": "INT. OLD", "bb22": "Rain."])
        XCTAssertEqual(fresh.items, held.items)
        XCTAssertEqual(fresh.sequences["doc-a"], ["cc33", "aa11", "bb22"])
        XCTAssertEqual(fresh.paragraphText["cc33"], "INT. NEW")
        XCTAssertEqual(fresh.unreadableDocIds, [])

        let failed = ResolveReader.rereading(held, docId: "doc-a", sequence: nil, paragraphs: [:])
        XCTAssertEqual(failed.items, held.items)
        XCTAssertEqual(failed.sequences, held.sequences)
        XCTAssertEqual(failed.paragraphText, [:])
        XCTAssertEqual(failed.unreadableDocIds, ["doc-a"])
        XCTAssertEqual(ResolveReader.rereading(failed, docId: "doc-a", sequence: nil, paragraphs: [:])
                        .unreadableDocIds, ["doc-a"])
    }
}
