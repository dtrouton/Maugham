import AppKit
import MaughamCore

// MARK: - The in-place grid (report plan 7c)
//
// A table figure's card expands in place into its grid (Task 6, spec §6.2):
// double-click the card, Return inside its line (R7c-3), or Insert ▸ Table.
// The expanded line's room becomes the grid's (bars + viewport, R7c-2), held
// constant while expanded and grown only at a `figureCardVersion` edge; only
// that paragraph re-lays out at expand and fold (`refreshFigureRooms`). The
// grid is a real subview of the text view framed at the line's bottom; the
// text around it is dimmed by a click-through view. The expansion is keyed by
// the figure's id and a line anchor carried through every storage edit, so
// the same figure on another line keeps its card (R7c-4), and a line moved,
// relabelled or removed under the grid is found again by id, or folds.
//
// The grid's controller writes cells through the figure host; the one thing
// it changes in the TEXT — the figure line's caption — comes here, through
// Route A, behind the membrane (ruling R7c-6: the caption follows the text's
// `.writeText`, the cells the figure's `.editFigure`).

/// **How a surface opens a figure's grid** (wired by `EditorHost`; nil on
/// every other surface, which never expands).
struct FigureGridOpening {
    /// The table figure a line's path names now (the book's list, live, so a
    /// figure just renamed is found on its new path), or nil.
    var tableFigureId: @MainActor (String) -> String?
    /// Opens a visit on a figure (`FigureGridController.open`).
    var open: @MainActor (_ figureId: String, _ typography: TypographySettings,
                          _ line: FigureGridController.Line,
                          _ undoManager: @escaping @MainActor () -> UndoManager?)
        async throws -> FigureGridController

    /// The window's: its stores, and the document's project-relative path.
    @MainActor
    static func window(store: DocumentStore, projectStore: ProjectStore, documentPath: String) -> FigureGridOpening {
        FigureGridOpening(
            tableFigureId: { [weak projectStore] linePath in
                guard let projectStore else { return nil }
                return tableFigureId(linePath: linePath, documentPath: documentPath,
                                     figures: projectStore.manifest.figures ?? [])
            },
            open: { [weak store, weak projectStore] figureId, typography, line, undoManager in
                guard let store, let projectStore else { throw CancellationError() }
                return try await FigureGridController.open(
                    figureId: figureId, store: store, projectStore: projectStore,
                    typography: typography, line: line, undoManager: undoManager)
            })
    }

    /// The table figure `linePath` names among `figures`, by the rule Publish
    /// uses (`FigureLineResolution`); nil for an image, a miss or two records.
    static func tableFigureId(linePath: String, documentPath: String, figures: [FigureRecord]) -> String? {
        guard case .figure(let record) = FigureLineResolution.Index(figures)
                .record(forLinePath: linePath, documentPath: documentPath),
              record.kind == .table else { return nil }
        return record.id
    }
}

/// **Why a grid folds** (report plan 7c Task 7, R7c-8): how its open edit is
/// treated, and what the text is handed.
enum FigureGridFoldCause {
    /// Esc or Done, from the grid.
    case grid
    /// The text is taking the focus near the grid (a click in it, Insert's
    /// landing — `makeFirstResponder(textView)`): the caller's selection and
    /// focus change are left to the caller.
    case textTookFocus
    /// A navigation moved the view and selection elsewhere (a task, scene or
    /// annotation jump, a find match), or the text's caret left the line:
    /// the jump wins, so the fold cannot be refused; the caret stays where
    /// it was put.
    case navigation
    /// The figure line left the text.
    case lineGone
    /// The editor is torn down: detach, a document switch, the window closing.
    case teardown

    /// The grid cannot stay: an open formula that will not read is said as a
    /// notice carrying its text, never kept in a grid with nowhere to be.
    var isForced: Bool { self == .navigation || self == .lineGone || self == .teardown }
    /// The caret goes to the end of the figure line (a line gone leaves it
    /// where the text put it).
    var movesTheCaretToTheLine: Bool { self == .grid }
    /// The text takes the focus, when the grid had it.
    var focusesTheText: Bool { self == .grid || self == .lineGone || self == .navigation }
}

/// **One expansion**: which figure, which line (its start, carried through
/// every storage edit), the room it holds, and the views on screen.
@MainActor
final class FigureGridExpansion {
    /// The rows a table is taken to have before its card is cached (Insert ▸
    /// Table's 3×3).
    static let defaultRows = 3

    let figureId: String
    /// The expanded line's start.
    private(set) var lineLocation: Int
    /// The path as the line writes it, when last found.
    private(set) var path: String
    /// The room the line holds while expanded (R7c-2).
    var room: CGFloat
    /// An edit covered the line's start: the line is looked for again by id,
    /// in this run of the text only (what replaced it). Nil while the anchor
    /// is exact.
    private(set) var refindWithin: NSRange?
    var controller: FigureGridController?
    var panel: FigureGridPanel?
    let dim = FigureGridDimView()
    /// Opening the visit (the host, the book); a test awaits it.
    var opening: Task<Void, Never>?
    /// Why the fold under way was asked (Esc and Done reach the teardown
    /// through the controller's `onFold`, so it is held here).
    var foldCause: FigureGridFoldCause = .grid
    /// The text was refused the focus (a formula that will not read): the
    /// edit shows its error again, with the keys, once that focus change is
    /// over. A test awaits it.
    var reshowing: Task<Void, Never>?
    /// The text's selection when last seen, so only a selection that moves
    /// (never one re-set where it was) can take the caret off the line.
    var textSelection: NSRange?

    init(figureId: String, lineLocation: Int, path: String, room: CGFloat) {
        self.figureId = figureId
        self.lineLocation = lineLocation
        self.path = path
        self.room = room
    }

    /// **A storage edit** (`editedRange` in the text after it): the line's
    /// start rides it, by the rule the table tidy's anchor uses; an edit over
    /// the start leaves the line to be found again in what replaced it.
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        if let shifted = TableTidyState.shifted(lineLocation, editedRange: editedRange, delta: delta) {
            lineLocation = shifted
            if let within = refindWithin {
                refindWithin = TableTidyState.shifted(within.location, editedRange: editedRange, delta: delta)
                    .map { NSRange(location: $0, length: within.length) } ?? editedRange
            }
        } else {
            lineLocation = max(0, editedRange.location)
            refindWithin = refindWithin.map { NSUnionRange($0, editedRange) } ?? editedRange
        }
    }

    /// **The whole buffer was replaced** (`applyExternalText`): the line is
    /// followed through a line diff (`FigureGridLineFollow`), so a line kept
    /// is kept, a line rewritten (a rename's relabel) is looked for in what
    /// replaced it, and a line removed is looked for nowhere.
    /// - Parameter lineStart: the line's start in `old`, read before the
    ///   replace (whose own storage edit has since covered the anchor).
    func followReplacement(of lineStart: Int, old: String, new: String) {
        let within = FigureGridLineFollow.follow(lineStart: lineStart, old: old, new: new)
        lineLocation = within.location
        refindWithin = within
    }

    /// The line was found (again) at `location`, writing `path`.
    func found(at location: Int, path: String) {
        lineLocation = location
        self.path = path
        refindWithin = nil
    }
}

/// **Where a line went when the whole text was replaced** (pure): the old
/// and new texts' lines are diffed (`CollectionDifference`). A line the diff
/// keeps answers its own range in the new text; a line it removed answers
/// the run of new lines inserted between its kept neighbours — empty when
/// nothing took its place. UTF-16 offsets, `\n`-separated lines.
enum FigureGridLineFollow {
    static func follow(lineStart: Int, old: String, new: String) -> NSRange {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let oldStarts = starts(of: oldLines), newStarts = starts(of: newLines)
        guard let line = oldStarts.lastIndex(where: { $0 <= lineStart }) else {
            return NSRange(location: 0, length: 0)
        }
        let diff = newLines.difference(from: oldLines)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // The kept lines, old index → new index, in order.
        var kept: [Int: Int] = [:]
        var n = 0
        for o in oldLines.indices where !removed.contains(o) {
            while inserted.contains(n) { n += 1 }
            kept[o] = n
            n += 1
        }
        func range(_ lines: Range<Int>) -> NSRange {
            guard let first = lines.first, let last = lines.last else {
                let at = lines.lowerBound < newStarts.count ? newStarts[lines.lowerBound] : (new as NSString).length
                return NSRange(location: at, length: 0)
            }
            let end = newStarts[last] + (newLines[last] as NSString).length
            return NSRange(location: newStarts[first], length: end - newStarts[first])
        }
        if let to = kept[line] { return range(to..<(to + 1)) }
        let before = (0..<line).last { kept[$0] != nil }.flatMap { kept[$0] } ?? -1
        let after = ((line + 1)..<oldLines.count).first { kept[$0] != nil }.flatMap { kept[$0] } ?? newLines.count
        return range((before + 1)..<max(before + 1, after))
    }

    private static func starts(of lines: [String]) -> [Int] {
        var out: [Int] = [], at = 0
        for line in lines {
            out.append(at)
            at += (line as NSString).length + 1
        }
        return out
    }
}

extension EditorCoordinator {

    // MARK: Expanding

    /// **Expand the table figure on the line holding `location`** into its
    /// grid. True when it is (or already was) expanded there. False — nothing
    /// changed — off a manuscript that shows cards, in translation review
    /// (R7c-5), on a line that is not a table figure's, or while the tokens
    /// describe an earlier text. Another expanded line folds first, its open
    /// edit committed; one that will not fold (a formula that will not read)
    /// keeps this one from expanding.
    ///
    /// The room changes at once — this paragraph re-laid out, nothing else,
    /// caret and scroll still — and the grid mounts when its visit has opened.
    @discardableResult
    func expandFigureGrid(lineAt location: Int) -> Bool {
        guard !isDetached, showsFigureThumbnails, !isTranslationReview, !tokensDescribeAnEarlierText,
              let opening = figureGridOpening, let textView,
              let mark = figureLineMark(containing: location),
              let figureId = opening.tableFigureId(mark.path) else { return false }
        let model = figureCardModel?(mark.path)
        if let model, model.kind != .table { return false }   // parked, removed, ambiguous
        if let current = figureGrid {
            if current.lineLocation == mark.lineRange.location {
                if let grid = current.controller?.gridView { textView.window?.makeFirstResponder(grid) }
                return true
            }
            foldFigureGrid(commit: true)
            guard figureGrid == nil else { return false }
        }
        let rows = model.map { $0.shownRowCount + $0.moreRows } ?? FigureGridExpansion.defaultRows
        let expansion = FigureGridExpansion(
            figureId: figureId, lineLocation: mark.lineRange.location, path: mark.path,
            room: FigureGridPanel.room(rows: rows, typography: typography))
        expansion.textSelection = textView.selectedRange()
        figureGrid = expansion
        textView.addSubview(expansion.dim)
        relayoutFigureGridLine()
        layoutFigureGrid()
        figureThumbnailOverlay?.needsDisplay = true
        expansion.opening = Task { @MainActor [weak self] in
            await self?.openFigureGrid(expansion, through: opening)
        }
        return true
    }

    /// **A double-click**: expand the table card under `point` (text-view
    /// coordinates). False when the point is in no table card.
    func expandFigureGrid(atCardPoint point: CGPoint) -> Bool {
        guard let line = figureCardLine(at: point) else { return false }
        return expandFigureGrid(lineAt: line)
    }

    /// The table card whose room holds `point`, by geometry
    /// (`FigureCardHit`): the figure lines laid out near the point, each with
    /// the room it holds.
    func figureCardLine(at point: CGPoint) -> Int? {
        guard showsFigureThumbnails, !tokensDescribeAnEarlierText, let textView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage else { return nil }
        let origin = textView.textContainerOrigin
        // A card hangs below its line, so look a tall room above the point.
        let reach = max(FigureCardMetrics.maxRoom(typography: typography), figureGrid?.room ?? 0)
        let probe = CGRect(x: 0, y: point.y - origin.y - reach, width: container.size.width, height: reach + 1)
        let glyphs = layoutManager.glyphRange(forBoundingRect: probe, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let padding = container.lineFragmentPadding
        var cards: [FigureCardHit.Card] = []
        for mark in FigureThumbnailLayout.marks(figureThumbnailMarks, intersecting: chars)
        where mark.lineRange.length > 0 && NSMaxRange(mark.lineRange) <= storage.length
            && mark.lineRange.location != figureGrid?.lineLocation
            && Self.showsATableCard(figureCardModel?(mark.path), path: mark.path, opening: figureGridOpening) {
            let last = layoutManager.glyphIndexForCharacter(at: NSMaxRange(mark.lineRange) - 1)
            let bottom = layoutManager.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxY + origin.y
            cards.append(.init(lineLocation: mark.lineRange.location, frame: FigureCardHit.frame(
                lineBottom: bottom, room: figureRoom(forLinePath: mark.path, at: mark.lineRange.location),
                columnX: origin.x + padding, columnWidth: container.size.width - 2 * padding)))
        }
        return FigureCardHit.line(at: point, in: cards)
    }

    /// A table's card, or a table figure whose card the cache has not filled
    /// yet (its placeholder expands as Return on the line would, review M6).
    private static func showsATableCard(_ model: FigureCardModel?, path: String,
                                        opening: FigureGridOpening?) -> Bool {
        if let model { return model.kind == .table }
        return opening?.tableFigureId(path) != nil
    }

    /// **Return inside a table figure's line expands it** (R7c-3); at the
    /// line's end, and at its very start (ruling M4: the writer opening a
    /// line above), Return inserts a newline as it always has (false here).
    func handleFigureGridCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), figureGridOpening != nil else { return false }
        let selection = textView.selectedRange()
        guard let mark = figureLineMark(containing: selection.location),
              NSMaxRange(selection) <= NSMaxRange(mark.lineRange),
              selection.length > 0
                || (selection.location > mark.lineRange.location && selection.location < NSMaxRange(mark.lineRange))
        else { return false }
        return expandFigureGrid(lineAt: mark.lineRange.location)
    }

    /// The figure line holding `location` (its ends included).
    private func figureLineMark(containing location: Int) -> FigureThumbnailLayout.Mark? {
        figureThumbnailMarks.first {
            location >= $0.lineRange.location && location <= NSMaxRange($0.lineRange)
        }
    }

    /// Open the visit, then mount the grid — unless the expansion was folded
    /// meanwhile. A visit that will not open folds and is said.
    private func openFigureGrid(_ expansion: FigureGridExpansion, through opening: FigureGridOpening) async {
        let line = FigureGridController.Line(
            number: figureGridNumber(atLine: expansion.lineLocation),
            caption: figureGridCaption(atLine: expansion.lineLocation),
            commitCaption: { [weak self, weak expansion] caption in
                guard let self, let expansion, self.figureGrid === expansion else { return false }
                return self.replaceFigureCaption(ofLineAt: expansion.lineLocation, with: caption)
            })
        do {
            let controller = try await opening.open(
                expansion.figureId, typography, line,
                { [weak self] in self?.undoManagerOverrideForTesting ?? self?.textView?.undoManager })
            guard figureGrid === expansion, !isDetached, let textView else {
                controller.close()
                return
            }
            mountFigureGrid(controller, in: expansion, on: textView)
        } catch {
            guard figureGrid === expansion else { return }
            commandFailureReporter?("The table couldn't be opened: \(error.localizedDescription)")
            closeFigureGrid()
        }
    }

    private func mountFigureGrid(_ controller: FigureGridController, in expansion: FigureGridExpansion,
                                 on textView: NSTextView) {
        expansion.controller = controller
        controller.onFold = { [weak self, weak expansion] in
            guard let self, let expansion, self.figureGrid === expansion else { return }
            self.closeFigureGrid()
        }
        let panel = FigureGridPanel(bars: controller.bars, gridView: controller.gridView)
        expansion.panel = panel
        textView.addSubview(panel, positioned: .above, relativeTo: expansion.dim)
        // A room guessed before the card was cached grows to the table (M3).
        let room = FigureGridPanel.room(rows: controller.host.state.table.rows.count, typography: typography)
        if room > expansion.room {
            expansion.room = room
            relayoutFigureGridLine()
        }
        layoutFigureGrid()
        controller.gridView.reloadData()
        textView.window?.makeFirstResponder(controller.gridView)
    }

    /// "Table 2": the line's number in the book, as the margin shows it.
    private func figureGridNumber(atLine location: Int) -> String {
        let words = referenceIndex?().words ?? .english
        guard let line = figureCaptionLine(at: location), let before = figureNumbersBefore?() else {
            return words.table
        }
        return "\(line.kind == .tbl ? words.table : words.figure) \(line.number(after: before))"
    }

    /// The caption the line writes now.
    private func figureGridCaption(atLine location: Int) -> String {
        guard let text = textView?.string as NSString?, location < text.length else { return "" }
        let line = text.substring(with: text.lineRange(for: NSRange(location: location, length: 0)))
        guard let range = FigureIngest.captionRange(inLine: line) else { return "" }
        return (line as NSString).substring(with: range)
    }

    // MARK: Folding

    /// **Fold the grid back into its card** — the one verb every fold takes.
    /// An open edit is committed when `commit` (Done, click-away, text focus)
    /// or discarded (Esc), R7c-8; a formula that will not read keeps the grid
    /// open with its error shown. Done and the model's second Esc reach the
    /// same teardown through the controller's `onFold`.
    func foldFigureGrid(commit: Bool) {
        guard let expansion = figureGrid else { return }
        expansion.foldCause = .grid
        if let controller = expansion.controller {
            controller.fold(commit: commit)   // its `.fold` effect closes, through `onFold`
        } else {
            closeFigureGrid()   // still opening: nothing typed yet
        }
    }

    /// **The text is taking the focus** — `MaughamTextView.becomeFirstResponder`,
    /// so every `makeFirstResponder(textView)` (a navigation has already
    /// folded, forced), and the click itself (`mouseDown`). The grid folds,
    /// its open edit committed, the caller's selection kept (R7c-8). True
    /// when the text may take the focus. A formula that will not read keeps
    /// the grid open: false, and once this focus change is over the edit
    /// shows its error again, with the keys (keys typed in that one turn go
    /// to the window).
    func figureGridYieldsToText() -> Bool {
        guard let expansion = figureGrid else { return true }
        if let controller = expansion.controller, controller.unreadableOpenEdit() != nil {
            expansion.reshowing?.cancel()
            expansion.reshowing = Task { @MainActor [weak controller] in controller?.showOpenEditError() }
            return false
        }
        fold(expansion, as: .textTookFocus)
        return true
    }

    /// **The text's caret moved off the expanded line** — a selection set by
    /// a navigation, or the writer's arrows while the visit is still
    /// opening: the grid folds as a navigation does (forced: an edit that
    /// will not read is said as a notice with its text), the caret where it
    /// was put, the text focused if the grid had the keys. Not for a selection
    /// an edit carries (typing, a command's landing, a sync), nor one re-set
    /// where it was.
    func figureGridSelectionDidChange(in textView: NSTextView) {
        guard let expansion = figureGrid else { return }
        let selection = textView.selectedRange()
        let previous = expansion.textSelection
        expansion.textSelection = selection
        guard selection != previous, !isApplyingCommandEdit, !tokensDescribeAnEarlierText else { return }
        let text = textView.string as NSString
        let caret = NSRange(location: min(selection.location, text.length), length: 0)
        guard text.lineRange(for: caret).location != expansion.lineLocation else { return }
        fold(expansion, as: .navigation)
    }

    /// **A fold the grid cannot refuse** (`.navigation`, `.lineGone`,
    /// `.teardown`): an open edit that reads is committed; one that will not
    /// is said as a notice carrying its text, and the grid folds all the same.
    func forceFoldFigureGrid(_ cause: FigureGridFoldCause) {
        guard let expansion = figureGrid else { return }
        fold(expansion, as: cause)
    }

    private func fold(_ expansion: FigureGridExpansion, as cause: FigureGridFoldCause) {
        expansion.foldCause = cause
        guard let controller = expansion.controller else {
            closeFigureGrid()   // still opening: nothing typed yet
            return
        }
        if cause.isForced {
            controller.foldForced()
            if figureGrid === expansion { closeFigureGrid() }   // it cannot stay
        } else {
            controller.fold(commit: true)   // its `.fold` effect closes, through `onFold`
            // A commit that will not read kept it open, its error shown; a
            // later Esc or Done folds as the grid's own.
            if figureGrid === expansion { expansion.foldCause = .grid }
        }
    }

    /// The teardown: the views off the text view, the line's card back (only
    /// that paragraph re-laid out; nothing on a teardown), the visit closed
    /// once its writes have landed, and — when the grid had the focus — the
    /// text focused, nothing scrolled, the caret at the end of the figure
    /// line on Esc, Done or a line gone (`FigureGridFoldCause`).
    private func closeFigureGrid() {
        guard let expansion = figureGrid else { return }
        figureGrid = nil
        let cause = expansion.foldCause
        expansion.opening?.cancel()
        expansion.reshowing?.cancel()
        let window = textView?.window
        let hadFocus = (window?.firstResponder as? NSView).map { responder in
            expansion.panel.map { responder.isDescendant(of: $0) } ?? false
        } ?? false
        expansion.panel?.removeFromSuperview()
        expansion.dim.removeFromSuperview()
        if let controller = expansion.controller {
            controller.didFold()
            Task { @MainActor in
                await controller.settleWrites()
                controller.close()
            }
        }
        if cause != .teardown { relayoutFigureGridLine() }
        figureThumbnailOverlay?.needsDisplay = true
        guard cause.focusesTheText, hadFocus, let textView else { return }
        let text = textView.string as NSString
        if cause.movesTheCaretToTheLine, expansion.lineLocation < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: expansion.lineLocation, length: 0))
            textView.setSelectedRange(NSRange(location: contentsEnd, length: 0))
        }
        window?.makeFirstResponder(textView)
    }

    // MARK: Following the line

    /// Re-lay out the figure lines whose room moved — at expand and fold,
    /// only the expanded line. Inside a typing burst it waits for the settle
    /// paint; inside `applyExternalText` the whole-document paint that
    /// follows carries it.
    private func relayoutFigureGridLine() {
        if isApplyingExternalUpdate { return }
        if isInTypingBurst || tokensDescribeAnEarlierText {
            figureRoomsWaitForTheSettle = true
            return
        }
        refreshFigureRooms()
    }

    /// **After every retokenize**: is the expanded line still where its
    /// anchor says, writing the same path? If not, find the figure's line
    /// again by id — only in what replaced the line (or on the anchor's own
    /// line), so the other line of a figure written twice never takes it
    /// (R7c-4) — and hold the room there; a figure renamed under the grid
    /// (its line relabelled, `applyExternalText`) stays open. No line there
    /// names it any more: the grid folds, its open edit committed (or, when
    /// it will not read, said as a notice carrying its text).
    func figureGridTokensDidChange() {
        guard let expansion = figureGrid, let textView else { return }
        let marks = figureThumbnailMarks
        if expansion.refindWithin == nil,
           marks.contains(where: { $0.lineRange.location == expansion.lineLocation && $0.path == expansion.path }) {
            layoutFigureGrid()
            return
        }
        // Where to look: what replaced the line, or the line the anchor is on.
        let text = textView.string as NSString
        let within = expansion.refindWithin
            ?? text.lineRange(for: NSRange(location: min(expansion.lineLocation, text.length), length: 0))
        let names = figureGridOpening?.tableFigureId
        // An empty run means nothing replaced the line: it is gone, and the
        // line after it — even the same figure's — never takes the grid (M1).
        let candidates = within.length == 0 ? [] : marks.filter { mark in
            NSLocationInRange(mark.lineRange.location, within)
                && (mark.path == expansion.path || names?(mark.path) == expansion.figureId)
        }
        guard let nearest = candidates.min(by: {
            abs($0.lineRange.location - expansion.lineLocation) < abs($1.lineRange.location - expansion.lineLocation)
        }) else {
            forceFoldFigureGrid(.lineGone)
            return
        }
        let moved = nearest.lineRange.location != expansion.lineLocation
        expansion.found(at: nearest.lineRange.location, path: nearest.path)
        if moved { relayoutFigureGridLine() }
        layoutFigureGrid()
    }

    /// **A `figureCardVersion` edge**: the visit reads the book again, and the
    /// room grows when the table did (R7c-2: up to 15 rows, at this edge
    /// only, never on a keystroke). The caller re-lays out the line.
    func figureGridCardsChanged() {
        guard let expansion = figureGrid, let controller = expansion.controller else { return }
        Task { @MainActor in await controller.figureCardsChanged() }
        let room = FigureGridPanel.room(rows: controller.host.state.table.rows.count, typography: typography)
        if room > expansion.room {
            expansion.room = room
            layoutFigureGrid()
        }
    }

    /// **Frame the grid at its line's bottom** and the dimming around it:
    /// after a re-layout, a resize or an inset change
    /// (`MaughamTextView.updateColumnInset`), and after every retokenize.
    func layoutFigureGrid() {
        guard let expansion = figureGrid, let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let text = textView.string as NSString
        guard expansion.lineLocation < text.length else { return }
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                          for: NSRange(location: expansion.lineLocation, length: 0))
        guard contentsEnd > start else { return }
        let origin = textView.textContainerOrigin
        let first = layoutManager.glyphIndexForCharacter(at: start)
        let last = layoutManager.glyphIndexForCharacter(at: contentsEnd - 1)
        let top = layoutManager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY + origin.y
        let bottom = layoutManager.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxY + origin.y
        let padding = container.lineFragmentPadding
        let frame = FigureGridPanel.frame(lineBottom: bottom, room: expansion.room, columnX: origin.x + padding,
                                          columnWidth: container.size.width - 2 * padding)
        if expansion.panel?.frame != frame { expansion.panel?.frame = frame }
        expansion.dim.frame = textView.bounds
        expansion.dim.tint = textView.backgroundColor
        expansion.dim.hole = CGRect(x: 0, y: top, width: textView.bounds.width, height: bottom + expansion.room - top)
    }

    // MARK: The text edits

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
