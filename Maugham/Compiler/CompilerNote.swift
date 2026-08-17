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
    /// `.query` for a continuity question, `.comment` for a reader's report.
    /// The mapping is the register: a question asks the writer something and
    /// its reply is a decision; a report does not ask anything.
    let kind: AnnotationKind
    /// The paragraph the note is anchored to — the first ref that resolved
    /// against the live document at ingest. `nil` for a note that named no
    /// paragraph at all, which the schema permits.
    let paragraphId: String?
    /// The model's own words: the question, or the report.
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

    init(kind: AnnotationKind, paragraphId: String?, body: String, fingerprint: String?) {
        self.kind = kind
        self.paragraphId = paragraphId
        self.body = body
        self.fingerprint = fingerprint
    }

    /// The accepted diagnostic this run raised, as the note it is about to
    /// become — or `nil` for a conformance strain, which stays in the sidecar,
    /// and for a v1 record, which has no section at all.
    ///
    /// A note the schema allowed to name no paragraph is minted anchorless
    /// only if the annotation layer can hold one; `Document.addAnnotation`
    /// refuses a paragraph-scoped kind with no id, so such a note fails its own
    /// mint and is counted rather than silently reshaped into a craft note.
    init?(diagnostic: Diagnostic) {
        let kind: AnnotationKind
        switch diagnostic.kind {
        case .continuity: kind = .query
        case .readerReport: kind = .comment
        case .conformanceStrain, .none: return nil
        }
        self.init(
            kind: kind,
            paragraphId: diagnostic.anchor?.paragraphId,
            body: diagnostic.body,
            fingerprint: RoundFingerprint.make(of: diagnostic)?.stringValue)
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
