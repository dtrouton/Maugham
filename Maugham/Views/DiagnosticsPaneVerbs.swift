import SwiftUI
import MaughamCore

// MARK: - The pane's verbs and formatters — windowless, so each is a test without a press

extension DiagnosticsPane {
    /// `notes` in the order their paragraphs appear in the document, with the
    /// ones that name no live paragraph after them.
    ///
    /// Pure and static so the order is a direct assertion without a mount, and
    /// **stable within a rank**: `sorted(by:)` is not, and the tie is common —
    /// a round often raises two findings against one paragraph, and rows that
    /// swapped places between two renders of the same check would be the pane
    /// shuffling under a writer mid-read. Ties break on the annotation's own
    /// id — a ULID, monotonic within the process (`ULID.swift`) — which is
    /// mint order.
    ///
    /// **Deliberately NOT the incoming array's own order.** An earlier version
    /// broke ties on `notes`' position, reasoning that array order already
    /// WAS mint order — false: `queueAnnotations` reads
    /// `Document.annotations(filter:)`, and `AnnotationDeriver.derive` sorts
    /// its result **newest-first** for the queue's own purposes. Inheriting
    /// that array's order for a tie silently put the newest of two
    /// same-paragraph notes first — exactly the "queue-consistent
    /// newest-first" the manuscript-order ruling exists to NOT be. Caught by
    /// `test_theEmptyStateAcknowledgesACheckTheWriterHasHandled` failing with
    /// the wrong row surviving after two same-paragraph dispositions pressed
    /// in mint order.
    ///
    /// The trailing bucket is two cases with one honest answer: a doc-scoped
    /// craft note (the compiler's whole-piece observation, anchored to no
    /// paragraph by design) and a note whose paragraph has since left the
    /// sequence. Neither has a place in the prose, so both follow it.
    static func inManuscriptOrder(
        _ notes: [Annotation], sequence: [String]
    ) -> [Annotation] {
        var position: [String: Int] = [:]
        for (index, paragraphId) in sequence.enumerated() { position[paragraphId] = index }
        return notes.sorted { lhs, rhs in
            let left = lhs.paragraphId.flatMap { position[$0] } ?? Int.max
            let right = rhs.paragraphId.flatMap { position[$0] } ?? Int.max
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    /// The words a wet-ink row's jump chip carries — **never its paragraph
    /// id** (requirement 3, `test_noParagraphIdIsEverRendered`).
    ///
    /// A `Diagnostic` arrives carrying the excerpt the model quoted; an
    /// `Annotation` carries no excerpt at all, so the words come from the live
    /// paragraph through `currentText` — the closure this pane already holds
    /// for `DiagnosticsStore.live`'s staleness check, rather than a second
    /// reach for the document.
    ///
    /// `nil` in the two cases where a chip would be a button labelled nothing:
    /// a doc-scoped craft note (the compiler's anchorless finding — no
    /// paragraph to travel to) and a paragraph this pane cannot read. The row
    /// itself still jumps on a tap where there is an id.
    ///
    /// Trimmed by `truncatedDriftQuote`, whose budget is the right one for the
    /// same reason it is right there: one line of a narrow pane. `ExcerptChip`
    /// limits itself to a single line anyway, so the budget only decides where
    /// the ellipsis falls rather than what is legible.
    static func jumpExcerpt(
        for annotation: Annotation, currentText: (String) -> String?
    ) -> Diagnostic.Ref? {
        guard let paragraphId = annotation.paragraphId,
              let text = currentText(paragraphId) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Diagnostic.Ref(
            paragraphId: paragraphId, excerpt: truncatedDriftQuote(trimmed))
    }

    /// **Got it's verb, windowless** — what the row's button runs, pinned
    /// without a press (tripwire 33): the annotation layer's own accept, and
    /// nil when it settled, else the sentence the row shows.
    static func gotIt(annotationId: String, in document: Document,
                      undoManager: UndoManager?) async -> String? {
        do {
            try await document.acceptAnnotation(id: annotationId, undoManager: undoManager)
            return nil
        } catch let error as AnnotationAcceptError where error == .suggestionAnchorLost {
            documentLog.error("\u{201C}Got it\u{201D} refused for \(annotationId, privacy: .public): the suggestion's anchor is gone")
            return anchorLostRefusal
        } catch {
            documentLog.error("\u{201C}Got it\u{201D} failed for \(annotationId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return dispositionRefusal(error)
        }
    }

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

    /// The one refusal with a cause worth naming in the writer's terms rather
    /// than the error's — unreachable from this pane today (`gotIt`'s own
    /// doc), and spelled out so it cannot arrive as a raw `Error` string the
    /// day something mints a suggestion.
    static let anchorLostRefusal =
        "That didn\u{2019}t settle: the passage it points at has changed since "
        + "the note was written."

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

    /// One clause of the summary and every strain raised against it.
    struct ConformanceRow: Identifiable {
        /// Where this clause sat in the run's own list. Part of the identity
        /// and nothing else — the rows are never sorted by it.
        let position: Int
        let status: DiagnosticIngest.ClauseStatus
        let strains: [Diagnostic]
        /// **Position first, then the writer's sentence.** The quote alone is
        /// not unique: `conformanceRows` deliberately renders a clause the
        /// writer declared twice as two rows (see its doc), which handed
        /// SwiftUI's `ForEach` two identical ids — undefined behaviour for the
        /// duplicate the design intends to keep.
        var id: String { "\(position)\u{0}\(status.clauseQuote)" }
    }

    /// Pair every clause with the strains raised against it, and report any
    /// strain left over.
    ///
    /// Pure and returned as a value rather than assembled in the body, so the
    /// pairing — including the leftovers, which are the interesting half — is a
    /// direct test without a mount. Matching is on the quoted clause because
    /// that is the only thing the two records share: `DiagnosticIngest` mints a
    /// `ClauseStatus` and a `.conformanceStrain` from one entry and stamps both
    /// with the same `clause_quote`.
    ///
    /// Clauses keep the order the run reported them in; a duplicate quote (the
    /// writer declared the same sentence twice) takes the same strains on both
    /// rows rather than dropping one — a wrong-looking duplicate is a smaller
    /// harm than a missing finding.
    static func conformanceRows(
        clauses: [DiagnosticIngest.ClauseStatus], strains: [Diagnostic]
    ) -> (rows: [ConformanceRow], orphans: [Diagnostic]) {
        let quotes = Set(clauses.map(\.clauseQuote))
        let rows = clauses.enumerated().map { position, status in
            ConformanceRow(
                position: position, status: status,
                strains: strains.filter { $0.clauseQuote == status.clauseQuote })
        }
        let orphans = strains.filter { strain in
            guard let quote = strain.clauseQuote else { return true }
            return !quotes.contains(quote)
        }
        return (rows, orphans)
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

    /// The glyph for one clause's answer. Deliberately three quiet marks: a
    /// strain is something to look at, not an error, and an alarm here would be
    /// the pane raising its voice at the writer's own declaration.
    ///
    /// A status this build has never heard of gets a neutral mark rather than
    /// falling into one of the three — `DiagnosticIngest` drops those at ingest,
    /// so this arm is unreachable through the run and exists so a later
    /// contract's fourth word cannot silently render as "holds".
    static func statusSymbol(_ status: String) -> String {
        switch status {
        case DiagnosticIngest.SectionField.holds: return "checkmark"
        case DiagnosticIngest.SectionField.strains: return "arrow.left.and.right"
        case DiagnosticIngest.SectionField.silent: return "circle.dashed"
        default: return "questionmark"
        }
    }

    /// What that glyph says aloud — VoiceOver reads this, and a mark alone is
    /// silent.
    static func statusWord(_ status: String) -> String {
        switch status {
        case DiagnosticIngest.SectionField.holds: return "holds"
        case DiagnosticIngest.SectionField.strains: return "strains"
        case DiagnosticIngest.SectionField.silent:
            return "nothing in this draft touches it"
        default: return status
        }
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
    /// **Whether Got it and Not this are drawn** (P3c Task 7, controller
    /// ruling Q) — `.acceptOrReject` of THIS document, the verb the queue
    /// row asks for the same two acts (`AnnotationRowVerbs.decide`). Hidden,
    /// never disabled; the `Document`'s own door refuses a press that arrives
    /// anyway (`Document.PostureRefusal`).
    static func offersDisposal(_ posture: DiagnosticsPostures) -> Bool {
        posture.document.allows(.acceptOrReject)
    }

    /// **Whether Answer is drawn, by WHO** (P3c Task 7) — the posture half of
    /// the question, beside `offersAnAnswer(_:)`'s kind half. An answer files a
    /// ruling in this piece's own intent (`commitAnswer`), so it asks
    /// `.editStatement` of THAT statement: a piece statement follows its piece.
    /// **Whether Promote to Task and the letter's Accept as task are drawn**
    /// (P3c Task 8, controller ruling U) — `.task` of THIS document, where
    /// both file the task (`createPaneTask`). Hidden, never disabled; the
    /// `Document`'s task door refuses a press that arrives anyway.
    static func offersATask(_ posture: DiagnosticsPostures) -> Bool {
        posture.document.allows(.task)
    }

    static func offersAnAnswer(docId: String, posture: DiagnosticsPostures) -> Bool {
        posture.statement(.intent, .document(docId)).allows(.editStatement)
    }

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

    /// **The jump, windowless** (tripwire 33, #120) — what every excerpt
    /// chip on the pane reaches through its `onJump`.
    static func jump(toParagraph pid: String) {
        // Reuses `AnnotationsPane.jump`'s event rather than a copy — span
        // precision is that pane's alone; a diagnostic anchors a whole
        // paragraph.
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: ["paragraph_id": pid])
    }
}
