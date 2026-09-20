import Foundation
import XCTest
@testable import MaughamCore

/// **The ladder of spec §2, written out by hand and read against the code**
/// (P3a Task 4).
///
/// Everything here is a pure value in and a verdict out: no disk, no keys, no
/// registry. `TrustTable` has already decided whose key signed a line and which
/// of that device's four actors it was; this asks only what that person, on that
/// key, may put in that stream.
///
/// **The grid below is the specification, not a transcript of the
/// implementation.** It was written from §2's three rows and its narrowing
/// paragraph before the switch was read back, and it is a literal: a reviewer
/// checking this milestone reads the grid against the spec and the assertions
/// take care of themselves. That is deliberate — a table-driven test whose
/// expectations are computed the way the subject computes them proves only that
/// the subject is self-consistent.
final class PermitTableTests: XCTestCase {

    // MARK: - The axes

    /// One piece of hers, one of somebody else's, and everything a stream can
    /// be — so that *inside her pieces* and *everywhere else* are two columns
    /// of the same row rather than two tests.
    private static let hers = "p-hers"
    private static let theirs = "p-theirs"

    /// **Ten streams.** The seven `DocumentClass` cases, with the three that
    /// carry a piece id appearing twice: once about her piece, once about
    /// somebody's.
    private let classes: [DocumentClass] = [
        .piece(PermitTableTests.hers),                      // 0
        .piece(PermitTableTests.theirs),                    // 1
        .pieceStatement(piece: PermitTableTests.hers),      // 2
        .pieceStatement(piece: PermitTableTests.theirs),    // 3
        .projectStatement,                                  // 4
        .projectStream,                                     // 5
        .translation(piece: PermitTableTests.hers),         // 6
        .translation(piece: PermitTableTests.theirs),       // 7
        .inbox,                                             // 8
        .unplaceable("st_unreadableScope")                  // 9
    ]

    /// The one stream whose PLACEMENT is unknown — the row every other row is
    /// read against.
    private let unplaceableIndex = 9

    /// The placements an `.unplaceable` statement could turn out to have: every
    /// other row of the grid. A cell is answered here only if it is the same in
    /// all of them.
    private var placements: [Int] { Array(0..<unplaceableIndex) }

    /// **Four permits**, in the order of the grid's four columns.
    private let permits: [Permit] = [
        .reviewer,                                  // r
        .author(.pieces([PermitTableTests.hers])),  // s — an author of some pieces
        .author(.book),                             // b
        .unjudgeable(raw: "curator")                // ? — a later build's word
    ]

    private let reviewerColumn = 0
    private let unjudgeableColumn = 3

    // MARK: - The grid

    /// One character per verdict, so a row fits on a line and the shape of the
    /// ladder is visible at a glance.
    ///
    /// | char | verdict |
    /// |---|---|
    /// | `y` | yes |
    /// | `c` | cannot judge |
    /// | `m` | no — manuscript text |
    /// | `d` | no — a disposition |
    /// | `s` | no — a statement |
    /// | `t` | no — a task |
    /// | `r` | no — a translation |
    /// | `o` | no — something else |
    private func verdict(_ char: Character) -> Allowed {
        switch char {
        case "y": return .yes
        case "c": return .cannotJudge
        case "m": return .no(.manuscriptText)
        case "d": return .no(.disposition)
        case "s": return .no(.statement)
        case "t": return .no(.task)
        case "r": return .no(.translation)
        case "o": return .no(.other)
        default:
            XCTFail("unknown verdict character \(char)")
            return .cannotJudge
        }
    }

    /// **Spec §2, literal.** Nine rows per group — one per stream, in
    /// `classes`' order — and four characters per row, one per permit in
    /// `permits`' order:
    ///
    ///     reviewer · author of [p-hers] · author of the book · unrecognised
    ///
    /// Read it as the ladder: the reviewer column is *annotations and inbox
    /// rows and nothing else*; the scoped-author column is *everything inside
    /// her pieces, task ops on the project stream, the reviewer row everywhere
    /// else*; the book-author column is *everything*; the last column is the
    /// global pending rule — a permit this build cannot read decides nothing.
    ///
    /// The reviewer column doubles as the phrasebook: wherever a reviewer is
    /// refused, the character is the noun the refusal carries.
    private let grid: [Permit.WrittenGroup: [String]] = [

        // The words themselves. Hers, or the book author's, and nobody else's —
        // and on a statement's stream the same op is a STATEMENT, which is the
        // one thing the stream changes about the sentence.
        .manuscriptText: [
            "myyc",  // 0 her piece
            "mmyc",  // 1 somebody else's piece
            "syyc",  // 2 her piece's statement
            "ssyc",  // 3 somebody else's piece's statement
            "ssyc",  // 4 a project statement — the book author's alone
            "mmyc",  // 5 the project stream
            "myyc",  // 6 her piece's translation
            "mmyc",  // 7 somebody else's piece's translation
            "mmyc",  // 8 the inbox
            // 9 a statement this build cannot place. The reviewer and the
            // scoped author are HELD: a later build's scope word could put this
            // inside her own piece, and setting her words aside for a placement
            // we cannot read is exactly what this milestone forbids. The book
            // author is not held — her answer was `y` in all nine rows above,
            // so where it sits was never her question.
            "ccyc"
        ],

        // The reviewer row. A reviewer may annotate any piece of the book.
        .annotationCreation: [
            "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc",
            "yyyc"   // 9 — `y` in every row above, so no placement could change it
        ],

        // Also the reviewer row — WHOSE annotation is a same-person rule that
        // `AnnotationDeriver` applies, not a permission this table holds.
        .ownAnnotation: [
            "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc",
            "yyyc"   // 9
        ],

        // Settling a note is the writer's act. A reviewer raises them; the
        // author of the piece disposes of them.
        .disposition: [
            "dyyc", "ddyc", "syyc", "ssyc", "ssyc", "ddyc", "dyyc", "ddyc", "ddyc",
            "ccyc"   // 9 — the reviewer's noun differs by placement (d vs s), so held
        ],

        // ⌘S's breadcrumb: an author's mark on a stream they may write.
        .checkpoint: [
            "oyyc", "ooyc", "syyc", "ssyc", "ssyc", "ooyc", "oyyc", "ooyc", "ooyc",
            "ccyc"   // 9
        ],

        // The one thing an author of some pieces may write OUTSIDE her pieces:
        // task ops on the project stream (column 5). Never a reviewer's.
        .task: [
            "tyyc", "ttyc", "tyyc", "ttyc", "ttyc", "tyyc", "tyyc", "ttyc", "ttyc",
            // 9 — a reviewer signs no task in ANY row above, noun and all, so
            // there is no second answer to wait for. The scoped author's does
            // change (`y` on her pieces and on the project stream), so she is held.
            "tcyc"
        ],

        // A translation of a piece is the piece's: hers if the piece is hers.
        .translationRecord: [
            "ryyc", "rryc", "ryyc", "rryc", "rryc", "rryc", "ryyc", "rryc", "rryc",
            "rcyc"   // 9 — the reviewer's `r` is uniform above; hers is not
        ],

        // The reviewer row's third member.
        .inboxRow: [
            "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc", "yyyc",
            "yyyc"   // 9
        ],

        // A later build's kind. Nothing may be decided — not applied, and not
        // refused either (spec §4.2).
        .unreadable: [
            "cccc", "cccc", "cccc", "cccc", "cccc", "cccc", "cccc", "cccc", "cccc",
            "cccc"   // 9
        ]
    ]

    /// **The phrasebook for an unplaceable statement**, which the grid's
    /// reviewer column cannot supply because that column is mostly `c` there.
    ///
    /// Reached only from the two narrowed keys — `translator` writing something
    /// that is not a translation record, `maugham` writing something that is not
    /// the rebalance. Whatever else it is, it IS a statement, so that is the
    /// word; the two groups that name themselves keep their own.
    private let unplaceableNoun: [Permit.WrittenGroup: RefusedWhat] = [
        .manuscriptText: .statement,
        .disposition: .statement,
        .checkpoint: .statement,
        .task: .task,
        .translationRecord: .translation,
        .annotationCreation: .other,
        .ownAnnotation: .other,
        .inboxRow: .other,
        .unreadable: .other
    ]

    /// **The kinds, grouped by hand from their own doc comments.** Manuscript
    /// text is `Deriver.appliesToManuscript`'s list — the three that are also
    /// dispositions (`claudeAccept`, `claudeReject`, `claudeAcceptRevert`) are
    /// here because both readings land on the same rung: the piece author's,
    /// never a reviewer's and never the assistant's.
    private let expectedGroup: [OpKind: Permit.WrittenGroup] = [
        .typingBurst: .manuscriptText,
        .bootstrap: .manuscriptText,
        .externalEdit: .manuscriptText,
        .checkpointRestore: .manuscriptText,
        .claudeAccept: .manuscriptText,
        .claudeReject: .manuscriptText,
        .claudeAcceptRevert: .manuscriptText,

        .claudeComment: .annotationCreation,
        .claudeQuery: .annotationCreation,
        .claudeCraftNote: .annotationCreation,
        .claudeSuggestion: .annotationCreation,

        .annotationEdit: .ownAnnotation,
        .annotationWithdraw: .ownAnnotation,

        .claudeArchive: .disposition,
        .annotationReopen: .disposition,
        .annotationStet: .disposition,
        .annotationTriage: .disposition,

        .checkpoint: .checkpoint,

        .taskCreate: .task,
        .taskStatusChange: .task,
        .taskPriorityChange: .task,
        .taskParentChange: .task,
        .taskBodyEdit: .task,
        .taskArchive: .task,

        .unknown: .unreadable
    ]

    // MARK: - Reading the grid

    private func cell(
        _ group: Permit.WrittenGroup, _ classIndex: Int, _ permitIndex: Int
    ) -> Allowed {
        guard let rows = grid[group] else {
            XCTFail("the grid has no row for \(group)")
            return .cannotJudge
        }
        let row = Array(rows[classIndex])
        return verdict(row[permitIndex])
    }

    /// The noun a refusal carries, read off the grid's reviewer column: a
    /// reviewer is refused everything but the reviewer row, so wherever that
    /// column is not `y` it IS the phrasebook. The three rows where it is `y`
    /// are the reviewer row itself, and a refusal there can only come from one
    /// of the two narrowed keys, which refuse it as *something else*.
    private func noun(_ group: Permit.WrittenGroup, _ classIndex: Int) -> RefusedWhat {
        if classIndex == unplaceableIndex { return unplaceableNoun[group] ?? .other }
        if case .no(let what) = cell(group, classIndex, reviewerColumn) { return what }
        return .other
    }

    /// **The four keys, from §2's narrowing paragraph**, applied over the grid.
    ///
    /// Each line is one sentence of the spec and nothing else:
    /// an unreadable permit decides nothing; an unreadable kind decides
    /// nothing; `author` is the person's own row; `assistant` is the reviewer
    /// column whoever the person is; `translator` is translation records only;
    /// `maugham` is the task rebalance only.
    private func expected(
        _ what: Written, _ classIndex: Int, _ permitIndex: Int, _ actor: DeviceActor
    ) -> Allowed {
        let group = specGroup(of: what)
        if permitIndex == unjudgeableColumn { return .cannotJudge }
        if group == .unreadable { return .cannotJudge }
        switch actor {
        case .author:
            return cell(group, classIndex, permitIndex)
        case .assistant:
            return cell(group, classIndex, reviewerColumn)
        case .translator:
            return group == .translationRecord
                ? cell(.translationRecord, classIndex, permitIndex)
                : .no(noun(group, classIndex))
        case .maugham:
            return what == .op(.taskPriorityChange)
                ? cell(.task, classIndex, permitIndex)
                : .no(noun(group, classIndex))
        }
    }

    private func specGroup(of what: Written) -> Permit.WrittenGroup {
        switch what {
        case .translationRecord: return .translationRecord
        case .inboxRow: return .inboxRow
        case .op(let kind):
            guard let group = expectedGroup[kind] else {
                XCTFail("""
                    `OpKind.\(kind)` has no row in this test's grouping table. A new \
                    op kind needs a rung on the ladder (spec §2) before it can be \
                    signed by anybody.
                    """)
                return .unreadable
            }
            return group
        }
    }

    // MARK: - The grid is whole

    /// Every group has a row, and every row has one entry per stream.
    func test_theGridCoversEveryGroupAndEveryStream() {
        for group in Permit.WrittenGroup.allCases {
            guard let rows = grid[group] else {
                XCTFail("no grid row for \(group)")
                continue
            }
            XCTAssertEqual(rows.count, classes.count, "\(group) has the wrong stream count")
            for row in rows {
                XCTAssertEqual(row.count, permits.count, "\(group): \"\(row)\" is not \(permits.count) permits wide")
            }
        }
    }

    /// **A new `OpKind` fails here before it fails anywhere else.** The
    /// exhaustive switch in `Permit.group(of:)` makes it a compile error to add
    /// a kind without a rung; this makes it a test failure to add one without
    /// somebody having thought about which rung.
    func test_everyOpKindIsGroupedAndTheGroupingIsTheOneTheSpecGives() {
        for kind in OpKind.allCases {
            guard let mine = expectedGroup[kind] else {
                XCTFail("OpKind.\(kind) is ungrouped in this test's table")
                continue
            }
            XCTAssertEqual(Permit.group(of: kind), mine, "OpKind.\(kind)")
        }
        XCTAssertEqual(expectedGroup.count, OpKind.allCases.count,
                       "the test's table names a kind that no longer exists")
    }

    /// Manuscript text is asked of the deriver and not restated (spec §4.2).
    func test_theManuscriptRowIsTheDeriversOwnList() {
        for kind in OpKind.allCases {
            XCTAssertEqual(
                Permit.group(of: kind) == .manuscriptText,
                Deriver.appliesToManuscript(kind),
                "OpKind.\(kind) disagrees with Deriver.appliesToManuscript")
        }
    }

    // MARK: - The whole table

    /// **Every op kind, in every stream, under every permit, on every key.**
    func test_theTableIsTheLadder() {
        var checked = 0
        for kind in OpKind.allCases {
            for (classIndex, documentClass) in classes.enumerated() {
                for (permitIndex, permit) in permits.enumerated() {
                    for actor in DeviceActor.allCases {
                        XCTAssertEqual(
                            permit.allows(.op(kind), in: documentClass, actor: actor),
                            expected(.op(kind), classIndex, permitIndex, actor),
                            "\(kind) · \(documentClass) · \(permit) · \(actor)")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(
            checked,
            OpKind.allCases.count * classes.count * permits.count * DeviceActor.allCases.count)
    }

    /// **`allowsEverything` is the grid's own answer, not a second one**
    /// (P3a Task 5's fix round 1, I1/I3).
    ///
    /// The partition skips both of its expensive questions — what the line was
    /// and where the stream sits — for a (permit, actor) pair that can refuse
    /// nothing. This asserts the skip is exactly right, cell by cell, over the
    /// same grid every other test here reads: `allowsEverything` is true if
    /// and only if every class × every `Written` answers `.yes`.
    ///
    /// **`OpKind.unknown` is excluded, and it is the one exclusion.** `allows`
    /// answers `.cannotJudge` for an unreadable kind under every permit,
    /// including the book author's, so including it here would make the
    /// predicate false for everybody and the skip impossible. The ruling
    /// (`Permit.allowsEverything`'s own doc) is that a book author's own hand
    /// carrying a kind from a later build is left to `parse` exactly as it was
    /// before P3 — she may write everything, so there is no narrower build for
    /// a hold to protect — and `test_aBookAuthorsUnknownKindIsNotHeld` pins
    /// that half at the partition.
    func test_allowsEverythingIsTrueForExactlyTheCellsThatAreAllYes() {
        var trueFor: [String] = []
        for permit in permits {
            for actor in DeviceActor.allCases {
                var everyCellIsYes = true
                for documentClass in classes {
                    for kind in OpKind.allCases where kind != .unknown {
                        if permit.allows(.op(kind), in: documentClass, actor: actor) != .yes {
                            everyCellIsYes = false
                        }
                    }
                    for what in [Written.translationRecord, .inboxRow] {
                        if permit.allows(what, in: documentClass, actor: actor) != .yes {
                            everyCellIsYes = false
                        }
                    }
                }
                XCTAssertEqual(
                    permit.allowsEverything(actor: actor), everyCellIsYes,
                    "\(permit) · \(actor)")
                if everyCellIsYes { trueFor.append("\(permit) · \(actor)") }
            }
        }
        XCTAssertEqual(
            trueFor, ["author(MaughamCore.Permit.Scope.book) · author"],
            "exactly one pair, and it is the one every book on disk is made of")
        XCTAssertFalse(
            Permit.author(.book).allowsEverything(actor: nil),
            "a key this device cannot name an actor for is never skipped")
    }

    /// The two things written that are not ops.
    func test_theTableIsTheLadderForTranslationRecordsAndInboxRows() {
        for what in [Written.translationRecord, .inboxRow] {
            for (classIndex, documentClass) in classes.enumerated() {
                for (permitIndex, permit) in permits.enumerated() {
                    for actor in DeviceActor.allCases {
                        XCTAssertEqual(
                            permit.allows(what, in: documentClass, actor: actor),
                            expected(what, classIndex, permitIndex, actor),
                            "\(what) · \(documentClass) · \(permit) · \(actor)")
                    }
                }
            }
        }
    }

    // MARK: - The named negatives

    /// **The constitution's sentence**: *MCP never mutates manuscript text*.
    ///
    /// Not "unless the writer is the root". The assistant key on the root's own
    /// Mac, under the widest permit this app has, still may not write a word of
    /// the manuscript — and it may not write a disposition either, because
    /// accepting a suggestion is how you would write one anyway.
    func test_theAssistantNeverSignsManuscriptTextUnderAnyPermit() {
        for permit in permits {
            for kind in OpKind.allCases where Deriver.appliesToManuscript(kind) {
                XCTAssertNotEqual(
                    permit.allows(.op(kind), in: .piece(Self.hers), actor: .assistant),
                    .yes,
                    "the assistant signed \(kind) under \(permit)")
            }
        }
        XCTAssertEqual(
            Permit.author(.book).allows(.op(.typingBurst), in: .piece(Self.hers), actor: .assistant),
            .no(.manuscriptText))
        XCTAssertEqual(
            Permit.author(.book).allows(.op(.claudeAccept), in: .piece(Self.hers), actor: .assistant),
            .no(.manuscriptText))
        // And what it MAY do is unchanged: the reviewer row, in full.
        XCTAssertEqual(
            Permit.reviewer.allows(.op(.claudeComment), in: .piece(Self.theirs), actor: .assistant),
            .yes)
    }

    /// A reviewer raises notes; they do not settle them.
    func test_aReviewerNeverSignsADisposition() {
        for kind in OpKind.allCases where Permit.group(of: kind) == .disposition {
            XCTAssertEqual(
                Permit.reviewer.allows(.op(kind), in: .piece(Self.hers), actor: .author),
                .no(.disposition),
                "\(kind)")
        }
        // The dispositions that are also manuscript text refuse in the other
        // word, and refuse just as hard.
        XCTAssertEqual(
            Permit.reviewer.allows(.op(.claudeAccept), in: .piece(Self.hers), actor: .author),
            .no(.manuscriptText))
    }

    /// *Sam's Mac wrote 14 changes to "Chapter 4", which isn't one of her
    /// pieces* (spec §4.4).
    func test_aScopedAuthorIsRefusedOutsideHerPieces() {
        let sam = Permit.author(.pieces([Self.hers]))
        XCTAssertEqual(sam.allows(.op(.typingBurst), in: .piece(Self.hers), actor: .author), .yes)
        XCTAssertEqual(
            sam.allows(.op(.typingBurst), in: .piece(Self.theirs), actor: .author),
            .no(.manuscriptText))
        XCTAssertEqual(
            sam.allows(.op(.annotationStet), in: .piece(Self.theirs), actor: .author),
            .no(.disposition))
        XCTAssertEqual(
            sam.allows(.translationRecord, in: .translation(piece: Self.theirs), actor: .author),
            .no(.translation))
        // What she keeps outside her pieces is the reviewer row.
        XCTAssertEqual(
            sam.allows(.op(.claudeComment), in: .piece(Self.theirs), actor: .author), .yes)
        XCTAssertEqual(sam.allows(.inboxRow, in: .inbox, actor: .author), .yes)
    }

    /// The book's own prose about itself — intent, visual language, lessons,
    /// the first reader, an edition brief — is the book author's.
    func test_aScopedAuthorIsRefusedOnAProjectStatement() {
        let sam = Permit.author(.pieces([Self.hers]))
        XCTAssertEqual(
            sam.allows(.op(.typingBurst), in: .projectStatement, actor: .author),
            .no(.statement))
        // Her own piece's statement is hers.
        XCTAssertEqual(
            sam.allows(.op(.typingBurst), in: .pieceStatement(piece: Self.hers), actor: .author),
            .yes)
        // Somebody else's piece's statement is not, and refuses in the
        // statement's word rather than the manuscript's.
        XCTAssertEqual(
            sam.allows(.op(.typingBurst), in: .pieceStatement(piece: Self.theirs), actor: .author),
            .no(.statement))
        XCTAssertEqual(
            Permit.author(.book).allows(.op(.typingBurst), in: .projectStatement, actor: .author),
            .yes)
    }

    /// *On the project stream: task ops* — the one thing she writes outside her
    /// own pieces.
    func test_aScopedAuthorSignsTaskOpsOnTheProjectStream() {
        let sam = Permit.author(.pieces([Self.hers]))
        for kind in OpKind.allCases where Permit.group(of: kind) == .task {
            XCTAssertEqual(sam.allows(.op(kind), in: .projectStream, actor: .author), .yes, "\(kind)")
            XCTAssertEqual(sam.allows(.op(kind), in: .piece(Self.hers), actor: .author), .yes, "\(kind)")
            XCTAssertEqual(
                sam.allows(.op(kind), in: .piece(Self.theirs), actor: .author), .no(.task), "\(kind)")
        }
        // A reviewer signs no task anywhere, project stream included.
        XCTAssertEqual(
            Permit.reviewer.allows(.op(.taskCreate), in: .projectStream, actor: .author),
            .no(.task))
        // And the rebalance key signs the one op it is for, and nothing else.
        XCTAssertEqual(
            sam.allows(.op(.taskPriorityChange), in: .projectStream, actor: .maugham), .yes)
        XCTAssertEqual(
            sam.allows(.op(.taskCreate), in: .projectStream, actor: .maugham), .no(.task))
        XCTAssertEqual(
            sam.allows(.op(.typingBurst), in: .piece(Self.hers), actor: .maugham),
            .no(.manuscriptText))
    }

    /// The translator key carries translations and nothing else — and only for
    /// pieces the person's own permit covers.
    func test_theTranslatorKeyCarriesTranslationsAndNothingElse() {
        let sam = Permit.author(.pieces([Self.hers]))
        XCTAssertEqual(
            sam.allows(.translationRecord, in: .translation(piece: Self.hers), actor: .translator),
            .yes)
        XCTAssertEqual(
            sam.allows(.translationRecord, in: .translation(piece: Self.theirs), actor: .translator),
            .no(.translation))
        XCTAssertEqual(
            Permit.reviewer.allows(
                .translationRecord, in: .translation(piece: Self.hers), actor: .translator),
            .no(.translation))
        XCTAssertEqual(
            Permit.author(.book).allows(
                .op(.typingBurst), in: .piece(Self.hers), actor: .translator),
            .no(.manuscriptText))
        XCTAssertEqual(
            Permit.author(.book).allows(.inboxRow, in: .inbox, actor: .translator), .no(.other))
    }

    // MARK: - A statement this build cannot place

    /// **The safety property, stated once and checked over the whole grid.**
    ///
    /// An `.unplaceable` statement is one whose placement is unreadable, so what
    /// happens to its lines may be what every placement agrees happens to them,
    /// or it may be *pending* — and it may never be a THIRD outcome that some
    /// placement would have contradicted. That is the whole of the rule: an
    /// older Mac must not set aside what a newer one would apply.
    ///
    /// **The property is over the DECISION, not the sentence.** Applied, set
    /// aside, held: those are what a placement could change the meaning of. The
    /// refusal NOUN is a word in a diagnostic, and it genuinely does differ by
    /// placement — the two narrowed keys refuse a `typingBurst` here as *a
    /// statement* and on a piece as *manuscript text*, both being refusals. A
    /// noun that varies costs nobody a line; asserting it in this property
    /// would only force the sentence to be vaguer than it can be. The nouns are
    /// pinned exactly, cell by cell, by the grid.
    ///
    /// One-directional on purpose. Where every placement agrees, answering is
    /// *allowed* and not *required*: pending is always the safe side, and a
    /// degenerate permit (an author of some pieces with an empty list) is held
    /// a little wider than it strictly needs to be rather than earning an arm
    /// of its own.
    func test_anUnplaceableStatementNeverContradictsAPlacement() {
        /// Applied, set aside, or held — the three things that can become of a
        /// line, which is what a placement could change.
        func decision(_ allowed: Allowed) -> String {
            switch allowed {
            case .yes: return "applied"
            case .no: return "set aside"
            case .cannotJudge: return "held"
            }
        }
        let unplaceable = classes[unplaceableIndex]
        for what in ([.translationRecord, .inboxRow] + OpKind.allCases.map(Written.op)) {
            for permit in permits {
                for actor in DeviceActor.allCases {
                    let answer = permit.allows(what, in: unplaceable, actor: actor)
                    if answer == .cannotJudge { continue }
                    for placement in placements {
                        XCTAssertEqual(
                            decision(answer),
                            decision(permit.allows(what, in: classes[placement], actor: actor)),
                            """
                            \(what) · \(permit) · \(actor): an unplaceable statement's line \
                            is \(decision(answer)), which \(classes[placement]) contradicts
                            """)
                    }
                }
            }
        }
    }

    /// **The Important this fix round exists for.** Her words are HELD, not set
    /// aside: a later build's scope word could put this statement inside her own
    /// piece, and Backup is not where they belong in the meantime.
    func test_aScopedAuthorsWordsInAnUnplaceableStatementArePending() {
        let sam = Permit.author(.pieces([Self.hers]))
        let unplaceable = DocumentClass.unplaceable("st_unreadableScope")
        for kind in OpKind.allCases where Deriver.appliesToManuscript(kind) {
            XCTAssertEqual(
                sam.allows(.op(kind), in: unplaceable, actor: .author), .cannotJudge, "\(kind)")
        }
        XCTAssertEqual(
            sam.allows(.op(.annotationStet), in: unplaceable, actor: .author), .cannotJudge)
        XCTAssertEqual(
            sam.allows(.op(.checkpoint), in: unplaceable, actor: .author), .cannotJudge)
        XCTAssertEqual(
            sam.allows(.op(.taskCreate), in: unplaceable, actor: .author), .cannotJudge)
        XCTAssertEqual(
            sam.allows(.translationRecord, in: unplaceable, actor: .author), .cannotJudge)

        // **End to end, from the manifest**, because the defect this fix round
        // closes lived in `resolve` and not in the table: read as a project
        // statement, every one of these becomes `.no(.statement)` and her words
        // go to Backup.
        let statements = [
            Statement(id: "st_unreadableScope", kind: .intent,
                      scope: .unknown("series:3"), path: "x.md")
        ]
        let resolved = DocumentClass.resolve(docId: "st_unreadableScope", statements: statements)
        XCTAssertEqual(resolved, unplaceable)
        XCTAssertEqual(sam.allows(.op(.typingBurst), in: resolved, actor: .author), .cannotJudge)
        XCTAssertEqual(sam.allows(.op(.bootstrap), in: resolved, actor: .author), .cannotJudge)
    }

    /// **An annotation is `.yes`, and the reason is the rule and not a mood:**
    /// annotation creation is the reviewer row, and the reviewer row is granted
    /// in *every* class. There is no placement this statement could turn out to
    /// have that would refuse it, so there is nothing to wait for.
    func test_anybodyMayAnnotateAnUnplaceableStatement() {
        let unplaceable = DocumentClass.unplaceable("st_unreadableScope")
        for permit in permits where !permit.isUnjudgeable {
            for kind in OpKind.allCases
            where Permit.group(of: kind) == .annotationCreation
                || Permit.group(of: kind) == .ownAnnotation {
                XCTAssertEqual(
                    permit.allows(.op(kind), in: unplaceable, actor: .author), .yes,
                    "\(kind) · \(permit)")
            }
            XCTAssertEqual(permit.allows(.inboxRow, in: unplaceable, actor: .author), .yes)
        }
    }

    /// A book author's answer never depended on where the statement sits, so
    /// she is not made to wait for a word this build cannot read to write her
    /// own book's prose.
    func test_aBookAuthorWritesAnUnplaceableStatementAsSheWritesAnyOther() {
        let unplaceable = DocumentClass.unplaceable("st_unreadableScope")
        for kind in OpKind.allCases where kind != .unknown {
            XCTAssertEqual(
                Permit.bookAuthor.allows(.op(kind), in: unplaceable, actor: .author), .yes,
                "\(kind)")
        }
        XCTAssertEqual(
            Permit.bookAuthor.allows(.translationRecord, in: unplaceable, actor: .author), .yes)
    }

    /// The assistant key is the reviewer row wherever it is, so on an
    /// unplaceable statement it gets the reviewer's cell — under the root's own
    /// permit as under anybody's.
    func test_theAssistantOnAnUnplaceableStatementGetsTheReviewersCell() {
        let unplaceable = DocumentClass.unplaceable("st_unreadableScope")
        for permit in permits where !permit.isUnjudgeable {
            XCTAssertEqual(
                permit.allows(.op(.typingBurst), in: unplaceable, actor: .assistant),
                Permit.reviewer.allows(.op(.typingBurst), in: unplaceable, actor: .author))
            XCTAssertEqual(
                permit.allows(.op(.typingBurst), in: unplaceable, actor: .assistant), .cannotJudge)
            XCTAssertEqual(
                permit.allows(.op(.claudeComment), in: unplaceable, actor: .assistant), .yes)
        }
    }

    /// The two narrowed keys keep exactly the gate they already had: a
    /// translation record is never written to a statement's stream, and neither
    /// is anything but the rebalance from the app's own key — so what comes back
    /// is a refusal in the statement's word, and it is pinned rather than
    /// designed.
    func test_theNarrowedKeysOnAnUnplaceableStatementKeepTheirOwnGate() {
        let unplaceable = DocumentClass.unplaceable("st_unreadableScope")
        XCTAssertEqual(
            Permit.bookAuthor.allows(.op(.typingBurst), in: unplaceable, actor: .translator),
            .no(.statement))
        XCTAssertEqual(
            Permit.bookAuthor.allows(.op(.typingBurst), in: unplaceable, actor: .maugham),
            .no(.statement))
        XCTAssertEqual(
            Permit.bookAuthor.allows(.op(.taskCreate), in: unplaceable, actor: .maugham),
            .no(.task))
        // And where the gate matches, the row answers: the book author's `y`.
        XCTAssertEqual(
            Permit.bookAuthor.allows(
                .op(.taskPriorityChange), in: unplaceable, actor: .maugham), .yes)
        XCTAssertEqual(
            Permit.bookAuthor.allows(.translationRecord, in: unplaceable, actor: .translator), .yes)
    }

    // MARK: - An author of some pieces with no pieces yet

    /// *She may write what she starts* is a real state, and until she starts it
    /// she writes no manuscript — but the project's tasks are still hers.
    func test_anAuthorOfNoPiecesYetWritesNoWordsAndStillSignsTasks() {
        let newcomer = Permit.author(.pieces([]))
        for documentClass in [DocumentClass.piece(Self.hers), .piece(Self.theirs),
                              .piece("d_anythingAtAll")] {
            XCTAssertEqual(
                newcomer.allows(.op(.typingBurst), in: documentClass, actor: .author),
                .no(.manuscriptText),
                "\(documentClass)")
        }
        XCTAssertEqual(
            newcomer.allows(.op(.taskCreate), in: .projectStream, actor: .author), .yes)
        XCTAssertEqual(
            newcomer.allows(.op(.taskPriorityChange), in: .projectStream, actor: .maugham), .yes)
        // And the reviewer row is hers, as it is everybody's.
        XCTAssertEqual(
            newcomer.allows(.op(.claudeComment), in: .piece(Self.theirs), actor: .author), .yes)
    }

    // MARK: - The three that cannot be judged

    /// **A key nobody can name is not the writer's own hand.**
    ///
    /// `TrustTable.actor(forSealKey:)` answers nil for an unrecorded key, for a
    /// key two people claim, and for an actor word a later build invented.
    /// Defaulting any of those to `.author` would hand the widest of the four
    /// keys to a signature nobody can attribute.
    func test_aLineWhoseActorCannotBeNamedIsNotJudged() {
        for permit in permits {
            for documentClass in classes {
                for kind in OpKind.allCases {
                    XCTAssertEqual(
                        permit.allows(.op(kind), in: documentClass, actor: nil),
                        .cannotJudge,
                        "\(kind) · \(documentClass) · \(permit)")
                }
                XCTAssertEqual(
                    permit.allows(.translationRecord, in: documentClass, actor: nil), .cannotJudge)
                XCTAssertEqual(
                    permit.allows(.inboxRow, in: documentClass, actor: nil), .cannotJudge)
            }
        }
    }

    /// A kind from a later build is PENDING under every permit, the book
    /// author's included: an older Mac must not apply what it cannot read, and
    /// must not refuse it either.
    func test_anUnknownKindIsNeverAppliedAndNeverRefused() {
        for permit in permits {
            for documentClass in classes {
                for actor in DeviceActor.allCases {
                    XCTAssertEqual(
                        permit.allows(.op(.unknown), in: documentClass, actor: actor),
                        .cannotJudge,
                        "\(documentClass) · \(permit) · \(actor)")
                }
            }
        }
    }

    /// A role or scope word this build does not know decides nothing at all.
    func test_anUnjudgeablePermitJudgesNothing() {
        let later = Permit.unjudgeable(raw: "curator")
        for documentClass in classes {
            for actor in DeviceActor.allCases {
                for kind in OpKind.allCases {
                    XCTAssertEqual(
                        later.allows(.op(kind), in: documentClass, actor: actor), .cannotJudge)
                }
                XCTAssertEqual(
                    later.allows(.translationRecord, in: documentClass, actor: actor), .cannotJudge)
                XCTAssertEqual(
                    later.allows(.inboxRow, in: documentClass, actor: actor), .cannotJudge)
            }
        }
    }

    // MARK: - Behaviour neutrality

    /// **Every book on disk today.** No events ⇒ every admitted person is an
    /// author of the whole book from the start ⇒ nothing anybody's Mac has ever
    /// written is refused, except through the assistant key, which could not
    /// write manuscript text before this milestone either (MCP has never had a
    /// tool that does).
    func test_aBookAuthorOnTheirOwnKeyIsRefusedNothing() {
        for documentClass in classes {
            for kind in OpKind.allCases where kind != .unknown {
                XCTAssertEqual(
                    Permit.bookAuthor.allows(.op(kind), in: documentClass, actor: .author),
                    .yes,
                    "\(kind) · \(documentClass)")
            }
            XCTAssertEqual(
                Permit.bookAuthor.allows(.translationRecord, in: documentClass, actor: .author), .yes)
            XCTAssertEqual(
                Permit.bookAuthor.allows(.inboxRow, in: documentClass, actor: .author), .yes)
        }
    }
}

/// **Which stream is which** (P3a Task 4, spec §4.1).
final class DocumentClassTests: XCTestCase {

    private func manifest(statements: [Statement]) -> ProjectManifest {
        var m = ProjectManifest(
            type: .novel, title: "Book", author: "Denver",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [
                StructureItem(id: "d_chapter1", title: "Chapter One", type: .document,
                              path: "manuscript/chapter1.md")
            ],
            research: [])
        m.statements = statements
        return m
    }

    func test_theProjectStreamIsItsOwnClass() {
        XCTAssertEqual(
            DocumentClass.resolve(docId: "__project__", manifest: manifest(statements: [])),
            .projectStream)
        XCTAssertEqual(DocumentClass.projectStreamDocId, "__project__")
    }

    /// **The scope test is on the PIECE, not the statement.** A per-document
    /// intent has an id of its own that appears in nobody's `pieces` list, so
    /// resolving it to itself would refuse its own author her own statement.
    func test_aDocumentStatementResolvesToThePieceItIsAbout() {
        let statements = [
            Statement(id: "st_intent_ch1", kind: .intent,
                      scope: .document("d_chapter1"), path: "intent/chapter-one.md")
        ]
        XCTAssertEqual(
            DocumentClass.resolve(docId: "st_intent_ch1", manifest: manifest(statements: statements)),
            .pieceStatement(piece: "d_chapter1"))
    }

    func test_aProjectStatementResolvesToTheProjectStatementClass() {
        for kind in [Statement.Kind.intent, .visualLanguage, .lessons, .firstReader,
                     .editionBrief("es")] {
            let statements = [Statement(id: "st_x", kind: kind, scope: .project, path: "x.md")]
            XCTAssertEqual(
                DocumentClass.resolve(docId: "st_x", manifest: manifest(statements: statements)),
                .projectStatement,
                "\(kind)")
        }
    }

    /// **A statement whose scope a later build invented is UNPLACEABLE, not a
    /// project statement.** Folding it into the restrictive class would refuse a
    /// scoped author's words there — and the scope word this build cannot read
    /// might be the one that says the statement is about her own piece.
    func test_aStatementWithAnUnreadableScopeIsUnplaceable() {
        let statements = [
            Statement(id: "st_x", kind: .intent, scope: .unknown("series:3"), path: "x.md")
        ]
        XCTAssertEqual(
            DocumentClass.resolve(docId: "st_x", manifest: manifest(statements: statements)),
            .unplaceable("st_x"))
    }

    /// **An unrecognised KIND is fully placeable**, and that asymmetry is the
    /// point: what a statement IS changes nobody's authority over it, only what
    /// it is ABOUT does. So only the scope is consulted.
    func test_aStatementOfAnUnreadableKindIsPlacedByItsScopeLikeAnyOther() {
        let projectScoped = [
            Statement(id: "st_p", kind: .unknown("series_bible"), scope: .project, path: "p.md")
        ]
        XCTAssertEqual(
            DocumentClass.resolve(docId: "st_p", manifest: manifest(statements: projectScoped)),
            .projectStatement)

        let documentScoped = [
            Statement(id: "st_d", kind: .unknown("series_bible"),
                      scope: .document("d_chapter1"), path: "d.md")
        ]
        XCTAssertEqual(
            DocumentClass.resolve(docId: "st_d", manifest: manifest(statements: documentScoped)),
            .pieceStatement(piece: "d_chapter1"))
    }

    /// *An id the manifest does not know is a piece in nobody's scope* (§4.1) —
    /// and a manuscript document reaches the same answer, which is why no walk
    /// of `structure` is performed.
    func test_aDocumentAndAStrangerAreBothPieces() {
        let m = manifest(statements: [])
        XCTAssertEqual(DocumentClass.resolve(docId: "d_chapter1", manifest: m), .piece("d_chapter1"))
        XCTAssertEqual(DocumentClass.resolve(docId: "d_neverSeen", manifest: m), .piece("d_neverSeen"))
    }

    /// The piece behind a class, asked once for the scope test.
    func test_theThreeClassesThatAreAboutAPieceSayWhichOne() {
        XCTAssertEqual(DocumentClass.piece("p").piece, "p")
        XCTAssertEqual(DocumentClass.pieceStatement(piece: "p").piece, "p")
        XCTAssertEqual(DocumentClass.translation(piece: "p").piece, "p")
        XCTAssertNil(DocumentClass.projectStatement.piece)
        XCTAssertNil(DocumentClass.projectStream.piece)
        XCTAssertNil(DocumentClass.inbox.piece)
        // A statement's own id is not a piece id, so an unplaceable one offers
        // nothing to the scope test even though it carries a string.
        XCTAssertNil(DocumentClass.unplaceable("st_x").piece)
    }
}
