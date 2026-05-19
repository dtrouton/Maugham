// MaughamTests/Editor/EditorIntegrationHarness.swift
import XCTest
import AppKit
import SwiftUI
@testable import Maugham

/// Drives a real NSTextView wired to a real EditorCoordinator, hosted in
/// an offscreen NSWindow, with a Binding<String> that mirrors what
/// EditorHost passes to EditorSurface. Provides helpers to simulate
/// typing, paste, cursor moves, and external-edit dispatch.
///
/// The harness is the conformance contract for the Document-first-class
/// refactor: tests pass against both the current API and the refactored
/// API. Test 8 (assertNoApplyExternalText during typing) fails today
/// and passes after Stage 2.
@MainActor
final class EditorIntegrationHarness {

    let window: NSWindow
    let scrollView: NSScrollView
    let textView: NSTextView
    let coordinator: EditorCoordinator
    let projectURL: URL
    let docPath: String

    /// Binding's @State backing — the test's view of "documentText".
    private var boundText: String

    init(
        mode: any WritingMode = ProseMode(),
        initialText: String = "",
        cursorLocation: Int? = nil
    ) {
        // Offscreen project directory.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EIH-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let mdURL = tmp.appendingPathComponent("manuscript/test.md")
        try! initialText.data(using: .utf8)?.write(to: mdURL, options: .atomic)

        self.projectURL = tmp
        self.docPath = "manuscript/test.md"
        self.boundText = initialText

        // Offscreen window + text view + scroll view.
        let storage = NSTextStorage(string: initialText)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        let tv = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 600),
            textContainer: container)
        tv.isEditable = true
        tv.isRichText = false
        tv.allowsUndo = true

        let sv = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        sv.documentView = tv
        self.scrollView = sv
        self.textView = tv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = sv
        self.window = win

        // Binding whose setter mirrors what EditorHost does today: store
        // the new value. The Document refactor will change this body but
        // the contract (boundText reflects user input) stays.
        // Use a heap-allocated box so the Binding closures don't need to
        // capture `self` before all stored properties are initialized.
        final class TextBox { var value: String; init(_ v: String) { value = v } }
        let textBox = TextBox(initialText)

        let coord = EditorCoordinator(
            text: Binding(
                get: { textBox.value },
                set: { textBox.value = $0 }),
            mode: mode,
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        tv.delegate = coord
        coord.attach(to: tv)
        self.coordinator = coord

        if let cursor = cursorLocation {
            tv.setSelectedRange(NSRange(location: cursor, length: 0))
        } else {
            tv.setSelectedRange(NSRange(
                location: (initialText as NSString).length, length: 0))
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Input simulation

    /// Insert a single character at the current selection, mirroring what
    /// AppKit does when the user presses a key. Goes through the full
    /// shouldChangeText → storage.replaceCharacters → didChangeText path
    /// so EditorCoordinator's delegate methods fire normally.
    func typeCharacter(_ c: Character) {
        let s = String(c)
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: s) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: s)
        textView.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
        textView.didChangeText()
    }

    /// Type each character of the string sequentially. `intervalMs == 0`
    /// fires them back-to-back on the same runloop tick — the rapid-
    /// typing case that exposes binding races.
    func typeString(_ s: String, intervalMs: Int = 0) async {
        for c in s {
            typeCharacter(c)
            if intervalMs > 0 {
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    func setCursor(to location: Int) {
        let clamped = max(0, min(location, (textView.string as NSString).length))
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }

    func paste(_ s: String) {
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: s) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: s)
        textView.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
        textView.didChangeText()
    }

    // MARK: - State inspection

    var currentText: String { textView.string }
    var cursorLocation: Int { textView.selectedRange().location }

    /// Invariant assertion for Test 8 and similar. Captures the
    /// applyExternalText call counter before `body`, runs body, asserts
    /// counter didn't move. Available via @testable EditorCoordinator.
    func assertNoApplyExternalText(
        file: StaticString = #file, line: UInt = #line,
        during body: () -> Void
    ) {
        let before = coordinator.applyExternalTextCallCount
        body()
        let after = coordinator.applyExternalTextCallCount
        XCTAssertEqual(after, before,
            "applyExternalText fired during user typing (\(after - before) times) — race condition",
            file: file, line: line)
    }
}
