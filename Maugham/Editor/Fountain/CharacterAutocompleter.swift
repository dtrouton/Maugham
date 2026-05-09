import AppKit

public final class CharacterAutocompleter: NSObject {

    private(set) public var suggestions: [String] = []
    private(set) public var selectedIndex: Int = 0

    private let popover: NSPopover
    private let tableView: NSTableView
    private let scrollView: NSScrollView

    public var isVisible: Bool { popover.isShown }

    public override init() {
        self.popover = NSPopover()
        popover.behavior = .transient

        // Set up the table view inside a scroll view.
        let tv = NSTableView()
        tv.headerView = nil
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = false
        tv.backgroundColor = .clear
        tv.intercellSpacing = NSSize(width: 0, height: 2)
        tv.rowHeight = 22
        tv.usesAlternatingRowBackgroundColors = false
        tv.style = .plain

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 200
        tv.addTableColumn(column)

        let sv = NSScrollView()
        sv.hasVerticalScroller = false
        sv.documentView = tv
        sv.drawsBackground = false

        self.tableView = tv
        self.scrollView = sv
        super.init()

        tv.delegate = self
        tv.dataSource = self

        let vc = NSViewController()
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        sv.frame = containerView.bounds
        sv.autoresizingMask = [.width, .height]
        containerView.addSubview(sv)
        vc.view = containerView
        popover.contentViewController = vc
    }

    /// Update suggestions and either show or update the popover.
    /// `anchorRect` is the cursor's screen-rect (relative to the text view).
    /// `relativeTo` is the text view that owns the cursor.
    public func show(
        suggestions: [String],
        anchorRect: NSRect,
        relativeTo view: NSView
    ) {
        guard !suggestions.isEmpty else {
            dismiss()
            return
        }

        // If suggestions are unchanged AND popover is already visible, no work.
        if popover.isShown && self.suggestions == suggestions {
            return
        }

        let suggestionsChanged = self.suggestions != suggestions
        self.suggestions = suggestions
        if suggestionsChanged {
            self.selectedIndex = 0
        }

        let height = CGFloat(min(suggestions.count, 8) * 24 + 8)
        if let containerView = popover.contentViewController?.view {
            containerView.frame = NSRect(x: 0, y: 0, width: 200, height: height)
            scrollView.frame = containerView.bounds
        }

        tableView.reloadData()
        if !suggestions.isEmpty, selectedIndex < suggestions.count {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }

        // Don't re-show if already visible — re-showing during animation has
        // surfaced as a crash source. AppKit handles content updates fine via
        // reloadData; the popover stays anchored at its initial position.
        guard !popover.isShown else { return }

        // Clamp anchor rect to the relativeTo view's bounds to avoid the
        // "anchor rect outside view bounds" exception.
        let viewBounds = view.bounds
        let clampedRect = NSRect(
            x: max(viewBounds.minX, min(anchorRect.origin.x, viewBounds.maxX - 1)),
            y: max(viewBounds.minY, min(anchorRect.origin.y, viewBounds.maxY - 1)),
            width: max(1, min(anchorRect.width, viewBounds.width)),
            height: max(1, min(anchorRect.height, viewBounds.height)))

        popover.show(relativeTo: clampedRect, of: view, preferredEdge: .minY)
    }

    public func dismiss() {
        if popover.isShown { popover.close() }
        suggestions = []
        selectedIndex = 0
    }

    public func moveSelectionUp() {
        guard !suggestions.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex),
                                   byExtendingSelection: false)
    }

    public func moveSelectionDown() {
        guard !suggestions.isEmpty else { return }
        selectedIndex = min(suggestions.count - 1, selectedIndex + 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex),
                                   byExtendingSelection: false)
    }

    /// Replace the active line's character cue text with the selected suggestion
    /// and dismiss the popover. Preserves any leading `@` prefix.
    public func acceptSelection(in textView: NSTextView) {
        guard !suggestions.isEmpty,
              selectedIndex >= 0, selectedIndex < suggestions.count,
              let storage = textView.textStorage else {
            dismiss()
            return
        }
        let chosen = suggestions[selectedIndex]
        let cursor = textView.selectedRange().location
        let lineRange = (storage.string as NSString).lineRange(
            for: NSRange(location: cursor, length: 0))
        var lineText = (storage.string as NSString).substring(with: lineRange)
        // Strip trailing newline for processing.
        let hasTrailingNewline = lineText.hasSuffix("\n")
        if hasTrailingNewline { lineText.removeLast() }
        let hasAt = lineText.hasPrefix("@")
        let newContent = hasAt ? "@" + chosen : chosen
        let newLine = newContent + (hasTrailingNewline ? "\n" : "")

        guard textView.shouldChangeText(in: lineRange, replacementString: newLine) else {
            dismiss()
            return
        }
        storage.replaceCharacters(in: lineRange, with: newLine)
        textView.didChangeText()
        let endLocation = lineRange.location + (newContent as NSString).length
        textView.setSelectedRange(NSRange(location: endLocation, length: 0))
        dismiss()
    }

    // MARK: - Pure data (kept from T5)

    public static func rankSuggestions(
        prefix: String,
        characterNames: Set<String>
    ) -> [String] {
        guard !prefix.isEmpty, !characterNames.isEmpty else { return [] }
        let upperPrefix = prefix.uppercased()
        let allUpper = Set(characterNames.map { $0.uppercased() })
        let prefixMatches = allUpper
            .filter { $0.hasPrefix(upperPrefix) }
            .sorted()
        let substringMatches = allUpper
            .filter { name in
                guard let range = name.range(of: upperPrefix),
                      !name.hasPrefix(upperPrefix) else { return false }
                return range.upperBound < name.endIndex
            }
            .sorted()
        let combined = prefixMatches + substringMatches
        return Array(combined.prefix(8))
    }
}

// MARK: - NSTableViewDataSource

extension CharacterAutocompleter: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }
}

// MARK: - NSTableViewDelegate

extension CharacterAutocompleter: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard row >= 0, row < suggestions.count else { return nil }
        let cellId = NSUserInterfaceItemIdentifier("nameCell")
        let view: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            view = reused
        } else {
            view = NSTableCellView()
            view.identifier = cellId
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            tf.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(tf)
            view.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        view.textField?.stringValue = suggestions[row]
        return view
    }
}
