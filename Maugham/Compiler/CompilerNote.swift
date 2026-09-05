import Foundation
import MaughamCore

/// **A finding on its way out of the compiler and into the writer's notes**
/// (M4 P1 Task 3).
///
/// The second draft put every finding on the Diagnostics pane, in a per-device
/// sidecar the next run wholly superseded. Two of the three kinds do not belong
/// there: a continuity question and a reader's report are about the WORDS, they
/// outlive the check that raised them, and the writer answers them in the same
/// place they answer every other note about their prose. So they leave the
/// sidecar entirely and become annotations — pass-stamped, op-logged, synced,
/// and durable. **One finding, one home.**
///
/// This is the value that crosses that seam: what a mint needs and nothing
/// else. It is deliberately NOT a `Diagnostic` (that type carries a run id, a
/// staleness anchor and a sidecar identity, none of which an annotation wants)
/// and NOT an `Annotation` (which is derived from ops and cannot be
/// constructed by a caller).
///
/// **Whole-paragraph anchors only.** The entries carry their quotations in
/// prose — the schema has no span field — so a note anchors to the paragraph
/// its first resolving ref named, exactly as the sidecar note did. Minting a
/// span would mean guessing where in the paragraph the model meant, and a
/// guessed span is a note pointing at the wrong sentence.
struct CompilerNote: Equatable, Sendable {
    /// `.query` for a continuity question, `.comment` for a reader's report,
    /// and `.craftNote` for either when it named no paragraph at all.
    ///
    /// The first two are the register: a question asks the writer something and
    /// its reply is a decision; a report does not ask anything. The third is
    /// the SHAPE: `.query` and `.comment` are paragraph-scoped and
    /// `Document.addAnnotation` refuses one with no id, so an anchorless
    /// finding minted as either is a finding destroyed on its way out — and a
    /// whole-piece observation ("the outline promised a scene that never got
    /// written") is exactly what a doc-scoped craft note is for.
    let kind: AnnotationKind
    /// The paragraph the note is anchored to — the first ref that resolved
    /// against the live document at ingest. `nil` only for a `.craftNote`,
    /// which is doc-scoped and takes none.
    let paragraphId: String?
    /// The model's own words: the question, or the report — the reader's
    /// prefixed with its kind, so the label the pane used to draw above the
    /// row travels with the note instead of being lost at the seam.
    let body: String
    /// **The one identity spelling** (`RoundFingerprint.stringValue`), stamped
    /// on the op so a later round can recognise the same finding without
    /// reading its prose — the model rewords a question every time it raises
    /// it.
    ///
    /// `nil` when the finding has no discriminator (no anchor and no clause
    /// quote). Such a note mints normally and simply takes no part in the
    /// dedupe, which is `RoundFingerprint.make`'s own abstention rather than a
    /// second rule: a fingerprint of "nothing" is a bucket, and every
    /// unidentifiable note in a round would collapse into it.
    let fingerprint: String?
    /// **The habit heading the finding was raised under**, carried to the mint
    /// so it can be stamped on the note's op (editorial letter P2). Set only
    /// for a letter question the run raised out of the piece's lessons ledger;
    /// nil for a continuity question, a reader's report and every note a
    /// person wrote.
    ///
    /// Carried rather than derived from `kind`: a letter question raised out
    /// of nothing in the ledger has none either, and inferring one from the
    /// section would put a heading on a note that was never about it.
    let lessonHeading: String?

    init(kind: AnnotationKind, paragraphId: String?, body: String,
         fingerprint: String?, lessonHeading: String? = nil) {
        self.kind = kind
        self.paragraphId = paragraphId
        self.body = body
        self.fingerprint = fingerprint
        self.lessonHeading = lessonHeading
    }

    /// The reader's own kind, as words — and **nothing else**. v2 mints no
    /// free-form category (spec §5: the tag is "removed from the shipped
    /// design"), so a value from anywhere but the schema gets no label rather
    /// than putting the old tag in front of the writer through a side door.
    ///
    /// **Four kinds since two loops P2** (spec §4.3): the two a continuity
    /// editor reports, plus the two the first reader's instruction asks for by
    /// name. This switch is the label half of `DiagnosticIngest.readerKinds` —
    /// a kind the parser accepts and this function cannot name would reach the
    /// writer as a bare report with the label silently missing.
    ///
    /// It lives here rather than on the pane because the label is now part of
    /// what the note SAYS: the reader's reports leave for the queue, and a
    /// "Belief" heading rendered on a surface they no longer reach would be a
    /// label with nothing under it.
    static func readerKindLabel(_ category: String?) -> String? {
        switch category {
        case DiagnosticIngest.SectionField.dreamBreak: return "Dream break"
        case DiagnosticIngest.SectionField.belief: return "Belief"
        case DiagnosticIngest.SectionField.drag: return "Drag"
        case DiagnosticIngest.SectionField.lost: return "Lost"
        default: return nil
        }
    }

    /// The accepted diagnostic this run raised, as the note it is about to
    /// become — or `nil` for a conformance strain, which stays in the sidecar,
    /// and for a v1 record, which has no section at all.
    ///
    /// **An anchorless finding becomes a doc-scoped craft note**, whatever
    /// section raised it. The schema lets an entry name no paragraph, and both
    /// `.query` and `.comment` are paragraph-scoped: minting one of those with
    /// a nil id throws `paragraphNotFound`, so the mint's own failure arm would
    /// swallow exactly the notes that are about the piece as a whole. A craft
    /// note is what that observation IS.
    ///
    /// **Accepted residual, ledgered rather than fought:** an anchorless
    /// finding has no fingerprint (`RoundFingerprint.make` refuses one, and for
    /// its own good reason — a fingerprint with no discriminator is a bucket
    /// every such note falls into), so the dedupe cannot see it. A warm round
    /// is protected by the dispositions briefing; a Fresh Eyes reread may
    /// duplicate one, and the writer disposes of it.
    init?(diagnostic: Diagnostic) {
        let sectionKind: AnnotationKind
        switch diagnostic.kind {
        case .continuity: sectionKind = .query
        // The letter's own question, on the continuity question's rule and
        // for the same reason: it asks the writer something, and what the
        // writer does about it is a decision. Constraint 8 keeps the
        // anchorless case away from here — a letter question whose refs all
        // failed to resolve mints no `Diagnostic` at all — but the craft-note
        // fallback below still covers it correctly if one ever arrives.
        case .letterQuestion: sectionKind = .query
        case .readerReport: sectionKind = .comment
        case .conformanceStrain, .none: return nil
        }
        let paragraphId = diagnostic.anchor?.paragraphId
        // **The reader's label travels in the body.** The pane used to draw it
        // above the row; the row is gone, and a `dream_break` the writer never
        // sees is a distinction the model was asked to make for nothing.
        let label = diagnostic.kind == .readerReport
            ? Self.readerKindLabel(diagnostic.category)
            : nil
        self.init(
            kind: paragraphId == nil ? .craftNote : sectionKind,
            paragraphId: paragraphId,
            body: label.map { "\($0) \u{2014} \(diagnostic.body)" } ?? diagnostic.body,
            fingerprint: RoundFingerprint.make(of: diagnostic)?.stringValue,
            lessonHeading: diagnostic.lessonHeading)
    }
}

/// What one mint needs to know about the run that produced it.
///
/// Everything here is minted at the keystroke (`CompilerOrchestrator.beginRun`)
/// and carried — the lane, the round number, the editor's name and whether the
/// round was read cold. Asking any of it again at mint time would read a
/// project the writer may have moved on since the check began.
struct CompilerMintContext: Equatable, Sendable {
    let docId: String
    /// The run these notes came from — `CompilerRun.id`, so a note and the
    /// report it was raised in name the same check.
    let runId: String
    /// The review pass the round belonged to, or `nil` for a passless ⌘R. An
    /// unstamped note appears in every pass's queue, which is what a note
    /// raised outside any pass should do.
    let passId: String?
    let round: Int?
    let freshEyes: Bool
    /// **The bucket the writer filters by** — the active pass's
    /// `effectiveEditorName` ("Gould" for a copyedit round), or "Claude" for a
    /// passless run, which is M2's identity and the label
    /// `AnnotationAuthorPresentation` already gives a nil author.
    let editorName: String

    init(docId: String, runId: String, passId: String?, round: Int?,
         freshEyes: Bool, editorName: String) {
        self.docId = docId
        self.runId = runId
        self.passId = passId
        self.round = round
        self.freshEyes = freshEyes
        self.editorName = editorName
    }
}
