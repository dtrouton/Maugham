import AppKit
import MaughamCore

// **A table figure's card expanded in place** (report plan 7c Task 6, spec
// §6.2): the grid and its three bars in the room the figure line's paragraph
// spacing holds, a real subview of the text view; the text around it dimmed
// by a click-through view, never by a storage edit; and the pure geometry
// both stand on — the room, the frame under the line, and which card a click
// landed in. Nothing here is a character (tripwires 1, 26): the room is still
// the line's `paragraphSpacing`, written by `ProseMode.figureLineStyle` alone.

/// **Which figure card a point lands in** (pure). A card's area is the room
/// under its line, across the text column; a click on the line's own text,
/// or past the room on the next line, is no card's. `characterIndexForInsertion`
/// would put a click in the room on the NEXT line, so geometry decides.
enum FigureCardHit {
    struct Card: Equatable {
        /// The figure line's start.
        let lineLocation: Int
        /// The room under it, in the text view's coordinates.
        let frame: CGRect
    }

    /// The room under a line whose text ends at `lineBottom`.
    static func frame(lineBottom: CGFloat, room: CGFloat, columnX: CGFloat, columnWidth: CGFloat) -> CGRect {
        CGRect(x: columnX, y: lineBottom, width: max(0, columnWidth), height: max(0, room))
    }

    /// The line whose card holds `point`, or nil.
    static func line(at point: CGPoint, in cards: [Card]) -> Int? {
        cards.first { $0.frame.contains(point) }?.lineLocation
    }
}

/// **The expanded grid's box**: the toolbar, the formula bar, the grid and
/// the bottom bar stacked in the line's room (spec §6.2). It holds the
/// controller's views and lays them out; it writes nothing.
final class FigureGridPanel: NSView, NSUserInterfaceValidations {
    /// The space above and below the panel inside the room.
    static let gap: CGFloat = 6

    /// **The room an expanded table holds** (R7c-2): the three bars, the
    /// letter band and min(rows, 15) rows, with a gap above and below.
    /// Constant from 15 rows up.
    static func room(rows: Int, typography: TypographySettings) -> CGFloat {
        2 * gap + FigureGridBars.totalHeight
            + FigureGridLayout.viewportHeight(rows: rows, rowHeight: FigureCardMetrics.rowHeight(for: typography))
    }

    /// The panel's frame in the room under a line ending at `lineBottom`.
    static func frame(lineBottom: CGFloat, room: CGFloat, columnX: CGFloat, columnWidth: CGFloat) -> CGRect {
        FigureCardHit.frame(lineBottom: lineBottom, room: room, columnX: columnX, columnWidth: columnWidth)
            .insetBy(dx: 0, dy: gap)
            .standardized
    }

    /// Where each part goes in a panel of `size`, top to bottom.
    struct Parts: Equatable {
        let toolbar: CGRect
        let formulaBar: CGRect
        let grid: CGRect
        let bottomBar: CGRect
    }

    static func parts(in size: CGSize) -> Parts {
        let bar = FigureGridBars.barHeight
        let gridHeight = max(0, size.height - 3 * bar)
        return Parts(
            toolbar: CGRect(x: 0, y: 0, width: size.width, height: bar),
            formulaBar: CGRect(x: 0, y: bar, width: size.width, height: bar),
            grid: CGRect(x: 0, y: 2 * bar, width: size.width, height: gridHeight),
            bottomBar: CGRect(x: 0, y: 2 * bar + gridHeight, width: size.width, height: bar))
    }

    private let bars: FigureGridBars
    let gridView: FigureGridView

    init(bars: FigureGridBars, gridView: FigureGridView) {
        self.bars = bars
        self.gridView = gridView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        for view in [bars.toolbar, bars.formulaBar, gridView, bars.bottomBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// **The panel's responder chain skips the text it sits in** (re-review
    /// I-N1): an action with no target sent while the grid or a bar has the
    /// keys — Paste and Match Style, Transformations, Substitutions, the
    /// Spelling panel's Change — would otherwise walk grid → panel → the
    /// manuscript's text view and change the text under the dim. The chain
    /// goes on from the text view's own next responder (its clip view, the
    /// scroll view, the window). ⌘Z and ⇧⌘Z never get that far: the panel
    /// answers them for the grid's own stack (plan 7d Task 6).
    ///
    /// AppKit walks the chain by the stored link (an overridden getter is
    /// not asked) and sets it when the panel is added, so the coordinator
    /// calls this after mounting and at each re-frame; idempotent.
    func skipTheTextInTheResponderChain() {
        if let text = nextResponder as? NSTextView { nextResponder = text.nextResponder }
    }

    // MARK: ⌘Z and ⇧⌘Z from the bars (plan 7d Task 6)

    /// The grid's own stack, as the grid answers it.
    override var undoManager: UndoManager? { gridView.undoManager }

    /// **⌘Z with a bar having the keys** (the formula bar, the caption, the
    /// name, a toolbar control): the grid's, as from the grid itself — the
    /// bars' fields answer no `undo:`, so the walk reaches the panel before
    /// the window, whose `undo:` would run the manuscript's stack.
    @objc func undo(_ sender: Any?) { gridView.undo(sender) }
    @objc func redo(_ sender: Any?) { gridView.redo(sender) }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return false }
        guard FigureGridView.undoSelectors.contains(action) else { return responds(to: action) }
        return gridView.validateUserInterfaceItem(item)
    }

    /// **A key a bar's control left unhandled stops here** (final review
    /// C1): the panel is a subview of the manuscript's text view, which would
    /// otherwise take the key (a toolbar button focused under Full Keyboard
    /// Access passes on all but Space). Tab still moves between the controls.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, flags.isDisjoint(with: [.command, .control, .option]) {
            if flags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            return
        }
        NSSound.beep()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let parts = Self.parts(in: newSize)
        bars.toolbar.frame = parts.toolbar
        bars.formulaBar.frame = parts.formulaBar
        gridView.frame = parts.grid
        bars.bottomBar.frame = parts.bottomBar
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

/// **The text around the expanded grid, dimmed**: a translucent wash of the
/// text's background over the whole text view but the expanded line and its
/// room. Click-through, so a click in the text still reaches the text
/// (where Task 7 folds the grid); no storage edit, so no re-layout.
final class FigureGridDimView: NSView {
    /// How strongly the text around the grid is washed out.
    static let alpha: CGFloat = 0.55

    /// The undimmed band: the figure line and the room under it.
    var hole: CGRect = .zero {
        didSet { if hole != oldValue { needsDisplay = true } }
    }
    var tint: NSColor = .textBackgroundColor {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never intercept clicks

    override func draw(_ dirtyRect: NSRect) {
        let wash = NSBezierPath(rect: bounds)
        wash.append(NSBezierPath(rect: hole))
        wash.windingRule = .evenOdd
        tint.withAlphaComponent(Self.alpha).setFill()
        wash.fill()
    }
}
