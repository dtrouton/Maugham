// Maugham/OpLog/Deriver.swift
import Foundation

public enum Deriver {
    public struct DerivedState: Equatable, Sendable {
        public let paragraphs: [String: String]
        public let sequence: [String]
        public init(paragraphs: [String: String], sequence: [String]) {
            self.paragraphs = paragraphs
            self.sequence = sequence
        }
    }

    /// Fold ops in the given order into a paragraph_id → text map and the
    /// current sequence. Caller sorts by `op_id` first.
    ///
    /// Only manuscript-mutation ops contribute paragraph text. Annotation
    /// creation ops (claude_comment/claude_query/claude_suggestion/
    /// claude_craft_note) carry a change entry purely as a paragraph anchor
    /// + priorText snapshot for stale detection — their `change.next` is
    /// empty (or the proposed text for suggestions) and MUST NOT overwrite
    /// the live paragraph. Same for lifecycle ops (reject/archive) which
    /// always carry empty changes. claude_accept of a suggested change DOES
    /// mutate the manuscript and is included.
    public static func derive(ops: [Op]) -> DerivedState {
        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        for op in ops {
            if Deriver.appliesToManuscript(op.kind) {
                for change in op.changes {
                    paragraphs[change.paragraphId] = change.next
                }
            }
            if let s = op.sequence {
                sequence = s
            }
        }
        return DerivedState(paragraphs: paragraphs, sequence: sequence)
    }

    /// Derive state as it was when op `cursor` had just been applied — or
    /// the full state when `cursor == .now`.
    ///
    /// Same fold semantics as `derive(ops:)`: only manuscript-mutating op
    /// kinds contribute paragraph text; annotation creation ops are walked
    /// for sequence/timing purposes but their `.next` is not applied.
    ///
    /// When `cursor` references an op_id not present in `ops`, returns the
    /// full derivation — defensive against stale UI cursors that survived
    /// a cross-Mac merge that compacted the source op away.
    public static func derive(ops: [Op], upTo cursor: RewindCursor) -> DerivedState {
        switch cursor {
        case .now:
            return derive(ops: ops)
        case .atOp(let opId, _):
            // Find the inclusive index of the target op.
            guard let idx = ops.firstIndex(where: { $0.opId == opId }) else {
                return derive(ops: ops)
            }
            let prefix = Array(ops.prefix(through: idx))
            return derive(ops: prefix)
        }
    }

    private static func appliesToManuscript(_ kind: OpKind) -> Bool {
        switch kind {
        case .typingBurst, .bootstrap, .externalEdit,
             .checkpointRestore, .claudeAccept:
            return true
        case .checkpoint, .claudeSuggestion, .claudeComment,
             .claudeQuery, .claudeCraftNote, .claudeReject, .claudeArchive:
            return false
        }
    }
}
