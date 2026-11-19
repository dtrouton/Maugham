import SwiftUI
import MaughamCore

/// **A piece's Brief**, in the fixed order Denver approved (spec "Brief"):
/// the line, Going for, Decided, then two quiet lines — From the book and
/// What Claude has read.
///
/// **Reading without loading, and editing too.** Everything here is a
/// manifest write (the line) or a statement write (the intent, a decision, a
/// confirmed reading), each asked of the intent's OWN posture — none needs the
/// piece's manuscript `Document`, so a piece that is not open is as editable
/// here as one that is (plan 3 Global Constraints; Review Focus 2).
struct BriefPieceView: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let docId: String
    let contents: BriefContents
    let bible: BibleStore?
    let world: DeclaredWorldStore?
    let inTheCentre: Bool
    let onOpenInCentre: (CentreItem) -> Void
    let onShowStrain: (_ docId: String, _ clauseQuote: String) -> Void

    @State private var lineDraft = ""
    @FocusState private var lineFocused: Bool
    @State private var showsBook = false
    @State private var showsReadings = false

    static let linePrompt = "A line for the cards and the outline — optional"
    static let fromTheBook = "From the book"
    static let readingsTitle = "What Claude has read"

    /// The posture of the piece's intent statement — the drawing door, at the
    /// id the statement host's own rule names.
    private var posture: Posture {
        documentStore.posture(forDocId: StatementEditorHost.postureDocId(
            kind: .intent, scope: .document(docId), statements: store.manifest.statements))
    }

    private var snapshot: BriefSnapshot { contents.snapshot }

    private var offers: BriefOffers {
        BriefPane.offers(posture: posture, mayWriteTheLine: BriefPane.mayWriteTheLine(
            docId: docId, store: store, documentStore: documentStore))
    }

    /// The line this view last wrote, until the next read shows it — so a
    /// submit followed by a blur writes once.
    @State private var lineWritten: String?

    var body: some View {
        let offers = self.offers
        VStack(alignment: .leading, spacing: 14) {
            line(offers)
            GoingForView(
                store: store, documentStore: documentStore, scope: .document(docId),
                isRead: contents.isRead, essay: snapshot.intentEssay, marks: contents.marks,
                mayEdit: offers.editsIntent, inTheCentre: inTheCentre, posture: posture,
                onOpenInCentre: { onOpenInCentre(.statement(kind: .intent, scope: .document(docId))) },
                onShowStrain: onShowStrain)
            BriefDecidedSection(
                fileOrder: contents.fileOrder[docId] ?? [],
                decisions: snapshot.decisions.map(\.ruling),
                kind: .intent, scope: .document(docId), store: store, world: world,
                posture: posture, liveParagraphIds: contents.liveParagraphIds)
            quietLines(offers)
        }
        .onAppear { lineDraft = snapshot.line ?? "" }
        .onChange(of: snapshot.line) { _, stored in
            lineWritten = nil
            if !lineFocused { lineDraft = stored ?? "" }
        }
        .onChange(of: lineFocused) { _, focused in
            if !focused { commitLine() }
        }
        .onDisappear { commitLine() }
    }

    // MARK: - The line

    @ViewBuilder
    private func line(_ offers: BriefOffers) -> some View {
        if offers.editsLine {
            TextField(Self.linePrompt, text: $lineDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                .lineLimit(1...3)
                .focused($lineFocused)
                .onSubmit { commitLine() }
                .accessibilityIdentifier("brief.line")
        } else if let line = snapshot.line {
            Text(line)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("brief.line")
        }
    }

    /// Whether the field holds something other than what is stored. Pure:
    /// committing an unchanged line writes nothing.
    /// Both sides trimmed: an old line stored with trailing spaces is not
    /// rewritten on every blur.
    static func lineNeedsCommitting(draft: String, stored: String?) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            != (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitLine() {
        guard offers.editsLine,
              Self.lineNeedsCommitting(draft: lineDraft, stored: lineWritten ?? snapshot.line) else { return }
        let words = lineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        lineWritten = words
        let id = docId
        Task { @MainActor in
            do {
                try await store.updateInspector(id: id, synopsis: words)
            } catch {
                lineWritten = nil
                MaughamEvent.postNotice(error.localizedDescription, projectURL: store.url)
            }
        }
    }

    // MARK: - The two quiet lines

    @ViewBuilder
    private func quietLines(_ offers: BriefOffers) -> some View {
        let shown = BriefPane.quietLines(snapshot)
        if shown.fromTheBook {
            VStack(alignment: .leading, spacing: 6) {
                BriefPane.disclosure(Self.fromTheBook, isOpen: $showsBook)
                if showsBook {
                    BriefPane.FromTheBook(essay: snapshot.bookIntentEssay, decisions: snapshot.bookDecisions)
                }
            }
        }
        if let count = shown.readings, let bible {
            VStack(alignment: .leading, spacing: 6) {
                BriefPane.disclosure("\(Self.readingsTitle) (\(count))", isOpen: $showsReadings)
                if showsReadings {
                    BibleStratumView(
                        facts: contents.facts, scope: .document(docId), store: store,
                        bible: bible, world: world, posture: posture)
                }
            }
        }
    }
}
