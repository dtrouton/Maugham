import AppKit

/// One row the completion list offers (plan 3b Task 2): what the row shows
/// and what accepting it writes.
struct CompletionItem: Equatable {
    /// The row's main text ("Smith 2026 — The title").
    let title: String
    /// The muted text after it (the key, the label).
    let subtitle: String
    /// What replaces the trigger and the query on accept (`[@smith2026]`).
    let insertion: String
}

/// Where a completion is, as its source reads the text at the caret (plan 3b
/// Task 2 fix round 1, I2).
struct CompletionTrigger: Equatable {
    /// What an accept replaces: from the trigger's first character (`[` of
    /// `[@`), through the caret, and on past it through the rest of a key or
    /// label already there — so re-picking inside `[@smy|th2019]` replaces the
    /// whole key, up to but not including `]`, `;` or whitespace.
    let replaceRange: NSRange
    /// The text between the trigger and the caret: what the rows filter on.
    let query: String
    /// What the source needs to remember about this trigger (a fresh `[@` or
    /// a `;` continuation, a bracket already closed): a small value the source
    /// defines, carried back to `items(for:)` and `insertion(for:trigger:)`
    /// so the source keeps no state of its own.
    let context: AnyHashable?

    init(replaceRange: NSRange, query: String, context: AnyHashable? = nil) {
        self.replaceRange = replaceRange
        self.query = query
        self.context = context
    }

    /// Where the trigger starts: the list stays open while this holds.
    var start: Int { replaceRange.location }
}

/// What the completion list completes from (plan 3b Task 2, ruling R-S1): a
/// citation's sources (Task 3), a cross-reference's targets (Task 4). The
/// coordinator holds an ordered list of them (`completionSources`) and asks
/// each, in order, whether the text at the caret opens it.
///
/// Every answer is asked of THIS document's text near the caret, or of data
/// the source already holds: a source never walks the project per keystroke
/// (the plan's review focus 1).
@MainActor
protocol CompletionSource {
    /// The trigger at `caret` when the text there opens this source; nil when
    /// it does not. Asked after each typed character, and again while the
    /// list is open, as the writer types, deletes or moves the caret: a
    /// trigger starting somewhere else, or none, closes the list. Its
    /// `replaceRange` must contain `caret`.
    func trigger(in text: NSString, caret: Int) -> CompletionTrigger?
    /// The rows for a trigger, in the order they are offered. Asked again
    /// only when the trigger's query or context changes.
    func items(for trigger: CompletionTrigger) -> [CompletionItem]
    /// What accepting `item` writes over `trigger.replaceRange` (`[@key]`, or
    /// `@key` in a `;` continuation). Defaults to the item's own `insertion`.
    func insertion(for item: CompletionItem, trigger: CompletionTrigger) -> String
    /// The one muted row shown when nothing matches ("No matching sources").
    var emptyMessage: String { get }
    /// The undo step's name ("Undo Insert Citation").
    var actionName: String { get }
}

extension CompletionSource {
    func insertion(for item: CompletionItem, trigger: CompletionTrigger) -> String { item.insertion }
    var actionName: String { "Insert Reference" }
}

/// Where the list goes (plan 3b Task 2), pure so it is tested without a
/// window: under the caret, left-aligned with it, or above it when there is
/// no room below; never past the parent's edges.
enum CompletionListLayout {
    /// The gap between the caret's line and the list.
    static let gap: CGFloat = 4
    /// The margin the list keeps from the parent's edges.
    static let margin: CGFloat = 8

    /// The list's frame in its parent. `caret` is the caret's rect in the
    /// parent's coordinates; `flipped` is the parent's `isFlipped`.
    static func frame(size: NSSize, caret: NSRect, in bounds: NSRect, flipped: Bool) -> NSRect {
        let width = max(0, min(size.width, bounds.width - 2 * margin))
        let height = size.height
        let x = max(bounds.minX + margin, min(caret.minX, bounds.maxX - margin - width))
        var y: CGFloat
        if flipped {
            // y grows downwards: "below" is a larger y.
            y = caret.maxY + gap
            if y + height > bounds.maxY - margin {
                let above = caret.minY - gap - height
                if above >= bounds.minY + margin { y = above }
            }
            y = max(bounds.minY, min(y, bounds.maxY - height))
        } else {
            // y grows upwards (the scroll view): "below" is a smaller y.
            y = caret.minY - gap - height
            if y < bounds.minY + margin {
                let above = caret.maxY + gap
                if above + height <= bounds.maxY - margin { y = above }
            }
            y = max(bounds.minY, min(y, bounds.maxY - height))
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// The in-editor completion list (plan 3b Task 2): the app's first, shared by
/// the citation and cross-reference pickers. A plain `NSView` added to the
/// editor's scroll view, as `SelectionToolbarView` is — never an `NSPopover`
/// (tripwire 5): it never takes the focus, so the writer keeps typing into the
/// text view, whose `doCommandBy` routes ↑, ↓, Return, Tab and Esc here first.
///
/// At most `maxVisibleRows` rows show; the rest scroll inside (the selection
/// keeps itself in view, and the wheel scrolls). The rows are reused views,
/// so a source with hundreds of entries costs eight rows. Driven one-way by
/// the coordinator (`EditorCoordinator+Completion.swift`), which owns the
/// state; the view only shows it and reports a click.
final class CompletionListView: NSView {
    static let maxVisibleRows = 8
    static let rowHeight: CGFloat = 24
    static let preferredWidth: CGFloat = 400
    static let padding: CGFloat = 4

    /// A click on row `index` (into `items`).
    var onAccept: ((Int) -> Void)?

    private(set) var items: [CompletionItem] = []
    private(set) var emptyMessage = ""
    private(set) var selectedIndex = 0
    /// The first row in view.
    private(set) var topRow = 0
    private var rows: [CompletionRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyAdaptiveLayerColors()
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        for _ in 0..<Self.maxVisibleRows {
            let row = CompletionRowView(frame: .zero)
            row.isHidden = true
            addSubview(row)
            rows.append(row)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Completions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// The size the list wants for its rows.
    var preferredSize: NSSize {
        let shown = max(1, min(Self.maxVisibleRows, items.count))
        return NSSize(width: Self.preferredWidth,
                      height: CGFloat(shown) * Self.rowHeight + 2 * Self.padding)
    }

    /// Show `items` (or `emptyMessage` when there are none), `selected` chosen.
    func show(items: [CompletionItem], emptyMessage: String, selected: Int) {
        let changed = items != self.items || emptyMessage != self.emptyMessage
        self.items = items
        self.emptyMessage = emptyMessage
        if changed { topRow = 0 }
        select(selected, announce: false)
        if changed { refreshRows() }
    }

    /// Move the selection to `index`, scrolling it into view, and tell
    /// VoiceOver (its focus stays in the text view, so the row is announced).
    func select(_ index: Int, announce: Bool = true) {
        guard !items.isEmpty else { selectedIndex = 0; refreshRows(); return }
        selectedIndex = max(0, min(index, items.count - 1))
        if selectedIndex < topRow { topRow = selectedIndex }
        if selectedIndex >= topRow + Self.maxVisibleRows {
            topRow = selectedIndex - Self.maxVisibleRows + 1
        }
        refreshRows()
        guard announce else { return }
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        speak(items[selectedIndex].title)
    }

    /// The last sentence the list asked VoiceOver to speak.
    private(set) var lastAnnouncement: String?

    /// Speak what an opened list offers: the first row's title and how many
    /// there are, or the empty message (VoiceOver's focus stays in the text).
    func announceOpen() {
        let sentence: String
        switch items.count {
        case 0: sentence = emptyMessage
        case 1: sentence = "\(items[0].title). 1 suggestion"
        default: sentence = "\(items[0].title). \(items.count) suggestions"
        }
        speak(sentence)
    }

    private func speak(_ sentence: String) {
        lastAnnouncement = sentence
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: sentence,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// The rows in view, in order: what VoiceOver reads as the list's children.
    var visibleRows: [CompletionRowView] { rows.filter { !$0.isHidden } }

    private func refreshRows() {
        let width = bounds.width - 2 * Self.padding
        for (slot, row) in rows.enumerated() {
            let frame = NSRect(x: Self.padding, y: Self.padding + CGFloat(slot) * Self.rowHeight,
                               width: max(0, width), height: Self.rowHeight)
            if items.isEmpty {
                row.isHidden = slot != 0
                row.configure(title: emptyMessage, subtitle: "", selected: false, muted: true)
                row.frame = frame
                continue
            }
            let index = topRow + slot
            guard index < items.count else { row.isHidden = true; continue }
            row.isHidden = false
            row.frame = frame
            row.configure(title: items[index].title, subtitle: items[index].subtitle,
                          selected: index == selectedIndex, muted: false)
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshRows()
    }

    override func accessibilityChildren() -> [Any]? { visibleRows }
    override func accessibilitySelectedChildren() -> [Any]? {
        guard !items.isEmpty else { return [] }
        let slot = selectedIndex - topRow
        return rows.indices.contains(slot) ? [rows[slot]] : []
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !items.isEmpty else { return }
        let slot = Int((point.y - Self.padding) / Self.rowHeight)
        let index = topRow + slot
        guard slot >= 0, slot < Self.maxVisibleRows, index < items.count else { return }
        onAccept?(index)
    }

    override func scrollWheel(with event: NSEvent) {
        guard items.count > Self.maxVisibleRows else { return }
        let step = event.scrollingDeltaY > 0 ? -1 : (event.scrollingDeltaY < 0 ? 1 : 0)
        topRow = max(0, min(topRow + step, items.count - Self.maxVisibleRows))
        refreshRows()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A thin position indicator when more rows than fit.
        guard items.count > Self.maxVisibleRows else { return }
        let track = bounds.insetBy(dx: 0, dy: Self.padding + 2)
        let fraction = CGFloat(Self.maxVisibleRows) / CGFloat(items.count)
        let height = max(12, track.height * fraction)
        let travel = track.height - height
        let position = CGFloat(topRow) / CGFloat(items.count - Self.maxVisibleRows)
        let knob = NSRect(x: bounds.maxX - 5, y: track.minY + travel * position,
                          width: 3, height: height)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: knob, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAdaptiveLayerColors()
    }

    private func applyAdaptiveLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// One row of the completion list: the title, then the subtitle muted at the
/// right. VoiceOver reads it as static text with its title.
final class CompletionRowView: NSView {
    private(set) var title = ""
    private(set) var subtitle = ""
    private(set) var isSelected = false
    private var isMuted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    func configure(title: String, subtitle: String, selected: Bool, muted: Bool) {
        guard title != self.title || subtitle != self.subtitle
                || selected != isSelected || muted != isMuted else { return }
        self.title = title
        self.subtitle = subtitle
        isSelected = selected
        isMuted = muted
        setAccessibilityLabel(title)
        setAccessibilityTitle(title)
        setAccessibilityValue(subtitle.isEmpty ? nil : subtitle)
        setAccessibilitySelected(selected)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // the list takes the click

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let titleColor: NSColor = isSelected ? .alternateSelectedControlTextColor
            : (isMuted ? .secondaryLabelColor : .labelColor)
        let subtitleColor: NSColor = isSelected
            ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let subtitleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let inset: CGFloat = 8
        var subtitleWidth: CGFloat = 0
        if !subtitle.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: subtitleFont, .foregroundColor: subtitleColor, .paragraphStyle: truncating]
            subtitleWidth = min((subtitle as NSString).size(withAttributes: attributes).width + 1,
                                bounds.width * 0.4)
            let y = (bounds.height - subtitleFont.boundingRectForFont.height) / 2
            (subtitle as NSString).draw(
                in: NSRect(x: bounds.maxX - inset - subtitleWidth, y: y,
                           width: subtitleWidth, height: subtitleFont.boundingRectForFont.height),
                withAttributes: attributes)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont, .foregroundColor: titleColor, .paragraphStyle: truncating]
        let lineHeight = titleFont.boundingRectForFont.height
        let titleWidth = bounds.width - 2 * inset - (subtitleWidth > 0 ? subtitleWidth + 12 : 0)
        (title as NSString).draw(
            in: NSRect(x: inset, y: (bounds.height - lineHeight) / 2,
                       width: max(0, titleWidth), height: lineHeight),
            withAttributes: attributes)
    }
}
