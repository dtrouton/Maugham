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

/// **Going for** — a piece's intent, or the Book's, in Brief (spec "Brief"
/// §2; the Book's since Task 5, at scope `.project`, where no check reads and
/// so no mark ever applies).
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
    /// Whose intent: `.document(id)` for a piece, `.project` for the Book.
    let scope: Statement.Scope
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
    static let bookEmptyPrompt = "What is this book going for? Write it here."
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

    /// The prompt over an empty intent's editor, by whose intent it is.
    static func emptyPrompt(for scope: Statement.Scope) -> String {
        if case .document = scope { return emptyPrompt }
        return bookEmptyPrompt
    }

    /// **What each face draws** (Task 5). While the statement is the
    /// centre's cover, Brief still READS it — the placeholder line over the
    /// reading view, marks only while they apply to the live text — and
    /// never mounts an editor: the centre's host holds the `Document`.
    struct Face: Equatable {
        let placeholder: Bool
        let reading: Bool
        let editor: Bool
    }

    static func face(_ mode: GoingForMode) -> Face {
        switch mode {
        case .inTheCentre: return Face(placeholder: true, reading: true, editor: false)
        case .reading: return Face(placeholder: false, reading: true, editor: false)
        case .editing: return Face(placeholder: false, reading: false, editor: true)
        }
    }

    /// Whether the statement's `Document` is open in a host that is not this
    /// one. `openStatementDocument` is the store-wide registry every host
    /// registers in; ours is in it exactly while `editorHeld`.
    static func heldElsewhere(registryHoldsIt: Bool, editorHeldHere: Bool) -> Bool {
        registryHoldsIt && !editorHeldHere
    }

    private var statementId: String? {
        store.statement(kind: .intent, scope: scope)?.id
    }

    /// The essay the reading face draws. While the centre holds the
    /// statement and no mark applies, the centre's live text, so Brief reads
    /// along as the writer types there (observed through the live
    /// `Document`, with no re-read of the scope per keystroke). Marks are
    /// placed on the read essay, so a face with marks keeps it — they apply
    /// only while the live text is the text the check read.
    private var shownEssay: String? {
        guard inTheCentre, marks.isEmpty, let statementId,
              let live = store.openStatementDocument(id: statementId) else { return essay }
        return StatementEssay.half(of: live.displayText)
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

    private var strainDocId: String? {
        if case .document(let docId) = scope { return docId }
        return nil
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
                faceView(mode)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brief.goingFor")
    }

    @ViewBuilder
    private func faceView(_ mode: GoingForMode) -> some View {
        let face = Self.face(mode)
        if face.placeholder {
            quiet(Self.inTheCentreLine)
        }
        if face.reading {
            reading
        }
        if face.editor {
            if !hasIntent { quiet(Self.emptyPrompt(for: scope)) }
            StatementEditorHost(
                store: store, documentStore: documentStore,
                kind: .intent, scope: scope, posture: posture)
                .frame(height: Self.editorHeight)
                .onAppear { editorHeld = true }
                // Whatever takes the editor away (Done, a refusing posture,
                // the centre's cover), it is no longer held here.
                .onDisappear { editorHeld = false }
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
        if let essay = shownEssay,
           !essay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.paragraphs(of: essay, marks: marks).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.callout)
                        // A solid mark is a link (its click target); the
                        // writer's words keep their own ink — a mark is a
                        // line, never a tint.
                        .tint(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                legend
            }
            .environment(\.openURL, OpenURLAction { url in
                if let docId = strainDocId, let quote = Self.strainQuote(for: url, marks: marks) {
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

    /// **The essay as the statement editor's blocks**, each the WRITER's own
    /// words with the marks that fall in it underlined: solid for `strains`
    /// (a `maugham-mark:<index>` link), dotted for `silent` (no link).
    ///
    /// Blocks come from `MarkdownBlockParser` (the parser the editor and
    /// publishing share): a heading draws without its `#`s and bold, a fence
    /// in monospace without its fence lines, and `*emphasis*` / `**strong**`
    /// as italic / bold without their markers. Only those ASCII markers are
    /// dropped, and every drawn unit remembers its offset in the essay, so a
    /// mark's essay range lands on exactly the words it covers. Nothing is
    /// added; nothing is recoloured (the solid mark's link keeps the prose's
    /// ink — the view tints links `.primary`).
    static func paragraphs(of essay: String, marks: [ClauseMark]) -> [AttributedString] {
        let whole = essay as NSString
        let lines = essay.components(separatedBy: "\n")
        var lineStarts: [Int] = []
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += (line as NSString).length + 1
        }
        func lineRange(_ index: Int) -> NSRange {
            NSRange(location: lineStarts[index], length: (lines[index] as NSString).length)
        }

        var result: [AttributedString] = []
        for (block, span) in MarkdownBlockParser.parseWithLineRanges(essay) where !span.isEmpty {
            var segments: [NSRange] = span.map(lineRange)
            var style: BlockStyle = .prose
            switch block {
            case .heading:
                style = .heading
                if let first = segments.first {
                    let text = whole.substring(with: first) as NSString
                    let prefix = text.range(of: #"^\s{0,3}#{1,6}\s*"#, options: .regularExpression)
                    let cut = prefix.location == NSNotFound ? 0 : prefix.length
                    segments = [NSRange(location: first.location + cut, length: first.length - cut)]
                }
            case .fence:
                style = .code
                segments = segments.filter {
                    !whole.substring(with: $0).trimmingCharacters(in: .whitespaces).hasPrefix("```")
                }
            case .paragraph, .list, .table, .blockquote, .thematicBreak, .soloImage:
                break
            }
            guard let rendered = Rendered(whole, segments: segments, emphasis: style != .code),
                  !rendered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var attributed = AttributedString(rendered.text)
            switch style {
            case .heading: attributed.inlinePresentationIntent = .stronglyEmphasized
            case .code: attributed.inlinePresentationIntent = .code
            case .prose: break
            }
            for (range, intent) in rendered.emphasis {
                if let local = rendered.output(of: range), let span = Range(local, in: attributed) {
                    attributed[span].inlinePresentationIntent = intent
                }
            }
            for (index, mark) in marks.enumerated() {
                guard let local = rendered.output(of: mark.range),
                      let span = Range(local, in: attributed) else { continue }
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

    private enum BlockStyle { case prose, heading, code }

    /// A block's drawn text, and for each drawn UTF-16 unit its offset in the
    /// essay — the map a mark's essay range is carried through.
    private struct Rendered {
        let text: String
        let map: [Int]
        /// Essay ranges of emphasised content, and how to draw each.
        var emphasis: [(NSRange, InlinePresentationIntent)] = []

        private static let strong = try! NSRegularExpression(
            pattern: #"(?<![\w*_])(\*\*|__)(?=\S)(.+?)(?<=\S)\1(?![\w*_])"#)
        private static let emphasised = try! NSRegularExpression(
            pattern: #"(?<![\w*_])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![\w*_])"#)

        init?(_ whole: NSString, segments: [NSRange], emphasis: Bool) {
            var units: [unichar] = []
            var map: [Int] = []
            for (n, segment) in segments.enumerated() {
                if n > 0, let last = map.last { units.append(10); map.append(last) }
                var dropped = Set<Int>()
                if emphasis {
                    let line = whole.substring(with: segment)
                    let ns = line as NSString
                    var taken = IndexSet()
                    for (regex, intent) in [(Self.strong, InlinePresentationIntent.stronglyEmphasized),
                                            (Self.emphasised, InlinePresentationIntent.emphasized)] {
                        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                            let whole = match.range
                            guard !taken.intersects(integersIn: whole.location..<NSMaxRange(whole)) else { continue }
                            taken.insert(integersIn: whole.location..<NSMaxRange(whole))
                            let marker = match.range(at: 1).length
                            for i in 0..<marker {
                                dropped.insert(segment.location + whole.location + i)
                                dropped.insert(segment.location + NSMaxRange(whole) - 1 - i)
                            }
                            let content = match.range(at: 2)
                            self.emphasis.append((NSRange(location: segment.location + content.location,
                                                          length: content.length), intent))
                        }
                    }
                }
                for i in segment.location..<NSMaxRange(segment) where !dropped.contains(i) {
                    units.append(whole.character(at: i))
                    map.append(i)
                }
            }
            guard !units.isEmpty else { return nil }
            self.text = String(utf16CodeUnits: units, count: units.count)
            self.map = map
        }

        /// The drawn range covering the essay range `range`, or nil when none
        /// of its units is drawn here.
        func output(of range: NSRange) -> NSRange? {
            guard let first = map.firstIndex(where: { $0 >= range.location && $0 < NSMaxRange(range) }),
                  let last = map.lastIndex(where: { $0 >= range.location && $0 < NSMaxRange(range) })
            else { return nil }
            return NSRange(location: first, length: last - first + 1)
        }
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
