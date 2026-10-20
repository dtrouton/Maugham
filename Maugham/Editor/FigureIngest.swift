import Foundation
import AppKit
import UniformTypeIdentifiers
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

/// **A figure backed by research** (plan 3a Task 6, R-3a-3 and R-3a-4): an
/// image from Insert Figure… (⌘⇧I), a drop or a paste is copied into the
/// document's research, and `![Caption](relative/path){#fig:name}` is written
/// as its own paragraph with `Caption` selected.
///
/// The pure rules live here and are pinned without a window
/// (`FigureIngestTests`); the store half is `importImage`, which `EditorHost`
/// hands the editor as `ParagraphProviders.figureImporter`; the coordinator
/// half (`EditorCoordinator+Figure.swift`) remembers the point, awaits the
/// copy and writes the line through Route A — one ⌘Z step.
enum FigureIngest {
    /// The caption a new figure carries, selected so the writer types over it.
    static let captionPlaceholder = "Caption"

    /// Images only, one or several, never a folder.
    static let panelConfiguration = FigureImagePanelConfiguration(
        allowedContentTypes: [.image], canChooseFiles: true, canChooseDirectories: false,
        allowsMultipleSelection: true, prompt: "Insert")

    // MARK: - R-3a-3 the path

    /// The figure line's path: `researchPath` (project-relative) written
    /// relative to the folder of `docPath` (project-relative), the way
    /// `FigureImageResolver.resolve` reads it back — `manuscript/ch1.md` reaches
    /// `research/x.png` as `../research/x.png`, a root `story.md` as
    /// `research/x.png`, a Collection piece `pieces/a/a.md` its own
    /// `pieces/a/research/x.png` as `research/x.png`.
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

    /// The name a stem gives: lower-case ASCII, every non-name character a
    /// `-`, runs of `-` folded, and trimmed so it starts with a letter or
    /// digit (`ManuscriptLabel.isValidName`). A stem with no name character at
    /// all gives `figure`.
    static func figureName(stem: String) -> String {
        var out = ""
        for scalar in stem.lowercased().unicodeScalars {
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

    /// The `fig:` names taken: those the project's other documents define
    /// (`elsewhere`, the host's `projectLabelsElsewhere`), and those this text
    /// defines or refers to with `@fig:`.
    static func existingFigureNames(in text: String, elsewhere: Set<ManuscriptLabel>) -> Set<String> {
        var names = Set(elsewhere.filter { $0.kind == .fig }.map(\.name))
        names.formUnion(ReportInsert.definedLabels(in: text).filter { $0.kind == .fig }.map(\.name))
        for (marker, _) in ManuscriptInlineScanner.scan(text) {
            if case .crossRef(let label) = marker, label.kind == .fig { names.insert(label.name) }
        }
        return names
    }

    /// `![Caption](path){#fig:name}` (spec §3.1).
    static func figureLine(path: String, label: ManuscriptLabel) -> String {
        "![\(captionPlaceholder)](\(path)){#\(label.reference)}"
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
    /// manuscript with an importer) and every dragged file is an image
    /// (`ImagePasteHandler.isIngestableImage`). Then the membrane decides.
    static func dropDecision(fileURLs: [URL], answersFigures: Bool, mayWrite: Bool) -> DropDecision {
        guard answersFigures, !fileURLs.isEmpty,
              fileURLs.allSatisfy({ $0.isFileURL && ImagePasteHandler.isIngestableImage($0) })
        else { return .notOurs }
        return mayWrite ? .accept(fileURLs) : .refuse
    }

    // MARK: - The store half

    /// Copies `url` into the document's research and returns the figure path
    /// relative to the document. `createResearchAsset(scope: .document)` is
    /// R-3a-3's routing: a Collection piece's image lands in its own
    /// `pieces/<x>/research/` (contained, so not linked — a link there is the
    /// legacy data `TreeDropIntent` ignores); a novel chapter's in the
    /// project's `research/`, linked to the chapter, as the binder's drop
    /// does; a short story's or screenplay's in `research/`, where every
    /// research item is already the document's. The copy is
    /// `DocumentStore.executeCopy` (or the piece copy), never a move.
    @MainActor
    static func importImage(_ url: URL, documentId: String, documentPath: String,
                            store: ProjectStore) async throws -> String {
        let item = try await store.createResearchAsset(scope: .document(documentId), fromURL: url)
        guard let path = item.path else {
            throw ProjectStoreError.fileSystemError("The copied picture has no path")
        }
        return relativePath(fromDocument: documentPath, toResearch: path)
    }

    /// Writes pasted image data as a PNG the importer can copy, named for the
    /// moment it was pasted (`ResearchPasteImporter`'s convention), in a
    /// folder of its own so two pastes in one second never collide. The
    /// caller removes the folder once the copy is done.
    static let temporaryFolderPrefix = "pasted-figure-"

    static func writeTemporaryPNG(_ image: NSImage) throws -> URL {
        let data = try ImagePasteHandler.encodePNG(image)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("image-\(formatter.string(from: Date())).png")
        try data.write(to: url)
        return url
    }
}
