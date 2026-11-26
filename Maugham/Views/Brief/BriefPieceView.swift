import SwiftUI
import MaughamCore

/// **A piece's Brief**, in the fixed order Denver approved (spec "Brief"):
/// the line, Going for, Decided (only once something is filed), two quiet
/// lines — From the book and What Claude has read — and the foot: the set
/// values and History on one quiet line (`BriefFoot`; Denver, 2026-11-21).
/// A brand-new chapter's Brief is the line, Going for and that one line.
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
    let onShowStrain: (ResolveRequest) -> Void
    /// A filed line's link (`ProjectWindow.openBrief`); nil draws it as text.
    var onOpenBrief: ((BinderSubject) -> Void)? = nil
    /// Brief's pull-up act (`ProjectWindow.pullUpItem`): the History link.
    var onPullUp: (PulledUp) -> Void = { _ in }
    /// The window's tree (the foot's sheets and cached publishing answer).
    /// Nil offers no sheet.
    var tree: BinderTreeSectionsState? = nil
    /// What a Collection's loose piece is written as ("Prose" /
    /// "Screenplay"), a quiet caption at the head; nil draws none
    /// (`BriefPane.formatCaption`).
    var formatCaption: String? = nil

    @State private var lineDraft = ""
    @FocusState private var lineFocused: Bool
    /// ⌘⌥I's request (`BriefField.line`), consumed here.
    @Environment(\.briefFocus) private var focusRequest
    @State private var showsBook = false
    @State private var showsReadings = false
    /// Where a Confirm (or a Correct) filed — one quiet line under the
    /// readings (shell plan 3 Task 6).
    @State private var filedNotice: FiledNotice.Filing?

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

    /// The piece's intent would not read (`BriefSnapshot.unreadable`).
    private var intentIsUnreadable: Bool {
        BriefPane.statementIsUnreadable(kind: .intent, scope: .document(docId),
                                        snapshot: snapshot, statements: store.manifest.statements)
    }

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
            if let formatCaption {
                Text(formatCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("brief.format")
            }
            line(offers)
            GoingForView(
                store: store, documentStore: documentStore, scope: .document(docId),
                isRead: contents.isRead, essay: snapshot.intentEssay, marks: contents.marks,
                mayEdit: offers.editsIntent, inTheCentre: inTheCentre,
                isUnreadable: intentIsUnreadable, posture: posture,
                onOpenInCentre: { onOpenInCentre(.statement(kind: .intent, scope: .document(docId))) },
                onShowStrain: onShowStrain)
            BriefDecidedSection(
                fileOrder: contents.fileOrder[docId] ?? [],
                decisions: snapshot.decisions.map(\.ruling),
                kind: .intent, scope: .document(docId), store: store, world: world,
                posture: posture, liveParagraphIds: contents.liveParagraphIds,
                isUnreadable: intentIsUnreadable)
            quietLines(offers)
            foot
        }
        .onAppear { lineDraft = snapshot.line ?? "" }
        .onChange(of: snapshot.line) { _, stored in
            lineWritten = nil
            if !lineFocused { lineDraft = stored ?? "" }
        }
        .onChange(of: lineFocused) { _, focused in
            if !focused { commitLine() }
        }
        // Saved 500 ms after the last edit too (final wave, I1): at ⌘Q no
        // view disappears, and the store's close flushes the pending line.
        .onChange(of: lineDraft) { _, _ in
            if lineFocused { scheduleLine() }
        }
        .onDisappear { commitLine() }
        // ⌘⌥I: the keys in the line, where it is a field. Consumed either way.
        .onChange(of: focusRequest.wrappedValue, initial: true) { _, asked in
            guard asked == .line else { return }
            focusRequest.wrappedValue = nil
            if offers.editsLine { DispatchQueue.main.async { lineFocused = true } }
        }
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

    /// Hand the line to the store's debounced slot (`scheduleBriefLine`),
    /// which writes it 500 ms after the last edit, or at once when flushed.
    /// Nothing is scheduled for an unchanged line. Answers whether it
    /// scheduled.
    @discardableResult
    private func scheduleLine() -> Bool {
        guard offers.editsLine,
              Self.lineNeedsCommitting(draft: lineDraft, stored: lineWritten ?? snapshot.line) else { return false }
        let words = lineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        lineWritten = words
        documentStore.scheduleBriefLine(docId: docId, line: words)
        return true
    }

    /// Blur, Return, disappear: the pending line is written now, through the
    /// same slot (a failure is said by the store's notice).
    private func commitLine() {
        scheduleLine()
        Task { @MainActor in await documentStore.flushBriefLines() }
    }

    // MARK: - The foot

    /// The set values and History, on one line (`BriefFoot`).
    private var foot: some View {
        let line = BriefFoot.line(docId: docId, store: store, tree: tree)
        return BriefFootView(
            parts: line.parts,
            openSheet: tree.map { tree in
                { [docId] item in tree.pieceRowSheet = PieceRowSheet(item, pieceId: docId) }
            },
            onPullUp: onPullUp, offered: line.offered, noun: line.noun)
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
                        bible: bible, world: world, posture: posture,
                        onFiled: { destination in
                            filedNotice = FiledNotice.after(
                                .filed(FiledUnder.filing(destination, faces: .item(docId), store: store)),
                                current: filedNotice)
                        })
                }
            }
        }
        // Outside the readings, so the line outlives the last reading the
        // Confirm took away.
        if filedNotice != nil {
            FiledNotice(filing: $filedNotice, onOpenBrief: onOpenBrief)
        }
    }
}
