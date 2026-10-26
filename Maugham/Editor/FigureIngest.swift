import Foundation
import AppKit
import UniformTypeIdentifiers
import ImageIO
import MaughamCore

/// **Insert Figure…'s open panel, as a value** (plan 3a Task 6). A test pins
/// this struct and never allocates a panel (CLAUDE.md; `AddFilePanelConfiguration`
/// is the precedent, and TROUBLESHOOTING.md says why).
struct FigureImagePanelConfiguration: Equatable {
    let allowedContentTypes: [UTType]
    let canChooseFiles: Bool
    let canChooseDirectories: Bool
    let allowsMultipleSelection: Bool
    let prompt: String

    func apply(to panel: NSOpenPanel) {
        panel.allowedContentTypes = allowedContentTypes
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.prompt = prompt
    }
}

/// **An image figure** (plan 3a Task 6, R-3a-4; report plan 6a Task 9): an
/// image from Insert Figure… (⌘⇧I), a drop or a paste becomes an image
/// figure — its file in the project's `figures/`, its hash in the op log
/// (`ProjectStore.createImageFigure`) — and
/// `![Caption](relative/path){#fig:name}` is written as its own paragraph
/// with `Caption` selected. Figure lines written before, pointing into
/// research, keep resolving (spec §4.4).
///
/// The pure rules live here and are pinned without a window
/// (`FigureIngestTests`); the store half is `importImage`, which `EditorHost`
/// hands the editor as `ParagraphProviders.figureImporter`; the coordinator
/// half (`EditorCoordinator+Figure.swift`) remembers the point, awaits the
/// copy and writes the line through Route A — one ⌘Z step.
enum FigureIngest {
    /// The caption a new figure carries, selected so the writer types over it.
    static let captionPlaceholder = "Caption"

    /// Images and PDFs, one or several, never a folder.
    static let panelConfiguration = FigureImagePanelConfiguration(
        allowedContentTypes: [.image, .pdf], canChooseFiles: true, canChooseDirectories: false,
        allowsMultipleSelection: true, prompt: "Insert")

    // MARK: - R-3a-3 the path

    /// The figure line's path: `researchPath` (project-relative — a figure's
    /// `figures/x.png`, or a research file) written relative to the folder of
    /// `docPath` (project-relative), the way `FigureImageResolver.resolve`
    /// reads it back — `manuscript/ch1.md` reaches `figures/x.png` as
    /// `../figures/x.png`, a root `story.md` as `figures/x.png`, a Collection
    /// piece `pieces/a/a.md` as `../../figures/x.png` (and its own
    /// `pieces/a/research/x.png` as `research/x.png`).
    static func relativePath(fromDocument docPath: String, toResearch researchPath: String) -> String {
        let folder = Array(components(docPath).dropLast())
        let target = components(researchPath)
        var shared = 0
        while shared < folder.count, shared < target.count - 1, folder[shared] == target[shared] {
            shared += 1
        }
        let climb = Array(repeating: "..", count: folder.count - shared)
        return (climb + target[shared...]).joined(separator: "/")
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).filter { $0 != "." }
    }

    // MARK: - R-3a-4 the label

    /// The name a stem gives: folded to Latin, then to ASCII without
    /// diacritics, lower-cased (`Café über` → `cafe-uber`, `日本` → `ri-ben`);
    /// every remaining non-name character a `-`, runs of `-` folded, and
    /// trimmed so it starts with a letter or digit
    /// (`ManuscriptLabel.isValidName`). A stem with no name character at all
    /// gives `figure`.
    static func figureName(stem: String) -> String {
        let latin = stem.applyingTransform(.toLatin, reverse: false) ?? stem
        let folded = latin.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            let isName = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "_" || scalar == "-"
            let c: Character = isName ? Character(scalar) : "-"
            if c == "-", out.last == "-" { continue }
            out.append(c)
        }
        while let first = out.unicodeScalars.first,
              !(("a"..."z").contains(first) || ("0"..."9").contains(first)) {
            out.removeFirst()
        }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "figure" : out
    }

    /// `fig:<figureName(stem)>`, made unique against `existing` (the `fig:`
    /// NAMES already taken) by appending `-2`, `-3`, …
    static func figureLabel(stem: String, existing: Set<String>) -> ManuscriptLabel {
        let base = figureName(stem: stem)
        var name = base
        var n = 2
        while existing.contains(name) { name = "\(base)-\(n)"; n += 1 }
        // `figureName` only ever yields a valid name, and `-N` keeps it valid.
        return ManuscriptLabel(reference: "fig:\(name)")!
    }

    /// The names of `kind` taken (`fig:` for a picture, `tbl:` for Insert ▸
    /// Table): those the project's other documents define (`elsewhere`, the
    /// host's `projectLabelsElsewhere`), and those this text defines or refers
    /// to with `@kind:`.
    static func existingFigureNames(in text: String, elsewhere: Set<ManuscriptLabel>,
                                    kind: ManuscriptLabel.Kind = .fig) -> Set<String> {
        var names = Set(elsewhere.filter { $0.kind == kind }.map(\.name))
        names.formUnion(ReportInsert.definedLabels(in: text).filter { $0.kind == kind }.map(\.name))
        for (marker, _) in ManuscriptInlineScanner.scan(text) {
            if case .crossRef(let label) = marker, label.kind == kind { names.insert(label.name) }
        }
        return names
    }

    /// `![Caption](path){#kind:name}` (spec §3.1): `fig:` for a picture,
    /// `tbl:` for a table figure (Insert ▸ Table always labels its line, R7b-9).
    /// Convert to Table Figure passes the pipe table's own `caption`, kept
    /// on one line and with any `](` opened to `] (` so the line still reads
    /// as one figure (`ManuscriptBlocks.imageRegex`).
    static func figureLine(path: String, kind: ManuscriptLabel.Kind, name: String,
                           caption: String = captionPlaceholder) -> String {
        let kept = caption.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "](", with: "] (")
        return "![\(kept)](\(path)){#\(kind.rawValue):\(name)}"
    }

    /// Where `Caption` sits in a `figureLine`.
    static let captionRange = NSRange(location: 2, length: (captionPlaceholder as NSString).length)

    /// The figure line on a paragraph of its own at `location`, `Caption`
    /// selected: Insert Table's placement (`ReportInsert.blockEdit`), so inside
    /// a table it goes after the table rather than splitting it.
    static func figureEdit(in text: String, at location: Int, tableBlocks: [NSRange],
                           line: String) -> ReportInsert.Edit {
        ReportInsert.blockEdit(in: text, at: location, tableBlocks: tableBlocks,
                               block: line, selectionInBlock: captionRange)
    }

    // MARK: - The async insert point

    /// **Where the figure goes once the copy is done.** The copy is async, so
    /// the writer may type before it lands. The rule, in one place:
    ///
    /// - nothing changed → the original point (the caret, or the drop point);
    /// - the text changed → the START of the paragraph that held the point,
    ///   carried through every edit since, so the figure lands above that
    ///   paragraph and never inside a word the writer is typing;
    /// - that paragraph's start was inside an edit's replaced run (select-all
    ///   and type, a cut, a whole-buffer swap) → the paragraph is gone, and the
    ///   figure goes to the current caret.
    struct Anchor: Equatable {
        let point: Int
        private(set) var paragraphStart: Int
        private(set) var edited = false
        private(set) var lost = false

        init(point: Int, in text: String) {
            let ns = text as NSString
            let at = max(0, min(point, ns.length))
            self.point = at
            self.paragraphStart = ReportInsert.paragraphRange(containing: at, in: ns).location
        }

        /// One edit to the text, as `NSTextStorage` reports it: `editedRange`
        /// in the text AFTER the edit, and the change in length.
        mutating func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
            edited = true
            guard !lost else { return }
            let start = editedRange.location
            let replacedEnd = start + editedRange.length - delta     // in the text BEFORE
            if start >= paragraphStart { return }                   // at or after it
            if replacedEnd <= paragraphStart { paragraphStart += delta; return }
            lost = true                                             // the start was replaced
        }

        /// The location to insert at in `text`, the writer's caret being `caret`.
        func location(in text: String, caret: Int) -> Int {
            let ns = text as NSString
            if lost { return max(0, min(caret, ns.length)) }
            guard edited else { return min(point, ns.length) }
            let start = max(0, min(paragraphStart, ns.length))
            return ReportInsert.paragraphRange(containing: start, in: ns).location
        }
    }

    // MARK: - The drop decision

    enum DropDecision: Equatable {
        /// Not a figure drop: today's behaviour (`super`).
        case notOurs
        /// A figure drop the membrane refuses: the no-entry cursor.
        case refuse
        /// A figure drop: ingest these, in order.
        case accept([URL])
    }

    /// A drop is a figure drop when the surface answers figures (a Markdown
    /// manuscript with an importer) and every dragged file is a figure file
    /// (`isFigureFile`). Then the membrane decides. A MIXED drop — pictures
    /// and anything else — is not a figure drop, on purpose: the text view's
    /// own behaviour takes the whole drag rather than half of it.
    static func dropDecision(fileURLs: [URL], answersFigures: Bool, mayWrite: Bool) -> DropDecision {
        guard answersFigures, !fileURLs.isEmpty, fileURLs.allSatisfy(isFigureFile)
        else { return .notOurs }
        return mayWrite ? .accept(fileURLs) : .refuse
    }

    /// A file that can become a figure: an image
    /// (`ImagePasteHandler.isIngestableImage`) or a PDF, which does not
    /// conform to `.image` and is named here (R-S5).
    static func isFigureFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if ImagePasteHandler.isIngestableImage(url) { return true }
        let declared = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if declared?.conforms(to: .pdf) == true { return true }
        return UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true
    }

    /// Whether a pasteboard carries WORDS. A paste that does is the text's,
    /// even with an image beside it (fix round 1, C1): Word, Pages and Excel
    /// always put a `.string` beside their PDF or TIFF rendering. A browser's
    /// Copy Image puts the bitmap beside an `<img>`-only HTML fragment (Safari
    /// also an attachment-only RTFD) and often no `.string` — no words, and
    /// `super` would paste nothing, so that is the picture's (fix round 2).
    ///
    /// Words are a `.string` that is not blank, or RTF, RTFD or HTML whose text
    /// is not just whitespace and attachment characters (U+FFFC). HTML is read
    /// by stripping tags, never through WebKit's importer, which would fetch
    /// the `<img>`'s source.
    static func carriesText(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if let plain = pasteboard.string(forType: .string), hasWords(plain) { return true }
        if types.contains(.rtfd), let data = pasteboard.data(forType: .rtfd),
           let text = NSAttributedString(rtfd: data, documentAttributes: nil)?.string,
           hasWords(text) { return true }
        if types.contains(.rtf), let data = pasteboard.data(forType: .rtf),
           let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string,
           hasWords(text) { return true }
        if types.contains(.html), let html = pasteboard.string(forType: .html),
           hasWords(textOfHTML(html)) { return true }
        return false
    }

    /// Anything but whitespace and the attachment character.
    private static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{FFFC}"
        }
    }

    /// The visible text of an HTML fragment, roughly: `<script>`, `<style>`
    /// and `<head>` dropped, every other tag removed, and the space entities
    /// read as spaces. Enough to tell words from none.
    private static func textOfHTML(_ html: String) -> String {
        var text = html
        for pattern in ["(?is)<(script|style|head)\\b.*?</\\1>", "(?s)<!--.*?-->", "(?s)<[^>]*>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        for entity in ["&nbsp;", "&#160;", "&#xa0;", "&#xA0;"] {
            text = text.replacingOccurrences(of: entity, with: " ")
        }
        return text
    }

    // MARK: - R-S5 what is copied as it is

    /// The extensions a figure keeps as they are: what the outputs show
    /// (`FigureImageResolver`'s formats). Everything else is a raster image
    /// re-encoded as PNG before the copy.
    static let keptExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "pdf", "svg"]

    /// `url` itself when its format is kept; otherwise a PNG of its first
    /// image, written to a temporary folder under the same stem (so the
    /// figure and its label are named as the writer named the file).
    /// The caller removes the PNG's folder (`removeTemporary`).
    static func copyableFile(for url: URL) throws -> (url: URL, isTemporary: Bool) {
        guard !keptExtensions.contains(url.pathExtension.lowercased()) else { return (url, false) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImagePasteHandler.ImagePasteError.notAnImage(filename: url.lastPathComponent)
        }
        let folder = try makeTemporaryFolder()
        let stem = url.deletingPathExtension().lastPathComponent
        let png = folder.appendingPathComponent((stem.isEmpty ? "image" : stem) + ".png")
        guard let destination = CGImageDestinationCreateWithURL(
                png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            removeTemporary(png)
            throw ImagePasteHandler.ImagePasteError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            removeTemporary(png)
            throw ImagePasteHandler.ImagePasteError.encodingFailed
        }
        return (png, true)
    }

    /// Removes a temporary file this type wrote, with the folder made for it —
    /// and nothing whose folder's name does not say it is ours.
    static func removeTemporary(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(temporaryFolderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The name every temporary folder this type makes starts with — a
    /// pasted picture's, a converted one's — and the only folders
    /// `removeTemporary` deletes.
    static let temporaryFolderPrefix = "maugham-figure-"

    /// A new temporary folder of this type's (`removeTemporary` deletes it);
    /// also where *Send to Research* writes a working copy before the copy
    /// into Research (`ProjectStore.sendToResearch`).
    static func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - The store half

    /// **What the editor hands a picture to**: the picture, and the `fig:`
    /// names the text already uses (`existingFigureNames`, read when the
    /// ingest begins); it answers the figure path relative to the document,
    /// whose file stem is the figure's name — the label the line takes.
    typealias Importer = @MainActor (URL, Set<String>) async throws -> String

    /// Makes `url` an image figure of the document and returns the figure
    /// path relative to the document (report plan 6a Task 9).
    /// `ProjectStore.createImageFigure` asks the figure's posture, copies
    /// the picture into the project's `figures/` through
    /// `DocumentStore.executeCopy` (never a move) under a vacant name, HEIC
    /// and other formats the outputs can't show re-encoded as PNG first
    /// (R-S5, `copyableFile`), and records its hash in the figure's op log.
    ///
    /// **The figure is the document's piece's** (Denver's ruling): `piece`
    /// is `documentId`, the id the document's own text resolves to
    /// (`DocumentClass.piece(docId)`) — a chapter's, a Collection piece's,
    /// and the one document of a short story or a Report alike — so the
    /// figure is editable exactly where its text is. `taken` keeps the name
    /// clear of the labels the text already uses, so the line's label is the
    /// figure's name.
    @MainActor
    static func importImage(_ url: URL, documentId: String, documentPath: String,
                            taken: Set<String>, store: ProjectStore) async throws -> String {
        let record = try await store.createImageFigure(
            fromURL: url, piece: documentId, avoiding: taken)
        return relativePath(fromDocument: documentPath, toResearch: record.path)
    }

    // MARK: - Insert ▸ Table (report plan 7b Task 4)

    /// The name Insert ▸ Table gives its figure (`table`, `table_2`, … as the
    /// store steps it), which is also its line's label, `tbl:<name>` (R7b-9).
    static let tableFigureName = "table"

    /// **A table figure Insert ▸ Table or Convert to Table Figure made**: its
    /// id, the path its line writes (relative to the document), its name (the
    /// store's, stepped clear of the registry), the store that holds it — for
    /// the one ⌘Z that sends it to the Trash with its line (`FigureBirthUndo`),
    /// or the Trash when the line can't be written (R7b-6) — and, for a
    /// converted table, the cells kept as text because their formula would
    /// not read (R7b-10).
    struct TableFigureBirth {
        let figureId: String
        let linePath: String
        let name: String
        let store: ProjectStore
        var problems: [CSVReadProblem] = []
    }

    /// **What the editor asks for a table figure**: the name to start from
    /// (`tableFigureName` for Insert ▸ Table; a converted table's label's name
    /// or its caption's), the names to step clear of — Insert's `tbl:` names
    /// the text already uses (`existingFigureNames(kind: .tbl)`), read when
    /// the command begins — and the pipe table to read the cells of (nil:
    /// Insert's empty 3×3, `insertedTable()`).
    struct TableFigureRequest: Equatable {
        let name: String
        let taken: Set<String>
        let pipe: TableText?
    }

    /// Answers the figure it made for a `TableFigureRequest`.
    typealias TableFigureMaker = @MainActor (TableFigureRequest) async throws -> TableFigureBirth

    /// The table Insert ▸ Table opens with: three rows by three columns, the
    /// first a header row, every cell empty (spec §6.4).
    static func insertedTable() -> FigureTable {
        var table = FigureTable(rows: 3, columns: 3)
        table.headerRows = 1
        return table
    }

    /// Makes a table figure in the document's piece (`documentId`, as
    /// `importImage`), named `request.name` stepped clear of the registry and
    /// of `request.taken`. A pipe table's cells are read as a CSV import
    /// reads them (`FigureTable.importing(pipe:locale:names:)`, over the
    /// book's `tableImportContext`), before anything is made.
    /// `ProjectStore.createFigure` asks the new figure's posture (`.editFigure`)
    /// before it writes anything.
    @MainActor
    static func makeTableFigure(documentId: String, documentPath: String,
                                request: TableFigureRequest,
                                store: ProjectStore) async throws -> TableFigureBirth {
        var table = insertedTable()
        var problems: [CSVReadProblem] = []
        if let pipe = request.pipe {
            let context: (locale: TableLocale, names: FormulaNames)
            if let documentStore = store.documentStore {
                context = try await documentStore.tableImportContext()
            } else {
                context = (TableLocale(languageTag: await store.bookLanguageTag()), .empty)
            }
            (table, problems) = try FigureTable.importing(pipe: pipe, locale: context.locale,
                                                          names: context.names)
        }
        let record = try await store.createFigure(
            kind: .table, name: request.name, piece: documentId,
            table: table, avoiding: request.taken)
        return TableFigureBirth(
            figureId: record.id,
            linePath: relativePath(fromDocument: documentPath, toResearch: record.path),
            name: record.name, store: store, problems: problems)
    }

    /// What the writer is told when the table figure could not be made.
    static func tableFigureFailureMessage(for error: Error) -> String {
        error is FigureEditRefused
            ? "This Mac may not make a figure here, so no table was inserted."
            : "The table figure couldn’t be made, so no table was inserted."
    }

    // MARK: - Convert to Table Figure (report plan 7b Task 5)

    /// The name a converted table's figure starts from when its table had no
    /// `tbl:` label (R7b-9): its other label's name, else its caption's first
    /// few words as a name (`figureName(stem:)`), else `tableFigureName`.
    static func convertedTableName(caption: String?, label: ManuscriptLabel?) -> String {
        if let label { return label.name }
        let caption = (caption ?? "").trimmingCharacters(in: .whitespaces)
        guard !caption.isEmpty else { return tableFigureName }
        let name = figureName(stem: caption)
        guard name != "figure" || caption.lowercased().hasPrefix("figure") else {
            return tableFigureName
        }
        return name.split(separator: "-").prefix(convertedNameWords).joined(separator: "-")
    }

    /// How many of a caption's words a converted table's name keeps.
    static let convertedNameWords = 4

    /// What the writer is told when a pipe table could not become a figure.
    static func tableConvertFailureMessage(for error: Error) -> String {
        if error is FigureEditRefused {
            return "This Mac may not make a figure here, so the table was not converted."
        }
        if case FigureTablePipeError.tooLarge(let cells) = error {
            return "The table has \(cells) cells, more than a table figure holds "
                + "(\(TableCSV.figureCellLimit)), so it was not converted."
        }
        return "The table figure couldn’t be made, so the table was not converted."
    }

    /// What the writer is told when a converted table's cells were kept as
    /// text because their formula would not read (R7b-10); nil when none
    /// were. Row 1 is the header row, as in the figure.
    static func convertedTableProblemsMessage(_ problems: [CSVReadProblem]) -> String? {
        guard !problems.isEmpty else { return nil }
        let shown = problems.prefix(convertedProblemsShown).map {
            "row \($0.row + 1), column \($0.column + 1) (\($0.message))"
        }
        let more = problems.count - shown.count
        let list = shown.joined(separator: "; ") + (more > 0 ? "; and \(more) more" : "")
        let cells = problems.count == 1 ? "One formula" : "\(problems.count) formulas"
        return "The table is a figure now. \(cells) couldn’t be read and "
            + (problems.count == 1 ? "was" : "were") + " kept as text: \(list)."
    }

    /// How many unread formulas `convertedTableProblemsMessage` names.
    static let convertedProblemsShown = 5

    /// Writes pasted image data as a PNG the importer can copy, named for the
    /// moment it was pasted (`ResearchPasteImporter`'s convention), in a
    /// folder of its own so two pastes in one second never collide. The
    /// caller removes the folder once the copy is done.
    static func writeTemporaryPNG(_ image: NSImage) throws -> URL {
        let data = try ImagePasteHandler.encodePNG(image)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = try makeTemporaryFolder()
        let url = folder.appendingPathComponent("image-\(formatter.string(from: Date())).png")
        try data.write(to: url)
        return url
    }
}
