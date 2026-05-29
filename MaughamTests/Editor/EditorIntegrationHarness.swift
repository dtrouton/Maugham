// MaughamTests/Editor/EditorIntegrationHarness.swift
import XCTest
import MaughamCore
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

    /// Secondary initializer for the real-Document harness variant. Accepts a
    /// pre-built `Binding<String>` so the caller can wire the production-
    /// equivalent setter (including `recordEditorTextWrite` side-effects) before
    /// constructing the harness. `projectURL` and `docPath` are already on-disk;
    /// `initialText` seeds the NSTextStorage only.
    ///
    /// Only `EditorIntegrationHarness.withRealDocument` should call this — use
    /// the plain `init(mode:initialText:cursorLocation:)` for synthetic harnesses.
    init(
        mode: any WritingMode,
        initialText: String,
        projectURL: URL,
        docPath: String,
        boundText: Binding<String>
    ) {
        self.projectURL = projectURL
        self.docPath = docPath
        self.boundText = initialText  // local mirror; not used when external binding is live

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

        let coord = EditorCoordinator(
            text: boundText,
            mode: mode,
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        tv.delegate = coord
        coord.attach(to: tv)
        self.coordinator = coord

        tv.setSelectedRange(NSRange(
            location: (initialText as NSString).length, length: 0))
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

    // MARK: - External-edit helpers

    /// Simulate an external tool writing new bytes to the manuscript file
    /// on disk. The harness needs a DocumentStore to drive presenter
    /// callbacks for these tests. Current implementation: load a real
    /// DocumentStore so the presenter fires.
    func attachDocumentStore() async throws -> DocumentStore {
        // Manifest must exist for DocumentStore.open to work.
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(
                    id: "doc-test", title: "Test", type: .document,
                    path: docPath)
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectURL.appendingPathComponent("project.maugham.json"))
        return try await DocumentStore.open(url: projectURL)
    }

    func writeExternalMdContent(_ content: String) async throws {
        let mdURL = projectURL.appendingPathComponent(docPath)
        try content.data(using: .utf8)!.write(to: mdURL, options: .atomic)
        // Give the presenter callback a tick to fire.
        try await Task.sleep(for: .milliseconds(100))
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

// MARK: - Real-Document harness variant

/// Wraps an `EditorIntegrationHarness` that is wired to a real `Document`
/// and the production-equivalent binding setter (including the
/// `recordEditorTextWrite` side-effects). Tests interact via `harness` and
/// assert against `projectStore` / `documentStore`.
///
/// Only constructed via `EditorIntegrationHarness.withRealDocument(...)`.
@MainActor
final class RealDocumentHarness {
    let harness: EditorIntegrationHarness
    let projectStore: ProjectStore
    let documentStore: DocumentStore
    let document: Document
    let docId: String
    let projectURL: URL

    fileprivate init(
        harness: EditorIntegrationHarness,
        projectStore: ProjectStore,
        documentStore: DocumentStore,
        document: Document,
        docId: String,
        projectURL: URL
    ) {
        self.harness = harness
        self.projectStore = projectStore
        self.documentStore = documentStore
        self.document = document
        self.docId = docId
        self.projectURL = projectURL
    }
}

extension EditorIntegrationHarness {

    /// Builds a harness wired to a real `Document` and the production-equivalent
    /// binding setter — the same closure `EditorHost` installs — so tests can
    /// assert end-to-end that typing produces the `recordEditorTextWrite`
    /// side-effects (project word count refresh, session start,
    /// `liveSessionWordsNet` accumulation).
    ///
    /// Tests interact via `RealDocumentHarness.harness.typeString(...)` and
    /// assert against the public properties on `projectStore` / `documentStore`.
    @MainActor
    static func withRealDocument(
        mode: any WritingMode = ProseMode(),
        initialText: String = ""
    ) async throws -> RealDocumentHarness {
        // Build a real project on disk via ProjectFactory.
        let tempDir = TempDirectory()
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "EIH-RD-\(UUID().uuidString.prefix(8))",
            in: tempDir.url)

        let projectStore = try await ProjectStore.load(from: projectURL)
        let documentStore = try await DocumentStore.open(url: projectURL)

        // Locate the single document item in the manifest.
        guard let item = projectStore.manifest.structure
            .first(where: { $0.type == .document }),
              let docPath = item.path else {
            throw NSError(domain: "EditorIntegrationHarness",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "ProjectFactory novel has no document item in manifest"])
        }

        let docId = item.id
        let docURL = projectURL.appendingPathComponent(docPath)

        // If initialText is non-empty, write it to disk before loading the
        // Document so Bootstrap sees it and mints ¶id anchors for it.
        if !initialText.isEmpty {
            try initialText.data(using: .utf8)!.write(to: docURL, options: .atomic)
        }

        let document = try await Document.load(
            url: docURL,
            device: "test-device",
            session: "test-session",
            presenter: documentStore.presenter)
        documentStore.register(document: document, for: docPath)

        // Build the production-equivalent binding setter. This mirrors the
        // closure EditorHost installs at EditorHost.swift line 66–75 exactly.
        // Capturing `document`, `documentStore`, `projectStore`, and `docPath`
        // by value is safe — they're reference types / value types that outlive
        // the harness.
        let binding = Binding<String>(
            get: { document.displayText },
            set: { newText in
                document.setFullText(newText)
                documentStore.recordEditorTextWrite(
                    documentId: document.docId,
                    newText: newText,
                    mode: WritingModeFactory.mode(for: docPath),
                    store: projectStore)
            })

        let harness = EditorIntegrationHarness(
            mode: mode,
            initialText: document.displayText,
            projectURL: projectURL,
            docPath: docPath,
            boundText: binding)

        return RealDocumentHarness(
            harness: harness,
            projectStore: projectStore,
            documentStore: documentStore,
            document: document,
            docId: docId,
            projectURL: projectURL)
    }
}
