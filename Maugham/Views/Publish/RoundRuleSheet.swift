import SwiftUI

/// **"Make it a rule": one round's finding becomes doctrine for the edition**
/// (translation pipeline P4 Task 3).
///
/// `TranslatorsNoteSheet`'s shape — headline, the sentence, Cancel and a default
/// action — with one difference that is the whole reason it is its own type: the
/// sentence arrives **prefilled** with what the reader or the collator already
/// wrote. The author is not composing doctrine from nothing; they are agreeing
/// with a note in front of them, and retyping it is how they would decide not to
/// bother.
///
/// **It holds no destination.** Where the ruling goes is the caller's — the
/// edition brief the round belongs to — and this sheet's only product is the
/// writer's own words. `QueryRulingSheet`'s discipline: the sheet chooses the
/// words, `RulingPerformer` is still the one door.
@MainActor
struct RoundRuleSheet: View {
    /// The note as it was written, which the writer edits rather than replaces.
    let seed: String
    /// The edition this becomes doctrine for — named in the confirmation, never
    /// picked here: the round knows its own language, and a picker would let a
    /// Spanish decision be filed under the French brief with nothing red.
    let language: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var textFocused: Bool

    init(seed: String, language: String,
         onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.seed = seed
        self.language = language
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: seed)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RoundRuleCopy.title)
                .font(.headline)
            TextEditor(text: $text)
                .frame(minHeight: 90)
                .border(Color.gray.opacity(0.3))
                .focused($textFocused)
                .onAppear { textFocused = true }
            Text(RoundRuleCopy.confirmation(language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(RoundRuleCopy.cancelTitle, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(RoundRuleCopy.confirmTitle) { onCommit(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The sheet's own words — assertable without mounting anything,
/// `TranslatorsNoteCopy`'s shape.
enum RoundRuleCopy {
    static let title = TranslationRoundReport.makeRuleTitle
    static let confirmTitle = "Make Rule"
    static let cancelTitle = "Cancel"

    /// The destination, before the click: a ruling in this edition's brief,
    /// which every later round is briefed on.
    static func confirmation(language: String) -> String {
        "This becomes a dated ruling in the "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " edition brief, briefed to every round after it."
    }
}
