import AppKit
import MaughamCore

// **The suggestion strip** (report plan 9c-2 Tasks 5–6, spec §6.5): the band
// between the formula bar and the grid that shows the open notes on the
// active cell — a suggestion's before → after with Accept and Reject, a
// comment's or query's words with Got it and Reject. Its room is the panel's
// (`FigureGridPanel.stripHeight`), reserved while the figure has an open live
// cell note; what it shows follows the selection, from the controller's
// cached `FigureCellNotes` — never the host's projection per arrow key.

/// **What the strip shows** (pure, `FigureGridStripPlanTests`).
enum FigureGridStrip {

    /// An answer the strip offers (plan ruling: a suggestion gets Accept and
    /// Reject; any other note Got it and Reject; Reply stays in the queue).
    enum Verb: Equatable {
        case accept, gotIt, reject

        var title: String {
            switch self {
            case .accept: "Accept"
            case .gotIt: "Got it"
            case .reject: "Reject"
            }
        }
    }

    /// A button: its verb, and whether it may be pressed.
    struct Action: Equatable {
        let verb: Verb
        let isEnabled: Bool
    }

    /// One note on the active cell.
    struct Entry: Equatable {
        let noteId: String
        let kind: AnnotationKind
        /// "Suggested change · C3".
        let heading: String
        let body: String
        /// A suggestion's "12 → 14" (the cell as it stands, then what it
        /// would hold); nil for any other note.
        let change: String?
        /// The buttons, in order; none while the grid is read-only.
        let actions: [Action]
    }

    /// **The strip's content for the active cell.**
    struct Plan: Equatable {
        /// Every open live note whose cell or range holds the active cell,
        /// in the projection's order; empty shows `noNotes`.
        let entries: [Entry]
        /// Why the buttons are hidden (a read-only grid) or disabled (this
        /// Mac may not answer the figure's notes); nil when they may be pressed.
        let reason: String?

        static let empty = Plan(entries: [], reason: nil)

        /// The line an unmarked cell shows.
        static let noNotes = "No notes on this cell"
        /// Why the buttons are disabled when the figure's posture refuses
        /// `.acceptOrReject`.
        static let notPermitted = "This Mac may not answer notes on this figure."
        /// Why Accept is disabled in the window's review mode, where Got it
        /// and Reject (no cell moves) stay offered (fix round ruling I1).
        static let reviewModeAccept = "Turn off review mode to accept \u{2014} it writes the cell."

        /// The entry on `page` (clamped) and its "1 of 2" (nil with one note).
        func page(_ page: Int) -> (entry: Entry, label: String?)? {
            guard !entries.isEmpty else { return nil }
            let index = min(max(page, 0), entries.count - 1)
            return (entries[index], entries.count > 1 ? "\(index + 1) of \(entries.count)" : nil)
        }

        /// - `notes`: the controller's cached open live cell notes.
        /// - `active`: the selection's active cell; nil shows nothing.
        /// - `mayAccept`: a suggestion may be accepted — the figure's posture
        ///   allows `.acceptOrReject` and the grid may change the cell.
        /// - `mayReject`: a note may be answered without writing a cell
        ///   (Reject, Got it) — the posture allows `.acceptOrReject`.
        /// - `readOnly`: the grid's read-only reason; the buttons are hidden
        ///   and the reason said — except review mode, which keeps Got it and
        ///   Reject (the posture decides) and shows Accept disabled.
        static func make(
            notes: FigureCellNotes, active: CellKey?, table: FigureTable, names: FormulaNames,
            locale: TableLocale, mayAccept: Bool, mayReject: Bool, readOnly: FigureGridGate.Reason?
        ) -> Plan {
            guard let active else { return .empty }
            let found = notes.notes(containing: active)
            guard !found.isEmpty else { return .empty }
            let reviewing = readOnly == .reviewMode
            let hidden = readOnly != nil && !reviewing
            let entries = found.map { note -> Entry in
                let address: String? = switch note.figureAnchor?.resolve(in: table) {
                case .live(let a1)?: a1
                default: note.figureAddress
                }
                let heading = [note.kind.displayName, address].compactMap { $0 }.joined(separator: " \u{00B7} ")
                let change = SuggestionDisplay.figureCells(for: note, table: table, names: names, locale: locale)
                    .map { "\(shownCell($0.before ?? "")) \u{2192} \(shownCell($0.after))" }
                let actions: [Action]
                if hidden {
                    actions = []
                } else if note.kind == .suggestedChange {
                    actions = [Action(verb: .accept, isEnabled: mayAccept && !reviewing),
                               Action(verb: .reject, isEnabled: mayReject)]
                } else {
                    actions = [Action(verb: .gotIt, isEnabled: mayReject), Action(verb: .reject, isEnabled: mayReject)]
                }
                return Entry(noteId: note.id, kind: note.kind, heading: heading, body: note.body,
                             change: change, actions: actions)
            }
            let reason: String? = if hidden, let readOnly {
                readOnly.sentence
            } else if !mayReject {
                notPermitted
            } else if reviewing, entries.contains(where: { $0.kind == .suggestedChange }) {
                reviewModeAccept
            } else if entries.contains(where: { $0.actions.contains { !$0.isEnabled } }) {
                notPermitted
            } else {
                nil
            }
            return Plan(entries: entries, reason: reason)
        }

        /// A cell's text in the change line; an empty cell reads as the queue's.
        static func shownCell(_ text: String) -> String {
            text.isEmpty ? AnnotationRow.emptyCell : text
        }
    }
}

/// What the writer did in the strip. The strip writes nothing: the controller acts.
@MainActor
protocol FigureGridStripViewDelegate: AnyObject {
    func stripView(_ view: FigureGridStripView, perform verb: FigureGridStrip.Verb, noteId: String)
    func stripView(_ view: FigureGridStripView, turnPage delta: Int)
}

/// **The strip, drawn** in the bars' style: two rows — the note's kind and
/// cell, its words and its "1 of 2" with ‹ ›; then a suggestion's change, the
/// reason the buttons are hidden or disabled, and the buttons.
@MainActor
final class FigureGridStripView: NSStackView {
    weak var stripDelegate: FigureGridStripViewDelegate?

    let headingLabel = NSTextField(labelWithString: "")
    let bodyLabel = NSTextField(labelWithString: "")
    let pageLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton(title: "\u{2039}", target: nil, action: nil)
    let nextButton = NSButton(title: "\u{203A}", target: nil, action: nil)
    let changeLabel = NSTextField(labelWithString: "")
    let reasonLabel = NSTextField(labelWithString: "")
    let acceptButton = NSButton(title: FigureGridStrip.Verb.accept.title, target: nil, action: nil)
    let gotItButton = NSButton(title: FigureGridStrip.Verb.gotIt.title, target: nil, action: nil)
    let rejectButton = NSButton(title: FigureGridStrip.Verb.reject.title, target: nil, action: nil)

    private let top = NSStackView()
    private let bottom = NSStackView()
    /// The note the buttons answer.
    private(set) var shownNoteId: String?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        distribution = .fillEqually
        spacing = 0
        wantsLayer = true
        headingLabel.textColor = ReviewPalette.claudeTerracotta
        headingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        for label in [bodyLabel, changeLabel, reasonLabel, pageLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.lineBreakMode = .byTruncatingTail
        }
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changeLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        changeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reasonLabel.textColor = .secondaryLabelColor
        reasonLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageLabel.textColor = .secondaryLabelColor
        previousButton.toolTip = "Previous Note"
        previousButton.setAccessibilityLabel("Previous Note")
        nextButton.toolTip = "Next Note"
        nextButton.setAccessibilityLabel("Next Note")
        for button in [previousButton, nextButton, acceptButton, gotItButton, rejectButton] {
            button.target = self
            button.action = #selector(acted(_:))
            button.controlSize = .small
        }
        for (row, views) in [(top, [headingLabel, bodyLabel, pageLabel, previousButton, nextButton]),
                             (bottom, [changeLabel, reasonLabel, acceptButton, gotItButton, rejectButton])]
            as [(NSStackView, [NSView])] {
            row.orientation = .horizontal
            row.spacing = 6
            row.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
            for view in views { row.addArrangedSubview(view) }
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        show(.empty, page: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = ReviewPalette.claudeTerracotta.withAlphaComponent(0.06).cgColor
    }

    /// **`plan`'s entry on `page`**, or "No notes on this cell".
    func show(_ plan: FigureGridStrip.Plan, page: Int) {
        guard let (entry, label) = plan.page(page) else {
            shownNoteId = nil
            headingLabel.stringValue = ""
            headingLabel.isHidden = true
            bodyLabel.stringValue = FigureGridStrip.Plan.noNotes
            bodyLabel.textColor = .secondaryLabelColor
            for view in [pageLabel, previousButton, nextButton, changeLabel, reasonLabel,
                         acceptButton, gotItButton, rejectButton] as [NSView] {
                view.isHidden = true
            }
            return
        }
        shownNoteId = entry.noteId
        headingLabel.stringValue = entry.heading
        headingLabel.isHidden = false
        bodyLabel.stringValue = entry.body
        bodyLabel.textColor = .labelColor
        pageLabel.stringValue = label ?? ""
        for view in [pageLabel, previousButton, nextButton] as [NSView] { view.isHidden = label == nil }
        changeLabel.stringValue = entry.change ?? ""
        changeLabel.isHidden = entry.change == nil
        reasonLabel.stringValue = plan.reason ?? ""
        reasonLabel.isHidden = plan.reason == nil
        for (button, verb) in [(acceptButton, FigureGridStrip.Verb.accept), (gotItButton, .gotIt),
                               (rejectButton, .reject)] {
            let action = entry.actions.first { $0.verb == verb }
            button.isHidden = action == nil
            button.isEnabled = action?.isEnabled ?? false
        }
    }

    @objc private func acted(_ sender: NSButton) {
        switch sender {
        case previousButton: stripDelegate?.stripView(self, turnPage: -1)
        case nextButton: stripDelegate?.stripView(self, turnPage: 1)
        default:
            guard let noteId = shownNoteId else { return }
            let verb: FigureGridStrip.Verb = sender === acceptButton ? .accept
                : sender === gotItButton ? .gotIt : .reject
            stripDelegate?.stripView(self, perform: verb, noteId: noteId)
        }
    }
}

// MARK: - The strip's questions (report plan 9c-2 Task 6)

extension FigureGridStrip {

    /// **The cell changed since the suggestion was made** — asked before an
    /// Accept that would replace what the writer put there since. A value,
    /// so a test answers it (no alert in a test).
    struct ChangedQuestion: Equatable {
        /// "B2".
        let address: String
        /// The cell as it stands now.
        let now: String
        /// What the suggestion would put there.
        let after: String

        var message: String { FigureNoteError.cellChangedSinceSuggestion.errorDescription ?? "" }
        var informative: String {
            "\(address) now holds \(Plan.shownCell(now)). Accept anyway and put \(Plan.shownCell(after)) there?"
        }
        static let confirmTitle = "Accept Anyway"
    }

    /// **Why the note is rejected** — the optional reason kept as its reply.
    struct RejectQuestion: Equatable {
        /// The note's heading, as the strip shows it ("Comment · C1").
        let heading: String
        let body: String

        static let message = "Reject this note?"
        static let informative = "Say why, if you like \u{2014} the reason is kept with the note."
        static let placeholder = "Reason (optional)"
    }

    /// The reject sheet's answer: reject (a blank reason is none), or cancel.
    enum RejectAnswer: Equatable {
        case reject(reason: String?)
        case cancel
    }

    /// **The questions as AppKit sheets on the grid's window** (plan ruling:
    /// the reject reason is a sheet on the grid's window, not the queue's
    /// SwiftUI sheet). No window, no question: nothing is written.
    @MainActor
    enum Sheets {
        static func ask(_ question: ChangedQuestion, in window: NSWindow?) async -> Bool {
            guard let window else { return false }
            let alert = NSAlert()
            alert.messageText = question.message
            alert.informativeText = question.informative
            alert.addButton(withTitle: ChangedQuestion.confirmTitle)
            alert.addButton(withTitle: "Cancel")
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }

        static func ask(_ question: RejectQuestion, in window: NSWindow?) async -> RejectAnswer {
            guard let window else { return .cancel }
            let alert = NSAlert()
            alert.messageText = RejectQuestion.message
            alert.informativeText = "\(question.heading): \(question.body)\n\n\(RejectQuestion.informative)"
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = RejectQuestion.placeholder
            alert.accessoryView = field
            alert.addButton(withTitle: Verb.reject.title)
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            let pressed = await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0) }
            }
            guard pressed == .alertFirstButtonReturn else { return .cancel }
            let reason = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .reject(reason: reason.isEmpty ? nil : reason)
        }
    }
}
