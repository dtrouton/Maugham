import SwiftUI
import AppKit

/// **What an edition's centre column puts over the manuscript stack**
/// (shell-finish stage 3b Task 5, revised by Denver's rulings of 2026-08-12).
///
/// One value with two arms, answered by `ProjectWindow.publishCentre`, so the
/// window has a single question to ask rather than one gate per surface. Two
/// gates would be two answers free to disagree about what is in the centre
/// column — and here that disagreement would be a "nothing published yet"
/// notice sitting on top of the writer's compiled book.
///
/// **Neither arm is reachable over a chapter.** Denver, 2026-08-12: *"a
/// chapter/piece subject in Publish ALWAYS opens the editor — I might tweak
/// something for layout."* The preview and its notices are PROJECT-level
/// surfaces, which is why the rule now asks the subject question at all (it
/// took none until this revision).
enum PublishCentre: Equatable {
    /// **The publish problems the desk's Show Problems asked for** (report
    /// foundations plan 2, Task 8, ruling R-S12). It outranks the round and the
    /// gate because it is what the writer just asked for, and like the round it
    /// draws over a chapter: Back or a Show in Manuscript clears it.
    case problems([TectonicLogParser.Diagnostic])
    /// **A translation round the writer asked to read** (translation pipeline P4
    /// Task 3) — the department desk's other Show, answered in this column.
    ///
    /// It outranks the gate below it, which outranks the book, for the reason
    /// the gate outranks the book: two Shows now reach this column from the same
    /// desk, each clearing the other as it writes (`ProjectWindow`'s desk
    /// wiring), so the last thing the writer pressed is the thing on screen and
    /// an order is what makes that true rather than two independent gates.
    ///
    /// The round travels whole rather than by `(language, number)`: the desk
    /// just read it off `TranslationRoundStore` to draw the row that offered the
    /// Show, and a second read here would be a second answer about the same
    /// file. This arm carries no state of its own, so deselecting costs nothing.
    case translationRound(TranslationRound)
    /// **A design proposal the writer asked to look at** (publish-department P4
    /// Task 5) — the department desk's Show, answered in this column.
    ///
    /// It outranks the two arms below while it is selected, for the reason the
    /// book outranks altitude: the writer asked for the proposal, and a compiled
    /// PDF drawn over the thing they asked to see is the truth table upside
    /// down. Deselecting hands the column straight back — this arm carries no
    /// state of its own, so there is nothing for leaving it to cost.
    ///
    /// The proposal travels whole rather than by id: it was just read off disk
    /// by the desk that offered the Show, and a second read here would be a
    /// second answer about the same file.
    case designProposal(DesignProposalStore.Proposal)
    /// Every readable PDF, newest first and non-empty. WHICH of them is drawn is
    /// the header picker's business — a window-transient choice — and
    /// deliberately not this rule's: a rule that carried the selection would be
    /// re-decided on every keystroke of window state.
    case books([Publication])
    /// Nothing to draw, and the reason kept — see `PublishCentreNotice`.
    case notice(PublishCentreNotice)
}

/// **The two ways Publish has no book to show, kept apart on screen.**
///
/// RULING-7's shape ("unreadable is never presented as empty") is why
/// `PublishPreviewResolution` carries a reason rather than an optional; until
/// Denver's 2026-08-12 ruling that distinction lived only in the value and both
/// degrades looked identical to the writer — a bare corkboard, which is what
/// read to him as *"basically Author"*. Each now says its own thing, and they
/// are DIFFERENT things: one is a project that has not been compiled, the other
/// is a project whose catalog is sitting right there and cannot be read.
enum PublishCentreNotice: Equatable {
    /// The catalog was read and holds no PDF this column can draw.
    case neverCompiled
    /// The catalog exists and could not be read, carrying the failure's own
    /// sentence — which already NAMES the file (`PublicationStore.ReadError
    /// .unreadableFile`), so the banner does not have to invent a name for it.
    case unreadableCatalog(reason: String)

    var headline: String {
        switch self {
        case .neverCompiled:
            return "No compiled book yet"
        case .unreadableCatalog:
            return "Preview unavailable — the publications catalog can't be read"
        }
    }

    var detail: String {
        switch self {
        case .neverCompiled:
            return "Your published output will appear here."
        case .unreadableCatalog(let reason):
            return reason
        }
    }

    /// Distinct at a glance, which is the point of keeping the two cases: a
    /// writer must never mistake "your book can't be read from here" for "you
    /// haven't made one yet".
    var symbol: String {
        switch self {
        case .neverCompiled: return "book.closed"
        case .unreadableCatalog: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .neverCompiled: return .secondary
        case .unreadableCatalog: return .orange
        }
    }
}

/// **The centre column of an edition: the book itself** (shell-finish
/// stage 3b Task 5, spec §4's Publish column).
///
/// Denver's rulings, recorded: the compiled book is a PROJECT-level surface (a
/// chapter subject opens the editor, because a writer in Publish still tweaks
/// things for layout), and the header carries a picker over every readable PDF
/// publication so a writer can put the previous version — or another language
/// edition — on screen. Which one is showing is window-transient and never
/// persisted: a relaunch is the newest book, always.
///
/// A header over `PDFPreview` (`Maugham/Views/research/PDFPreview.swift`),
/// reused rather than copied: one `PDFView` configuration in the app, so the
/// research preview and the book cannot come to scroll differently.
///
/// **Opaque and full-frame on purpose.** This is the third layer of
/// `CentreColumn.manuscriptEditor`'s `ZStack` — `EditorHost` is still mounted
/// underneath it (and the altitude view is too, since both are project-level),
/// and anything translucent would read the corkboard through the page.
///
/// `title` is the PROJECT's, not the publication's: a `Publication` carries a
/// version, a language and a date, and none of them says which book this is.
struct PublishPreviewCentre: View {
    /// Newest first, non-empty — `PublishCentre.books`' own contract.
    let publications: [Publication]
    let projectURL: URL
    let title: String
    /// The writer's pick, by `publicationID`. `nil` is "the newest", which is
    /// also what a new compile resets it to (`PublishPreviewModifier`).
    @Binding var selectedPublicationID: String?
    /// **Which edition's book this is** (shell p4 Task 5) — the tag its
    /// anchors carry is read off it per publication
    /// (`PublishPreviewResolver.bodyTag`). Nil draws the book alone.
    var edition: EditionBook? = nil
    /// **The piece on the faces**, when it is a document: the page goes to
    /// where it starts. Nil leaves the page where the writer put it.
    var piece: PieceInBook? = nil
    /// The piece's paragraph order, no load (`currentParagraphState`).
    var sequence: (String) -> [String]? = { _ in nil }
    /// Every piece's paragraph order, from the window's presence read
    /// (`BinderTreeSectionsState.bookReading`): a ¶id another piece also has
    /// is never trusted as this piece's anchor (`PDFAnchors.locate`).
    var sequences: () -> [String: [String]] = { [:] }
    /// Compile… and the imprint picker, under the title.
    var bar: EditionCompileBar? = nil

    /// What the page knows about the faced piece, for the shown book.
    @State private var place: PiecePlace?
    /// The shown book's anchors, read once per publication off the main
    /// actor; every click after the first is a dictionary lookup.
    @State private var anchors: (publication: String, pages: [String: Int])?
    /// Each resolve's serial — what makes a second ask for the same page a
    /// new ask (`PDFPreview.Target`).
    @State private var serial = 0
    /// The header's "starts on page N" presses: going back after scrolling.
    @State private var goBack = 0

    /// Never resolved locally — `PublishPreviewResolver.shown` owns the fallback
    /// so that a pick whose row has left the list still draws the newest book
    /// rather than an empty column.
    private var shown: Publication? {
        PublishPreviewResolver.shown(selectedPublicationID, in: publications)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let bar {
                if place == .noAnchors {
                    bar.hinting(PiecePlace.compileAgainLine)
                } else {
                    bar
                }
            }
            placeLine
            Divider()
            if let shown, let url = PublishPreviewResolver.fileURL(of: shown, in: projectURL) {
                PDFPreview(fileURL: url, target: place?.target)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        // **Once per ask**: a new book, a new piece, or the header's "starts
        // on page N". The anchors are read off the main actor once per book.
        .task(id: PiecePlace.Key(publication: shown?.publicationID, piece: piece?.id, ask: goBack)) {
            let next = await locate()
            guard !Task.isCancelled else { return }
            place = next
        }
    }

    /// **Where the faced piece is, said under the bar**: its first page as a
    /// control that goes back there; not in this book; or no telling.
    @ViewBuilder
    private var placeLine: some View {
        switch place {
        case .page(let page, _):
            if let piece {
                Button {
                    goBack &+= 1
                } label: {
                    Label(PiecePlace.startsLine(piece.title, page: page), systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help("Go back to where \(piece.title) starts")
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .notInBook(let title), .ambiguous(let title):
            Text(place == .notInBook(title) ? PiecePlace.notInBookLine(title)
                                            : PiecePlace.ambiguousLine(title))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .noAnchors, .none:
            EmptyView()
        }
    }

    /// Where the faced piece starts in the shown book, or why it cannot.
    private func locate() async -> PiecePlace? {
        guard let piece, let edition, let shown,
              let url = PublishPreviewResolver.fileURL(of: shown, in: projectURL) else { return nil }
        let pages: [String: Int]
        if let anchors, anchors.publication == shown.publicationID {
            pages = anchors.pages
        } else {
            pages = await Task.detached(priority: .userInitiated) {
                PDFAnchors.anchorPages(inFileAt: url)
            }.value
            guard !Task.isCancelled else { return place }
            anchors = (shown.publicationID, pages)
        }
        guard !pages.isEmpty else { return .noAnchors }
        guard let tag = PiecePlace.bodyTag(of: shown, edition: edition, pages: pages) else {
            return .notInBook(piece.title)
        }
        var sequences = sequences()
        if let own = sequence(piece.id) { sequences[piece.id] = own }
        serial &+= 1
        return PiecePlace(PDFAnchors.locate(piece: piece.id, bodyTag: tag, sequences: sequences,
                                            pages: pages),
                          title: piece.title, ask: serial)
    }

    /// **The header, and the one place this view branches on VoiceOver rather
    /// than on layout.**
    ///
    /// With a single publication the row is four labels and no control, so it is
    /// COMBINED into one sentence — *"The Novel, v1.0 · ES · 12 Aug 2026 at
    /// 15:04"* — which is what this column read before the picker existed and is
    /// the right reading: four fragments swept past one arrow key at a time say
    /// less than the sentence they make together.
    ///
    /// With a choice to make the row must NOT combine, and that is the whole
    /// reason for the branch: `.combine` flattens its children into one static
    /// element, and the child it would flatten here is the `Picker` — the only
    /// way to reach another publication without a mouse. Combining it away
    /// would trade a slightly better sentence for a control a VoiceOver user
    /// cannot operate. Uncombined, the title reads itself and the picker
    /// announces its own label and value.
    @ViewBuilder
    private var header: some View {
        if publications.count > 1 {
            headerRow
        } else {
            headerRow
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if publications.count > 1 {
                picker
            } else if let shown {
                stamp(for: shown)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// **Every readable PDF, newest first** — EPUBs are the Exports footer's
    /// business, since this column draws pages. Shown only when there is a
    /// choice to make: a one-entry menu is chrome about nothing, which is the
    /// same argument the language capsule below already makes for itself.
    private var picker: some View {
        Picker("Publication", selection: Binding(
            get: { shown?.publicationID },
            set: { selectedPublicationID = $0 })) {
                ForEach(publications, id: \.publicationID) { publication in
                    Text(Self.label(for: publication))
                        .tag(Optional(publication.publicationID))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Publication")
    }

    /// The single-publication header: what this column showed before there was
    /// anything to choose between. Draws `parts(for:)` — the language part
    /// keeps its capsule, everything else is a plain caption — so this and
    /// `label(for:)` can never describe the same publication differently.
    @ViewBuilder
    private func stamp(for publication: Publication) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.parts(for: publication).enumerated()), id: \.offset) {
                _, part in
                if let language = publication.language, part == language.uppercased() {
                    Text(part)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                } else {
                    Text(part)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        guard let shown else { return title }
        return "\(title), \(Self.label(for: shown))"
    }

    /// One row of the menu, and the header's own sentence: version, imprint
    /// when there is one, language when there is one, and when it was
    /// compiled — the full identity a publication carries as of the imprints
    /// work (P1's `imprint`, P2's joined language identity). Built from
    /// `parts(for:)`, so `stamp(for:)` draws the same sequence rather than a
    /// hand-built twin of it.
    static func label(for publication: Publication) -> String {
        parts(for: publication).joined(separator: " · ")
    }

    /// **The one composition of a publication's identity**, read off the
    /// record rather than re-derived from a filename (spec §6): version,
    /// imprint (when there is one), language (when there is one, already
    /// uppercased — a joined `"en+sr"` reads as `"EN+SR"`), then when it was
    /// compiled. `label(for:)`, `stamp(for:)` and
    /// `DepartmentCompileState.completedLine` all draw from this, so no two
    /// surfaces that name a book can disagree about what it's called.
    static func parts(for publication: Publication) -> [String] {
        // A row is named as a draft only when its format mints drafts: a
        // version of any other format is "v…", whatever it spells.
        let draftName = publication.format.mintsDrafts
            ? WordDraft.displayName(ofVersion: publication.version) : nil
        var parts = [draftName ?? "v\(publication.version)"]
        if let imprint = publication.imprint { parts.append(imprint) }
        if let language = publication.language { parts.append(language.uppercased()) }
        parts.append(compiled.string(from: publication.compiledAt))
        return parts
    }

    private static let compiled: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// **An edition, as the book's header needs it** (shell p4 Task 5): its tag
/// and the book's own, which together say which body of a publication is
/// this edition's (`PublishPreviewResolver.bodyTag`).
struct EditionBook: Equatable {
    let language: String
    let sourceLanguage: String
}

/// **The piece on the faces**, by id and title (the not-in-book line).
struct PieceInBook: Equatable {
    let id: String
    let title: String
}

/// **Where the faced piece is in the shown book**: a page, or not in it (a
/// book compiled before anchors, or an imprint that leaves the piece out) —
/// the page then stays where it was and the header says so.
enum PiecePlace: Equatable {
    /// Its first page, and which ask found it — a new ask for the same page
    /// goes there again.
    case page(Int, ask: Int)
    case notInBook(String)
    /// Its anchors resolve, but none is surely its own (two pieces share it).
    case ambiguous(String)
    /// The book carries no paragraph anchors: compiled before they existed.
    case noAnchors

    init(_ location: PDFAnchors.Location, title: String, ask: Int) {
        switch location {
        case .page(let page): self = .page(page, ask: ask)
        case .notInBook: self = .notInBook(title)
        case .ambiguous: self = .ambiguous(title)
        case .noAnchors: self = .noAnchors
        }
    }

    /// What the PDF view goes to.
    var target: PDFPreview.Target? {
        if case .page(let page, let ask) = self { return .init(page: page, ask: ask) }
        return nil
    }

    static func notInBookLine(_ title: String) -> String {
        "\(title) is not in this book"
    }

    static func ambiguousLine(_ title: String) -> String {
        "Can\u{2019}t tell where \(title) starts in this book"
    }

    static func startsLine(_ title: String, page: Int) -> String {
        "\(title) starts on page \(page + 1)"
    }

    /// Said once, beside Compile…, for a book with no paragraph anchors.
    static let compileAgainLine = "Compile again to jump to chapters"

    /// **The tag this edition's body carries in the book**, checked against
    /// the tags its anchors actually use: a one-body book whose compile spelled
    /// its tag otherwise (an imprint's own `metadata.language`, or the ordinal a
    /// tag that cannot be a filename becomes) is read by the one tag it has.
    static func bodyTag(of publication: Publication, edition: EditionBook,
                        pages: [String: Int]) -> String? {
        guard let tag = PublishPreviewResolver.bodyTag(
            of: publication, edition: edition.language, sourceLanguage: edition.sourceLanguage)
        else { return nil }
        let tags = PDFAnchors.tags(in: pages)
        if tags.contains(tag) { return tag }
        let oneBody = !(publication.language ?? "").contains("+")
        return oneBody && tags.count == 1 ? tags.first : tag
    }

    /// The task's key: a new book, a new piece, or a going-back is a new ask.
    struct Key: Equatable {
        let publication: String?
        let piece: String?
        var ask: Int = 0
    }
}

/// **Compile… and the imprint picker, in the edition's book header** (shell
/// p4 Task 5), moved from the desk: where the writer looks when looking at
/// the book. Values and closures; the compile runs on the window's
/// `PublishCentreModel.compileRunner`, so it survives the column going.
///
/// One line at the column's floor: the picker and the buttons keep their
/// size, the status sentence truncates (its whole text is the help).
struct EditionCompileBar: View {
    let imprints: [String]
    let selectedImprint: String?
    let selectImprint: (String?) -> Void
    let compileRun: DepartmentCompileState
    /// This edition's tag, checked in the sheet; nil for the Source, where
    /// the book's own language is.
    let editionLanguage: String?
    /// Every edition's tag, the Source first — read when Compile… is
    /// pressed (`TreeEditionRows.languages`), never on a body path.
    let editions: () -> [String]
    let runCompile: (DeskCompileRunner.Request) -> Void
    let cancelCompile: () -> Void
    let showProblems: () -> Void
    /// A line beside Compile… when the book asks for one (a book compiled
    /// before chapter anchors existed).
    var hint: String? = nil

    @State private var sheet: EditionCompileAsk?

    /// The same bar, saying `hint` beside Compile….
    func hinting(_ hint: String) -> EditionCompileBar {
        var copy = self
        copy.hint = hint
        return copy
    }

    var body: some View {
        HStack(spacing: 8) {
            if !imprints.isEmpty {
                Picker(DepartmentDesk.imprintLabel,
                       selection: Binding(get: { selectedImprint }, set: { selectImprint($0) })) {
                    Text(DepartmentDesk.bookImprintTitle).tag(String?.none)
                    ForEach(imprints, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                // A long imprint name truncates rather than pushing Cancel
                // off the column at its floor.
                .frame(maxWidth: 160)
                .help(DepartmentDesk.imprintHelp)
            }
            Button(DepartmentDesk.compileTitle) {
                sheet = EditionCompileAsk.make(editions: editions(), edition: editionLanguage)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(compileRun.isRunning)
            .help(compileRun.isRunning ? DepartmentCompileState.alreadyRunning
                                       : DepartmentDesk.compileHelp)
            if compileRun.isRunning {
                ProgressView().controlSize(.small)
            }
            if compileRun.statusLine == nil, !compileRun.isRunning, let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(hint)
                    .layoutPriority(-1)
            }
            if let status = compileRun.statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(compileRun.isFailure ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(status)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if compileRun.offersShowProblems {
                Button(DepartmentCompileState.showProblemsTitle) { showProblems() }
                    .controlSize(.small)
                    .fixedSize()
                    .help(DepartmentCompileState.showProblemsHelp)
            }
            if compileRun.isRunning {
                Button(DepartmentCompileState.cancelTitle) { cancelCompile() }
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(DepartmentDesk.cancelCompileLabel)
                    .help(DepartmentDesk.cancelCompileHelp)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .sheet(item: $sheet) { ask in
            DepartmentCompileSheet(
                languages: ask.languages, bookLanguage: ask.bookLanguage,
                imprint: selectedImprint,
                initiallyIncludesBook: ask.includesBook,
                initiallySelected: ask.selected,
                onCompile: { request in
                    sheet = nil
                    runCompile(request)
                },
                onCancel: { sheet = nil })
        }
    }
}

/// **What Compile… asks, from an edition** (shell p4 Task 5): the desk's
/// sheet, with this edition's language checked — the book's own language for
/// the Source, only the translation for a translated edition.
struct EditionCompileAsk: Identifiable, Equatable {
    let languages: [String]
    let bookLanguage: String
    let includesBook: Bool
    let selected: Set<String>
    var id: String { bookLanguage + "|" + languages.joined(separator: ",") }

    /// `editions` is the tree's list, the Source first; `edition` this
    /// edition's tag, nil for the Source.
    static func make(editions: [String], edition: String?) -> EditionCompileAsk {
        let book = editions.first ?? PublishConfig.Metadata().language
        var others = editions.dropFirst().filter { $0.caseInsensitiveCompare(book) != .orderedSame }
        if let edition, edition.caseInsensitiveCompare(book) != .orderedSame,
           !others.contains(where: { $0.caseInsensitiveCompare(edition) == .orderedSame }) {
            others.append(edition)
        }
        let picked = edition.flatMap { tag in
            others.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        return EditionCompileAsk(languages: Array(others), bookLanguage: book,
                                 includesBook: picked == nil,
                                 selected: picked.map { [$0] } ?? [])
    }
}

/// **An edition with no book to show, and its Compile…** (shell p4 Task 5):
/// the header bar, opaque and taking its own clicks, over the standing
/// notice, which takes none — the Book's view stays readable beneath.
struct EditionNoticeCover: View {
    let notice: PublishCentreNotice
    let bar: EditionCompileBar?

    var body: some View {
        VStack(spacing: 0) {
            if let bar {
                bar
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }
            PublishCentreNoticeBanner(notice: notice)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// **The standing notice over the project at altitude** (Denver, 2026-08-12).
///
/// A BANNER rather than a `ContentUnavailableView`, because the centre column is
/// not empty: the corkboard/outline is underneath and is real, usable content.
/// The banner names why there is no book over it — the bare unexplained
/// altitude is what read as *"basically Author"* and sent Denver looking for the
/// missing feature.
///
/// **`allowsHitTesting(false)` is load-bearing, not tidiness.** The banner fills
/// the column (top-aligned) so it can sit at the head of whatever is beneath it;
/// without this, that frame would swallow every click meant for the altitude
/// view's cards and rows — the surface the notice exists to explain.
struct PublishCentreNoticeBanner: View {
    let notice: PublishCentreNotice

    var body: some View {
        PublishNoticeLine(headline: notice.headline, detail: notice.detail,
                          symbol: notice.symbol, tint: notice.tint)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

/// **The house shape for "Maugham couldn't read this"** — a symbol, a headline
/// and the failure's own sentence under it, in a bordered card.
///
/// Extracted from `PublishCentreNoticeBanner` when Publish grew a second place
/// to say it (issue #43, F-D: the department desk names a chapter whose history
/// file it could not open). Plain strings rather than `PublishCentreNotice`,
/// because the desk's line is about one document rather than about the centre
/// column's two ways of having no book — and two hand-built cards that looked
/// almost alike would be the writer learning the same signal twice.
///
/// The banner keeps its own outer frame, `allowsHitTesting(false)` and padding:
/// those are about standing over the altitude view, which is that surface's
/// concern and not this shape's.
struct PublishNoticeLine: View {
    let headline: String
    let detail: String
    /// Defaults to the warning triangle, which is what every caller so far is:
    /// something present that cannot be read.
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail)")
    }
}

/// **Keeping the centre column's book current**, with no watcher and no poll.
///
/// Three triggers, and each answers a way the answer can go stale:
///
/// - **The window opens** (`.task(id:)`) — the writer relaunches into Publish.
/// - **A compile completes** — `PublishOrchestrator` posts
///   `.maughamPublicationCompleted` AFTER appending to the catalog, scoped
///   `.project`; received through the ADR 0021 helper, which filters to this
///   project and drops closed windows.
/// - **Opening an edition** (`.onChange(of: subject.open)`) — which also covers the
///   export a writer deleted in the Finder while they were elsewhere. That is
///   deliberately not a directory watcher: the staleness only matters when the
///   book is about to be on screen, and a watcher would be a second source of
///   truth about a file the resolver already checks.
///
/// **It is also where a new compile takes the writer's manual pick away**
/// (Denver, 2026-08-12: *"a NEW compile snaps the preview back to the
/// newest"*). The reset is keyed on the NEWEST publication changing rather than
/// on the refresh happening, so walking out of an edition and back keeps whatever
/// the writer was looking at — a refresh is not news, a new book is. The rule
/// itself is `PublishCentreModel.publishSelection(after:)`; this is what calls it.
///
/// A modifier rather than lines in `ProjectWindow.body`, which has no expression
/// budget under the Release type-checker. Delete the one line that applies it
/// and every token in this file is still present, every decision test still
/// green, and the writer's compile never reaches the centre column.
struct PublishPreviewModifier: ViewModifier {
    let projectURL: URL
    /// Hosting window for ADR 0021's project scope + closed-window liveness
    /// guard, the `ExportsListView` idiom.
    let window: NSWindow?
    /// Read, never written: this only wants to know when an edition opens in
    /// the centre, or stops being there.
    let subject: WindowSubject
    /// **The centre column's state, owned by the window** (foundations plan 4
    /// Task 2). This modifier is the only writer of its books
    /// (`publishSelection(after:)`, which carries the new-compile reset), and it
    /// lets the desk's two decisions go whenever the centre's `open` changes
    /// (`clearDecisions`) while keeping the book's pick — the asymmetry
    /// `PublishCentreModel.clearDecisions` argues. Here rather than in a
    /// modifier of its own because this is already the one place that owns the
    /// Publish centre's transient picks, and the body it hangs off has no
    /// expression budget (the Release type-check ceiling).
    let centre: PublishCentreModel
    /// The project, for the manuscript ids the source tag is resolved over.
    var store: ProjectStore? = nil

    func body(content: Content) -> some View {
        content
            .task(id: projectURL) { await refresh() }
            // **The window's compile settling** (shell p4 Task 5): the one
            // observer of `compileRunner`, wherever it was pressed — a
            // refusal over the manuscript's problems covers the centre.
            .onChange(of: centre.compileRunner.state) { old, new in
                centre.compileSettled(from: old, to: new)
            }
            .onProjectEvent(.maughamPublicationCompleted,
                            url: projectURL, window: window) { _ in
                Task { await refresh() }
            }
            .onChange(of: subject.open) { _, next in
                // Before the arrival guard: leaving an edition is a change of
                // `open` too, and it is the one that most needs the gate let go
                // of. A click on a piece while an edition is open moves only the
                // faces, so it lets nothing go.
                centre.clearDecisions()
                guard case .edition = next else { return }
                Task { await refresh() }
            }
            // **The gate's proposal goes stale where it sits** (the final-review
            // wave). It is a VALUE the writer opened with, and three things move
            // the record underneath it: a new round stages and supersedes it, a
            // promotion rewrites its status from the desk or another window, and
            // `.maugham/design/` is derived — a writer who clears it deletes the
            // very folder the gate is describing. `.project`-scoped through the
            // ADR 0021 helper, which drops the post for a closed window.
            .onProjectEvent(.maughamDesignProposalsChanged,
                            url: projectURL, window: window) { _ in
                centre.rereadProposal {
                    try? DesignProposalStore(projectURL: projectURL).load(id: $0)
                }
            }
    }

    private func refresh() async {
        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: projectURL),
            projectURL: projectURL)
        let next = await PublishPreviewResolver.readablePDFs(
            store: stores.publicationStore, projectURL: projectURL)
        // **The config, read once with the catalog** (shell p4 Task 5): which
        // edition is the Source, and the header's imprint rows — the desk's
        // own two readings of it (`DepartmentPaneHost.derive`).
        let config = (try? PublishConfigStore.read(in: projectURL)) ?? nil
        centre.sourceLanguage = DepartmentPaneHost.sourceLanguage(
            imprint: nil, in: config, pieceIDs: manuscriptIDs())
        centre.imprints = DepartmentPaneHost.imprintNames(in: config)
        centre.publishSelection(after: next)
    }

    /// The manuscript's document ids, for an imprint's `sections` fold —
    /// empty with no store (the source tag then comes from the top level).
    private func manuscriptIDs() -> [String] {
        store.map { EditionStatus.manuscriptDocumentIds(in: $0.manifest) } ?? []
    }
}
