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
                // Defensive: ignore empty-sequence bootstrap ops. Earlier
                // builds emitted a junk bootstrap with `sequence: []` and
                // `changes: []` when a doc was opened against a momentarily-
                // empty .md mid-session. Folding such an op clobbered the
                // accumulated sequence to [], corrupting the display until
                // load-time recovery ran. The emission path is now guarded
                // (Bootstrap.run + Document.load) but existing op logs in
                // the wild still carry these junk ops; this defensive
                // filter heals them transparently. Legitimate empty
                // sequence (writer deleted all paragraphs) only happens
                // via typing_burst, which is unaffected.
                if op.kind == .bootstrap && s.isEmpty {
                    continue
                }
                sequence = s
            }
        }
        return DerivedState(paragraphs: paragraphs, sequence: sequence)
    }

    /// Same as `derive(ops:)` but with a fallback: when no op in the stream
    /// provided an explicit `sequence` field (legacy projects whose typing
    /// bursts predate the "always capture sequence" fix in
    /// `Document.flushBurstNow`), synthesize one from paragraph_id
    /// insertion order in changes.
    ///
    /// Used by `RewindWindow` so the preview / scrubber works on legacy
    /// projects whose ops have non-empty `changes` but no `sequence`.
    /// Otherwise the deriver returns `sequence == []` and the materialized
    /// preview collapses to "" even though `paragraphs` is fully populated.
    ///
    /// NOT used by `Document.load`: that path relies on the empty-sequence
    /// signal to trigger its on-disk `.md` recovery, which is more
    /// accurate than first-appearance synthesis when paragraphs have been
    /// reordered or deleted post-burst.
    public static func deriveWithSequenceFallback(ops: [Op]) -> DerivedState {
        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        var synthesized: [String] = []
        var synthesizedSet: Set<String> = []
        var sequenceWasExplicit = false
        for op in ops {
            if Deriver.appliesToManuscript(op.kind) {
                for change in op.changes {
                    paragraphs[change.paragraphId] = change.next
                    if !synthesizedSet.contains(change.paragraphId) {
                        synthesized.append(change.paragraphId)
                        synthesizedSet.insert(change.paragraphId)
                    }
                }
            }
            if let s = op.sequence {
                sequence = s
                sequenceWasExplicit = true
            }
        }
        if !sequenceWasExplicit {
            sequence = synthesized
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
            return deriveWithSequenceFallback(ops: ops)
        case .atOp(let opId, _):
            // Find the inclusive index of the target op.
            guard let idx = ops.firstIndex(where: { $0.opId == opId }) else {
                return deriveWithSequenceFallback(ops: ops)
            }
            let prefix = Array(ops.prefix(through: idx))
            return deriveWithSequenceFallback(ops: prefix)
        }
    }

    private static func appliesToManuscript(_ kind: OpKind) -> Bool {
        switch kind {
        case .typingBurst, .bootstrap, .externalEdit,
             .checkpointRestore, .claudeAccept:
            return true
        case .checkpoint, .claudeSuggestion, .claudeComment,
             .claudeQuery, .claudeCraftNote, .claudeReject, .claudeArchive,
             .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            return false
        }
    }
}
