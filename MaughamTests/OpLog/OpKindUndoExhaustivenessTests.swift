import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0023 completeness gate (Task 20, 2026-07-11 maintainability review
/// §3.2, A2 Medium): "No exhaustiveness test tying `OpKind` cases to undo
/// inverse coverage — completeness is discipline; a new `OpKind` can ship
/// without an inverse." `classify(_:)` below is the fix: it switches
/// EXHAUSTIVELY over `OpKind` with NO `default:` clause, so adding a new
/// `OpKind` case fails to COMPILE here until a human sorts it into
/// `.inverseCovered` (naming the real factory/registrar, verified by reading
/// the source below) or `.nonUndoable` (naming the reason, matching ADR
/// 0023 §5's scope boundaries). This mirrors the existing pattern at
/// `Deriver.appliesToManuscript` (ADR 0015) — an exhaustive switch as the
/// compile-forcing gate for a future kind.
final class OpKindUndoExhaustivenessTests: XCTestCase {

    enum Coverage: Equatable {
        case inverseCovered(mechanism: String)
        case nonUndoable(reason: String)
    }

    /// THE gate. Every arm below was verified against the actual production
    /// source (not inferred from the audit) — see task-20-report.md for the
    /// file:line citations and the captured compile error from temporarily
    /// commenting out one case.
    func classify(_ kind: OpKind) -> Coverage {
        switch kind {

        // MARK: - Annotation lifecycle (AnnotationInverse, MaughamCore)

        case .claudeReject:
            // Document+Annotations.swift rejectAnnotation(...) registers
            // OpUndoRegistrar whose undo closure calls reopenAnnotation(id:),
            // which builds its compensating op via
            // AnnotationInverse.reopenOp(undoing: .claudeReject, ...).
            return .inverseCovered(mechanism: "AnnotationInverse.reopenOp via Document.reopenAnnotation")

        case .claudeArchive:
            // Document+Annotations.swift archiveAnnotation(...) — same
            // reopenOp mechanism, undoing: .claudeArchive.
            return .inverseCovered(mechanism: "AnnotationInverse.reopenOp via Document.reopenAnnotation")

        case .annotationWithdraw:
            // Document+Annotations.swift withdrawReviewerAnnotation(...) —
            // same reopenOp mechanism, undoing: .annotationWithdraw.
            return .inverseCovered(mechanism: "AnnotationInverse.reopenOp via Document.reopenAnnotation")

        case .annotationEdit:
            // Document+Annotations.swift editReviewerAnnotation(...)'s
            // OpUndoRegistrar undo closure calls
            // AnnotationInverse.editRevertOp, appending a compensating
            // annotationEdit carrying the pre-edit body (and prior suggested
            // replacement, when present).
            return .inverseCovered(mechanism: "AnnotationInverse.editRevertOp via Document.editReviewerAnnotation")

        case .annotationReopen:
            // annotationReopen IS the compensating op AnnotationInverse.reopenOp
            // produces for the three cases above. Its own reversal is the
            // ORIGINAL resolution replayed — the nested redo closure inside
            // rejectAnnotation / archiveAnnotation / withdrawReviewerAnnotation's
            // OpUndoRegistrar.register calls (Document+Annotations.swift).
            return .inverseCovered(mechanism: "compensating op of AnnotationInverse.reopenOp; reversed by the original resolution's OpUndoRegistrar redo")

        // MARK: - Accept / revert (bespoke choreography, predates OpUndoRegistrar's generalization — see TaskInverse.swift doc comment on OpUndoRegistrar)

        case .claudeAccept:
            // Document+Annotations.swift revertAcceptedAnnotation(...) appends
            // the compensating claudeAcceptRevert op (restores pre-accept
            // text via `changes`, returns the annotation to .open).
            return .inverseCovered(mechanism: "Document.revertAcceptedAnnotation (appends claudeAcceptRevert)")

        case .claudeAcceptRevert:
            // revertAcceptedAnnotation's own undo registration re-invokes
            // Document.acceptAnnotation directly (registerUndo block,
            // Document+Annotations.swift ~544-561) — not via a shared
            // factory; deliberately not refactored onto OpUndoRegistrar per
            // that file's doc comment (accept carries extra manuscript-text
            // choreography).
            return .inverseCovered(mechanism: "Document.acceptAnnotation re-invoked by revertAcceptedAnnotation's undo registration")

        // MARK: - Task lifecycle (TaskInverse, Mac-only — task types have no phone surface)

        case .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            // TaskInverse.inverse(undoing:prior:...) switches exhaustively
            // over exactly these six kinds (TaskInverse.swift); every task
            // mutation site (Document+Tasks.swift, ProjectStore+Tasks.swift,
            // TasksPane.swift) calls it before registering undo.
            return .inverseCovered(mechanism: "TaskInverse.inverse")

        // MARK: - Rewind (Document+RewindUndo.swift)

        case .checkpointRestore:
            // Document.restoreToOpUndoable wraps restoreToOp in an
            // OpUndoRegistrar registration whose undo appends a compensating
            // checkpointRestore (stamped SynthesisSource.undoRewind) back to
            // the pre-rewind tip.
            return .inverseCovered(mechanism: "Document.restoreToOpUndoable (compensating checkpointRestore, SynthesisSource.undoRewind)")

        // MARK: - Excluded by design (ADR 0023 §5 "Scope boundaries" + CLAUDE.md invariants)

        case .typingBurst:
            // Ordinary typing is undone by AppKit's native NSTextView undo
            // stack, not an op-log inverse (ADR 0023 context: "Through
            // v0.17.0, ⌘Z covered typing... plus exactly one op-log
            // mutation"). Inline checkbox flips also produce a .typingBurst
            // op (a plain setParagraph) but get their own bespoke
            // buffer-guarded undo (InlineToggleUndo.perform,
            // OpUndoRegistrar.swift) that flips paragraph text back
            // directly — it never inspects or produces an op-kind-keyed
            // inverse, so it doesn't change this classification.
            return .nonUndoable(reason: "typing = native NSTextView undo by design; inline-checkbox flips use InlineToggleUndo's buffer-guarded flip, not an op inverse")

        case .externalEdit:
            // Represents an already-reconciled external .md mutation
            // (discarded per ADR 0019 / "external .md edits not honored"),
            // not a writer-invoked action with a window undo stack.
            return .nonUndoable(reason: "represents an already-reconciled external .md mutation, not a writer-invoked action with an undo stack (ADR 0019)")

        case .checkpoint:
            // CLAUDE.md: "⌘S is a labeled checkpoint, not a save." A
            // checkpoint is a named pointer into the log, not a mutation to
            // reverse.
            return .nonUndoable(reason: "⌘S labeled checkpoint is a pointer, not a mutation to reverse")

        case .bootstrap:
            // One-time ¶id-anchor minting on document load (Bootstrap.run),
            // not a user-invoked action.
            return .nonUndoable(reason: "one-time ¶id-anchor minting on document load, not a user action")

        case .claudeSuggestion, .claudeComment, .claudeQuery, .claudeCraftNote:
            // Annotation CREATION ops, appended by MCP tools (add_note /
            // add_comment / suggest_change), never through a window's
            // NSUndoManager. ADR 0023 §5: "MCP- and cross-device-originated
            // ops never register on any undo stack — ⌘Z undoes only what the
            // writer did in this window."
            return .nonUndoable(reason: "MCP-originated annotation creation; never registers on a window's undo stack (ADR 0023 §5)")

        case .unknown:
            // Forward-tolerance decode fallback for an op kind written by a
            // NEWER build (OpKind.init(from:)); this build never creates one,
            // so there is nothing for it to undo (ADR 0015).
            return .nonUndoable(reason: "cross-version decode fallback; never created by this build (ADR 0015)")
        }
    }

    func test_everyOpKind_hasADeclaredUndoStory() {
        for kind in OpKind.allCases {
            switch classify(kind) {
            case .inverseCovered(let mechanism):
                XCTAssertFalse(mechanism.isEmpty, "\(kind) claims coverage but names no mechanism")
            case .nonUndoable(let reason):
                XCTAssertFalse(reason.isEmpty, "\(kind) is excluded but gives no reason")
            }
        }
    }

    /// Documents which kinds fall in which bucket so a diff on this test is
    /// legible in review, rather than only the exhaustive-switch compile
    /// error surfacing a change. Redundant with `classify(_:)` by
    /// construction — that's the point: the two must agree.
    func test_bucketMembership_matchesADR0023() {
        let covered: [OpKind] = [
            .claudeReject, .claudeArchive, .annotationWithdraw, .annotationEdit,
            .annotationReopen, .claudeAccept, .claudeAcceptRevert,
            .taskCreate, .taskStatusChange, .taskPriorityChange,
            .taskParentChange, .taskBodyEdit, .taskArchive,
            .checkpointRestore,
        ]
        let excluded: [OpKind] = [
            .typingBurst, .externalEdit, .checkpoint, .bootstrap,
            .claudeSuggestion, .claudeComment, .claudeQuery, .claudeCraftNote,
            .unknown,
        ]
        XCTAssertEqual(
            covered.count + excluded.count, OpKind.allCases.count,
            "bucket lists don't add up to OpKind.allCases — a case is missing or double-listed")
        for kind in OpKind.allCases {
            let inCovered = covered.contains(kind)
            let inExcluded = excluded.contains(kind)
            XCTAssertTrue(inCovered != inExcluded, "\(kind) must be in exactly one bucket")
        }
        for kind in covered {
            guard case .inverseCovered = classify(kind) else {
                XCTFail("\(kind) listed as covered but classify() disagrees")
                continue
            }
        }
        for kind in excluded {
            guard case .nonUndoable = classify(kind) else {
                XCTFail("\(kind) listed as excluded but classify() disagrees")
                continue
            }
        }
    }
}
