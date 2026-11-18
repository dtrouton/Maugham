// Static-only by rule (#116): no instance members — instance state stays in the root.
import SwiftUI
import MaughamCore

// MARK: - The pane's verbs and formatters — windowless, so each is a test without a press

extension CheckNarrative {
    /// **What a refused disposition says in the row it was pressed in** (M4 P2
    /// Task 1 review, Minor 2).
    ///
    /// The log is not a surface. A Got it that the op log refused leaves the
    /// row exactly where it was — which is correct, the note did not settle —
    /// and without a sentence beside it that reads as a button that did
    /// nothing, so the writer presses it again. It names what did not happen
    /// rather than the mechanism, and carries the error's own words after it
    /// because a refusal with no detail cannot be acted on.
    static func dispositionRefusal(_ error: Error) -> String {
        "That didn\u{2019}t settle: \(error.localizedDescription)"
    }

    /// **Not this's verb, windowless** — what the row's button runs, pinned
    /// without a press (tripwire 33): the annotation layer's own reject, and
    /// nil when it settled, else the sentence the row shows.
    static func notThis(annotationId: String, in document: Document,
                        undoManager: UndoManager?) async -> String? {
        do {
            try await document.rejectAnnotation(id: annotationId, undoManager: undoManager)
            return nil
        } catch {
            documentLog.error("\u{201C}Not this\u{201D} failed for \(annotationId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return dispositionRefusal(error)
        }
    }

    // MARK: - Drift (spec §4's last bullet; findings computed by `DriftDetector`)

    /// **The one line above the conformance summary when a clause is
    /// drifting** — pinned to `findings.first`, in the order
    /// `DriftDetector.drift` reports it (the newest run's own clause order).
    /// With more than one, "and one more" says a second is drifting without
    /// counting how many — two findings and five read identically, the same
    /// discipline the pane's now-deleted reader section once kept with its
    /// own "The reader had more to say." line (M4 P1 Task 3): how many is
    /// forensic detail the writer did not ask for.
    ///
    /// **No count beyond the fixed "three runs" is ever spoken**, either —
    /// not `DriftFinding.runsStraining`'s true streak length, which the
    /// detector reports honestly and can run past the threshold (its own
    /// doc: "the pane ... can choose to say so"; this pane chooses not to,
    /// for the reason above).
    static func driftNote(_ findings: [DriftFinding]) -> String? {
        guard let first = findings.first else { return nil }
        let quote = truncatedDriftQuote(first.clauseQuote)
        let andOneMore = findings.count > 1 ? " \u{2014} and one more" : ""
        return "Your line may have moved \u{2014} \u{201C}\(quote)\u{201D} has strained "
            + "three runs running\(andOneMore). Draft\u{2019}s right, or intent\u{2019}s right?"
    }

    /// How much of the clause the drift line's one sentence can carry —
    /// smaller than `IntentStrip.maximumLength` because this quote sits
    /// inside a longer sentence rather than filling a strip on its own.
    private static let driftQuoteMaxLength = 60

    /// `quote` if it fits, else cut at the last word boundary inside the
    /// budget and ellipsised — `IntentStrip.truncated`'s idiom, restated here
    /// because that one is `private` to its own file and the two truncate
    /// different budgets for different reasons.
    static func truncatedDriftQuote(_ quote: String) -> String {
        guard quote.count > driftQuoteMaxLength else { return quote }
        let head = String(quote.prefix(driftQuoteMaxLength))
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "\u{2026}" }
        let cut = String(head[head.startIndex..<lastSpace])
            .trimmingCharacters(in: .whitespaces)
        return (cut.isEmpty ? head : cut) + "\u{2026}"
    }

    // **`readerKindLabel` is gone with the section it labelled** (M4 P1
    // Task 3). `Diagnostic.category` is set by the ingest for a reader report
    // and for nothing else, and a reader report no longer reaches this pane —
    // so the label had no row left to sit above. The reader's two kinds are
    // still CONTENT and still parsed (`DiagnosticIngest.SectionField
    // .dreamBreak`/`.belief`); what changed is where the report is read.

    /// **Which notes offer to be answered** — a conformance strain, and only
    /// it (spec §5's fates, narrowed by M4 P1 Task 3).
    ///
    /// A conformance strain is read beside the clause it strains against, and
    /// the writer's reply to it is a decision: it lands as a ruling. A
    /// continuity question and a reader report are both about the WORDS
    /// rather than a declared clause — they now mint as pass-stamped
    /// annotations at the end of a run (`strains`'s own doc) and never reach
    /// this pane as a `Diagnostic` row, so a `.continuity` arm answering
    /// `true` here was dead: nothing upstream ever hands this function a
    /// continuity note. A reader report was never answerable either way —
    /// "I stopped believing her here" has no answer to rule on, and a reply
    /// field under one would invite the writer to argue with a reader, which
    /// is not a decision that belongs in the declared world.
    static func offersAnAnswer(_ diagnostic: Diagnostic) -> Bool {
        switch diagnostic.kind {
        case .conformanceStrain: return true
        case .continuity, .readerReport, .letterQuestion, .none: return false
        }
    }

    /// The paragraph a click on `diagnostic` should jump to, or `nil` for a note
    /// that named none. Split out as a pure static so the mapping is a direct
    /// unit test without mounting a view or simulating a tap gesture, which
    /// SwiftUI does not expose the way it does a `Button`'s press.
    static func paragraphToNavigateTo(for diagnostic: Diagnostic) -> String? {
        diagnostic.anchor?.paragraphId
    }

    // MARK: - The answer, which is a ruling

    /// What the ruling's line says about where it came from — a builder
    /// rather than a constant (M4 P1 Task 6), because *"answered a compiler
    /// note"* alone left the reader with no idea which note: a real defect
    /// this shipped with (Tribute) read "The reader is supposed to read this
    /// as it covering up" in the Intent pane, the ruling text's own dangling
    /// *this* with nothing beside it naming what it answered.
    ///
    /// **It names no paragraph, and that is requirement 3 rather than a
    /// shortfall.** The shim this replaced left a note anticipating *"from a run
    /// on ¶wnse"* — but a ruling's provenance is prose the writer reads, in the
    /// Intent pane, for as long as the decision stands, and a bare id is exactly
    /// what v2 took off every surface. The DATE is not restated here either:
    /// `RulingsSection` stamps every line with `ruled <d MMM yyyy>`, so a
    /// provenance carrying one too would print the day twice.
    ///
    /// **The excerpt is the note's own `clauseQuote`** — a conformance strain's
    /// clause, the only answerable kind post-Task-3 (`offersAnAnswer`) and the
    /// only one that carries one. Trimmed to `driftQuoteMaxLength` (60,
    /// `truncatedDriftQuote`'s own budget — the same idiom, restated for the
    /// same reason it already is here) and with every em-dash collapsed to a
    /// plain hyphen: `RulingsSection.parseItem` splits an item on its
    /// RIGHT-MOST "—", so an excerpt that still carried one could shift that
    /// split point into the quote and cut the writer's own sentence off
    /// mid-word. A `nil` `clauseQuote` — a v1 sidecar record, or a future note
    /// kind that answers without one — falls back to the bare legacy line.
    static func answeredNoteProvenance(for diagnostic: Diagnostic) -> String {
        guard let quote = diagnostic.clauseQuote, !quote.isEmpty else {
            return "answered a compiler note"
        }
        let sanitized = quote.replacingOccurrences(of: "\u{2014}", with: "-")
        let excerpt = truncatedDriftQuote(sanitized)
        return "answered a compiler note: \u{00AB}\(excerpt)\u{00BB}"
    }

    /// **Write the writer's answer into the piece's rulings, and take the note
    /// off the pane once it is there** — the loop this milestone exists for.
    ///
    /// A `static` taking everything it touches, so the whole of it is a direct
    /// test against a real `ProjectStore` and a real `DiagnosticsStore`. SwiftUI
    /// exposes no way to deliver a Return keystroke into a hosted `TextField`'s
    /// editor, so a commit written inline in the field's `.onSubmit` would be
    /// the one part of this path nothing could drive.
    ///
    /// **Through `RulingPerformer.rule`, which is the only door into the
    /// writer-owned layer** (spec §3.4). The answer arrives itemized, dated and
    /// carrying where it came from, under `## Rulings` — never as a paragraph
    /// appended to the essay the writer wrote, which is what shipped in M2 and
    /// what §3.4 names as the membrane's loosest point.
    ///
    /// **The dismissal is conditional on the write, and the order is the
    /// contract.** A note dismissed before the ruling could lose both the note
    /// and the answer to one refusal; dismissed after, the worst case is a note
    /// the writer answers twice. Returns the refusal's own sentence, or `nil`.
    ///
    /// Asymmetric about undo for `promote`'s reason: the answer is an op in the
    /// statement's log and ⌘Z reaches it there, while the dismissal is
    /// per-device derived state with no undo of its own — a ⌘Z that resurrected
    /// the note would claim the compiler had re-checked something it has not
    /// looked at since.
    static func commitAnswer(
        _ text: String, to diagnostic: Diagnostic, docId: String,
        store: ProjectStore, world: DeclaredWorldStore?, diagnostics: DiagnosticsStore
    ) async -> String? {
        do {
            try await RulingPerformer.rule(
                text, provenance: answeredNoteProvenance(for: diagnostic),
                kind: .intent, forScope: .document(docId), store: store, world: world)
        } catch {
            return error.localizedDescription
        }
        diagnostics.dismiss(diagnostic.id, docId: docId)
        return nil
    }
}
