import Foundation
import MaughamCore
import AppKit

/// The open completion list's state (plan 3b Task 2). Plain coordinator state,
/// never observed (tripwire 6).
struct CompletionState {
    let source: any CompletionSource
    /// Where the completion is: what an accept replaces, the query and the
    /// source's context (`CompletionTrigger`).
    var trigger: CompletionTrigger
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
    /// Anything else: a paste, a drop, an undo, a command, a composition.
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

    /// Registers the manuscript's reference pickers, in the order they are
    /// asked: the citation picker (plan 3b Task 3), then the cross-reference
    /// picker (Task 4), so `[@` is a citation. Each reads the window's
    /// cached index through `referenceIndex` when it is asked, never a copy.
    /// `EditorSurface` calls it for a surface that answers the Insert menu.
    func registerReferencePickers() {
        let index: () -> ReferenceIndex = { [weak self] in self?.referenceIndex?() ?? .empty }
        completionSources = [CitationCompletion(index: index), CrossReferenceCompletion(index: index)]
    }

    // MARK: - Opening and closing

    /// Opens the list for `source` at `trigger` (the source's own reading of
    /// the text at the caret, `CompletionSource.trigger(in:caret:)`). Refused —
    /// returning false, changing nothing — off a manuscript surface, when a
    /// command could not write (a read-only posture), while an input method
    /// composes, inside code, or for a trigger whose range does not hold the
    /// caret. Tasks 3 and 4's menu commands call it too.
    @discardableResult
    func openCompletion(source: any CompletionSource, trigger: CompletionTrigger) -> Bool {
        guard mayOfferCompletion, let textView, !tokensDescribeAnEarlierText else { return false }
        let ns = textView.string as NSString
        guard Self.trigger(trigger, holds: textView.selectedRange(), in: ns.length),
              !isInsideCode(trigger.start) else { return false }
        completion = CompletionState(source: source, trigger: trigger,
                                     items: source.items(for: trigger), selectedIndex: 0)
        armCompletionObservers()
        completionCaretMoved()      // the opening keystroke's own scroll follows
        showCompletionList()
        completionList?.announceOpen()
        return true
    }

    /// Whether `trigger`'s range fits a text of `length` and holds the
    /// collapsed `caret` (at its start, its end, or inside a key it extends past).
    nonisolated static func trigger(_ trigger: CompletionTrigger, holds caret: NSRange,
                                    in length: Int) -> Bool {
        let range = trigger.replaceRange
        return caret.length == 0 && range.location >= 0 && NSMaxRange(range) <= length
            && range.location <= caret.location && caret.location <= NSMaxRange(range)
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

    /// Whether `location` falls inside code: a closed code span, as the
    /// tokens place it, or code still being typed, which no token marks yet
    /// (`isInsideOpenCode`, fix round 1 I1). Asked only once a source has
    /// said yes, never per keystroke.
    func isInsideCode(_ location: Int) -> Bool {
        if lastTokens.contains(where: { token in
            token.kind == .code && location >= token.range.location
                && location < NSMaxRange(token.range)
        }) { return true }
        guard let textView else { return false }
        return Self.isInsideOpenCode(textView.string as NSString, at: location)
    }

    /// Code the tokenizer has not closed: an odd count of unescaped backticks
    /// on `location`'s line before it (`` `[@ `` typed left to right), or an
    /// odd count of fence lines (```` ``` ```` or `~~~`) in the blank-line block
    /// above its line (an opening fence with no close yet). O(line + block).
    nonisolated static func isInsideOpenCode(_ text: NSString, at location: Int) -> Bool {
        let at = min(max(0, location), text.length)
        let backtick = UInt16(UInt8(ascii: "`")), backslash = UInt16(UInt8(ascii: "\\"))
        let line = text.lineRange(for: NSRange(location: at, length: 0))
        var ticks = 0
        var i = line.location
        while i < at {
            let c = text.character(at: i)
            if c == backslash { i += 2; continue }
            if c == backtick { ticks += 1 }
            i += 1
        }
        if ticks % 2 == 1 { return true }
        var fences = 0
        var start = line.location
        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            let content = text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { break }
            if content.hasPrefix("```") || content.hasPrefix("~~~") { fences += 1 }
            start = previous.location
        }
        return fences % 2 == 1
    }

    // MARK: - The keys (first in doCommandBy)

    /// The completion arm of `textView(_:doCommandBy:)`, asked before every
    /// other. `complete:` (AppKit's own completion window) is swallowed in
    /// prose whether the list is open or not. With the list open: ↑ and ↓
    /// move, Return and Tab accept — inside a table cell too — and Esc
    /// closes; with nothing to accept, ↑, ↓, Return and Tab close it and do
    /// what they always do. With the list closed, or while an input method
    /// composes, every other command falls through untouched.
    func handleCompletionCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        if selector == #selector(NSTextView.complete(_:)) {
            return !(mode is ScreenplayMode)
        }
        guard let state = completion, !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            guard !state.items.isEmpty else {
                closeCompletion()
                return false
            }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): moveCompletionSelection(by: -1)
            case #selector(NSResponder.moveDown(_:)): moveCompletionSelection(by: 1)
            default: acceptCompletion()
            }
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

    /// Accepts row `index` (the selected row when nil): the trigger's
    /// `replaceRange` — through the query, and on through the rest of a key
    /// the caret sat inside — becomes the source's insertion for that row, as
    /// ONE Route A edit (one ⌘Z step, behind the membrane), the caret after
    /// it. The writer's typing before it stays its own steps.
    ///
    /// The row is resolved against the index as it is NOW (whole-branch
    /// review M2): the rows are asked again, and a row the current index no
    /// longer offers (a key renamed over MCP before the editor heard the new
    /// version) is never written — the list shows the current rows instead,
    /// and nothing changes. A pick that would write exactly the text already
    /// there (re-picking the key the caret sits in) writes nothing and leaves
    /// no undo step; the caret goes after it (M4).
    @discardableResult
    func acceptCompletion(at index: Int? = nil) -> Bool {
        guard let state = completion, let textView else { return false }
        let chosen = index ?? state.selectedIndex
        let range = state.trigger.replaceRange
        let ns = textView.string as NSString
        guard state.items.indices.contains(chosen), NSMaxRange(range) <= ns.length else { return false }
        let picked = state.items[chosen].insertion
        guard let item = state.source.items(for: state.trigger).first(where: { $0.insertion == picked })
        else {
            requeryOpenCompletion()
            return false
        }
        let insertion = state.source.insertion(for: item, trigger: state.trigger)
        closeCompletion()
        let caret = NSRange(location: range.location + (insertion as NSString).length, length: 0)
        if ns.substring(with: range) == insertion {
            textView.setSelectedRange(caret)
            return true
        }
        return applyCommandEdit(replacing: range, with: insertion, selecting: caret,
                                actionName: state.source.actionName, landing: .immediate)
    }

    /// Asks the open list's source for its rows again at the same trigger —
    /// the index moved under it (`setReferenceIndexVersion`, an accept of a
    /// row it no longer offers) — keeping the selected row when it is still
    /// offered (whole-branch review M2). A list opened before the first
    /// build, showing the empty message, gets its rows when the build lands.
    func requeryOpenCompletion() {
        guard var state = completion else { return }
        let selected = state.items.indices.contains(state.selectedIndex)
            ? state.items[state.selectedIndex].insertion : nil
        state.items = state.source.items(for: state.trigger)
        state.selectedIndex = selected.flatMap { insertion in
            state.items.firstIndex { $0.insertion == insertion }
        } ?? 0
        completion = state
        showCompletionList()
    }

    // MARK: - The trigger

    /// From `shouldChangeTextIn`, once the membrane has let an edit through:
    /// what the edit is, for `completionTextDidChange`. Only a length-1
    /// typing replacement counts as typed — never inside `applyCommandEdit`,
    /// a paste or a drop (`asNotTyping`), never an undo or a redo, never with
    /// marked text.
    func noteEditForCompletion(in textView: NSTextView, replacing range: NSRange,
                               with replacement: String) {
        guard answersInsertCommands else { return }
        let undo = undoManagerOverrideForTesting ?? textView.undoManager
        if isApplyingCommandEdit || isInsertingNotTyping || textView.hasMarkedText()
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
        // The first source that answers decides (citation before cross-reference),
        // and it may decline to open on a keystroke (a bare `@`).
        for source in completionSources {
            guard let trigger = source.trigger(in: ns, caret: caret.location) else { continue }
            if source.opensWhenTyped(trigger) { openCompletion(source: source, trigger: trigger) }
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

    /// Re-asks the open source at the caret. Same trigger start: the
    /// trigger and rows follow (rows asked again only when the query or the
    /// context changed), true. Otherwise the list closes, false.
    private func refreshOpenCompletion(in textView: NSTextView) -> Bool {
        guard var state = completion else { return false }
        let caret = textView.selectedRange()
        let ns = textView.string as NSString
        guard mayOfferCompletion,
              let trigger = state.source.trigger(in: ns, caret: caret.location),
              trigger.start == state.trigger.start,
              Self.trigger(trigger, holds: caret, in: ns.length) else {
            closeCompletion()
            return false
        }
        let rowsChange = trigger.query != state.trigger.query || trigger.context != state.trigger.context
        state.trigger = trigger
        if rowsChange {
            state.items = state.source.items(for: trigger)
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
        guard let list = completionList, let parent = list.superview, let textView,
              let caretInTextView = completionTriggerRectInTextView() else { return }
        let caret = textView.convert(caretInTextView, to: parent)
        list.frame = CompletionListLayout.frame(size: list.preferredSize, caret: caret,
                                                in: parent.bounds, flipped: parent.isFlipped)
    }

    /// The trigger start's caret rect in the text view (`firstRect`, screen
    /// space, converted back).
    func completionTriggerRectInTextView() -> NSRect? {
        guard let state = completion, let textView, let window = textView.window else { return nil }
        let screen = textView.firstRect(
            forCharacterRange: NSRange(location: state.trigger.start, length: 0), actualRange: nil)
        return textView.convert(window.convertFromScreen(screen), from: nil)
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
    /// that follows the caret in the same turn as a keystroke moves it —
    /// unless the trigger has left the visible text (fix round 1, M5).
    func completionClipViewDidScroll() {
        guard completion != nil else { return }
        guard completionCaretIsMoving, let textView,
              let trigger = completionTriggerRectInTextView(),
              textView.visibleRect.intersects(trigger.insetBy(dx: -1, dy: 0)) else {
            closeCompletion()
            return
        }
        positionCompletionList()
    }

    /// Runs `body` — a paste or a drop handed to AppKit — with its edits read
    /// as not typing, so a pasted or dropped `@` never opens the list
    /// (fix round 1, M4). `MaughamTextView.paste` and `performDragOperation`.
    func asNotTyping<T>(_ body: () -> T) -> T {
        let was = isInsertingNotTyping
        isInsertingNotTyping = true
        defer { isInsertingNotTyping = was }
        return body()
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
