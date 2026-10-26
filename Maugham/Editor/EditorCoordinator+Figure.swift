import Foundation
import MaughamCore
import AppKit

// EditorCoordinator — image figures (plan 3a Task 6; report plan 6a Task 9):
// Insert Figure… (⌘⇧I), an image dropped on the manuscript, an image pasted
// into it. All three end in `beginFigureIngest`, which makes the figure
// through the host's `figureImporter` and writes the line through Route A
// (`applyCommandEdit`).
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

    /// Makes each image a figure in `figures/`, then writes its figure line
    /// as a paragraph of its own, `Caption` selected — one ⌘Z step per
    /// figure. The label is the figure's name, the returned path's stem: the
    /// importer was handed the `fig:` names the text used when the ingest
    /// began, so the name it chose is clear of them.
    ///
    /// The point is remembered now and carried through any typing while the
    /// copy runs (`FigureIngest.Anchor`). Nothing is copied when the membrane
    /// refuses (returns nil). A failed copy writes nothing and is told through
    /// `commandFailureReporter`. A document that is no longer this editor's
    /// (a piece flip detaches the coordinator, `.id(path)`) gets nothing.
    /// Several images land one after another, in order. Files in
    /// `removingAfterwards` (a paste's temporary PNG) are deleted when done.
    ///
    /// The line lands after the event that asked for it, so it lands
    /// `.deferred` (whole-branch review I2): it never takes the focus, and a
    /// writer who has moved on — typed, moved the caret, or focused another
    /// view — keeps their selection; only a writer still where they were gets
    /// `Caption` selected. While an input method is composing it waits
    /// (`figureCompositionWait`, at most `figureCompositionWaitLimit` times),
    /// then gives up and says so: committing or moving the selection would
    /// break the composition.
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
        // Where the writer's selection was when they asked (or when the last
        // figure of this ingest landed): moved since means they moved on.
        var writersSelection = textView.selectedRange()
        let task = Task { @MainActor [weak self] in
            defer {
                tracker.stop()
                Self.remove(temporary)
            }
            for url in urls {
                let path: String
                do {
                    let taken = FigureIngest.existingFigureNames(
                        in: textView.string, elsewhere: self?.projectLabelsElsewhere?() ?? [])
                    path = try await importer(url, taken)
                } catch {
                    self?.commandFailureReporter?(ImagePasteHandler.failureMessage(for: error))
                    return
                }
                guard let self else { return }
                switch await self.waitOutComposition(in: textView) {
                case .ready: break
                case .gone: return
                case .gaveUp:
                    self.commandFailureReporter?(Self.compositionFailureMessage)
                    return
                }
                let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let writerMoved = tracker.anchor.edited
                    || textView.selectedRange() != writersSelection
                guard let end = self.writeFigure(path: path, stem: stem,
                                                 at: tracker.anchor.location(
                                                    in: textView.string,
                                                    caret: NSMaxRange(textView.selectedRange())),
                                                 writerMoved: writerMoved)
                else {
                    self.commandFailureReporter?(
                        "The picture is in figures, but this document can’t be written to now.")
                    return
                }
                tracker.anchor = FigureIngest.Anchor(point: end, in: textView.string)
                writersSelection = textView.selectedRange()
            }
        }
        figureIngestTask = task
        return task
    }

    /// One figure line at `location` through Route A. Returns the end of the
    /// written line (where a following figure goes), or nil when the membrane
    /// refused.
    private func writeFigure(path: String, stem: String, at location: Int,
                             writerMoved: Bool) -> Int? {
        guard let textView else { return nil }
        let text = textView.string
        let names = FigureIngest.existingFigureNames(
            in: text, elsewhere: projectLabelsElsewhere?() ?? [])
        let line = FigureIngest.figureLine(
            path: path, kind: .fig, name: FigureIngest.figureLabel(stem: stem, existing: names).name)
        let blocks = tableBlockRange(containing: location)
            .map { [$0] } ?? []
        let edit = FigureIngest.figureEdit(in: text, at: location, tableBlocks: blocks, line: line)
        guard applyCommandEdit(edit, actionName: "Insert Figure",
                               landing: .deferred(writerMoved: writerMoved)) else { return nil }
        return edit.selection.location - FigureIngest.captionRange.location
            + (line as NSString).length
    }

    /// Where a line that lands after its event stands once any composition
    /// is out of the way (`waitOutComposition`).
    enum CompositionWait: Equatable {
        /// Still this editor's document, nothing composing: write now.
        case ready
        /// The editor left the document (detached, or another text view).
        case gone
        /// An input method composed through every wait.
        case gaveUp
    }

    /// Waits while an input method is composing in `textView`
    /// (`figureCompositionWait`, at most `figureCompositionWaitLimit` times):
    /// committing or moving the selection would break the composition. Image
    /// ingest and Insert ▸ Table share it.
    func waitOutComposition(in textView: NSTextView) async -> CompositionWait {
        guard !isDetached, self.textView === textView else { return .gone }
        var waits = 0
        while textView.hasMarkedText() {
            guard waits < figureCompositionWaitLimit else { return .gaveUp }
            waits += 1
            await figureCompositionWait()
            guard !isDetached, self.textView === textView else { return .gone }
        }
        return .ready
    }

    /// What the writer is told when a composition outlasted every wait.
    static let compositionFailureMessage =
        "The picture is in figures, but it wasn’t placed while you were composing text. Insert it again."

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
            commandFailureReporter?(ImagePasteHandler.failureMessage(for: error))
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
