import SwiftUI
import MaughamCore

/// **The mint sheet for an unlisted language's translator** (publish-department
/// P4 Task 9).
///
/// `ProductionRole.defaultTranslatorName(language:)` only knows four languages;
/// asking `translatorRole(for:)` to mint a translator for anything else stores a
/// role with `name: nil`, and `effectiveName` falls back to the language tag
/// uppercased — a byline nobody chose, signing every paragraph and query the
/// round produces from here on. `DepartmentPaneHost.needsTranslatorName` is the
/// read that catches this BEFORE the click reaches `TranslatorOrchestrator
/// .runTranslation` (whose own `translatorIdentity` closure is that same mint,
/// unannounced); this file is only the sheet it shows instead —
/// `TranslationQueryReplySheet`'s shape (a headline, an explanation, one field,
/// Cancel and a default action) one persona over.
struct DepartmentMintPrompt: Equatable, Identifiable {
    /// The language a translator is about to be named for.
    let language: String
    /// **The document Global Constraint 1 resolved when Run was pressed** —
    /// captured here rather than re-read from `runTarget` at Confirm, so a
    /// writer who navigates the tree while the sheet is open still runs the
    /// chapter they actually clicked Run on, not whatever the tree names by
    /// the time they finish typing.
    let docId: String

    /// One language, one prompt: a second click on the same row while this one
    /// is open finds the same identity rather than presenting a second sheet.
    var id: String { language }
}

/// The sheet itself. `onName` receives the trimmed text; the caller decides
/// what an empty one means (`DepartmentPaneHost.confirmMint` never sees one —
/// Confirm is disabled while the field is blank, matching every other
/// name-taking control on the desk).
struct DepartmentMintSheet: View {
    let language: String
    let onName: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(DepartmentMintCopy.title(language: language))
                .font(.headline)
            Text(DepartmentMintCopy.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(DepartmentMintCopy.placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(DepartmentMintCopy.cancelTitle, action: onCancel)
                Button(DepartmentMintCopy.confirmTitle) { onName(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// **The sheet's own words**, split out on `DepartmentDesk`'s precedent — a
/// truth table of strings a test can assert without mounting anything.
enum DepartmentMintCopy {

    static func title(language: String) -> String {
        "Who translates into "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language) + "?"
    }

    /// **The placeholder explains who this is** (the brief's own phrase), so
    /// the field says something even before the writer's cursor lands in it —
    /// a writer who never reads the sentence above still reads the box they
    /// are about to type into.
    static let placeholder = "The name of this edition\u{2019}s translator"

    static let explanation =
        "This edition has no named translator yet. Whatever is typed here signs "
        + "every paragraph and every query this round writes \u{2014} the same "
        + "byline any other translator on the desk carries."

    static let confirmTitle = "Name & Run"
    static let cancelTitle = "Cancel"

    /// What the desk's one notice slot says when the writer backs out —
    /// `DepartmentRunState.cancelledLine`'s shape, but said before the run
    /// rather than during it: nothing was translated, and nothing was even
    /// asked for, because naming the translator is the one thing standing in
    /// front of the click.
    static func cancelledLine(language: String) -> String {
        "Translation cancelled \u{2014} the "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " edition needs a named translator before a round can run."
    }

    /// What the notice says when the mint or the rename itself failed —
    /// `DepartmentPaneHost.briefRefusal`'s shape, naming the edition for the
    /// same reason: a writer with three of them needs to know which one.
    static func mintFailed(language: String) -> String {
        "Couldn\u{2019}t name the "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " translator. Check that the project folder is still where it was."
    }
}
