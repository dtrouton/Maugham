import SwiftUI
import MaughamCore

/// **The publish problems the desk's last compile reported, as rows** (report
/// foundations plan 2, Task 8) — pure, so the whole list is assertable from
/// literals.
///
/// A problem is a `TectonicLogParser.Diagnostic` that names its piece
/// (`pieceID != nil`; `DepartmentCompileState.problems(in:)`). Each row names
/// the piece by its TITLE, never its id: the id is a binder key the writer has
/// never seen, and a list of them would be a list nobody could act on.
enum PublishProblems {

    /// One problem, ready to draw.
    struct Row: Equatable, Identifiable {
        /// The problem's place in the list. Two problems can share a piece, a
        /// paragraph and even a message, so position is the only honest id.
        let id: Int
        let level: TectonicLogParser.Level
        let pieceID: String
        let paragraphID: String?
        /// The edition the problem was found in — nil for the source text
        /// (R-S14). A translated body's problem reveals in that edition.
        let bodyLanguage: String?
        let title: String
        let message: String
        /// Whether the piece is still in the book. A problem from a compile
        /// that predates a deletion names a piece there is no going to (m7).
        let isInBook: Bool
    }

    /// The rows, in the order the orchestrator gave them (errors first, then
    /// warnings — its own ordering, kept). A diagnostic with no piece is not a
    /// publish problem and has no row.
    static func rows(_ problems: [TectonicLogParser.Diagnostic],
                     titles: [String: String]) -> [Row] {
        problems.enumerated().compactMap { index, diagnostic in
            guard let pieceID = diagnostic.pieceID else { return nil }
            let title = titles[pieceID]
            return Row(id: index, level: diagnostic.level, pieceID: pieceID,
                       paragraphID: diagnostic.paragraphID,
                       bodyLanguage: diagnostic.bodyLanguage,
                       title: title.map { $0.isEmpty ? untitledPiece : $0 } ?? removedPiece,
                       message: diagnostic.message,
                       isInBook: title != nil)
        }
    }

    /// Every document's title, by id — the same `collectDocuments` walk
    /// `ProjectStoreASTSource.publishablePieces()` makes, so the id a problem
    /// carries is a key here. A walk of the in-memory manifest and nothing
    /// else: no disk, no op log.
    @MainActor
    static func titles(in structure: [StructureItem]) -> [String: String] {
        var titles: [String: String] = [:]
        for item in ProjectStore.collectDocuments(in: structure) where titles[item.id] == nil {
            titles[item.id] = item.title
        }
        return titles
    }

    /// **What Show in Manuscript does for a row.** A paragraph is revealed
    /// through the window's one select-wait-scroll path (`TranslationReveal`),
    /// in the text the problem was found in: the source (no language) or the
    /// edition whose body held it (R-S14). A problem with no paragraph opens
    /// its piece, which is a subject write and nothing more.
    enum Reveal: Equatable {
        case paragraph(TranslationReveal)
        case piece(BinderSubject)
    }

    static func reveal(_ row: Row) -> Reveal {
        guard let paragraphID = row.paragraphID else { return .piece(.item(row.pieceID)) }
        return .paragraph(TranslationReveal(
            docId: row.pieceID, language: row.bodyLanguage, paragraphId: paragraphID))
    }

    /// **The list's header** (m6): "2 errors · 1 warning", a zero part
    /// omitted; nothing at all is `emptyTitle`.
    static func header(_ rows: [Row]) -> String {
        let errors = rows.filter { $0.level == .error }.count
        let warnings = rows.count - errors
        let parts = [count(errors, "error"), count(warnings, "warning")].compactMap { $0 }
        return parts.isEmpty ? emptyTitle : parts.joined(separator: " \u{00B7} ")
    }

    private static func count(_ n: Int, _ noun: String) -> String? {
        n == 0 ? nil : "\(n) \(noun)" + (n == 1 ? "" : "s")
    }

    /// **The glyph and its words** — never colour alone. The view draws them
    /// as one `Label`, so the word is both on screen and what VoiceOver reads.
    static func glyph(_ level: TectonicLogParser.Level)
    -> (systemImage: String, label: String) {
        switch level {
        case .error: return ("xmark.octagon.fill", errorLabel)
        case .warning: return ("exclamationmark.triangle.fill", warningLabel)
        }
    }

    // MARK: - Copy

    static let errorLabel = "Error"
    static let warningLabel = "Warning"
    static let untitledPiece = "Untitled piece"
    /// A row whose piece has left the book since the compile (m7).
    static let removedPiece = "A piece no longer in the book"
    static let closeTitle = "Back"
    static let closeAccessibilityLabel = "Back to the book"
    static let showInManuscriptTitle = "Show in Manuscript"
    static let openPieceHelp = "Open this piece in the manuscript."
    static let showParagraphHelp = "Open this piece and scroll to the paragraph."
    static let emptyTitle = "No Problems"
    static let emptyMessage = "The last compile reported nothing to fix."

    /// Show in Manuscript's accessibility label, naming the piece so a list of
    /// identical buttons is not a list of identical buttons to VoiceOver.
    static func showInManuscriptAccessibilityLabel(title: String) -> String {
        "Show in Manuscript: \(title)"
    }
}

/// **The publish problems arm of Publish's centre column** — the list the desk's
/// Show Problems opens. It takes values and closures only: the rows were
/// derived by the caller, Back is `onClose`, and each row's Show in Manuscript
/// hands its piece and paragraph to `onReveal`, which the window wires to the
/// source reveal.
struct PublishProblemsView: View {
    let rows: [PublishProblems.Row]
    let onClose: () -> Void
    /// The row whose Show in Manuscript was pressed; the window asks
    /// `PublishProblems.reveal(_:)` what that means.
    let onReveal: (PublishProblems.Row) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(
                    PublishProblems.emptyTitle,
                    systemImage: "checkmark.circle",
                    description: Text(PublishProblems.emptyMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { row in
                            rowView(row)
                            Divider()
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// **The row's one verb**, callable without a press so a test asserts the
    /// closure call directly (tripwire 33).
    func showInManuscript(_ row: PublishProblems.Row) {
        guard row.isInBook else { return }
        onReveal(row)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(PublishProblems.header(rows))
                .font(.headline)
            Spacer(minLength: 8)
            Button(PublishProblems.closeTitle) { onClose() }
                .controlSize(.small)
                .accessibilityLabel(PublishProblems.closeAccessibilityLabel)
                .help("Stop reading the problems and show the book again.")
        }
        .padding(14)
    }

    private func rowView(_ row: PublishProblems.Row) -> some View {
        let glyph = PublishProblems.glyph(row.level)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // One `Label`: the glyph and its word are one element, so the
                // level is read in words by eye and by VoiceOver alike and is
                // never carried by colour alone.
                Label {
                    Text(glyph.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: glyph.systemImage)
                        .foregroundStyle(row.level == .error ? Color.red : Color.orange)
                }
                .labelStyle(.titleAndIcon)
                Text(row.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                // A piece that has left the book has nowhere to go: no button
                // rather than one that does nothing (m7).
                if row.isInBook {
                    Button(PublishProblems.showInManuscriptTitle) { showInManuscript(row) }
                        .controlSize(.small)
                        .accessibilityLabel(
                            PublishProblems.showInManuscriptAccessibilityLabel(title: row.title))
                        .help(row.paragraphID == nil
                              ? PublishProblems.openPieceHelp
                              : PublishProblems.showParagraphHelp)
                }
            }
            Text(row.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
