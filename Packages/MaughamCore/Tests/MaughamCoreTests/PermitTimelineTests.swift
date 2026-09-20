import Foundation
import XCTest
@testable import MaughamCore

/// **A permit is evaluated as of the line** (P3a Task 3, spec §3.4, §5).
///
/// Everything here is a pure value: a list of events in, a permit per line out.
/// No disk, no keys, no registry — `RegistryReader` has already decided which
/// events are events, and this type is asked only what they MEAN to a line.
///
/// The two failures it exists to make impossible are each half of one rule and
/// each is silent:
///
/// - **A demotion reaching backwards.** Judge by today's permit and everything
///   she wrote as an author is set aside the moment she becomes a reviewer.
/// - **A promotion pardoning.** Judge by the permit at admission and what she
///   wrote while the permit said no is applied the moment it says yes — which
///   makes the refusal worth nothing.
///
/// They are tested as a PAIR in one timeline, because a rule with two
/// directions that is tested in one direction is a rule half-built (P2's two
/// wrong rulings were each half of a two-sided rule).
final class PermitTimelineTests: XCTestCase {

    // MARK: - Fixtures

    /// Eight lines of one stream, distinguishable by their bytes.
    private let stream = "d-chapter-4.author-abc"
    private lazy var lines: [Data] = (0..<8).map { Data("{\"op\":\($0)}".utf8) }

    /// A mark that cuts this stream after `index` — everything at or before it
    /// is OLD, everything after is NEW.
    private func mark(after index: Int) -> [String: PermitEvent.StreamMark] {
        [stream: .init(segments: [], line: OpLogChain.lineHash(lines[index]))]
    }

    private func event(
        _ id: String,
        kind: PermitEvent.Kind,
        role: String = Permit.authorRole,
        scope: String = Permit.bookScope,
        pieces: [String] = [],
        mark: [String: PermitEvent.StreamMark] = [:]
    ) -> PermitEvent {
        PermitEvent(
            event: "sam.\(id)", kind: kind, subject: "sam",
            role: role, scope: scope, pieces: pieces, mark: mark,
            at: Date(timeIntervalSince1970: 100), by: "root")
    }

    /// Every line of `lines`, judged against this timeline's own marks.
    private func permits(of timeline: PermitTimeline) -> [Permit] {
        timeline.permits(lineCount: lines.count) { mark in
            mark.judge(streamKey: stream, fileIsSegmentWithDigest: nil, lines: lines)
        }
    }

    // MARK: - No events at all

    /// **The whole of P3a's behaviour-neutrality.** Every book on disk today
    /// has no events, so every admitted person must read as an author of the
    /// whole book, from the very first line.
    func test_aPersonWithNoEventsIsAnAuthorOfTheWholeBookFromTheStart() {
        let timeline = PermitTimeline(events: [])

        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(timeline.entries[0].permit, .author(.book))
        XCTAssertNil(timeline.entries[0].mark, "there is no previous permit to cut from")
        XCTAssertNil(timeline.entries[0].event)
        XCTAssertFalse(timeline.hasEvents)
        XCTAssertEqual(timeline.current, .author(.book))
        XCTAssertEqual(permits(of: timeline), Array(repeating: .author(.book), count: 8))
        XCTAssertEqual(timeline, .bookAuthor)
    }

    // MARK: - Parsing a permit

    func test_aMissingScopeIsTheWholeBookAndPiecesWithNoListIsTheEmptySet() {
        XCTAssertEqual(
            Permit.parse(role: "author", scope: nil, pieces: nil), .author(.book),
            "every P2-era record: absent MEANS book")
        XCTAssertEqual(
            Permit.parse(role: "author", scope: "book", pieces: ["d-one"]),
            .author(.book),
            "a list under book is meaningless by the format's own definition")
        XCTAssertEqual(
            Permit.parse(role: "author", scope: "pieces", pieces: nil),
            .author(.pieces([])),
            "she may write what she starts — an author of no pieces yet is real")
        XCTAssertEqual(
            Permit.parse(role: "author", scope: "pieces", pieces: ["d-two", "d-one"]),
            .author(.pieces(["d-one", "d-two"])))
        XCTAssertEqual(Permit.parse(role: "reviewer", scope: nil, pieces: nil), .reviewer)
    }

    /// A reviewer has no scope: the rung is *annotations and inbox rows*
    /// wherever they are, so a scope word and a piece list beside it are
    /// ignored rather than narrowing anything. Pinned because both fields are
    /// written on every record and a reader that let them through would
    /// silently invent a rung the ladder does not have.
    func test_aReviewersScopeAndPiecesAreIgnored() {
        XCTAssertEqual(
            Permit.parse(role: "reviewer", scope: "pieces", pieces: ["d-one"]),
            .reviewer)
        XCTAssertEqual(
            Permit.parse(role: "reviewer", scope: "book", pieces: ["d-one", "d-two"]),
            .reviewer)
        XCTAssertEqual(
            Permit.parse(role: "reviewer", scope: "chapters", pieces: nil),
            .unjudgeable(raw: "chapters"),
            "a scope word this build does not know is still not understood")
    }

    /// An older Mac must not quarantine what a newer one would apply, so a word
    /// this build does not know is `.unjudgeable` — which the table answers
    /// *cannot judge* and the reader holds PENDING.
    func test_aRoleOrScopeThisBuildDoesNotKnowIsUnjudgeable() {
        XCTAssertEqual(
            Permit.parse(role: "copyeditor", scope: "book", pieces: nil),
            .unjudgeable(raw: "copyeditor"))
        XCTAssertEqual(
            Permit.parse(role: "author", scope: "chapters", pieces: ["d-one"]),
            .unjudgeable(raw: "chapters"))
        XCTAssertTrue(Permit.parse(role: "", scope: nil, pieces: nil).isUnjudgeable)
        XCTAssertFalse(Permit.author(.book).isUnjudgeable)
    }

    // MARK: - As of the line, both directions

    /// **The pair, in one timeline.** She is admitted as an author, demoted to
    /// reviewer after line 2, and promoted back after line 5.
    ///
    /// - Lines 0–2 are before the demotion's mark: they stay **author**. A
    ///   demotion does not reach back.
    /// - Lines 3–5 are between the two marks: they stay **reviewer**. A
    ///   promotion is not a pardon.
    /// - Lines 6–7 are after the promotion's mark: **author** again.
    func test_eachLineLandsUnderThePermitThatHeldWhenItWasWritten() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .admitted),
            event("b", kind: .roleChanged, role: Permit.reviewerRole,
                  mark: mark(after: 2)),
            event("c", kind: .roleChanged, role: Permit.authorRole,
                  mark: mark(after: 5)),
        ])

        XCTAssertEqual(permits(of: timeline), [
            .author(.book), .author(.book), .author(.book),
            .reviewer, .reviewer, .reviewer,
            .author(.book), .author(.book),
        ])
        XCTAssertEqual(timeline.current, .author(.book))
        XCTAssertTrue(timeline.hasEvents)
    }

    /// The same rule where what changes is the SCOPE rather than the role: a
    /// piece leaves her scope, and later another one joins it.
    func test_aPieceLeavingAndAPieceJoiningCutTheSameWay() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .admitted, scope: Permit.piecesScope,
                  pieces: ["d-chapter-4", "d-chapter-5"]),
            event("b", kind: .scopeChanged, scope: Permit.piecesScope,
                  pieces: ["d-chapter-5"], mark: mark(after: 1)),
            event("c", kind: .scopeChanged, scope: Permit.piecesScope,
                  pieces: ["d-chapter-5", "d-chapter-9"], mark: mark(after: 4)),
        ])

        XCTAssertEqual(permits(of: timeline), [
            .author(.pieces(["d-chapter-4", "d-chapter-5"])),
            .author(.pieces(["d-chapter-4", "d-chapter-5"])),
            .author(.pieces(["d-chapter-5"])),
            .author(.pieces(["d-chapter-5"])),
            .author(.pieces(["d-chapter-5"])),
            .author(.pieces(["d-chapter-5", "d-chapter-9"])),
            .author(.pieces(["d-chapter-5", "d-chapter-9"])),
            .author(.pieces(["d-chapter-5", "d-chapter-9"])),
        ])
    }

    /// A stream the mark does not name is wholly NEW — the strict side, and the
    /// one that makes a first admission's empty mark mean *nothing was
    /// applied*. Checked here rather than left to `PermitMarkTests` because it
    /// is what an event with no mark at all does to a whole file.
    func test_aStreamNoMarkNamesIsUnderTheNewestPermit() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .admitted, role: Permit.reviewerRole),
        ])

        XCTAssertEqual(permits(of: timeline), Array(repeating: .reviewer, count: 8))
    }

    /// **Marks out of order: the NEWEST entry that says *new* governs.**
    ///
    /// Marks are monotonic by construction — each is computed from what the
    /// root had applied at the moment it made the event, so a later one covers
    /// at least what an earlier one did. That is a WRITE-side invariant
    /// (`RegistryAdmission.changePermit`, Task 7), and nothing here can check
    /// it: the timeline reads whatever the folder holds. So the rule is stated
    /// for the case it does not expect, and it is deterministic rather than
    /// clever — walk newest to oldest, take the first entry whose mark judges
    /// the line new. Here the second event's mark cuts EARLIER than the first's
    /// and therefore governs everything after it, the first event's permit
    /// never applying to a line at all.
    func test_aMarkThatCutsEarlierThanAnOlderOneStillGoverns() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .roleChanged, role: Permit.reviewerRole,
                  mark: mark(after: 4)),
            event("b", kind: .scopeChanged, scope: Permit.piecesScope,
                  pieces: ["d-chapter-4"], mark: mark(after: 1)),
        ])

        let pieces = Permit.author(.pieces(["d-chapter-4"]))
        XCTAssertEqual(permits(of: timeline), [
            .author(.book), .author(.book),
            pieces, pieces, pieces, pieces, pieces, pieces,
        ])
        XCTAssertFalse(permits(of: timeline).contains(.reviewer),
                       "line 3 is NEW under b's mark and OLD under a's — b is newer")
    }

    // MARK: - Which kinds install a permit

    /// Revocation and retirement are not permits: `TrustVerdict` already has
    /// `.revoked` and `.retired`, and an entry here would restate a rule that
    /// lives somewhere else. The role they carry is the state they found.
    func test_revocationAndRetirementInstallNothing() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .admitted, role: Permit.reviewerRole),
            event("b", kind: .revoked, role: Permit.authorRole, mark: mark(after: 3)),
            event("c", kind: .retired, role: Permit.authorRole, mark: mark(after: 5)),
            event("d", kind: .revokedEntirely, role: Permit.authorRole),
        ])

        XCTAssertEqual(timeline.entries.count, 2, "the opening entry and the admission")
        XCTAssertEqual(permits(of: timeline), Array(repeating: .reviewer, count: 8))
    }

    /// A verb a later build invented holds everything after its mark PENDING.
    /// Skipping it would apply lines under a permit the newer Mac may have
    /// narrowed; refusing them would quarantine what the newer Mac applies.
    func test_aKindThisBuildDoesNotKnowHoldsWhatFollowsItUnjudgeable() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .admitted),
            event("b", kind: .unknown("delegatedToTheEditor"), mark: mark(after: 4)),
        ])

        XCTAssertEqual(permits(of: timeline), [
            .author(.book), .author(.book), .author(.book),
            .author(.book), .author(.book),
            .unjudgeable(raw: "delegatedToTheEditor"),
            .unjudgeable(raw: "delegatedToTheEditor"),
            .unjudgeable(raw: "delegatedToTheEditor"),
        ])
        XCTAssertTrue(timeline.current.isUnjudgeable)
    }

    // MARK: - Order

    /// Event ids are `<subject>.<ULID>` and sort into the order they were made,
    /// whatever order the folder listed them in.
    func test_eventsAreOrderedByTheirIdsAndNotByArrival() {
        let shuffled = PermitTimeline(events: [
            event("c", kind: .roleChanged, role: Permit.authorRole,
                  mark: mark(after: 5)),
            event("a", kind: .admitted),
            event("b", kind: .roleChanged, role: Permit.reviewerRole,
                  mark: mark(after: 2)),
        ])

        XCTAssertEqual(shuffled.entries.map(\.event),
                       [nil, "sam.a", "sam.b", "sam.c"])
        XCTAssertEqual(permits(of: shuffled), [
            .author(.book), .author(.book), .author(.book),
            .reviewer, .reviewer, .reviewer,
            .author(.book), .author(.book),
        ])
    }

    // MARK: - The judgements are computed once per entry

    /// The lookup's shape is what keeps a novel's tail from being hashed once
    /// per line: `judging` is called once for each entry that HAS a mark, and
    /// the opening entry — which has none — is never judged at all.
    func test_oneJudgementPerEntryAndNoneForTheOpeningEntry() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .admitted),
            event("b", kind: .roleChanged, role: Permit.reviewerRole,
                  mark: mark(after: 2)),
        ])
        var judged = 0

        _ = timeline.permits(lineCount: lines.count) { mark in
            judged += 1
            return mark.judge(
                streamKey: stream, fileIsSegmentWithDigest: nil, lines: lines)
        }

        XCTAssertEqual(judged, 2, "two events, two marks; the opening entry has none")
        XCTAssertEqual(timeline.entries.count, 3)
    }

    /// The indexed form is the primitive, and a caller may state the
    /// judgements as literals — which is how the partition (Task 5) will index
    /// a file it has already judged.
    func test_theIndexedFormAnswersFromJudgementsAlone() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .admitted),
            event("b", kind: .roleChanged, role: Permit.reviewerRole, mark: mark(after: 0)),
        ])

        let permits = timeline.permits(
            forFile: [nil,
                      .allNew(count: 3),
                      PermitMark.Judgement(sides: [.old, .new, .new])],
            lineCount: 3)

        XCTAssertEqual(permits, [.author(.book), .reviewer, .reviewer])
        XCTAssertEqual(timeline.permit(ofLineAt: 0, judgements: [nil, .allNew(count: 3),
                                                                PermitMark.Judgement(
                                                                    sides: [.old, .new, .new])]),
                       .author(.book))
    }

    /// A judgement list shorter than the timeline — a caller that judged only
    /// some entries — answers from the entries it did judge and never crashes.
    ///
    /// The event is a role CHANGE rather than an admission, so the opening
    /// entry is still the book author's and the two arms below stay
    /// distinguishable: after fix round 3 an `admitted` first event installs
    /// its own permit as the opening too, which would make both arms read
    /// `.reviewer` and this test stop discriminating.
    func test_aShortJudgementListIsAnsweredFromWhatWasJudged() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .roleChanged, role: Permit.reviewerRole),
        ])

        XCTAssertEqual(timeline.permits(forFile: [], lineCount: 2),
                       [.author(.book), .author(.book)])
        XCTAssertEqual(timeline.permits(forFile: [nil, .allNew(count: 2)], lineCount: 2),
                       [.reviewer, .reviewer])
    }

    // MARK: - What governs a line before the first event (fix round 3)

    /// **There is nothing before an admission.** A person admitted as a
    /// reviewer is a reviewer for everything they ever wrote — including the
    /// lines that were held while they were a stranger, which are SEEN and so
    /// fall at or before the admission's own mark.
    func test_anAdmissionGovernsWhatCameBeforeItToo() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .admitted, role: Permit.reviewerRole,
                  mark: ["s": .init(line: "somewhere")]),
        ])

        XCTAssertEqual(timeline.entries.first?.permit, .reviewer)
        XCTAssertEqual(
            timeline.permits(forFile: [nil, PermitMark.Judgement(sides: [.old, .new])],
                             lineCount: 2),
            [.reviewer, .reviewer],
            "both sides of the admission's mark are hers as a reviewer")
    }

    /// The other direction of the same rule: admitted as an author of the
    /// whole book, everything she ever wrote is an author's.
    func test_anAdmissionAsABookAuthorGovernsWhatCameBeforeItToo() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .silentlyAdmitted, role: Permit.authorRole,
                  mark: ["s": .init(line: "somewhere")]),
        ])

        XCTAssertEqual(timeline.entries.first?.permit, .author(.book))
        XCTAssertEqual(
            timeline.permits(forFile: [nil, PermitMark.Judgement(sides: [.old, .new])],
                             lineCount: 2),
            [.author(.book), .author(.book)])
    }

    /// **A role change is not an admission.** A person whose first event is a
    /// change was admitted under P2, with no event to point at — and P2
    /// admitted everybody as an author of the whole book. The opening stays
    /// that, which is what keeps a demotion from reaching back.
    func test_aFirstEventThatIsAChangeLeavesTheOpeningAsP2MeantIt() {
        for kind in [PermitEvent.Kind.roleChanged, .scopeChanged, .readmitted] {
            let timeline = PermitTimeline(events: [
                event("a", kind: kind, role: Permit.reviewerRole,
                      mark: ["s": .init(line: "somewhere")]),
            ])

            XCTAssertEqual(timeline.entries.first?.permit, .author(.book), "\(kind)")
            XCTAssertEqual(
                timeline.permits(forFile: [nil, PermitMark.Judgement(sides: [.old, .new])],
                                 lineCount: 2),
                [.author(.book), .reviewer],
                "\(kind): what she wrote before it stays an author's")
        }
    }

    /// **A first event of a kind this build cannot read holds everything.**
    /// It cannot tell whether a later build's first event was an admission,
    /// and the two answers are not interchangeable.
    func test_aFirstEventOfAnUnknownKindOpensUnjudgeable() {
        let timeline = PermitTimeline(events: [
            event("a", kind: .unknown("enrolled"), role: Permit.authorRole),
        ])

        XCTAssertEqual(timeline.entries.first?.permit, .unjudgeable(raw: "enrolled"))
        XCTAssertTrue(timeline.permits(forFile: [], lineCount: 2)
            .allSatisfy(\.isUnjudgeable))
    }

    /// **The verdict's own kinds install nothing and are skipped when looking
    /// for the first event**, so a person with only a revocation reads exactly
    /// as they did under P2.
    func test_aRevocationIsNotAFirstEvent() {
        for kind in [PermitEvent.Kind.revoked, .revokedEntirely, .retired] {
            let timeline = PermitTimeline(events: [
                event("a", kind: kind, role: Permit.reviewerRole),
            ])

            XCTAssertEqual(timeline.entries, [.opening], "\(kind)")
            XCTAssertEqual(timeline.current, .author(.book), "\(kind)")
        }
        // And one in FRONT of a real first event does not hide it.
        let timeline = PermitTimeline(events: [
            event("a", kind: .retired),
            event("b", kind: .admitted, role: Permit.reviewerRole),
        ])
        XCTAssertEqual(timeline.entries.first?.permit, .reviewer)
    }

    /// A timeline stated as entries directly still opens with something: an
    /// empty list is the book-author default rather than a value with no
    /// answer for line 0.
    func test_aTimelineOfNoEntriesIsStillAnswerable() {
        XCTAssertEqual(PermitTimeline(entries: []).current, .author(.book))
        XCTAssertEqual(PermitTimeline(entries: []).entries.count, 1)
    }
}
