// MaughamTests/DraftStageTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// `DraftStage` decides drafting vs. revising from the run's own delta
/// counts and process signals, and never anything else (spec
/// `2026-08-29-the-editorial-letter-design.md` §3.8). It is pure and cheap
/// to test directly; `ProcessSignals` is exercised through real ops rather
/// than a shortcut initializer, per constraint 23 — the value is derived,
/// never hand-assembled to fit a test.
///
/// The fixture below is `ProcessSignalsTests`' `makeOp`/`mint`/`edit` shape,
/// copied rather than shared so the two files stay independent.
final class DraftStageTests: XCTestCase {

    // MARK: - Fixture

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func minutes(_ value: Double) -> Date {
        base.addingTimeInterval(value * 60)
    }

    private func makeOp(
        opId: String,
        kind: OpKind = .typingBurst,
        at: Date,
        session: String = "s1",
        changes: [Op.ParagraphChange] = [],
        device: String = "macA"
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: at, device: device,
           session: session, kind: kind, changes: changes, sequence: nil)
    }

    private func mint(_ id: String, _ text: String = "New.") -> Op.ParagraphChange {
        .init(paragraphId: id, prior: nil, next: text)
    }

    private func edit(_ id: String, _ text: String = "Revised.") -> Op.ParagraphChange {
        .init(paragraphId: id, prior: "Was.", next: text)
    }

    /// One typing-burst mint, one session, `now` inside it — the frontier
    /// moved in the latest (only) session, so
    /// `sessionsSinceFrontierMoved == 0`.
    private func signalsFrontierMovedInLatestSession() -> ProcessSignals {
        ProcessSignals(
            ops: [makeOp(opId: "op1", at: minutes(0), session: "s1", changes: [mint("aaaa")])],
            sequence: ["aaaa"],
            now: minutes(0))
    }

    /// A mint in session 0, then an edit an idle gap later (60 minutes, past
    /// `SessionTracker.idleThreshold`'s 30) forms session 1 — the frontier is
    /// one session stale.
    private func signalsFrontierStale() -> ProcessSignals {
        ProcessSignals(
            ops: [
                makeOp(opId: "op1", at: minutes(0), session: "s1", changes: [mint("aaaa")]),
                makeOp(opId: "op2", at: minutes(60), session: "s1", changes: [edit("aaaa")]),
            ],
            sequence: ["aaaa"],
            now: minutes(60))
    }

    /// Only edits, never a mint — `frontier` is `nil` and so is
    /// `sessionsSinceFrontierMoved`.
    private func signalsNoFrontier() -> ProcessSignals {
        ProcessSignals(
            ops: [makeOp(opId: "op1", at: minutes(0), session: "s1", changes: [edit("aaaa")])],
            sequence: ["aaaa"],
            now: minutes(0))
    }

    // MARK: - The four (new > revised) × (frontier moved) cells

    func test_moreNewThanRevisedAndFrontierMovedLatestSessionIsDrafting() {
        let stage = DraftStage.derive(
            counts: .init(new: 3, revised: 1),
            signals: signalsFrontierMovedInLatestSession())
        XCTAssertEqual(stage, .drafting)
    }

    func test_moreNewThanRevisedButFrontierStaleIsRevising() {
        let stage = DraftStage.derive(
            counts: .init(new: 3, revised: 1),
            signals: signalsFrontierStale())
        XCTAssertEqual(stage, .revising)
    }

    func test_moreRevisedThanNewWithFrontierMovedIsStillRevising() {
        let stage = DraftStage.derive(
            counts: .init(new: 1, revised: 3),
            signals: signalsFrontierMovedInLatestSession())
        XCTAssertEqual(stage, .revising)
    }

    func test_moreRevisedThanNewWithFrontierStaleIsRevising() {
        let stage = DraftStage.derive(
            counts: .init(new: 1, revised: 3),
            signals: signalsFrontierStale())
        XCTAssertEqual(stage, .revising)
    }

    // MARK: - The equal-counts boundary

    /// `counts.new > counts.revised` is a strict inequality — equal counts
    /// are not "mostly new" and read as revising even with a moving
    /// frontier.
    ///
    /// Disable experiment: relaxed the guard from `>` to `>=` in
    /// `DraftStage.derive`. This test then failed:
    /// `XCTAssertEqual failed: ("drafting") is not equal to ("revising")`.
    /// Restored to `>` before committing.
    func test_equalCountsIsRevisingEvenWithAMovingFrontier() {
        let stage = DraftStage.derive(
            counts: .init(new: 2, revised: 2),
            signals: signalsFrontierMovedInLatestSession())
        XCTAssertEqual(stage, .revising)
    }

    // MARK: - Nil signals

    /// No reading taken (`signals == nil`) decides on the counts alone.
    func test_nilSignalsWithMoreNewThanRevisedIsDrafting() {
        let stage = DraftStage.derive(counts: .init(new: 3, revised: 1), signals: nil)
        XCTAssertEqual(stage, .drafting)
    }

    func test_nilSignalsWithMoreRevisedThanNewIsRevising() {
        let stage = DraftStage.derive(counts: .init(new: 1, revised: 3), signals: nil)
        XCTAssertEqual(stage, .revising)
    }

    // MARK: - Nil frontier

    /// A `nil` frontier — nothing was ever typed new in Maugham for this
    /// document — is revising even with a delta that is mostly new: there is
    /// no frontier to have just moved.
    ///
    /// Disable experiment: dropped the frontier check entirely (`derive`
    /// returned `.drafting` unconditionally once `counts.new > counts.revised`
    /// held, never consulting `signals`). This test then failed:
    /// `XCTAssertEqual failed: ("drafting") is not equal to ("revising")`.
    /// Restored the check before committing.
    func test_nilFrontierIsRevisingEvenWithMoreNewThanRevised() {
        let stage = DraftStage.derive(
            counts: .init(new: 3, revised: 1),
            signals: signalsNoFrontier())
        XCTAssertEqual(stage, .revising)
    }

    // MARK: - Dosage

    func test_freshEyesIsAlwaysFullRegardlessOfStage() {
        XCTAssertEqual(DraftStage.drafting.dosage(freshEyes: true), .full)
        XCTAssertEqual(DraftStage.revising.dosage(freshEyes: true), .full)
    }

    func test_draftingWithoutFreshEyesIsShort() {
        XCTAssertEqual(DraftStage.drafting.dosage(freshEyes: false), .short)
    }

    func test_revisingWithoutFreshEyesIsFull() {
        XCTAssertEqual(DraftStage.revising.dosage(freshEyes: false), .full)
    }

    // MARK: - Dosage caps

    func test_shortDosageCapsQuestionsAtOne() {
        XCTAssertEqual(LetterDosage.short.questionsCap, 1)
    }

    func test_fullDosageReadsTheSharedQuestionsCap() {
        XCTAssertEqual(LetterDosage.full.questionsCap, DiagnosticIngest.letterQuestionsCap)
    }

    func test_shortDosageDropsExerciseAndScenes() {
        XCTAssertFalse(LetterDosage.short.allowsExercise)
        XCTAssertFalse(LetterDosage.short.allowsScenes)
    }

    func test_fullDosageAllowsExerciseAndScenes() {
        XCTAssertTrue(LetterDosage.full.allowsExercise)
        XCTAssertTrue(LetterDosage.full.allowsScenes)
    }

    // MARK: - The raw values are stored

    /// `Letter.stage` carries `rawValue` into the sidecar, so these two
    /// strings are a disk format and not an implementation detail. A rename
    /// here silently reads back as `nil` on every letter already written
    /// (ADR 0015's shape).
    func test_theRawValuesAreTheSidecarsOwn() {
        XCTAssertEqual(DraftStage.drafting.rawValue, "drafting")
        XCTAssertEqual(DraftStage.revising.rawValue, "revising")
        XCTAssertEqual(DraftStage(rawValue: "revising"), .revising, "…and they decode back")
    }

    // MARK: - laneWord

    func test_laneWordIsTheRawValue() {
        XCTAssertEqual(DraftStage.drafting.laneWord, "drafting")
        XCTAssertEqual(DraftStage.revising.laneWord, "revising")
    }
}
