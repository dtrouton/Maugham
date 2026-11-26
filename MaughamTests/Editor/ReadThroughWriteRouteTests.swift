import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **In read-through typing is off, on every route** (shell read-through
/// Task 2). Each row of the plan's write-route table, driven on a real
/// `EditorSurface` mounted through `makeNSView` (so the mount's order is the
/// production one) or on the coordinator — never a press and a wait
/// (tripwire 33). The one fact under them all is
/// `EditorCoordinator.isInReadThrough`, asked of the coordinator's own
/// `documentId`: while it holds the view is not editable, so AppKit refuses
/// every typing route, and the membrane refuses again behind it.
@MainActor
final class ReadThroughWriteRouteTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    static let pieceA = "piece-a"
    static let pieceB = "piece-b"

    final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    @MainActor
    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: MaughamTextView
        let coordinator: EditorCoordinator
        let control: EditorControl
        var string: String { textView.string }
    }

    /// A manuscript editor on `docId`, mounted through `makeNSView` with
    /// `control`; `refused` is the host's typing-refused answer.
    private func mount(_ text: String, docId: String = pieceA, control: EditorControl,
                       refused: (() -> Void)? = nil) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: control)
        configuration.paragraphProviders.documentId = docId
        configuration.callbacks.onTypingRefused = refused
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500),
                                      as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        window.makeFirstResponder(textView)
        if let layout = textView.layoutManager {
            EditorIntegrationHarness.quietAsynchronousAppKitWork(textView, layout)
        }
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator,
                       control: control)
    }

    private func control(readThrough: Set<String>) -> EditorControl {
        let control = EditorControl()
        control.readThroughDocIds = readThrough
        return control
    }

    private static func textView(in view: NSView?) -> MaughamTextView? {
        guard let view else { return nil }
        if let tv = view as? MaughamTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    private func assertUntouched(_ m: Mounted, _ text: String, _ route: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(m.string, text, "\(route): the text changed", file: file, line: line)
        XCTAssertEqual(m.box.text, text, "\(route): the binding was written", file: file, line: line)
    }

    private func key(_ m: Mounted, _ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: m.window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("read-through-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    // MARK: - Keys

    /// A keystroke, Return, Backspace, Delete and a Cut's delete write
    /// nothing; a typed character is answered by the host (the line's pulse),
    /// a navigation key is not.
    func test_typingIsRefusedAndAnswered() throws {
        var answered = 0
        let text = "One two three."
        let m = try mount(text, control: control(readThrough: [Self.pieceA]), refused: { answered += 1 })
        XCTAssertTrue(m.coordinator.isInReadThrough)
        XCTAssertFalse(m.textView.isEditable)
        m.textView.setSelectedRange(NSRange(location: 3, length: 0))
        m.textView.keyDown(with: key(m, "x", code: 7))
        XCTAssertEqual(answered, 1, "a typed character is answered")
        m.textView.keyDown(with: key(m, "\r", code: 36))
        m.textView.keyDown(with: key(m, "\u{7F}", code: 51))
        m.textView.keyDown(with: key(m, "\u{F701}", code: 125))
        XCTAssertEqual(answered, 1, "Return, Backspace and an arrow are not typing")
        m.textView.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        m.textView.deleteBackward(nil)
        m.textView.deleteForward(nil)
        XCTAssertFalse(m.textView.shouldChangeText(in: NSRange(location: 0, length: 3),
                                                   replacementString: ""), "Cut's delete")
        XCTAssertFalse(m.coordinator.textView(m.textView, shouldChangeTextIn: NSRange(location: 0, length: 0),
                                              replacementString: "x"), "the membrane, behind the view")
        assertUntouched(m, text, "keys")
        // Who answers, by the pure rule the host asks.
        XCTAssertEqual(EditorHost.typingRefusal(isRecovery: false, isInReadThrough: true,
                                                isReadingTranslation: false), .readThrough)
        XCTAssertEqual(EditorHost.typingRefusal(isRecovery: false, isInReadThrough: false,
                                                isReadingTranslation: true), .readThrough,
                       "over a translation the line pulses instead of the beep")
        XCTAssertEqual(EditorHost.typingRefusal(isRecovery: true, isInReadThrough: true,
                                                isReadingTranslation: false), .recovery)
        XCTAssertEqual(EditorHost.typingRefusal(isRecovery: false, isInReadThrough: false,
                                                isReadingTranslation: false), .none)
        // The host answers every manuscript, and the line pulses on the post.
        let host = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/EditorHost.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(host.contains("case .readThrough: MaughamEvent.post(.maughamTypingRefused, to: .keyWindow)"))
        XCTAssertFalse(host.contains("onTypingRefused: doc.isReadOnlyRecovery"),
                       "no manuscript is left to AppKit's beep")
        let line = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/LanguageSwitch.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(line.contains(".modifier(TypingRefusedPulse(window: window))"))
        XCTAssertTrue(line.contains(".onKeyWindowCommand(.maughamTypingRefused, window: window)"))
    }

    /// **Bug B's shape**: the key's post flips this editor's view at once,
    /// before the control's mirror lands, so a Return pressed right after it
    /// meets a refusing view. Another piece's post changes nothing here.
    func test_theKeyFlipsTheViewBeforeTheMirrorLands() throws {
        let text = "One two."
        let m = try mount(text, control: control(readThrough: []))
        XCTAssertTrue(m.textView.isEditable, "premise: writing")
        ReadThrough.post(.init(docId: Self.pieceB, on: true))
        XCTAssertTrue(m.textView.isEditable, "another piece's read-through is not this one's")
        ReadThrough.post(.init(docId: Self.pieceA, on: true))
        XCTAssertTrue(m.control.readThroughDocIds.isEmpty, "premise: the mirror has not landed")
        XCTAssertTrue(m.coordinator.isInReadThrough)
        XCTAssertFalse(m.textView.isEditable)
        m.textView.setSelectedRange(NSRange(location: 3, length: 0))
        m.textView.keyDown(with: key(m, "\r", code: 36))
        m.textView.insertText("\n", replacementRange: NSRange(location: 3, length: 0))
        assertUntouched(m, text, "the entry turn")
        // The mirror lands and agrees; Resume's post gives the typing back.
        m.control.readThroughDocIds = [Self.pieceA]
        m.coordinator.applyControl(m.control)
        XCTAssertTrue(m.coordinator.isInReadThrough)
        ReadThrough.post(.init(docId: Self.pieceA, on: false))
        XCTAssertTrue(m.textView.isEditable)
        m.textView.insertText("!", replacementRange: NSRange(location: 7, length: 0))
        XCTAssertEqual(m.box.text, "One two!.", "typing lands again")
    }

    /// **An apply for another property never undoes the key's flip** (review
    /// M1): read-through is reconciled from the mirror only when the mirrored
    /// set moved, so a settle edge landing before the mirror cannot let a
    /// keystroke through, nor turn Resume back on.
    func test_anApplyForAnotherPropertyNeverUndoesTheKeysFlip() throws {
        let text = "One two."
        let m = try mount(text, control: control(readThrough: []))
        ReadThrough.post(.init(docId: Self.pieceA, on: true))
        m.control.referenceIndexVersion += 1          // the metrics settle, before the mirror
        m.coordinator.applyControl(m.control)
        XCTAssertTrue(m.coordinator.isInReadThrough, "the stale set does not switch it off")
        XCTAssertFalse(m.textView.isEditable)
        XCTAssertTrue(m.coordinator.isReviewMode, "nor the review render")
        m.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        assertUntouched(m, text, "a keystroke before the mirror")
        m.control.readThroughDocIds = [Self.pieceA]   // the mirror lands
        m.coordinator.applyControl(m.control)
        XCTAssertTrue(m.coordinator.isInReadThrough)
        ReadThrough.post(.init(docId: Self.pieceA, on: false))
        m.control.referenceIndexVersion += 1
        m.coordinator.applyControl(m.control)
        XCTAssertFalse(m.coordinator.isInReadThrough, "Resume holds until the mirror agrees")
        XCTAssertTrue(m.textView.isEditable)
        m.control.readThroughDocIds = []
        m.coordinator.applyControl(m.control)
        XCTAssertFalse(m.coordinator.isInReadThrough)
    }

    /// **A project reopened with a piece in read-through refuses the first
    /// keystroke** (review, unpinned point c): the store reads its file at
    /// once, the window seeds the control from the session before it
    /// publishes the stores (so before any editor can mount), and the mount
    /// asks the control.
    func test_aReopenedPieceInReadThroughRefusesTheFirstKeystroke() throws {
        let root = TestTemp.root.appendingPathComponent("reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let mac = DeviceSlug.make(from: "reopen-mac")
        ReadThroughStore(projectRoot: root, device: mac).begin(Self.pieceA, at: Date())
        let reopened = ReadThroughStore(projectRoot: root, device: mac)   // ⌘Q, relaunch
        XCTAssertEqual(reopened.pieceIds, [Self.pieceA], "remembered on this Mac")
        var answered = 0
        let text = "Words."
        let m = try mount(text, control: control(readThrough: reopened.pieceIds), refused: { answered += 1 })
        m.textView.keyDown(with: key(m, "x", code: 7))
        XCTAssertEqual(answered, 1)
        assertUntouched(m, text, "the first keystroke after a reopen")
        // The window's seed comes before the stores are published.
        let window = SourceScan.codeLines(of: try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"]))
        let seed = try XCTUnwrap(window.firstIndex {
            $0.contains("self.editorControl.readThroughDocIds = session.readThrough.pieceIds") })
        let publish = try XCTUnwrap(window.firstIndex { $0.contains("self.store = s") })
        XCTAssertLessThan(seed, publish, "seeded before any editor can mount")
    }

    /// A piece already in read-through refuses from its first frame: the
    /// mount sets the fact before `attach`, and the review render is drawn.
    func test_aMountInReadThroughRefusesFromTheFirstFrame() throws {
        let text = "Words."
        let m = try mount(text, control: control(readThrough: [Self.pieceA]))
        XCTAssertTrue(m.coordinator.isInReadThrough)
        XCTAssertFalse(m.textView.isEditable)
        XCTAssertTrue(m.coordinator.isReviewMode, "the review render: marks, rail, selection toolbar")
        XCTAssertTrue(m.coordinator.typingIsOff)
        m.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        assertUntouched(m, text, "the first frame")
        // The mount's order: the facts, then attach.
        let mount = try SourceTree.declaration(named: "static func mount(_ coordinator: EditorCoordinator",
                                               under: "Maugham")
        let set = try XCTUnwrap(mount.range(of: "coordinator.setReadThrough("))
        let attach = try XCTUnwrap(mount.range(of: "coordinator.attach(to: textView)"))
        XCTAssertLessThan(set.lowerBound, attach.lowerBound)
        // No typing caret: a reading position in the quiet ink.
        XCTAssertEqual(MaughamTextView.caretColor(typingIsOff: true, editing: .systemRed), .secondaryLabelColor)
        XCTAssertTrue(MaughamTextView.drawsReadingPosition(typingIsOff: true, isFirstResponder: true,
                                                           selectionIsEmpty: true))
    }

    /// **The guard follows the document the buffer holds**, never the
    /// window's open piece: with piece A in read-through and A's editor
    /// still mounted, the editor mounted on B takes typing.
    func test_theGuardFollowsTheDocumentTheBufferHolds() throws {
        let shared = control(readThrough: [Self.pieceA])
        let a = try mount("Alpha.", docId: Self.pieceA, control: shared)
        XCTAssertFalse(a.textView.isEditable)
        let b = try mount("Beta.", docId: Self.pieceB, control: shared)
        XCTAssertFalse(b.coordinator.isInReadThrough)
        XCTAssertTrue(b.textView.isEditable)
        b.textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(b.box.text, "Beta.!", "B takes the typing")
        a.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(a.box.text, "Alpha.", "and A still refuses it")
    }

    /// Leaving a translation of a piece in read-through lands non-editable:
    /// one rule decides editability (`refreshEditability`), not a restore of
    /// what the view was before the translation came in.
    func test_leavingATranslationLandsInReadThroughNotEditable() throws {
        let text = "Source one."
        let m = try mount(text, control: control(readThrough: [Self.pieceA]))
        EditorSurface.reconcileTextBuffer(textView: m.textView, coordinator: m.coordinator,
                                          translationLanguage: "sr", text: "Prevod jedan.",
                                          undoCoherentApply: false)
        XCTAssertTrue(m.coordinator.bufferHoldsTranslation)
        EditorSurface.reconcileTextBuffer(textView: m.textView, coordinator: m.coordinator,
                                          translationLanguage: nil, text: text,
                                          undoCoherentApply: false)
        XCTAssertFalse(m.coordinator.bufferHoldsTranslation)
        XCTAssertFalse(m.textView.isEditable, "still in read-through")
        XCTAssertNil(ReadingUndoGuard.standing(over: m.window), "and the window's Undo is free again")
        m.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        assertUntouched(m, text, "after the translation")
    }

    // MARK: - The pasteboard, drops and Services

    func test_pasteAndAFigureDropAreRefused() throws {
        let text = "Words here."
        let m = try mount(text, control: control(readThrough: [Self.pieceA]))
        let pasteboard = privatePasteboard()
        pasteboard.setString("PASTED", forType: .string)
        m.textView.setSelectedRange(NSRange(location: 0, length: 5))
        m.textView.paste(from: pasteboard)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let images = privatePasteboard()
        images.writeObjects([image])
        m.textView.paste(from: images)
        assertUntouched(m, text, "paste")
        // A figure's drop or paste asks before anything is copied.
        XCTAssertFalse(m.coordinator.commandMayWrite, "Insert, a table tidy, a figure: refused")
        XCTAssertFalse(m.coordinator.mayWriteFigure)
    }

    /// A drop, a drag-move and a Service's returned text all insert through
    /// the pasteboard reader.
    func test_aDropADragMoveAndAServiceAreRefused() throws {
        let text = "Words here."
        let m = try mount(text, control: control(readThrough: [Self.pieceA]))
        let pasteboard = privatePasteboard()
        pasteboard.setString("DROPPED", forType: .string)
        m.textView.setSelectedRange(NSRange(location: 2, length: 3))
        XCTAssertFalse(m.textView.readSelection(from: pasteboard, type: .string))
        XCTAssertNil(m.textView.validRequestor(forSendType: .string, returnType: .string),
                     "no Service may return text into the piece")
        assertUntouched(m, text, "drop / drag-move / Services")
    }

    func test_spellingCorrectionAndReplacementAreRefused() throws {
        let text = "Teh words."
        let m = try mount(text, control: control(readThrough: [Self.pieceA]))
        XCTAssertFalse(m.textView.shouldChangeText(inRanges: [NSValue(range: NSRange(location: 0, length: 3))],
                                                   replacementStrings: ["The"]), "a spelling correction")
        XCTAssertFalse(m.textView.shouldChangeText(in: NSRange(location: 0, length: 3),
                                                   replacementString: "The"), "autocorrect, text replacement")
        assertUntouched(m, text, "spelling")
    }

    /// An input method's composition open at the entry is committed — the
    /// text it holds stays as typed — and nothing more is taken.
    func test_aCompositionOpenAtEntryIsCommittedThenRefused() throws {
        let m = try mount("ab", control: control(readThrough: []))
        m.textView.setSelectedRange(NSRange(location: 1, length: 0))
        m.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(m.textView.hasMarkedText(), "premise: composing")
        ReadThrough.post(.init(docId: Self.pieceA, on: true))
        XCTAssertFalse(m.textView.hasMarkedText(), "committed at the entry")
        XCTAssertEqual(m.string, "aかb", "as typed")
        m.textView.setMarkedText("き", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: 2, length: 0))
        m.textView.insertText("木", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertFalse(m.textView.hasMarkedText())
        XCTAssertEqual(m.string, "aかb", "a composition after the entry takes nothing")
    }

    /// **What this proves**: the view is not editable (which Writing Tools,
    /// as a text input client, reads — by reading only: the Writing Tools
    /// coordinator itself is not driven here; ADR 0039 §4, hand check owed),
    /// find-bar Replace All's `shouldChangeText(inRanges:)` is refused, and a
    /// replacing `insertText` lands nothing.
    func test_theViewIsNotEditable_replaceAllAndAReplacingInsertAreRefused() throws {
        let text = "One two one."
        let m = try mount(text, control: control(readThrough: [Self.pieceA]))
        XCTAssertFalse(m.textView.isEditable, "a non-editable view offers no Replace and no Writing Tools rewrite")
        XCTAssertFalse(m.textView.shouldChangeText(
            inRanges: [NSValue(range: NSRange(location: 0, length: 3)),
                       NSValue(range: NSRange(location: 8, length: 3))],
            replacementStrings: ["1", "1"]), "Replace All")
        m.textView.insertText("Rewritten", replacementRange: NSRange(location: 0, length: 12))
        assertUntouched(m, text, "Writing Tools / Replace")
    }

    // MARK: - Commands and the table tidy

    /// Moving the caret through an untidy table and out arms no tidy, and a
    /// tidy already pending writes nothing.
    func test_noTableTidyRunsInReadThrough() throws {
        let untidy = "|A|B|\n|-|-|\n|c|d|\n\nAfter."
        let m = try mount(untidy, control: control(readThrough: []))
        m.textView.setSelectedRange(NSRange(location: (untidy as NSString).range(of: "c").location, length: 0))
        m.textView.setSelectedRange(NSRange(location: (untidy as NSString).range(of: "After").location, length: 0))
        XCTAssertTrue(m.coordinator.hasPendingTableTidy, "premise: writing, leaving the table arms its tidy")
        ReadThrough.post(.init(docId: Self.pieceA, on: true))
        XCTAssertFalse(m.coordinator.hasPendingTableTidy, "the entry drops the pending tidy")
        m.textView.setSelectedRange(NSRange(location: (untidy as NSString).range(of: "c").location, length: 0))
        m.textView.setSelectedRange(NSRange(location: (untidy as NSString).range(of: "After").location, length: 0))
        XCTAssertFalse(m.coordinator.hasPendingTableTidy, "reading through a table arms nothing")
        m.coordinator.performPendingTableTidy()
        // Tab in a cell moves, never tidies.
        m.textView.setSelectedRange(NSRange(location: (untidy as NSString).range(of: "c").location, length: 0))
        m.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        assertUntouched(m, untidy, "the tidy")
    }

    // MARK: - Undo

    /// **The entry drops the typing undo, by its target, and keeps the
    /// op-level entries** (owner's decision, 2026-11-22): AppKit would spend
    /// a typing entry silently on a view that is not editable.
    func test_entryDropsTheTypingUndoAndKeepsOpLevelEntries() throws {
        let m = try mount("One two", control: control(readThrough: []))
        let um = try XCTUnwrap(m.textView.undoManager)
        XCTAssertTrue(um === m.window.undoManager, "premise: the window's stack")
        um.groupsByEvent = false
        um.beginUndoGrouping()
        m.textView.insertText(" three", replacementRange: NSRange(location: 7, length: 0))
        um.endUndoGrouping()
        final class Note { var reopened = false }
        let note = Note()
        um.beginUndoGrouping()
        um.registerUndo(withTarget: note) { $0.reopened = true }   // an op-level entry
        um.endUndoGrouping()
        ReadThrough.post(.init(docId: Self.pieceA, on: true))
        XCTAssertTrue(um.canUndo, "the op-level entry is kept")
        um.undo()
        XCTAssertTrue(note.reopened)
        XCTAssertFalse(um.canUndo, "and no typing is left to spend")
        XCTAssertEqual(m.string, "One two three", "the typing before the entry stays")
        XCTAssertTrue(m.textView.undoManager === m.window.undoManager,
                      "no throwaway: a decision's ⌘Z reaches the window's stack")
        XCTAssertNil(ReadingUndoGuard.standing(over: m.window))
        um.groupsByEvent = true
    }

    // MARK: - The document moving under it

    /// **A merge from another device or the phone lands**: it was not typed
    /// here, and it comes through the one `applyExternalText` site.
    func test_aMergeLandsInTheView() throws {
        let m = try mount("Mine.", control: control(readThrough: [Self.pieceA]))
        let calls = m.coordinator.applyExternalTextCallCount
        EditorSurface.reconcileTextBuffer(textView: m.textView, coordinator: m.coordinator,
                                          translationLanguage: nil, text: "Mine. Theirs.",
                                          undoCoherentApply: false)
        XCTAssertEqual(m.coordinator.applyExternalTextCallCount, calls + 1)
        XCTAssertEqual(m.string, "Mine. Theirs.")
        XCTAssertFalse(m.textView.isEditable, "and typing is still off")
    }
}
