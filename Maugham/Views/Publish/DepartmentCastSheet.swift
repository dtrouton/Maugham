import SwiftUI
import MaughamCore

/// **What the desk is asking the writer about one of the book's people**
/// (publish-department P4 Task 9, generalized by cast-management 2026-08-21).
///
/// It began as one question — *who translates into this language?* — asked when
/// a Run would otherwise have minted a translator with `name: nil`, whose
/// `effectiveName` falls back to the language tag uppercased: a byline nobody
/// chose, signing every paragraph and query from then on.
///
/// **The other asks are the same question at another moment**, which is why they
/// share one sheet rather than growing a second and a third: *add a language* is
/// that question with the language itself still to be named, and *rename* is it
/// asked again about somebody who already has an answer. One sheet means one
/// place where a name is trimmed, one place where blank is refused, and one
/// visible act composed of `translatorRole(for:)` + `renameProductionRole` —
/// never a nameless role left standing for the writer to find later.
struct DepartmentCastPrompt: Equatable, Identifiable {

    /// Which question the desk is asking.
    enum Ask: Equatable {
        /// **Name the translator a Run is waiting on.** `docId` is the document
        /// Global Constraint 1 resolved when Run was pressed — captured here
        /// rather than re-read at Confirm, so a writer who navigates the tree
        /// while the sheet is open still runs the chapter they actually clicked
        /// Run on.
        case nameForRun(language: String, docId: String)
        /// **Start an edition the book does not have yet** — the only ask that
        /// takes a language tag, because it is the only one where the language
        /// is not already known.
        case addLanguage
        /// **Say who somebody on the desk is.** `currentName` is what the field
        /// starts with and what the sheet's own words are about; it is EMPTY for
        /// a row that has nobody yet (an unlisted language nothing has minted a
        /// role for), which is a naming rather than a renaming and says so.
        ///
        /// WHICH role this is stays the host's question: resolving it may have
        /// to mint one first — a preset translator, or the preset designer, who
        /// reaches disk for the first time here.
        case rename(subject: RenameSubject, currentName: String)
    }

    /// Who a rename is about. The desk has two kinds of person on it and they
    /// reach `renameProductionRole` by different routes — a translator through
    /// its language, the designer through `ProjectStore.designerRole()` — so the
    /// ask names the kind rather than an id the pane has no way to know.
    enum RenameSubject: Equatable {
        case translator(language: String)
        case designer
    }

    let ask: Ask

    /// One prompt per subject: a second click on a row while its sheet is open
    /// finds the same identity rather than presenting a second sheet.
    var id: String {
        switch ask {
        case .nameForRun(let language, _): return "run:\(language)"
        case .addLanguage: return "add"
        case .rename(.translator(let language), _): return "rename:\(language)"
        case .rename(.designer, _): return "rename:designer"
        }
    }

    /// The headline. Every ask names its own subject, because a sheet that named
    /// none would be a sheet a writer could answer about the wrong person.
    var title: String {
        switch ask {
        case .nameForRun(let language, _):
            return DepartmentCastCopy.nameForRunTitle(language: language)
        case .addLanguage:
            return DepartmentCastCopy.addLanguageTitle
        case .rename(let subject, let currentName):
            guard !currentName.isEmpty else {
                return DepartmentCastCopy.nameSubjectTitle(subject: subject)
            }
            return DepartmentCastCopy.renameTitle(currentName: currentName)
        }
    }

    var confirmTitle: String {
        switch ask {
        case .nameForRun: return DepartmentCastCopy.nameAndRunTitle
        case .addLanguage: return DepartmentCastCopy.addConfirmTitle
        case .rename(_, let currentName):
            return currentName.isEmpty
                ? DepartmentCastCopy.nameConfirmTitle
                : DepartmentCastCopy.renameConfirmTitle
        }
    }

    /// What the name field starts with — the current name for a rename, nothing
    /// for the asks about somebody who has none yet. (`.addLanguage` fills
    /// itself in as the tag is typed; see `DepartmentCastSheet`.)
    var initialName: String {
        if case .rename(_, let currentName) = ask { return currentName }
        return ""
    }

    /// Whether the sheet draws a language-tag field. `.addLanguage` alone.
    var takesLanguageTag: Bool {
        if case .addLanguage = ask { return true }
        return false
    }
}

/// What the writer answered: the language they typed, where the ask took one,
/// and the name they typed. Both already trimmed, and the tag already
/// lowercased — `TranslationRecord.isValidLanguageTag` is lowercase-only and
/// every other reader of a language tag agrees with it.
struct DepartmentCastAnswer: Equatable {
    let language: String?
    let name: String
}

/// The sheet itself — a headline, an explanation, one or two fields, Cancel and
/// a default action (`TranslationQueryReplySheet`'s shape, one persona over).
///
/// `onConfirm` receives trimmed text and can only be reached through a state the
/// sheet has already accepted: a blank name and an unusable tag both disable it,
/// and both say why in the sheet rather than leaving a dead button to be puzzled
/// over.
struct DepartmentCastSheet: View {
    let prompt: DepartmentCastPrompt
    let onConfirm: (DepartmentCastAnswer) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var tag = ""
    /// **The name this sheet filled in for the writer, if any.** A preset
    /// language comes with a translator, so typing `es` should offer Cortázar —
    /// but only while the writer has not typed a name of their own. Comparing
    /// against what was last auto-filled answers that without a second "has the
    /// writer touched this?" flag, which would have to be suppressed every time
    /// the sheet writes the field itself.
    @State private var autofilled: String?
    /// Whether a field has been left in a state worth complaining about. A sheet
    /// that refuses the moment it opens is a sheet that scolds the writer for
    /// not having typed yet.
    @State private var tagTouched = false
    @State private var nameTouched = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The tag as every other reader of one spells it. Lowercased BEFORE
    /// validation, so `PT-BR` is a Brazilian Portuguese edition rather than a
    /// refusal — the writer typed a language, not a syntax error.
    private var trimmedTag: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var tagIsUsable: Bool {
        !prompt.takesLanguageTag || TranslationRecord.isValidLanguageTag(trimmedTag)
    }

    /// What the sheet says about what it cannot accept yet. One slot, and the
    /// tag outranks the name: a writer who has typed neither is answering the
    /// first question first.
    private var refusal: String? {
        if prompt.takesLanguageTag, tagTouched, !tagIsUsable {
            return DepartmentCastCopy.unusableTag(
                tag.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if nameTouched, trimmedName.isEmpty { return DepartmentCastCopy.nameRequired }
        return nil
    }

    /// Who this is, said above the fields. For `.addLanguage` it follows the
    /// tag: a preset language arrives with somebody already attached and says
    /// so, and anything else gets the mint sheet's own who-is-this sentence.
    private var explanation: String {
        switch prompt.ask {
        case .nameForRun:
            return DepartmentCastCopy.explanation
        case .addLanguage:
            return DepartmentCastCopy.addExplanation(
                preset: ProductionRole.defaultTranslatorName(language: trimmedTag))
        case .rename(let subject, _):
            return DepartmentCastCopy.renameExplanation(subject: subject)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title)
                .font(.headline)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if prompt.takesLanguageTag {
                TextField(DepartmentCastCopy.tagPlaceholder, text: $tag)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tag) { _, _ in
                        tagTouched = true
                        // Offer the preset translator for the language now
                        // named — unless the writer has typed a name of their
                        // own, which outranks any preset.
                        if name.isEmpty || name == autofilled {
                            let offered = ProductionRole.defaultTranslatorName(
                                language: trimmedTag) ?? ""
                            name = offered
                            autofilled = offered
                        }
                    }
            }
            TextField(DepartmentCastCopy.placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, _ in nameTouched = true }
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(DepartmentCastCopy.cancelTitle, action: onCancel)
                Button(prompt.confirmTitle) {
                    onConfirm(DepartmentCastAnswer(
                        language: prompt.takesLanguageTag ? trimmedTag : nil,
                        name: trimmedName))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || !tagIsUsable)
            }
        }
        .padding(20)
        .frame(width: 380)
        // A rename starts from the name it is about — the writer is usually
        // correcting a spelling, not typing a stranger from scratch.
        .onAppear { name = prompt.initialName }
    }
}

/// **The sheet's own words**, split out on `DepartmentDesk`'s precedent — a
/// truth table of strings a test can assert without mounting anything.
enum DepartmentCastCopy {

    // MARK: - Naming the translator a Run is waiting on (P4 Task 9)

    static func nameForRunTitle(language: String) -> String {
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

    static let nameAndRunTitle = "Name & Run"
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

    // MARK: - Starting an edition (cast-management)

    static let addLanguageTitle = "Add a language"
    static let addConfirmTitle = "Add Language"

    static let tagPlaceholder = "A language tag \u{2014} es, fr, pt-br"

    /// The explanation follows the tag: four languages arrive with a translator
    /// already picked, and saying so is the difference between a name the writer
    /// wonders about and a name they recognise as the app's own offer.
    static func addExplanation(preset: String?) -> String {
        guard let preset else { return explanation }
        return "Maugham already has a translator for this language: \(preset). "
            + "Keep the name or type somebody else\u{2019}s \u{2014} whatever "
            + "stands here signs every paragraph and query of this edition."
    }

    /// **A tag the writer typed that no edition can be written for**, refused in
    /// the sheet rather than at the button. It quotes what they typed, so it
    /// reads as an answer to them rather than as a rule.
    static func unusableTag(_ typed: String) -> String {
        "\u{201C}\(typed)\u{201D} isn\u{2019}t a language tag. Use a short code "
            + "\u{2014} two or three letters, optionally a region after a hyphen: "
            + "es, fr, pt-br."
    }

    /// Blank is refused in words as well as by a disabled button
    /// (`renameProductionRole`'s own `.productionRoleNameEmpty`): a dead control
    /// with no sentence beside it teaches the writer nothing about why.
    static let nameRequired =
        "A name can\u{2019}t be blank \u{2014} every byline on the desk prints "
        + "somebody."

    /// The desk's one notice slot, when the writer backs out of adding a
    /// language: nothing was minted and no edition was started.
    static let addCancelledLine =
        "Nothing added \u{2014} the book\u{2019}s editions are as they were."

    /// **Adding a language the book already has is neither an error nor a
    /// duplicate** — the edition is already on the desk, so the honest answer
    /// names it and stops. `translatorRole(for:)` is idempotent and would have
    /// found the same person anyway; what this prevents is a rename the writer
    /// did not know they were performing.
    static func alreadyOnTheDesk(language: String) -> String {
        "The "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " edition is already on the desk."
    }

    // MARK: - Renaming somebody on the desk (cast-management)

    static func renameTitle(currentName: String) -> String {
        "Rename \(currentName)"
    }

    /// The headline for a row that has nobody on it yet — a naming rather than
    /// a renaming, which is a real state for an unlisted language nothing has
    /// minted a role for. The designer arm is unreachable (every project has
    /// Tschichold from the moment it exists) and total rather than clever.
    static func nameSubjectTitle(
        subject: DepartmentCastPrompt.RenameSubject) -> String {
        switch subject {
        case .translator(let language): return nameForRunTitle(language: language)
        case .designer: return "Who designs this book?"
        }
    }

    static let renameConfirmTitle = "Rename"
    static let nameConfirmTitle = "Name"

    /// **A rename orphans nothing, and the sheet says so** — identity is
    /// `ProductionRole.id`, minted once and never touched by a rename, so every
    /// annotation and every proposal already signed stays theirs. A writer who
    /// suspects otherwise will not rename anybody.
    static func renameExplanation(
        subject: DepartmentCastPrompt.RenameSubject) -> String {
        switch subject {
        case .translator(let language):
            return "Whatever stands here signs the "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " edition\u{2019}s paragraphs and queries from now on. Work "
                + "already signed stays theirs \u{2014} a new name renames the "
                + "person, it doesn\u{2019}t hand their work to somebody else."
        case .designer:
            return "Whatever stands here signs this book\u{2019}s design rounds "
                + "from now on. Rounds already proposed stay theirs \u{2014} a "
                + "new name renames the person, it doesn\u{2019}t hand their "
                + "work to somebody else."
        }
    }

    /// The desk's one notice slot, when the writer backs out of a rename.
    static func renameCancelledLine(currentName: String) -> String {
        currentName.isEmpty
            ? "Nothing named \u{2014} the desk is as it was."
            : "Nothing renamed \u{2014} they are still \(currentName)."
    }

    /// What the notice says when the designer's rename could not be written.
    /// A translator's failure is `mintFailed`'s, which names the edition —
    /// there is only one designer, so there is nothing to disambiguate here.
    static let designerRenameFailed =
        "Couldn\u{2019}t rename the designer. Check that the project folder is "
        + "still where it was."
}
