import AppKit
import MaughamCore

// MARK: - The in-place grid's text edits (report plan 7c)
//
// The grid's controller writes cells through the figure host; the one thing
// it changes in the TEXT — the figure line's caption — comes here, through
// Route A, behind the membrane (ruling R7c-6: the caption follows the text's
// `.writeText`, the cells the figure's `.editFigure`).

extension EditorCoordinator {

    /// **The grid's caption field committed**: the caption of the figure line
    /// holding `location` becomes `caption` (kept on one line, its `](`
    /// opened — `FigureIngest.keptCaption`), as one ⌘Z through
    /// `applyCommandEdit`. It lands `.deferred`: the grid keeps the focus and
    /// the writer's selection is shifted through the edit, never moved.
    /// Answers false — changing nothing — when the line is not a figure line,
    /// the membrane refuses, or the editor is detached.
    @discardableResult
    func replaceFigureCaption(ofLineAt location: Int, with caption: String) -> Bool {
        guard let storage = textView?.textStorage else { return false }
        let text = storage.string as NSString
        guard location >= 0, location <= text.length else { return false }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        guard let inLine = FigureIngest.captionRange(inLine: text.substring(with: line)) else { return false }
        let range = NSRange(location: line.location + inLine.location, length: inLine.length)
        let kept = FigureIngest.keptCaption(caption)
        guard text.substring(with: range) != kept else { return true }
        return applyCommandEdit(
            replacing: range, with: kept,
            selecting: NSRange(location: range.location + (kept as NSString).length, length: 0),
            actionName: "Edit Caption", landing: .deferred(writerMoved: true))
    }
}
