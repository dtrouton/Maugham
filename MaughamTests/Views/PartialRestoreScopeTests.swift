// MaughamTests/Views/PartialRestoreScopeTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// **The restore picker must not open scoped to a document that does not
/// exist.**
///
/// `PartialRestorePicker.init` seeded `_scope = .document(checkpoint.activeDoc)`
/// from whatever the record held. `checkpoints.jsonl` could hold a group id, or
/// `BinderSubject.noDocumentSubject`, so the radio group opened on a
/// `.document(...)` tag matching none of the offered rows — and pressing Revert
/// ran a restore over an id with no op log at all.
///
/// The write side stopped recording those (`CheckpointSubjectRecordTests`), but
/// **old checkpoints on disk still hold them** and tripwire 11 says no
/// migration. So this is a *read* fallback, and it has to cover more than the
/// new `nil`: every legacy shape, plus the case the sentinel never covered —
/// a document that was recorded honestly and has since been deleted.
///
/// One rule covers all of them, and it is the same membership test the write
/// side makes (`CheckpointCapture.documentSubject(of:in:)`): a recorded id is a
/// document only if it is in this project's document census.
final class PartialRestoreScopeTests: XCTestCase {

    private func checkpoint(activeDoc: String?) -> Checkpoint {
        Checkpoint(
            checkpointId: "cp-1", label: "L", labelSource: .auto,
            at: Date(timeIntervalSince1970: 0), device: "m",
            activeDoc: activeDoc,
            docPointers: ["doc-1": "op-1"],
            manuscriptWordCount: 3)
    }

    private let census = ["doc-1", "doc-2"]

    // MARK: - The control

    /// **The good path, first.** Without it every refusal below would still
    /// pass if the seed were replaced by a constant `.wholeProject`, and the
    /// picker would have quietly lost the convenience it exists for.
    func test_aRecordedDocumentStillOpensScopedToIt() {
        XCTAssertEqual(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: "doc-1"), allDocIds: census),
            .document("doc-1"),
            "the picker opens on the document you were in — that is the whole "
            + "point of recording it")
    }

    // MARK: - The refusals

    func test_noRecordedDocumentPreselectsNothing() {
        XCTAssertNil(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: nil), allDocIds: census),
            "the checkpoint indicates no scope, so the sheet must not choose "
            + "one on the writer's behalf")
    }

    /// The legacy value the binder's project row would have made routine.
    func test_aLegacySentinelPreselectsNothing() {
        XCTAssertNil(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: BinderSubject.noDocumentSubject),
                allDocIds: census),
            "an old checkpoint still holds the sentinel — tripwire 11 says "
            + "handle it on read, not with a migration")
    }

    /// The legacy value that has always been reachable: select a Part, ⌘S.
    func test_aLegacyGroupIdPreselectsNothing() {
        XCTAssertNil(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: "grp-1"), allDocIds: census),
            "select a Part, press ⌘S — the reproduction the binder has always "
            + "been able to produce")
    }

    /// **The case the sentinel never covered**, and the reason the fallback is
    /// a census membership test rather than a nil-check plus a sentinel
    /// compare: this checkpoint recorded a real document honestly and the
    /// writer has since deleted it.
    func test_aDeletedDocumentPreselectsNothing() {
        XCTAssertNil(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: "doc-gone"), allDocIds: census),
            "a nil-check alone would still seed a scope naming a document the "
            + "picker does not offer")
    }

    /// An empty census is the `.wholeProject`-only picker; nothing may seed a
    /// document scope there.
    func test_anEmptyCensusOffersOnlyTheWholeProject() {
        XCTAssertEqual(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: "doc-1"), allDocIds: []),
            .wholeProject)
    }

    // MARK: - The seed is what the picker actually opens with

    /// **The delivery path.** `initialScope` being right is worth nothing if
    /// `init` still seeds `_scope` from the raw field, so this asserts through
    /// the initializer the sheet calls rather than the helper beside it.
    ///
    /// **`seededScope` reads the `@State`'s own box for that reason.** Written
    /// first as a second stored property assigned from `initialScope` in the
    /// same `init`, the plant — a raw `.document(checkpoint.activeDoc)` on the
    /// `_scope` line — left this green: it was asserting a copy of the right
    /// answer sitting beside the wrong one that shipped.
    @MainActor
    func test_theInitializerSeedsItsScopeThroughTheFallback() {
        let picker = PartialRestorePicker(
            checkpoint: checkpoint(activeDoc: BinderSubject.noDocumentSubject),
            projectURL: URL(fileURLWithPath: "/tmp/nowhere"),
            activeDocId: BinderSubject.noDocumentSubject,
            allDocIds: census,
            device: "m", session: "s",
            docPaths: [:], documentStore: nil,
            onComplete: {}, onCancel: {})

        XCTAssertEqual(
            picker.seededScope, nil,
            "the sheet's own initializer must go through the fallback — a "
            + "correct helper beside a raw seed is the defect, not the fix")
    }
}
