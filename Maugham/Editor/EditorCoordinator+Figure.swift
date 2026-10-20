import Foundation
import MaughamCore
import AppKit

// EditorCoordinator — figures backed by research (plan 3a Task 6): Insert
// Figure… (⌘⇧I), an image dropped on the manuscript, an image pasted into it.
// All three end in `beginFigureIngest`, which copies through the host's
// `figureImporter` and writes the line through Route A (`applyCommandEdit`).
extension EditorCoordinator {
    /// The membrane's answer, asked BEFORE anything is copied
    /// (`commandMayWrite`).
    var mayWriteFigure: Bool { commandMayWrite }

    /// What a drag of `urls` means here (`FigureIngest.dropDecision`).
    func figureDropDecision(for urls: [URL]) -> FigureIngest.DropDecision {
        FigureIngest.dropDecision(fileURLs: urls, answersFigures: answersFigures,
                                  mayWrite: mayWriteFigure)
    }

    // MARK: - The ingest

    /// Copies each image into research, then writes its figure line as a
    /// paragraph of its own, `Caption` selected — one ⌘Z step per figure.
    ///
    /// The point is remembered now and carried through any typing while the
    /// copy runs (`FigureIngest.Anchor`). Nothing is copied when the membrane
    /// refuses (returns nil). A failed copy writes nothing and is told through
    /// `figureFailureReporter`. A document that is no longer this editor's
    /// (a piece flip detaches the coordinator, `.id(path)`) gets nothing.
    /// Several images land one after another, in order. Files in
    /// `removingAfterwards` (a paste's temporary PNG) are deleted when done.
    @discardableResult
    func beginFigureIngest(_ urls: [URL], at location: Int,
                           removingAfterwards temporary: [URL] = []) -> Task<Void, Never>? {
        guard answersFigures, mayWriteFigure, !urls.isEmpty,
              let textView, let storage = textView.textStorage,
              let importer = figureImporter else {
            Self.remove(temporary)
            return nil
        }
        let tracker = FigureAnchorTracker(
            anchor: FigureIngest.Anchor(point: location, in: textView.string), storage: storage)
        let task = Task { @MainActor [weak self] in
            defer {
                tracker.stop()
                Self.remove(temporary)
            }
            for url in urls {
                let path: String
                do {
                    path = try await importer(url)
                } catch {
                    self?.figureFailureReporter?(ImagePasteHandler.failureMessage(for: error))
                    return
                }
                guard let self, !self.isDetached, self.textView === textView else { return }
                let stem = url.deletingPathExtension().lastPathComponent
                guard let end = self.writeFigure(path: path, stem: stem,
                                                 at: tracker.anchor.location(
                                                    in: textView.string,
                                                    caret: NSMaxRange(textView.selectedRange())))
                else {
                    self.figureFailureReporter?(
                        "The picture is in research, but this document can’t be written to now.")
                    return
                }
                tracker.anchor = FigureIngest.Anchor(point: end, in: textView.string)
            }
        }
        figureIngestTask = task
        return task
    }

    /// One figure line at `location` through Route A. Returns the end of the
    /// written line (where a following figure goes), or nil when the membrane
    /// refused.
    private func writeFigure(path: String, stem: String, at location: Int) -> Int? {
        guard let textView else { return nil }
        let text = textView.string
        let names = FigureIngest.existingFigureNames(
            in: text, elsewhere: projectLabelsElsewhere?() ?? [])
        let line = FigureIngest.figureLine(
            path: path, label: FigureIngest.figureLabel(stem: stem, existing: names))
        let blocks = MarkdownTokenizer.tableBlockRange(containing: location, in: lastTokens)
            .map { [$0] } ?? []
        let edit = FigureIngest.figureEdit(in: text, at: location, tableBlocks: blocks, line: line)
        guard applyCommandEdit(edit, actionName: "Insert Figure") else { return nil }
        return edit.selection.location - FigureIngest.captionRange.location
            + (line as NSString).length
    }

    /// Removes a paste's temporary PNG (`FigureIngest.removeTemporary`).
    private static func remove(_ temporary: [URL]) {
        temporary.forEach(FigureIngest.removeTemporary)
    }

    // MARK: - The three ways in

    /// Insert ▸ Figure… (⌘⇧I): an open panel for images, then the ingest at
    /// the caret (after the selection).
    func insertFigure() {
        guard answersFigures, mayWriteFigure, let textView else { return }
        let at = NSMaxRange(textView.selectedRange())
        let panel = NSOpenPanel()
        FigureIngest.panelConfiguration.apply(to: panel)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            let images = panel.urls.filter(FigureIngest.isFigureFile)
            self?.beginFigureIngest(images, at: at)
        }
        if let window = textView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// ⌘V of a picture. Returns true when the paste is a picture's — handled,
    /// even when refused or failed, so `super.paste` never inserts an
    /// attachment character (Editor AREA.md: here false means not mine, never
    /// handled-and-fall-through). Two questions, in order (fix round 1, C1):
    ///
    /// 1. **File URLs** (a Finder copy) are ours only when EVERY one is a
    ///    figure file. Anything else — a `.txt` beside its icon image — is
    ///    `super`'s, so its path pastes as text, as it always has.
    /// 2. **Image data** is ours only when the pasteboard carries NO text
    ///    flavour (`FigureIngest.carriesText`). Word, Pages and Excel put a PDF
    ///    or TIFF rendering beside copied text; the writer copied the words.
    ///    A screenshot carries only the bitmap. The data becomes a temporary
    ///    PNG first.
    func pasteFigure(from pasteboard: NSPasteboard) -> Bool {
        guard answersFigures, let textView else { return false }
        let at = NSMaxRange(textView.selectedRange())
        let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            switch figureDropDecision(for: files) {
            case .accept(let images):
                beginFigureIngest(images, at: at)
                return true
            case .refuse:
                return true
            case .notOurs:
                return false
            }
        }
        guard !FigureIngest.carriesText(pasteboard),
              pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard) else { return false }
        guard mayWriteFigure else { return true }
        do {
            let png = try FigureIngest.writeTemporaryPNG(image)
            beginFigureIngest([png], at: at, removingAfterwards: [png])
        } catch {
            figureFailureReporter?(ImagePasteHandler.failureMessage(for: error))
        }
        return true
    }
}

/// Carries a `FigureIngest.Anchor` through every edit to one text storage
/// while a figure's copy runs. `NSTextStorage` reports each edit once,
/// synchronously on the main thread, whoever made it — typing, a paste, an
/// external replace — so nothing that moves the text is missed.
@MainActor
final class FigureAnchorTracker {
    var anchor: FigureIngest.Anchor
    private var token: NSObjectProtocol?

    init(anchor: FigureIngest.Anchor, storage: NSTextStorage) {
        self.anchor = anchor
        token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self] note in
            guard let storage = note.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            let range = storage.editedRange, delta = storage.changeInLength
            MainActor.assumeIsolated {
                self?.anchor.noteEdit(editedRange: range, changeInLength: delta)
            }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
