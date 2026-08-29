import SwiftUI
import MaughamCore

/// **Translator's note… — the author's Kundera move** (translation pipeline
/// spec §3). In the English, put the caret in a paragraph, ⌘⌥C, type the
/// instruction — "this repetition is deliberate", "one sentence, not two" —
/// and choose its home:
///
/// - **Every edition** (default): the piece's craft intent `## Rulings`,
///   because a directive about the English applies to every language.
/// - **This edition only**: that language's edition brief `## Rulings`.
///
/// On disk it is one plain line (`Ruling.directiveText`), minted through
/// `RulingPerformer.rule` — the one door — with provenance
/// `Ruling.Provenance.translatorsNote`. **No new door**: this type chooses the
/// destination and the words, and holds no markdown of its own
/// (`QueryRuling`'s shape, one verb over).
///
/// `world:` is passed for the intent home only: `RulingPerformer`'s cache
/// holds INTENT readings, and nothing derives a world from an edition brief.
///
/// **Isolation is per-member, not on the type.** `commit` and `target` touch
/// `ProjectStore`/`Document`/`DiagnosticsPane` and are `@MainActor`; the two
/// pure statics and the two value types are not, because
/// `ProjectActiveSheet`'s synthesized `Hashable` is nonisolated and has to
/// hash a `Target`.
enum TranslatorsNote {

    /// What the sheet is about: the paragraph under the caret, enough of its
    /// text to recognise it by, and the editions "This edition only" can name.
    struct Target: Hashable {
        let docId: String
        let paragraphId: String
        let excerpt: String
        let editions: [String]
    }

    enum Home: Hashable {
        case everyEdition
        case edition(String)
    }

    /// **The one spelling of where a note goes.** `StatementPane.effectiveScope`
    /// is the pane's rule for what it SHOWS; this is the verb's rule for what
    /// it WRITES, and the two agree by construction on the only case they
    /// share (intent on a document is document-scoped).
    static func destination(home: Home, docId: String) -> (kind: Statement.Kind, scope: Statement.Scope) {
        switch home {
        case .everyEdition: return (.intent, .document(docId))
        case .edition(let language): return (.editionBrief(language), .project)
        }
    }

    /// Every edition this book has — the desk's own union
    /// (`EditionStatus.editionLanguages`: translation files and stored roles),
    /// plus any language with a brief and nothing else yet. Sorted, so the
    /// picker is stable.
    static func editions(manifest: ProjectManifest, docId: String, projectURL: URL) -> [String] {
        // Every tag is lowercased before it reaches `EditionStatus.editionLanguages`
        // — that function dedupes case-insensitively against the union it is
        // handed, but a case mismatch already present in the union itself (e.g.
        // a brief stored `"ES"` beside a file `"es"`) would otherwise survive as
        // two rows in the picker.
        let files = Set(TranslationStore.languages(forDocId: docId, in: projectURL)
            .map { $0.lowercased() })
        let roles: [String] = manifest.productionRoles.compactMap { role in
            switch role.role {
            case .translator(let l), .reader(let l), .collator(let l): return l.lowercased()
            case .designer, .unknown: return nil
            }
        }
        let briefs: [String] = manifest.statements.compactMap {
            if case .editionBrief(let l) = $0.kind { return l.lowercased() }
            return nil
        }
        return EditionStatus.editionLanguages(files: files, queries: [], roles: roles + briefs)
    }

    /// The target under the caret, or nil when the document has no paragraph
    /// there (an empty document).
    @MainActor
    static func target(for document: Document, docId: String,
                       manifest: ProjectManifest, projectURL: URL) -> Target? {
        guard let paragraphId = document.paragraphId(at: document.cursorLocation) else {
            return nil
        }
        let text = MarkdownDisplayFilter.stripAnchors(document.paragraphs[paragraphId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Target(
            docId: docId, paragraphId: paragraphId,
            excerpt: DiagnosticsPane.truncatedDriftQuote(text),
            editions: editions(manifest: manifest, docId: docId, projectURL: projectURL))
    }

    /// Write the directive. Returns the refusal's own sentence, or nil.
    @MainActor
    static func commit(_ instruction: String, target: Target, home: Home,
                       store: ProjectStore, world: DeclaredWorldStore?) async -> String? {
        let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return TranslatorsNoteCopy.emptyRefusal }
        let (kind, scope) = destination(home: home, docId: target.docId)
        do {
            try await RulingPerformer.rule(
                Ruling.directiveText(paragraphId: target.paragraphId, words),
                provenance: Ruling.Provenance.translatorsNote,
                kind: kind, forScope: scope,
                store: store,
                world: home == .everyEdition ? world : nil)
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}

/// The sheet. `QueryRulingSheet`'s shape: headline, the paragraph it is about,
/// the instruction, where it goes, Cancel and a default action.
@MainActor
struct TranslatorsNoteSheet: View {
    let target: TranslatorsNote.Target
    let onCommit: (String, TranslatorsNote.Home) -> Void
    let onCancel: () -> Void
    @State private var instruction = ""
    @State private var home: TranslatorsNote.Home = .everyEdition
    @FocusState private var instructionFocused: Bool

    private var trimmed: String {
        instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TranslatorsNoteCopy.title)
                .font(.headline)
            Text("\u{201C}\(target.excerpt)\u{201D}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $instruction)
                .frame(minHeight: 70)
                .border(Color.gray.opacity(0.3))
                .focused($instructionFocused)
                .onAppear { instructionFocused = true }
            Picker(TranslatorsNoteCopy.homeLabel, selection: $home) {
                Text(TranslatorsNoteCopy.everyEdition).tag(TranslatorsNote.Home.everyEdition)
                ForEach(target.editions, id: \.self) { language in
                    Text(TranslatorsNoteCopy.thisEditionOnly(language))
                        .tag(TranslatorsNote.Home.edition(language))
                }
            }
            Text(TranslatorsNoteCopy.confirmation(home: home))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(TranslatorsNoteCopy.cancelTitle, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(TranslatorsNoteCopy.confirmTitle) { onCommit(trimmed, home) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The sheet's own words — assertable without mounting anything.
enum TranslatorsNoteCopy {
    static let title = "Translator\u{2019}s Note"
    static let homeLabel = "Applies to"
    static let everyEdition = "Every edition"
    static let confirmTitle = "Add Note"
    static let cancelTitle = "Cancel"

    static func thisEditionOnly(_ language: String) -> String {
        "This edition only: "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
    }

    /// Both possible destinations, before the click.
    static func confirmation(home: TranslatorsNote.Home) -> String {
        switch home {
        case .everyEdition:
            return "This becomes a dated ruling on this paragraph in the piece\u{2019}s "
                + "craft intent, briefed to every translator, reader and collator."
        case .edition(let language):
            return "This becomes a dated ruling on this paragraph in the "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " edition brief, briefed to that edition\u{2019}s people only."
        }
    }

    static let emptyRefusal =
        "A translator\u{2019}s note needs an instruction \u{2014} say what the "
        + "translator must keep, or must not do, here."
}
