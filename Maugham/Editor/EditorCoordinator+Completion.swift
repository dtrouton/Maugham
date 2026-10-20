import Foundation
import MaughamCore
import AppKit

/// The open completion list's state (plan 3b Task 2). Plain coordinator state,
/// never observed (tripwire 6).
struct CompletionState {
    let source: any CompletionSource
    /// The trigger and the query, ending at the caret (`[@smi`): what an
    /// accept replaces.
    var triggerRange: NSRange
    var query: String
    var items: [CompletionItem]
    var selectedIndex: Int
}

/// What the edit `shouldChangeTextIn` just let through was, for the trigger
/// (`textDidChange` reads it once and drops it).
enum CompletionEditNote: Equatable {
    /// The writer typed this one character (a length-1 typing replacement,
    /// not undo or redo, not a command's edit, no input-method composition).
    case typed(String)
    /// The writer deleted (backspace, forward delete).
    case deletion
    /// Anything else: a paste, an undo, a command, a composition.
    case other
}

// EditorCoordinator — the completion list (plan 3b Task 2, ruling R-3b-5): the
// app's first in-editor completion, shared by the citation and cross-reference
// pickers. The trigger comes from the typed character (recorded in
// `shouldChangeTextIn`, read after the retokenize in `textDidChange`); the keys
// are routed first in `doCommandBy`, before the table arms; an accept is one
// Route A edit. It opens on a manuscript surface only (`answersInsertCommands`),
// never inside a code span or while an input method composes, and closes on
// scroll, resize, focus loss, the caret leaving the trigger, an external text,
// a read-only posture, Esc and detach.
extension EditorCoordinator {
    var isCompletionOpen: Bool { completion != nil }

    // MARK: - Opening and closing

    /// Opens the list for `source` over `triggerRange` (the trigger through the
    /// caret). Refused — returning false, changing nothing — off a manuscript
    /// surface, when a command could not write (a read-only posture), while an
    /// input method composes, inside a code span, or for a range that does not
    /// fit the text. Tasks 3 and 4's menu commands call it too.
    @discardableResult
    func openCompletion(source: any CompletionSource, triggerRange: NSRange) -> Bool {
        guard mayOfferCompletion, let textView, !tokensDescribeAnEarlierText else { return false }
        let ns = textView.string as NSString
        guard triggerRange.location >= 0, NSMaxRange(triggerRange) <= ns.length,
              !isInsideCode(triggerRange.location) else { return false }
        let query = source.query(inTrigger: ns.substring(with: triggerRange))
        completion = CompletionState(source: source, triggerRange: triggerRange, query: query,
                                     items: source.items(matching: query), selectedIndex: 0)
        armCompletionObservers()
        completionCaretMoved()      // the opening keystroke's own scroll follows
        showCompletionList()
        return true
    }

    /// Closes the list. The text stays exactly as typed.
    func closeCompletion() {
        guard completion != nil else { return }
        completion = nil
        completionList?.isHidden = true
        disarmCompletionObservers()
    }

    /// Whether this editor may offer completion now: a manuscript surface,
    /// attached, one a command may write, with no composition in flight.
    var mayOfferCompletion: Bool {
        guard answersInsertCommands, !isDetached, let textView else { return false }
        return commandMayWrite && !textView.hasMarkedText()
    }

    /// Whether `location` falls inside an inline code span, as the tokens
    /// place it. Asked only once a source has said yes, never per keystroke.
    func isInsideCode(_ location: Int) -> Bool {
        lastTokens.contains { token in
            token.kind == .code && location >= token.range.location
                && location < NSMaxRange(token.range)
        }
    }

    // MARK: - The keys (first in doCommandBy)

    /// The completion arm of `textView(_:doCommandBy:)`, asked before every
    /// other. `complete:` (AppKit's own completion window) is swallowed in
    /// prose whether the list is open or not. With the list open: ↑ and ↓
    /// move, Return and Tab accept — inside a table cell too — and Esc
    /// closes; with nothing to accept, Return and Tab close it and do what
    /// they always do. With the list closed, or while an input method
    /// composes, every other command falls through untouched.
    func handleCompletionCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        if selector == #selector(NSTextView.complete(_:)) {
            return !(mode is ScreenplayMode)
        }
        guard let state = completion, !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveCompletionSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveCompletionSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            guard !state.items.isEmpty else {
                closeCompletion()
                return false
            }
            acceptCompletion()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeCompletion()
            return true
        default:
            return false
        }
    }

    func moveCompletionSelection(by delta: Int) {
        guard var state = completion, !state.items.isEmpty else { return }
        state.selectedIndex = max(0, min(state.selectedIndex + delta, state.items.count - 1))
        completion = state
        completionList?.select(state.selectedIndex)
    }

    /// Accepts row `index` (the selected row when nil): the trigger through
    /// the query becomes the row's `insertion`, as ONE Route A edit — one ⌘Z
    /// step, behind the membrane — the caret after it. The writer's typing
    /// before it stays its own steps.
    @discardableResult
    func acceptCompletion(at index: Int? = nil) -> Bool {
        guard let state = completion, let textView else { return false }
        let chosen = index ?? state.selectedIndex
        guard state.items.indices.contains(chosen),
              NSMaxRange(state.triggerRange) <= (textView.string as NSString).length
        else { return false }
        let insertion = state.items[chosen].insertion
        closeCompletion()
        return applyCommandEdit(
            replacing: state.triggerRange, with: insertion,
            selecting: NSRange(location: state.triggerRange.location
                                   + (insertion as NSString).length, length: 0),
            actionName: state.source.actionName, landing: .immediate)
    }

    // MARK: - The trigger

    /// From `shouldChangeTextIn`, once the membrane has let an edit through:
    /// what the edit is, for `completionTextDidChange`. Only a length-1
    /// typing replacement counts as typed — never inside `applyCommandEdit`,
    /// never an undo or a redo, never with marked text.
    func noteEditForCompletion(in textView: NSTextView, replacing range: NSRange,
                               with replacement: String) {
        guard answersInsertCommands else { return }
        let undo = undoManagerOverrideForTesting ?? textView.undoManager
        if isApplyingCommandEdit || textView.hasMarkedText()
            || undo?.isUndoing == true || undo?.isRedoing == true {
            completionEditNote = .other
        } else {
            switch (replacement as NSString).length {
            case 1: completionEditNote = .typed(replacement)
            case 0 where range.length > 0: completionEditNote = .deletion
            default: completionEditNote = .other
            }
        }
        if completion != nil { completionCaretMoved() }
    }

    /// From the end of `textDidChange`, after the retokenize: an open list
    /// follows a typed character or a deletion (or closes when its trigger
    /// is gone) and closes on any other edit; a closed list opens when the
    /// writer typed a character and a registered source — asked in order —
    /// says the text before the caret opens it.
    func completionTextDidChange(in textView: NSTextView) {
        let note = completionEditNote
        completionEditNote = nil
        guard answersInsertCommands else { return }
        let caret = textView.selectedRange()
        if completion != nil {
            switch note {
            case .typed?, .deletion?:
                if refreshOpenCompletion(in: textView) { return }
            default:
                closeCompletion()
                return
            }
        }
        guard case .typed? = note, caret.length == 0, mayOfferCompletion else { return }
        let ns = textView.string as NSString
        // The first source that answers decides (citation before cross-reference).
        for source in completionSources {
            guard let range = source.triggerRange(in: ns, caret: caret.location) else { continue }
            if NSMaxRange(range) == caret.location {
                openCompletion(source: source, triggerRange: range)
            }
            return
        }
    }

    /// From `textViewDidChangeSelection`: an open list follows a caret that
    /// stays in its trigger and closes on one that leaves it, or on a
    /// composition beginning. A selection change posted mid-edit (inside
    /// `replaceCharacters`, before the retokenize) is ignored;
    /// `textDidChange` reads the caret after.
    func completionSelectionDidChange(in textView: NSTextView) {
        guard completion != nil else { return }
        // An input method's composition closes the list at once — closing
        // only hides it, so the composition is never interrupted, and its
        // keys go to the input method.
        if textView.hasMarkedText() { closeCompletion(); return }
        completionCaretMoved()
        guard !tokensDescribeAnEarlierText, !isApplyingCommandEdit else { return }
        _ = refreshOpenCompletion(in: textView)
    }

    /// Re-asks the open source at the caret. Same trigger start: the query
    /// and rows follow (rows asked again only when the query changed), true.
    /// Otherwise the list closes, false.
    private func refreshOpenCompletion(in textView: NSTextView) -> Bool {
        guard var state = completion else { return false }
        let caret = textView.selectedRange()
        let ns = textView.string as NSString
        guard caret.length == 0, mayOfferCompletion,
              let range = state.source.triggerRange(in: ns, caret: caret.location),
              range.location == state.triggerRange.location,
              NSMaxRange(range) == caret.location, NSMaxRange(range) <= ns.length else {
            closeCompletion()
            return false
        }
        let query = state.source.query(inTrigger: ns.substring(with: range))
        state.triggerRange = range
        if query != state.query {
            state.query = query
            state.items = state.source.items(matching: query)
            state.selectedIndex = 0
        }
        completion = state
        showCompletionList()
        return true
    }

    // MARK: - The view

    private func showCompletionList() {
        guard let state = completion, let list = completionList else { return }
        list.show(items: state.items, emptyMessage: state.source.emptyMessage,
                  selected: state.selectedIndex)
        list.onAccept = { [weak self] index in self?.acceptCompletion(at: index) }
        positionCompletionList()
        list.isHidden = false
    }

    /// Places the list under the trigger's start (`firstRect`, screen space,
    /// converted into the scroll view), or above it near the bottom edge.
    func positionCompletionList() {
        guard let state = completion, let list = completionList, let parent = list.superview,
              let textView, let window = textView.window else { return }
        let screen = textView.firstRect(
            forCharacterRange: NSRange(location: state.triggerRange.location, length: 0),
            actualRange: nil)
        let caret = parent.convert(window.convertFromScreen(screen), from: nil)
        list.frame = CompletionListLayout.frame(size: list.preferredSize, caret: caret,
                                                in: parent.bounds, flipped: parent.isFlipped)
    }

    // MARK: - Closing on scroll, resize and focus loss

    /// The caret moves with a keystroke or a selection change, and AppKit's
    /// caret-following scroll (or typewriter centring) may follow it in the
    /// same turn: until the next runloop, a scroll moves the list with the
    /// caret instead of closing it.
    private func completionCaretMoved() {
        guard !completionCaretIsMoving else { return }
        completionCaretIsMoving = true
        DispatchQueue.main.async { [weak self] in self?.completionCaretSettled() }
    }

    /// The runloop hop after a caret move (a test may run it by hand).
    func completionCaretSettled() {
        completionCaretIsMoving = false
    }

    /// The clip view scrolled: the writer's own scroll closes the list; one
    /// that follows the caret in the same turn as a keystroke moves it.
    func completionClipViewDidScroll() {
        guard completion != nil else { return }
        if completionCaretIsMoving { positionCompletionList() } else { closeCompletion() }
    }

    private func armCompletionObservers() {
        disarmCompletionObservers()
        guard let textView else { return }
        let nc = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        if let scrollView = textView.enclosingScrollView {
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            tokens.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                         queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.completionClipViewDidScroll() }
            })
            scrollView.postsFrameChangedNotifications = true
            tokens.append(nc.addObserver(forName: NSView.frameDidChangeNotification,
                                         object: scrollView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeCompletion() }
            })
        }
        if let window = textView.window {
            tokens.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                         queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeCompletion() }
            })
        }
        completionObservers = tokens
    }

    func disarmCompletionObservers() {
        for token in completionObservers { NotificationCenter.default.removeObserver(token) }
        completionObservers = []
    }

    /// A posture change: a membrane that now refuses closes the list.
    func closeCompletionIfTheMembraneRefuses() {
        if completion != nil, !commandMayWrite { closeCompletion() }
    }
}
