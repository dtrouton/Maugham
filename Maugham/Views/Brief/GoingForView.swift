import SwiftUI
import MaughamCore

/// Which face Going for shows (shell plan 3, Task 4).
enum GoingForMode: Equatable {
    /// The writer's essay as prose, with the latest check's marks on it when
    /// they apply, and an Edit button where the posture offers one.
    case reading
    /// The intent's `StatementEditorHost`, in place.
    case editing
    /// The intent is the centre's cover: one quiet line, never a second host.
    case inTheCentre
}

/// **Going for** — a piece's intent, in Brief (spec "Brief" §2).
///
/// Two faces (Denver saw and accepted both): while the latest check's marks
/// APPLY (`ClauseMarks.applies`) the essay reads as prose with the marks on
/// the writer's own sentences and an Edit button; otherwise the statement
/// editor sits there, editable. A third case keeps the one-host rule: where
/// the intent is the centre's cover, or another host already holds its
/// `Document`, nothing here mounts an editor.
///
/// **A mark carries no model text** (constitution must-not #2, ADR 0027 §1).
/// It is drawn from `ClauseMark.Kind` alone — a solid underline for
/// `strains`, a dotted one for `silent` — over the WRITER's own characters;
/// its legend is the two app constants below. The check's quote is never
/// drawn: it travels only to `onShowStrain`, which Task 6 turns into a jump to
/// the To resolve item where what the check said is shown
/// (`BriefPaneTests.test_aMarkCarriesNoModelText`).
struct GoingForView: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let docId: String
    /// Whether `essay` and `marks` come from a read yet. Until one lands no
    /// face is chosen — the editor's appearance latches `editorHeld`, so a
    /// first frame drawn over nothing would keep the editor over marks.
    let isRead: Bool
    /// The essay half of the intent, as read for this pass, or nil.
    let essay: String?
    /// The marks placed on `essay` — empty unless they apply.
    let marks: [ClauseMark]
    let mayEdit: Bool
    let inTheCentre: Bool
    let posture: Posture
    let onOpenInCentre: () -> Void
    let onShowStrain: (_ docId: String, _ clauseQuote: String) -> Void

    /// The writer is in the editor HERE: set by Edit, and by the editor's own
    /// appearance (so a check landing mid-sentence never takes the editor
    /// away); cleared by Done. Per piece — the view is keyed by the piece.
    @State private var editorHeld = false

    static let strainsHelp = "The draft pulls against this"        // app copy; no model text
    static let silentHelp = "Nothing in this draft touches it"
    static let heading = "Going for"
    static let inTheCentreLine = "Open in the centre"
    static let emptyPrompt = "What is this piece going for? Write it here."
    static let noIntentLine = "No intent yet."
    /// The editor's height inside the scrolling pane.
    static let editorHeight: CGFloat = 220
    static let markScheme = "maugham-mark"
    /// SwiftUI's underline, named once (AppKit's has the same name).
    typealias Underline = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute

    /// **Which face Going for shows.** Pure.
    ///
    /// - The centre's cover wins outright (Review Focus 3).
    /// - A posture that refuses `.editStatement`, or another host holding the
    ///   statement, reads — never a second editor, never a disabled one.
    /// - Marks that apply read, until the writer asks to edit.
    /// - Everything else is the editor (an empty intent is an empty editor
    ///   that mints on the first keystroke, as the old pane did).
    static func mode(hasMarks: Bool, editingRequested: Bool, inTheCentre: Bool,
                     hasIntent: Bool, mayEdit: Bool = true,
                     heldElsewhere: Bool = false) -> GoingForMode {
        if inTheCentre { return .inTheCentre }
        if !mayEdit || heldElsewhere { return .reading }
        if hasMarks && !editingRequested { return .reading }
        return .editing
    }

    /// Whether the statement's `Document` is open in a host that is not this
    /// one. `openStatementDocument` is the store-wide registry every host
    /// registers in; ours is in it exactly while `editorHeld`.
    static func heldElsewhere(registryHoldsIt: Bool, editorHeldHere: Bool) -> Bool {
        registryHoldsIt && !editorHeldHere
    }

    private var statementId: String? {
        store.statement(kind: .intent, scope: .document(docId))?.id
    }

    private var isHeldElsewhere: Bool {
        // The registry is not observed; every open and close bumps the
        // revision, which is.
        _ = store.statementTextRevision
        let held = statementId.map { store.openStatementDocument(id: $0) != nil } ?? false
        return Self.heldElsewhere(registryHoldsIt: held, editorHeldHere: editorHeld)
    }

    private var hasIntent: Bool {
        !(essay ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var mode: GoingForMode {
        Self.mode(hasMarks: !marks.isEmpty, editingRequested: editorHeld,
                  inTheCentre: inTheCentre, hasIntent: hasIntent,
                  mayEdit: mayEdit, heldElsewhere: isHeldElsewhere)
    }

    var body: some View {
        let mode = self.mode
        VStack(alignment: .leading, spacing: 6) {
            header(mode)
            if isRead {
                face(mode)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brief.goingFor")
    }

    @ViewBuilder
    private func face(_ mode: GoingForMode) -> some View {
        switch mode {
        case .inTheCentre:
            quiet(Self.inTheCentreLine)
        case .reading:
            reading
        case .editing:
            if !hasIntent { quiet(Self.emptyPrompt) }
            StatementEditorHost(
                store: store, documentStore: documentStore,
                kind: .intent, scope: .document(docId), posture: posture)
                .frame(height: Self.editorHeight)
                .onAppear { editorHeld = true }
        }
    }

    @ViewBuilder
    private func header(_ mode: GoingForMode) -> some View {
        HStack(spacing: 8) {
            BriefPane.sectionHeading(Self.heading)
            Spacer(minLength: 0)
            if mode == .reading, mayEdit, !isHeldElsewhere {
                Button("Edit") { editorHeld = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if mode == .editing, editorHeld, !marks.isEmpty {
                Button("Done") { editorHeld = false }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if mode != .inTheCentre {
                Button { onOpenInCentre() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open in Centre")
                .accessibilityLabel("Open in Centre")
            }
        }
    }

    @ViewBuilder
    private var reading: some View {
        if let essay, hasIntent {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.paragraphs(of: essay, marks: marks).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                legend
            }
            .environment(\.openURL, OpenURLAction { url in
                if let quote = Self.strainQuote(for: url, marks: marks) {
                    onShowStrain(docId, quote)
                }
                return .handled
            })
        } else {
            quiet(Self.noIntentLine)
        }
    }

    /// One row per kind present; none when there are no marks.
    @ViewBuilder
    private var legend: some View {
        let kinds = Self.legendKinds(marks)
        if !kinds.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(kinds, id: \.self) { kind in
                    HStack(spacing: 6) {
                        Text("      ")
                            .underline(true, pattern: kind == .strains ? .solid : .dot)
                        Text(kind == .strains ? Self.strainsHelp : Self.silentHelp)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func quiet(_ line: String) -> some View {
        Text(line)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The marks, drawn (pure)

    /// The kinds the legend explains, solid first.
    static func legendKinds(_ marks: [ClauseMark]) -> [ClauseMark.Kind] {
        [ClauseMark.Kind.strains, .silent].filter { kind in marks.contains { $0.kind == kind } }
    }

    /// The essay as paragraphs (split on blank lines), each the WRITER's own
    /// characters with the marks that fall in it underlined: solid for
    /// `strains` (a `maugham-mark:<index>` link), dotted for `silent` (no
    /// link). Nothing is added to the text; a mark spanning a paragraph break
    /// marks each part in its own paragraph.
    static func paragraphs(of essay: String, marks: [ClauseMark]) -> [AttributedString] {
        let whole = essay as NSString
        var result: [AttributedString] = []
        var cursor = 0
        for piece in essay.components(separatedBy: "\n\n") {
            let length = (piece as NSString).length
            let range = NSRange(location: cursor, length: length)
            cursor += length + 2
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var attributed = AttributedString(whole.substring(with: range))
            for (index, mark) in marks.enumerated() {
                let overlap = NSIntersectionRange(mark.range, range)
                guard overlap.length > 0 else { continue }
                let local = NSRange(location: overlap.location - range.location, length: overlap.length)
                guard let span = Range(local, in: attributed) else { continue }
                switch mark.kind {
                case .strains:
                    attributed[span][Underline.self] = Text.LineStyle.single
                    attributed[span].link = URL(string: "\(markScheme):\(index)")
                case .silent:
                    attributed[span][Underline.self] = Text.LineStyle(pattern: .dot)
                }
            }
            result.append(attributed)
        }
        return result
    }

    /// The check's quote a clicked mark asks To resolve for — a SOLID mark's
    /// only; a dotted mark carries no link, and anything else is nil.
    static func strainQuote(for url: URL, marks: [ClauseMark]) -> String? {
        guard url.scheme == markScheme,
              let index = Int(url.absoluteString.dropFirst(markScheme.count + 1)),
              marks.indices.contains(index), marks[index].kind == .strains else { return nil }
        return marks[index].clauseQuote
    }
}
