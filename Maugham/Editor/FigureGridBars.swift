import AppKit
import MaughamCore

// MARK: - What the bars offer (pure)

/// **The number formats the toolbar's menu offers** (spec §6.2), each with
/// the format a cell takes when it is chosen.
enum FigureGridFormatChoice: CaseIterable, Equatable {
    case general, number, percent, currency, compact, date

    var title: String {
        switch self {
        case .general: "General"
        case .number: "Number"
        case .percent: "Percent"
        case .currency: "Currency"
        case .compact: "Compact"
        case .date: "Date"
        }
    }

    /// The menu item a cell's format shows as.
    static func choice(of format: NumberFormat) -> FigureGridFormatChoice {
        switch format {
        case .general: .general
        case .number: .number
        case .percent: .percent
        case .currency: .currency
        case .compact: .compact
        case .date: .date
        }
    }

    /// `current` switched to this choice: its decimals kept where both kinds
    /// have them, else the kind's own default; the format left as it is when
    /// it is already this kind (Number keeps its grouping, Currency its symbol).
    func applied(to current: NumberFormat) -> NumberFormat {
        if Self.choice(of: current) == self { return current }
        let kept = FigureGridFormatting.decimals(of: current)
        switch self {
        case .general: return .general
        case .number: return .number(decimals: kept ?? 2, grouping: true)
        case .percent: return .percent(decimals: kept ?? 0)
        case .currency: return .currency(symbol: nil, decimals: kept ?? 2)
        case .compact: return .compact(decimals: kept ?? 1)
        case .date: return .date(.day)
        }
    }
}

/// The toolbar's arithmetic, pure.
enum FigureGridFormatting {
    /// The most decimals the toolbar's + goes to.
    static let maxDecimals = 10

    /// The decimals `format` shows, nil for a kind without them.
    static func decimals(of format: NumberFormat) -> Int? {
        switch format {
        case .number(let d, _), .percent(let d), .currency(_, let d), .compact(let d): d
        case .general, .date: nil
        }
    }

    /// **Decimals −/+**: `format` with `delta` more decimals, held in
    /// 0…`maxDecimals`. General becomes a plain number (no grouping) at 0
    /// decimals for −, 1 for +; a date is left as it is.
    static func decimals(_ format: NumberFormat, by delta: Int) -> NumberFormat {
        let clamp = { (d: Int) in min(max(d + delta, 0), maxDecimals) }
        switch format {
        case .general: return .number(decimals: delta > 0 ? 1 : 0, grouping: false)
        case .number(let d, let grouping): return .number(decimals: clamp(d), grouping: grouping)
        case .percent(let d): return .percent(decimals: clamp(d))
        case .currency(let symbol, let d): return .currency(symbol: symbol, decimals: clamp(d))
        case .compact(let d): return .compact(decimals: clamp(d))
        case .date: return format
        }
    }

    /// **A parse error's caret, as a text field counts it**: `FormulaParseError`
    /// counts Characters into the typed text (`FigureCellEntry`), an
    /// `NSTextField`'s selection UTF-16 units. Past the end is the end.
    static func utf16Offset(ofCharacter offset: Int, in text: String) -> Int {
        let index = text.index(text.startIndex, offsetBy: max(0, offset), limitedBy: text.endIndex) ?? text.endIndex
        return NSRange(text.startIndex..<index, in: text).length
    }
}

// MARK: - The bars

/// What the writer did in a bar. The bars write nothing: the controller acts.
enum FigureGridBarAction: Equatable {
    /// The formula bar's text, after the writer changed it.
    case formulaTextChanged(String)
    /// Return, Tab, Esc in the formula bar.
    case formulaCommand(FigureGridKey)
    case format(FigureGridFormatChoice)
    case decimals(Int)
    case align(CellAlignment)
    case headerRow(Bool)
    case totalRow(Bool)
    case sum
    case caption(String)
    case name(String)
    case done
}

@MainActor
protocol FigureGridBarsDelegate: AnyObject {
    /// Answers whether the action was taken (a formula-bar command the
    /// controller declines stays the field's own).
    @discardableResult
    func figureGridBars(_ bars: FigureGridBars, perform action: FigureGridBarAction) -> Bool
}

/// **The expanded grid's three bars** (report plan 7c Task 5, spec §6.2):
/// the slim toolbar (format menu, decimals −/+, align, Header row, Total row,
/// Σ), the formula bar (the selection's address and the active cell's formula
/// or value, a parse error under it at its offset) and the bottom bar
/// ("Table N · caption · name", Done). Plain AppKit — an `NSPopUpButton`, no
/// popover (tripwire 5). Each bar is a fixed height; the card room frames
/// them (Task 6).
@MainActor
final class FigureGridBars: NSObject, NSTextFieldDelegate {
    static let barHeight: CGFloat = 28
    /// The three bars together.
    static let totalHeight: CGFloat = 3 * barHeight

    weak var delegate: FigureGridBarsDelegate?

    let toolbar = NSStackView()
    let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let fewerDecimals = NSButton(title: "−.0", target: nil, action: nil)
    let moreDecimals = NSButton(title: "+.0", target: nil, action: nil)
    let alignment = NSSegmentedControl()
    let headerRow = NSButton(checkboxWithTitle: "Header row", target: nil, action: nil)
    let totalRow = NSButton(checkboxWithTitle: "Total row", target: nil, action: nil)
    let sum = NSButton(title: "Σ", target: nil, action: nil)

    let formulaBar = NSStackView()
    let addressLabel = NSTextField(labelWithString: "")
    let formulaField = NSTextField(string: "")
    let errorLabel = NSTextField(labelWithString: "")

    let bottomBar = NSStackView()
    let numberLabel = NSTextField(labelWithString: "")
    let captionField = NSTextField(string: "")
    let nameField = NSTextField(string: "")
    let doneButton = NSButton(title: "Done", target: nil, action: nil)

    /// The caption and name as last committed: a field the writer leaves
    /// unchanged, or whose commit is refused, shows this again.
    private(set) var committedCaption = ""
    private(set) var committedName = ""

    static let alignments: [CellAlignment] = [.left, .center, .right]

    override init() {
        super.init()
        for choice in FigureGridFormatChoice.allCases { formatPopUp.addItem(withTitle: choice.title) }
        formatPopUp.toolTip = "Number Format"
        fewerDecimals.toolTip = "Fewer Decimal Places"
        moreDecimals.toolTip = "More Decimal Places"
        alignment.segmentCount = Self.alignments.count
        alignment.trackingMode = .selectOne
        for (i, name) in ["text.alignleft", "text.aligncenter", "text.alignright"].enumerated() {
            alignment.setImage(NSImage(systemSymbolName: name, accessibilityDescription: nil), forSegment: i)
        }
        alignment.toolTip = "Align"
        sum.toolTip = "Sum the column above"
        for control in [formatPopUp, fewerDecimals, moreDecimals, alignment, headerRow, totalRow, sum, doneButton] as [NSControl] {
            control.target = self
            control.action = #selector(controlActed(_:))
            control.controlSize = .small
        }
        configure(toolbar, [formatPopUp, fewerDecimals, moreDecimals, alignment, headerRow, totalRow, sum])

        addressLabel.alignment = .center
        addressLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        addressLabel.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byTruncatingTail
        for field in [formulaField, captionField, nameField] {
            field.delegate = self
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.controlSize = .small
        }
        captionField.placeholderString = "Caption"
        nameField.placeholderString = "Name"
        configure(formulaBar, [addressLabel, formulaField, errorLabel])
        configure(bottomBar, [numberLabel, captionField, nameField, doneButton])
    }

    private func configure(_ bar: NSStackView, _ views: [NSView]) {
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        for view in views { bar.addArrangedSubview(view) }
    }

    // MARK: Showing (from the controller)

    /// The selection's address and the formula bar's text; the field is left
    /// alone while the writer is typing in it.
    func showSelection(address: String, text: String) {
        addressLabel.stringValue = address
        if formulaField.currentEditor() == nil, formulaField.stringValue != text { formulaField.stringValue = text }
    }

    /// Replace the formula field's text even while it is being edited (a
    /// reference composed by a click while the writer types there).
    func setFormulaText(_ text: String) {
        formulaField.stringValue = text
        if let editor = formulaField.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    /// The active cell's format, alignment, and the table's header and total rows.
    func showFormat(_ format: NumberFormat, alignment cellAlignment: CellAlignment, header: Bool, total: Bool) {
        formatPopUp.selectItem(at: FigureGridFormatChoice.allCases.firstIndex(of: .choice(of: format)) ?? 0)
        let segment = Self.alignments.firstIndex(of: cellAlignment) ?? -1
        if segment >= 0 { alignment.selectedSegment = segment } else { alignment.selectedSegment = -1 }
        headerRow.state = header ? .on : .off
        totalRow.state = total ? .on : .off
    }

    /// "Table 2", the caption and the name — the committed values.
    func showLine(number: String, caption: String, name: String) {
        numberLabel.stringValue = number
        committedCaption = caption
        committedName = name
        if captionField.currentEditor() == nil { captionField.stringValue = caption }
        if nameField.currentEditor() == nil { nameField.stringValue = name }
    }

    /// A formula that will not read: its message, shown under the formula.
    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    func clearError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    var errorMessage: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }

    // MARK: The writer's acts

    @objc private func controlActed(_ sender: NSControl) {
        let action: FigureGridBarAction
        switch sender {
        case formatPopUp:
            let i = formatPopUp.indexOfSelectedItem
            guard FigureGridFormatChoice.allCases.indices.contains(i) else { return }
            action = .format(FigureGridFormatChoice.allCases[i])
        case fewerDecimals: action = .decimals(-1)
        case moreDecimals: action = .decimals(1)
        case alignment:
            guard Self.alignments.indices.contains(alignment.selectedSegment) else { return }
            action = .align(Self.alignments[alignment.selectedSegment])
        case headerRow: action = .headerRow(headerRow.state == .on)
        case totalRow: action = .totalRow(totalRow.state == .on)
        case sum: action = .sum
        case doneButton: action = .done
        default: return
        }
        delegate?.figureGridBars(self, perform: action)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === formulaField else { return }
        delegate?.figureGridBars(self, perform: .formulaTextChanged(formulaField.stringValue))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        switch notification.object as? NSTextField {
        case captionField where captionField.stringValue != committedCaption:
            delegate?.figureGridBars(self, perform: .caption(captionField.stringValue))
        case nameField where nameField.stringValue != committedName:
            delegate?.figureGridBars(self, perform: .name(nameField.stringValue))
        default: break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === formulaField {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            let key: FigureGridKey? = switch selector {
            case #selector(NSResponder.insertNewline(_:)): .returnKey(backward: shift)
            case #selector(NSResponder.insertTab(_:)): .tab(backward: false)
            case #selector(NSResponder.insertBacktab(_:)): .tab(backward: true)
            case #selector(NSResponder.cancelOperation(_:)): .escape
            default: nil
            }
            guard let key else { return false }
            return delegate?.figureGridBars(self, perform: .formulaCommand(key)) ?? false
        }
        // Esc in the caption or name puts back what was committed.
        if selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField {
            field.stringValue = field === captionField ? committedCaption : committedName
            field.abortEditing()
            return true
        }
        return false
    }
}
