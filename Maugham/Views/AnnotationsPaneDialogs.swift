import SwiftUI
import MaughamCore

/// **Every sheet and alert `AnnotationsPane`'s rows raise** — moved whole out
/// of the pane's `body`, in the same order and at the same place in its
/// modifier chain. Owns no state: each presentation is a binding to the pane's
/// own `@State`, and every answer reaches the pane's verbs.
@MainActor
struct AnnotationsPaneDialogs: ViewModifier {
    let store: ProjectStore
    let verbs: AnnotationsPaneVerbs
    @Binding var rejectSheet: AnnotationsPane.AnnotationTarget?
    @Binding var querySheet: AnnotationsPane.AnnotationTarget?
    @Binding var rulingSheet: AnnotationsPane.AnnotationTarget?
    @Binding var rulingNotice: String?
    @Binding var choiceOffer: ChoiceOffer?
    @Binding var ledgerNotice: String?
    @Binding var keepLessonSheet: AnnotationsPane.AnnotationTarget?
    @Binding var staleConfirm: AnnotationsPane.AnnotationTarget?
    @Binding var anchorLostNotice: AnnotationsPane.AnnotationTarget?
    @Binding var revertConfirm: AnnotationsPane.AnnotationTarget?
    @Binding var bulkNotice: String?
    @Binding var editSheet: AnnotationsPane.AnnotationTarget?
    @Binding var withdrawConfirm: AnnotationsPane.AnnotationTarget?

    func body(content: Content) -> some View {
        content
        .sheet(item: $rejectSheet) { target in
            RejectReasoningSheet(annotation: target.annotation) { reason in
                verbs.reject(target.document, target.annotation, reason: reason)
                rejectSheet = nil
            } onCancel: { rejectSheet = nil }
        }
        .sheet(item: $querySheet) { target in
            QueryReplySheet(annotation: target.annotation) { reply in
                verbs.replyToQuery(target.document, target.annotation, reply: reply)
                querySheet = nil
            } onCancel: { querySheet = nil }
        }
        .sheet(item: $rulingSheet) { target in
            // The destination is what opened the sheet, so it is there; the
            // fallback draws a sheet that will refuse in `commit`'s own words
            // rather than crashing on the writer's sentence.
            QueryRulingSheet(
                annotation: target.annotation,
                confirmation: RulingDestination.offered(
                    for: target.annotation, manifest: store.manifest)?
                    .confirmation ?? ""
            ) { answer in
                verbs.answerAsRuling(target.document, target.annotation, answer: answer)
                rulingSheet = nil
            } onCancel: { rulingSheet = nil }
        }
        .alert(
            "That answer could not be filed",
            isPresented: Binding(
                get: { rulingNotice != nil },
                set: { if !$0 { rulingNotice = nil } })
        ) {
            Button("OK") { rulingNotice = nil }
        } message: {
            Text(rulingNotice ?? "")
        }
        // **The second stet's offer** (editorial letter P2 Task 8, spec §6).
        // An alert rather than an `NSAlert`: the answer has to be observable
        // from a test, and a panel the headless worker has to dismiss is a
        // gate that hangs.
        //
        // **Three buttons, and Cancel is the one that carries `.cancel`**
        // (Denver's ruling, fix round 1). Escape ABANDONS: the offer goes away
        // and the note is left exactly as the writer found it. Giving the role
        // to **Just stet** would make Escape settle a note — a keystroke that
        // resolves something is not a way out of a question, and the writer who
        // hit it to make the dialog go away would find the note gone from their
        // queue. Both real answers are pressed on purpose.
        .alert(
            QueueLedgerVerbs.secondStetTitle(choiceOffer?.heading ?? ""),
            isPresented: Binding(
                get: { choiceOffer != nil },
                set: { if !$0 { verbs.setChoiceOffer(nil) } }),
            presenting: choiceOffer
        ) { offer in
            Button(QueueLedgerVerbs.makeItAChoiceTitle, action: offer.makeItAChoice)
            Button(QueueLedgerVerbs.justStetTitle, action: offer.justStet)
            Button(QueueLedgerVerbs.cancelTitle, role: .cancel,
                   action: offer.cancel)
        } message: { _ in
            Text(QueueLedgerVerbs.secondStetHelp)
        }
        .alert(
            "That could not be filed in your ledger",
            isPresented: Binding(
                get: { ledgerNotice != nil },
                set: { if !$0 { ledgerNotice = nil } })
        ) {
            Button("OK") { ledgerNotice = nil }
        } message: {
            Text(ledgerNotice ?? "")
        }
        .sheet(item: $keepLessonSheet) { target in
            LessonHeadingSheet(annotation: target.annotation) { heading in
                verbs.keepAsLesson(target.annotation, heading: heading)
                keepLessonSheet = nil
            } onCancel: { keepLessonSheet = nil }
        }
        .alert(
            "Paragraph has changed since this suggestion",
            isPresented: Binding(
                get: { staleConfirm != nil },
                set: { if !$0 { staleConfirm = nil } })
        ) {
            Button("Apply anyway") {
                if let target = staleConfirm {
                    Task { await verbs.performAccept(target.document, target.annotation) }
                }
                staleConfirm = nil
            }
            Button("Cancel", role: .cancel) { staleConfirm = nil }
        } message: {
            Text("Applying this suggestion will replace the current paragraph text with the originally-proposed replacement.")
        }
        .alert(
            "This suggestion can no longer be applied",
            isPresented: Binding(
                get: { anchorLostNotice != nil },
                set: { if !$0 { anchorLostNotice = nil } })
        ) {
            Button("OK") { anchorLostNotice = nil }
        } message: {
            Text(anchorLostMessage)
        }
        .alert(
            "Paragraph has changed since this suggestion was accepted",
            isPresented: Binding(
                get: { revertConfirm != nil },
                set: { if !$0 { revertConfirm = nil } })
        ) {
            Button("Revert anyway") {
                if let target = revertConfirm {
                    verbs.performRevert(target.document, target.annotation)
                }
                revertConfirm = nil
            }
            Button("Cancel", role: .cancel) { revertConfirm = nil }
        } message: {
            Text("Reverting will replace the current paragraph text with what it was before the accept. Edits made since the accept will be lost.")
        }
        .alert(
            "Not everything in the batch could be done",
            isPresented: Binding(
                get: { bulkNotice != nil },
                set: { if !$0 { bulkNotice = nil } })
        ) {
            Button("OK") { bulkNotice = nil }
        } message: {
            Text(bulkNotice ?? "")
        }
        .sheet(item: $editSheet) { target in
            EditAnnotationSheet(annotation: target.annotation) { newBody, newSuggested in
                verbs.editOwn(target.document, target.annotation,
                        newBody: newBody, newSuggested: newSuggested)
                editSheet = nil
            } onCancel: { editSheet = nil }
        }
        .alert(
            "Delete your annotation",
            isPresented: Binding(
                get: { withdrawConfirm != nil },
                set: { if !$0 { withdrawConfirm = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let target = withdrawConfirm {
                    verbs.withdrawOwn(target.document, target.annotation)
                }
                withdrawConfirm = nil
            }
            Button("Cancel", role: .cancel) { withdrawConfirm = nil }
        } message: {
            Text("This removes your annotation. The history is preserved, but the annotation will no longer appear here or in the editor.")
        }
    }

    private var anchorLostMessage: String {
        let quoted: String
        if let quote = anchorLostNotice?.annotation.span?.quote, !quote.isEmpty {
            quoted = " (\u{201C}\(quote)\u{201D})"
        } else {
            quoted = ""
        }
        return "The passage it would replace\(quoted) is no longer in the "
            + "paragraph, so applying it could put the replacement in the wrong "
            + "place. The suggestion stays open — ask Claude for a fresh one "
            + "against the current text."
    }
}

@MainActor
private struct RejectReasoningSheet: View {
    let annotation: Annotation
    let onReject: (String) -> Void
    let onCancel: () -> Void
    @State private var reason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why are you rejecting this?")
                .font(.headline)
            Text("Your reasoning is saved with the annotation so Claude can see it in future sessions.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $reason)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Reject") {
                    onReject(reason.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}

/// Inline editor for the reviewer's own annotation (author self-service).
/// Pre-fills the body; for a suggested change, also exposes the replacement
/// text. On commit delivers (newBody, newSuggested?) where newSuggested is nil
/// for non-suggestion kinds. Mirrors the look of the reject/reply sheets.
@MainActor
private struct EditAnnotationSheet: View {
    let annotation: Annotation
    /// (newBody, newSuggestedText?) — newSuggestedText is nil unless this is a
    /// suggested change.
    let onCommit: (String, String?) -> Void
    let onCancel: () -> Void
    @State private var noteBody: String
    @State private var suggested: String

    init(
        annotation: Annotation,
        onCommit: @escaping (String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.annotation = annotation
        self.onCommit = onCommit
        self.onCancel = onCancel
        _noteBody = State(initialValue: AnnotationRow.displayText(annotation.body))
        _suggested = State(initialValue:
            annotation.suggestedText.map(AnnotationRow.displayText) ?? "")
    }

    private var isSuggestion: Bool { annotation.kind == .suggestedChange }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit your \(annotation.kind.displayName.lowercased())")
                .font(.headline)
            Text("Only you can edit or delete your own annotations.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Note")
                .font(.caption.smallCaps()).foregroundStyle(.secondary)
            TextEditor(text: $noteBody)
                .frame(minHeight: 70)
                .border(Color.gray.opacity(0.3))
            if isSuggestion {
                Text("Replacement text")
                    .font(.caption.smallCaps()).foregroundStyle(.secondary)
                TextEditor(text: $suggested)
                    .frame(minHeight: 50)
                    .border(Color.gray.opacity(0.3))
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onCommit(
                        noteBody.trimmingCharacters(in: .whitespacesAndNewlines),
                        isSuggestion ? suggested : nil)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}

@MainActor
private struct QueryReplySheet: View {
    let annotation: Annotation
    let onReply: (String) -> Void
    let onCancel: () -> Void
    @State private var reply: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply")
                .font(.headline)
            Text(annotation.body)
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $reply)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Reply") {
                    onReply(reply.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}
