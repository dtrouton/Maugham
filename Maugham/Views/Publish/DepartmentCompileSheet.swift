import SwiftUI
import MaughamCore

/// **What the desk asks before it makes a book** (imprints P3 Task 5).
///
/// `DeskCompileRunner.Request` has four fields and the sheet has four
/// questions, one per field, in the order a writer answers them: what format,
/// which editions go in it, and — once — whether a stale translation is
/// allowed through. The imprint is the fourth and is *shown rather than asked*,
/// because the desk's own picker has already answered it and a second control
/// for the same decision is two places that can disagree about which book is
/// being made.
///
/// **It takes values and closures, exactly as the pane does** (tripwire 4). The
/// language list is the desk's own rows, the book's tag is `metadata.language`
/// read once by the host — nothing here opens a config or walks a manuscript.
struct DepartmentCompileSheet: View {

    /// The editions on the desk, in the order the rows are drawn. The book's
    /// own language is NOT among them — it is offered separately below,
    /// because it is the untranslated body rather than an edition anybody
    /// translated.
    let languages: [String]
    /// `metadata.language`. Checking it alone is the plain book.
    let bookLanguage: String
    /// Which imprint the desk is standing on, read-only. `nil` is the book.
    let imprint: String?
    let onCompile: (DeskCompileRunner.Request) -> Void
    let onCancel: () -> Void

    @State private var format: PublishConfig.Format = .pdf
    /// **The book's own language, checked on arrival.** A writer who opens this
    /// sheet and presses Compile gets the book — the thing they came for — and
    /// every other box is something they added deliberately.
    @State private var includesBook = true
    @State private var selected: Set<String> = []
    /// `allow_stale`, off. A stale translation is one whose source paragraph
    /// has moved underneath it, and shipping one silently is the whole reason
    /// the gate exists; the writer has to say so.
    @State private var allowStale = false

    /// **The request, in the order the bodies are rendered.** The source body
    /// leads when it is in — `LanguageSet` substitutes `bookLanguage` back to
    /// the untranslated body, so naming it here is how a source-only compile
    /// gets a status line that says which language that is, rather than an
    /// empty list that has nothing honest to print.
    private var request: DeskCompileRunner.Request {
        var tags: [String] = []
        if includesBook { tags.append(bookLanguage) }
        tags += languages.filter { selected.contains($0) }
        return DeskCompileRunner.Request(format: format, languages: tags,
                                         imprint: imprint, allowStale: allowStale)
    }

    /// Nothing checked is not "the book by default" — it is a writer who has
    /// unchecked everything, and an empty list would quietly compile the source
    /// book anyway (`LanguageSet` reads it as `[nil]`). Refused in words as
    /// well as by a disabled button, on `DepartmentCastSheet`'s rule.
    private var refusal: String? {
        request.languages.isEmpty ? DepartmentCompileSheetCopy.pickAnEdition : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(DepartmentCompileSheetCopy.title)
                .font(.headline)
            Text(DepartmentCompileSheetCopy.subjectLine(imprint: imprint))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(DepartmentCompileSheetCopy.formatLabel, selection: $format) {
                ForEach(PublishConfig.Format.allCases, id: \.self) { option in
                    Text(option.rawValue.uppercased()).tag(option)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Text(DepartmentCompileSheetCopy.editionsLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Toggle(DepartmentCompileSheetCopy.bookLanguageTitle(bookLanguage),
                       isOn: $includesBook)
                ForEach(languages, id: \.self) { language in
                    Toggle(TranslationReviewIndicator
                        .displayLabel(forLanguageTag: language),
                           isOn: Binding(
                            get: { selected.contains(language) },
                            set: { on in
                                if on { selected.insert(language) }
                                else { selected.remove(language) }
                            }))
                }
            }

            Toggle(DepartmentCompileSheetCopy.allowStaleTitle, isOn: $allowStale)
                .help(DepartmentCompileSheetCopy.allowStaleHelp)

            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(DepartmentCompileSheetCopy.cancelTitle, action: onCancel)
                Button(DepartmentCompileState.compileTitle) { onCompile(request) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(refusal != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// **The sheet's own words**, split out on `DepartmentCastCopy`'s precedent —
/// a truth table a test can assert without mounting anything.
enum DepartmentCompileSheetCopy {

    static let title = "Compile this book"

    /// **Which book, said before anything else.** An imprint has its own
    /// template, its own metadata and its own version counter, and a writer who
    /// compiled the wrong one wants to learn it here rather than from the
    /// filename afterwards.
    static func subjectLine(imprint: String?) -> String {
        guard let imprint else {
            return "The book itself, as it stands. Nothing already published is "
                + "touched \u{2014} a compile mints its own version."
        }
        return "The \(imprint) imprint \u{2014} its own template, its own "
            + "metadata and its own version count."
    }

    static let formatLabel = "Format"
    static let editionsLabel = "Editions"

    /// The untranslated body, named by its language rather than called
    /// "source": a writer reading "es" here should recognise the book they
    /// wrote, and the tag is what the status line and the filename will say.
    static func bookLanguageTitle(_ tag: String) -> String {
        "The book\u{2019}s own language ("
            + TranslationReviewIndicator.displayLabel(forLanguageTag: tag) + ")"
    }

    static let allowStaleTitle = "Allow stale translations"

    static let allowStaleHelp =
        "Compile even where a translated paragraph\u{2019}s source has changed "
        + "underneath it. Off, a stale paragraph stops the edition."

    static let cancelTitle = "Cancel"

    /// Nothing checked, refused in words. It says what to do rather than what
    /// is wrong: the writer unchecked the last box a moment ago and knows.
    static let pickAnEdition =
        "Pick at least one edition \u{2014} a compile with none would make "
        + "nothing."
}
