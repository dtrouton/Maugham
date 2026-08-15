import Foundation
import os

/// Diagnostic channel for derivation anomalies (F3: partial-sync bootstrap
/// re-mints). MaughamCore is otherwise wall-clock- and side-effect-free; a
/// `Logger` line is the lightest surface that doesn't change `DerivedState`'s
/// shape or every caller's signature.
// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit). Mirrors the Mac side's
// `documentLog`; MaughamCore links into whichever variant's bundle is running.
private let deriverLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "Deriver")

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
    /// the live paragraph. Same for `claude_archive`, which always carries
    /// empty changes. claude_accept of a suggested change DOES mutate the
    /// manuscript and is included — and so, since RULING-33, does
    /// `claude_reject`: the writer's own rejects still carry nothing, but the
    /// post-merge convergence repair issues one carrying the inverse of the
    /// accept it beat. See `appliesToManuscript`.
    public static func derive(ops: [Op]) -> DerivedState {
        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        var sawBootstrap = false
        for op in ops.sorted(by: opOrder) {
            // F3 — first-bootstrap-wins. A doc bootstraps exactly once; any
            // LATER `.bootstrap` op is a partial-sync re-mint (iCloud delivered
            // the clean `.md` before `.maugham/ops/`, so device B re-minted every
            // ¶id). Skip its SEQUENCE — the re-mint must not win ordering — but
            // KEEP its changes (paragraph text), so a subsequent burst carrying an
            // explicit sequence of the re-minted ids renders full content instead
            // of a near-empty doc (Minor 4). Ordered by opId (ULID), so the FIRST
            // bootstrap is the original; the original sequence therefore still
            // orders the doc. Residual risk: with no post-re-mint edit the kept
            // re-mint texts are orphan paragraphs (ids not in the surviving
            // sequence) that `Document.reconcile` drops; WITH a post-re-mint edit
            // the doc degrades to content-preserved-under-new-ids (an annotation
            // archive) rather than the near-empty render the old drop-changes
            // behavior produced (ADR 0019 addendum).
            var skipSequence = false
            if op.kind == .bootstrap {
                if sawBootstrap {
                    deriverLog.error(
                        "ignoring re-mint bootstrap op \(op.opId, privacy: .public) for doc \(op.docId, privacy: .public) — first-bootstrap-wins (keeping its changes as orphan text, dropping its ordering)")
                    skipSequence = true
                } else {
                    sawBootstrap = true
                }
            }
            if Deriver.appliesToManuscript(op.kind) {
                for change in op.changes {
                    paragraphs[change.paragraphId] = change.next
                }
            }
            if let s = op.sequence, !skipSequence {
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
        var sawBootstrap = false
        // Same internal opId-order sort as `derive(ops:)` for full determinism.
        // The first-appearance sequence synthesis below then runs over the
        // canonical order, so the fallback sequence is also order-independent.
        for op in ops.sorted(by: opOrder) {
            // F3 — first-bootstrap-wins (see `derive(ops:)` for the rationale):
            // skip a re-mint's SEQUENCE, keep its changes (Minor 4).
            var skipSequence = false
            if op.kind == .bootstrap {
                if sawBootstrap {
                    deriverLog.error(
                        "ignoring re-mint bootstrap op \(op.opId, privacy: .public) for doc \(op.docId, privacy: .public) — first-bootstrap-wins (keeping its changes as orphan text, dropping its ordering)")
                    skipSequence = true
                } else {
                    sawBootstrap = true
                }
            }
            if Deriver.appliesToManuscript(op.kind) {
                for change in op.changes {
                    paragraphs[change.paragraphId] = change.next
                    if !synthesizedSet.contains(change.paragraphId) {
                        synthesized.append(change.paragraphId)
                        synthesizedSet.insert(change.paragraphId)
                    }
                }
            }
            if let s = op.sequence, !skipSequence {
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
    /// `public` because derive is no longer the only reader: the compiler's
    /// `DeltaBuilder` asks the same question of the same op stream, and a
    /// target-local copy of this switch would be free to drift out of the
    /// compile-forcing gate below. The exhaustive switch is that gate for
    /// future kinds (ADR 0015); the schema-evolution tests assert `.unknown`
    /// is inert through it.
    public static func appliesToManuscript(_ kind: OpKind) -> Bool {
        switch kind {
        // `.claudeReject` is here for RULING-33 and for nothing else. Every
        // reject a writer issues carries `changes: []`, so folding it is a
        // no-op and this classification changes nothing for them. The one
        // reject that carries a payload is the convergence repair
        // (`Document.repairRejectedButSplicedAnnotations`): when a reject beats
        // an accept whose text was already spliced, the STATUS WINNER DECIDES
        // THE TEXT, which it can only do if a reject is allowed to move it.
        // Manifest schemaVersion 5 is the gate that keeps an older build —
        // which folds none of this — from opening such a project.
        case .typingBurst, .bootstrap, .externalEdit,
             .checkpointRestore, .claudeAccept, .claudeAcceptRevert,
             .claudeReject:
            return true
        case .checkpoint, .claudeSuggestion, .claudeComment,
             .claudeQuery, .claudeCraftNote, .claudeArchive,
             .annotationEdit, .annotationWithdraw, .annotationReopen,
             .annotationStet, .annotationTriage,
             .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            // annotationEdit/annotationWithdraw/annotationReopen live purely
            // in the annotation projection (AnnotationDeriver) — they never
            // touch derived .md. So do annotationStet and annotationTriage
            // (M3 P2): a stet's whole point is that the WORDS DO NOT CHANGE,
            // and a triage is a mark on a note, not on the prose.
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
