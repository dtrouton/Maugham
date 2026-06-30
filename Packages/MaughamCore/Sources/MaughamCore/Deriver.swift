import Foundation

/// Folds an op log into the current manuscript state (`paragraphs` + `sequence`)
/// — the single shared op-replay. The Mac editor (`Document.load`) and the iOS
/// reader (`AnnotationsListView`) both derive paragraph state through it; the
/// rewind-cursor variant (`derive(ops:upTo:)`) stays Mac-side in
/// `Deriver+Rewind.swift` because `RewindCursor` is editor-only.
public enum Deriver {
    public struct DerivedState: Equatable, Sendable {
        public let paragraphs: [String: String]
        public let sequence: [String]
        public init(paragraphs: [String: String], sequence: [String]) {
            self.paragraphs = paragraphs
            self.sequence = sequence
        }
    }

    /// A total order over ops `(opId, canonicalContentEncoding)` — the SAME order
    /// `OpLogStore.mergeSortedDedup` uses, so derive is correct-by-construction
    /// regardless of input order (defense in depth: a caller that forgets to
    /// pre-sort still derives the documented result). For a given paragraph,
    /// last-write-wins is BY opId; the canonical-content tiebreaker only matters
    /// for the astronomically-unlikely same-opId/divergent-content collision and
    /// keeps even that deterministic. The canonical encoding is the store's
    /// `.sortedKeys` + ISO8601-fractional JSON — a stable function of content.
    static func opOrder(_ a: Op, _ b: Op) -> Bool {
        if a.opId != b.opId { return a.opId < b.opId }
        func canonical(_ op: Op) -> String {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
            enc.outputFormatting = [.sortedKeys]
            return (try? enc.encode(op)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return canonical(a) < canonical(b)
    }

    /// Fold ops into a paragraph_id → text map and the current sequence.
    ///
    /// Order-independent by construction: derive sorts its input by the total
    /// `(opId, canonicalContent)` order itself before folding, so last-write-wins
    /// per paragraph is BY opId no matter what order the caller passes (no
    /// unenforced "caller must sort" precondition). Two devices with identical
    /// logs derive identical state.
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
        for op in ops.sorted(by: opOrder) {
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
    /// Now the `Document.load` derivation path (ADR 0019) as well as
    /// `RewindWindow`; for legacy sequence-less logs order is synthesized
    /// from first-appearance — the `.md` is no longer consulted for order.
    public static func deriveWithSequenceFallback(ops: [Op]) -> DerivedState {
        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        var synthesized: [String] = []
        var synthesizedSet: Set<String> = []
        var sequenceWasExplicit = false
        // Same internal opId-order sort as `derive(ops:)` for full determinism.
        // The first-appearance sequence synthesis below then runs over the
        // canonical order, so the fallback sequence is also order-independent.
        for op in ops.sorted(by: opOrder) {
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
                // Same junk-bootstrap guard as `derive(ops:)` — see that function's comment.
                if op.kind == .bootstrap && s.isEmpty {
                    continue
                }
                sequence = s
                sequenceWasExplicit = true
            }
        }
        if !sequenceWasExplicit {
            sequence = synthesized
        }
        return DerivedState(paragraphs: paragraphs, sequence: sequence)
    }

    /// Whether an op of this kind mutates the derived manuscript text.
    /// `internal` (not `private`) so the schema-evolution tests can assert the
    /// `.unknown` op is inert. The exhaustive switch is the compile-forcing
    /// gate for future kinds (ADR 0015).
    static func appliesToManuscript(_ kind: OpKind) -> Bool {
        switch kind {
        case .typingBurst, .bootstrap, .externalEdit,
             .checkpointRestore, .claudeAccept:
            return true
        case .checkpoint, .claudeSuggestion, .claudeComment,
             .claudeQuery, .claudeCraftNote, .claudeReject, .claudeArchive,
             .annotationEdit, .annotationWithdraw,
             .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            // annotationEdit/annotationWithdraw live purely in the annotation
            // projection (AnnotationDeriver) — they never touch derived .md.
            return false
        case .unknown:
            // An op kind written by a newer build. We can't know whether it
            // mutates the manuscript, so we treat it as inert — never apply it
            // to derived text. The op stays in the log (not quarantined) so the
            // newer build still sees it. When a future kind is added as a named
            // case, this exhaustive switch FAILS TO COMPILE here, forcing the
            // dev to classify it as manuscript-affecting or not. See ADR 0015.
            return false
        }
    }
}
