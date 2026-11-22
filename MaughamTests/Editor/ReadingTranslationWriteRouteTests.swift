import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **No route writes a translated surface into the manuscript** (shell p4 Task
/// 8 fix I1): every row of the review's write-route table that was not pinned,
/// each driven directly on the text view or the coordinator — never a press
/// and a wait (tripwire 33). The one fact under them all is
/// `EditorCoordinator.bufferHoldsTranslation`: set before a translated
/// surface goes in, cleared only once the source has landed; while it holds,
/// the view is not editable, the membrane refuses, and the binding is never
/// written.
@MainActor
final class ReadingTranslationWriteRouteTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    private let source = "Source one\n\nSource two"
    private let translated = "Prevod jedan\nSource one\n\nPrevod dva\nSource two"

    /// The entries that join into `translated`, and the source's ranges.
    private let entries = [
        TranslationBadgeLayout.Entry(paragraphId: "a", text: "Prevod jedan", source: "Source one", status: .fresh),
        TranslationBadgeLayout.Entry(paragraphId: "b", text: "Prevod dva", source: "Source two", status: .fresh),
    ]
    private let sourceRanges = ["a": NSRange(location: 0, length: 10), "b": NSRange(location: 12, length: 10)]

    /// A harness whose buffer holds the translated surface, with the control's
    /// model and the source's paragraph providers wired as EditorHost wires them.
    private func reading(_ harness: EditorIntegrationHarness? = nil) -> EditorIntegrationHarness {
        let harness = harness ?? EditorIntegrationHarness(initialText: source)
        let control = EditorControl()
        control.translationBadges = .init(entries: entries)
        harness.coordinator.observeControl(control)
        let ranges = sourceRanges
        harness.coordinator.paragraphRangeProvider = { ranges[$0] }
        harness.coordinator.paragraphLocator = { location in
            ranges.first { location >= $0.value.location && location <= NSMaxRange($0.value) }
                .map { ($0.key, location - $0.value.location) }
        }
        XCTAssertEqual(TranslationBadgeLayout.surface(entries: entries), translated)
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView, coordinator: harness.coordinator,
            translationLanguage: "sr", text: translated, undoCoherentApply: false)
        XCTAssertTrue(harness.coordinator.bufferHoldsTranslation)
        XCTAssertEqual(harness.textView.string, translated)
        return harness
    }

    private func assertUntouched(_ harness: EditorIntegrationHarness, _ route: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(harness.textView.string, translated, "\(route): the surface changed",
                       file: file, line: line)
        XCTAssertEqual(harness.boundValue, source, "\(route): the binding was written",
                       file: file, line: line)
    }

    // MARK: - The exit window (I1)

    /// **The language has cleared but the binding still serves the
    /// translation** — the pass the review's Window 2 lives in. The membrane
    /// holds, the view stays read-only, and a keystroke writes nothing.
    func test_theExitWindowRefusesUntilTheSourceLands() async throws {
        let rd = try await EditorIntegrationHarness.withRealDocument(mode: ProseMode(), initialText: source)
        let harness = rd.harness, doc = rd.document
        let coordinator = harness.coordinator
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: "sr", text: translated,
                                          undoCoherentApply: false)
        let ops = doc.opLogMirrorCount
        // The language clears (the exit observer, ⌃⌘L, Read Source)…
        coordinator.setReadingTranslation(false)
        // …and a pass reconciles with the STALE translated text still served.
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: nil, text: translated,
                                          undoCoherentApply: false, textIsTranslation: true)
        XCTAssertTrue(coordinator.isReadingTranslation, "the buffer still holds the translation")
        XCTAssertFalse(harness.textView.isEditable)
        XCTAssertFalse(coordinator.textView(harness.textView,
                                            shouldChangeTextIn: NSRange(location: 0, length: 0),
                                            replacementString: "X"))
        harness.typeCharacter("X")
        try await doc.flushBurstNow()
        XCTAssertEqual(doc.opLogMirrorCount, ops, "no keystroke in the exit window lands")
        XCTAssertEqual(doc.displayText, source)
        // The source lands: editing resumes.
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: nil, text: doc.displayText,
                                          undoCoherentApply: false, textIsTranslation: false)
        XCTAssertFalse(coordinator.isReadingTranslation)
        XCTAssertTrue(harness.textView.isEditable)
        await doc.close()
    }

    /// Disable experiment's target: whatever reached `textDidChange` while the
    /// buffer holds a translation, the binding is not written.
    func test_aChangeReachingTheDelegateOverATranslationIsNeverWritten() {
        let harness = reading()
        // Change the storage behind every gate, as a stray route would.
        harness.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Z")
        harness.coordinator.textDidChange(Notification(name: NSText.didChangeNotification,
                                                       object: harness.textView))
        XCTAssertEqual(harness.boundValue, source, "the translated surface never reaches the binding")
    }

    // MARK: - AppKit's routes, closed by the view not being editable

    func test_typingAndTextReplacementAreRefused() {
        let harness = reading()
        harness.textView.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        harness.typeCharacter("y")
        XCTAssertFalse(harness.textView.shouldChangeText(in: NSRange(location: 0, length: 4),
                                                         replacementString: "Text replacement"))
        assertUntouched(harness, "typing / autocorrect / text replacement")
    }

    func test_spellingCorrectionIsRefused() {
        let harness = reading()
        // A correction is a replace the view asks itself about first.
        XCTAssertFalse(harness.textView.shouldChangeText(inRanges: [NSValue(range: NSRange(location: 0, length: 6))],
                                                         replacementStrings: ["Prevood"]))
        assertUntouched(harness, "spelling")
    }

    func test_anInputMethodsCompositionIsRefused() {
        let harness = reading()
        harness.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                       replacementRange: NSRange(location: 2, length: 0))
        harness.textView.insertText("可", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertFalse(harness.textView.hasMarkedText())
        assertUntouched(harness, "IME")
    }

    /// A drop, a drag-move and a Service's returned text all insert through
    /// the pasteboard reader.
    func test_aDropADragMoveAndAServiceAreRefused() {
        let harness = reading()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("reading-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("DROPPED", forType: .string)
        harness.textView.setSelectedRange(NSRange(location: 2, length: 3))
        XCTAssertFalse(harness.textView.readSelection(from: pasteboard, type: .string))
        XCTAssertNil(harness.textView.validRequestor(forSendType: .string, returnType: .string),
                     "no Service may return text into the surface")
        assertUntouched(harness, "drop / drag-move / Services")
    }

    /// Writing Tools and find-bar Replace / Replace All ask the view, as a
    /// text-finder client and a text input client, whether it is editable.
    func test_writingToolsAndFindBarReplaceAreRefused() {
        let harness = reading()
        XCTAssertFalse(harness.textView.isEditable,
                       "a non-editable view offers no Replace and no Writing Tools rewrite")
        XCTAssertFalse(harness.textView.shouldChangeText(
            inRanges: [NSValue(range: NSRange(location: 0, length: 6)),
                       NSValue(range: NSRange(location: 22, length: 3))],
            replacementStrings: ["A", "B"]), "Replace All")
        harness.textView.insertText("Rewritten", replacementRange: NSRange(location: 0, length: 12))
        assertUntouched(harness, "Writing Tools / Replace")
    }

    func test_pasteIsRefused() {
        let harness = reading()
        harness.paste("PASTED")
        assertUntouched(harness, "paste")
    }

    // MARK: - The document moving under a reading window

    /// **A sync merge while reading**: the source changes, the binding still
    /// serves the (re-derived) translation, and nothing is written back.
    func test_aMergeWhileReadingWritesNothingBack() {
        let harness = reading()
        let refreshed = translated + "\n\nPrevod tri\nSource three"
        let calls = harness.coordinator.applyExternalTextCallCount
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: harness.coordinator,
                                          translationLanguage: "sr", text: refreshed,
                                          undoCoherentApply: false, textIsTranslation: true)
        XCTAssertEqual(harness.coordinator.applyExternalTextCallCount, calls + 1)
        XCTAssertEqual(harness.boundValue, source, "the merge's surface is not the manuscript")
        XCTAssertTrue(harness.coordinator.bufferHoldsTranslation)
        // An unchanged surface swaps nothing.
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: harness.coordinator,
                                          translationLanguage: "sr", text: refreshed,
                                          undoCoherentApply: false, textIsTranslation: true)
        XCTAssertEqual(harness.coordinator.applyExternalTextCallCount, calls + 1)
    }

    /// **A chapter mounted already read in a language** (the carried
    /// language): its first text is the translation, and the refusal holds
    /// from the mount — `makeNSView` sets the fact right after `attach`.
    func test_aMountAlreadyReadingRefusesFromTheFirstFrame() throws {
        let harness = EditorIntegrationHarness(initialText: translated)
        harness.coordinator.setBufferHoldsTranslation(true)
        XCTAssertFalse(harness.textView.isEditable)
        harness.typeCharacter("x")
        XCTAssertEqual(harness.textView.string, translated)
        let lines = SourceScan.codeLines(of: try SourceTree.read("Maugham/Editor/EditorSurface.swift"))
        XCTAssertTrue(lines.contains { $0.contains("Self.mount(context.coordinator, on: textView,") },
                      "makeNSView mounts through the one ordered function")
        XCTAssertFalse(lines.contains { $0.contains("context.coordinator.attach(to: textView)") },
                       "no attach of its own, out of that order")
    }

    /// The binding's own guard stays, and the host tells the surface what it serves.
    func test_theHostsBindingRefusesATranslationAndSaysWhatItServes() throws {
        let host = try SourceTree.read("Maugham/Views/EditorHost.swift")
        XCTAssertTrue(host.contains("guard translatedSurfaceText == nil else { return }"))
        XCTAssertTrue(host.contains("servesTranslatedSurface: translatedSurfaceText != nil,"))
    }

    // MARK: - Coordinates (fix I2, I3)

    /// **Over a translation the toolbar offers only the Translator's note**,
    /// and no review mark is painted: every anchor is a source position.
    func test_overATranslationTheToolbarOffersTheNoteAndNoMarkIsPainted() {
        XCTAssertEqual(SelectionToolbarView.kinds(isReadingTranslation: true), [.translatorsNote])
        XCTAssertEqual(SelectionToolbarView.kinds(isReadingTranslation: false),
                       SelectionToolbarView.Kind.allCases)
        let toolbar = SelectionToolbarView(frame: .zero)
        let full = toolbar.frame.width
        toolbar.show([.translatorsNote])
        XCTAssertEqual(toolbar.shownKinds, [.translatorsNote])
        XCTAssertLessThan(toolbar.frame.width, full, "resized to what it shows")
        toolbar.show(SelectionToolbarView.Kind.allCases)
        XCTAssertEqual(toolbar.shownKinds, SelectionToolbarView.Kind.allCases)

        let harness = EditorIntegrationHarness(initialText: source)
        let coordinator = harness.coordinator
        let ann = Annotation(
            id: "op1", kind: .comment, paragraphId: "ab12",
            body: "needs work", suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false)
        coordinator.reviewAnnotationsProvider = { [ann] }
        coordinator.reviewParagraphRangeProvider = { $0 == "ab12" ? NSRange(location: 0, length: 5) : nil }
        coordinator.setReviewMode(true)
        XCTAssertEqual(coordinator.resolvedReviewMarks.count, 1, "control: marked over the source")
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: "sr", text: translated,
                                          undoCoherentApply: false)
        XCTAssertTrue(coordinator.resolvedReviewMarks.isEmpty, "none at source offsets over a translation")
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: nil, text: source,
                                          undoCoherentApply: false)
        XCTAssertEqual(coordinator.resolvedReviewMarks.count, 1, "and back with the source")
    }

    /// **A source location lands where the surface shows its paragraph**: a
    /// Scenes row, a `.line` place — and the caret the host is told is the
    /// source's again, read against the ranges of the text the view HOLDS
    /// (fix 2, N6), not the control's model of a surface still to come.
    func test_aSourceLineLandsInItsParagraphOfTheSurface() {
        let harness = reading()
        let coordinator = harness.coordinator
        // b's translation starts at 25 ("Prevod jedan\nSource one\n\n").
        XCTAssertEqual(coordinator.surfaceLocation(forSource: 14), 27, "two into b's source → two into Dva")
        let landed = coordinator.navigateToLine(at: 14, in: harness.textView)
        XCTAssertEqual(landed.location, 27)
        XCTAssertEqual(coordinator.sourceLocation(forSurface: 27), 14, "and told back exactly")
        XCTAssertEqual(coordinator.surfaceLocation(forSource: 99), 0, "a paragraph the surface lacks: the start")
        // The control moves on to a model whose surface has not landed: the
        // mapping still reads the text held.
        let observed = EditorControl()
        observed.translationBadges = .init(entries: [entries[1]])
        coordinator.setTranslationBadges(observed.translationBadges)
        XCTAssertEqual(coordinator.surfaceLocation(forSource: 14), 27)
        XCTAssertEqual(coordinator.sourceLocation(forSurface: 27), 14)
    }

    /// **Every place that sets a selection or scrolls, and the rule it takes**
    /// over a translation (fix I2). A new caller fails here until it is
    /// classified:
    /// - SURFACE: it works in the coordinates of the text the view holds
    ///   (typing and command paths, which the membrane refuses while reading;
    ///   restores of the view's own selection);
    /// - MAPPED: a source location, through `surfaceLocation` /
    ///   `paragraphRangeProvider` (translated ranges while reading);
    /// - SOURCE FIRST: a find match, which waits for the source
    ///   (`ReadingLanguageModifier` reads Source first);
    /// - NO MARKS: review marks, none while reading (fix I3).
    func test_everySelectionAndScrollSetterIsClassified() throws {
        let classified: [String: Int] = [
            // Completion accept — typing (SURFACE).
            "Maugham/Editor/EditorCoordinator+Completion.swift": 1,
            // Grid fold caret — the grid never expands while reading (SURFACE).
            "Maugham/Editor/EditorCoordinator+FigureGrid.swift": 1,
            // Insert landings — commands refused while reading (SURFACE).
            "Maugham/Editor/EditorCoordinator+Insert.swift": 3,
            // Scene nav (MAPPED via navigateToLine), find match (SOURCE FIRST),
            // attach's restored caret (MAPPED by the host's surfaceCaret), the
            // external-text clamp (SURFACE, then the reader's place restored),
            // typewriter and review-mode scrolls (SURFACE), figure separation and
            // the typing restore (typing, SURFACE).
            "Maugham/Editor/EditorCoordinator.swift": 12,
            // Annotation jump (NO MARKS → its fallback is MAPPED), find match
            // (SOURCE FIRST), navigateToLine (MAPPED), landOnParagraph (MAPPED),
            // the pending place (MAPPED, then its scroll).
            "Maugham/Editor/EditorCoordinator+FindNavigation.swift": 14,
            // The reader's place (SURFACE, from paragraph ranges of the text held).
            "Maugham/Editor/EditorCoordinator+TranslationBadges.swift": 1,
            // Tab-cycle — writes, refused while reading (SURFACE).
            "Maugham/Editor/EditorCoordinator+TabCycle.swift": 4,
            // Table cell selection — over the text held (SURFACE).
            "Maugham/Editor/EditorCoordinator+Tables.swift": 2,
            // The toolbar's collapse after a note (SURFACE).
            "Maugham/Editor/EditorCoordinator+ReviewRender.swift": 1,
            // The restyle's selection restore (SURFACE).
            "Maugham/Editor/EditorCoordinator+Typography.swift": 2,
        ]
        var found: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham/Editor") {
            let n = SourceScan.codeLines(of: try SourceTree.read(file)).filter {
                $0.contains("setSelectedRange(") || $0.contains("scrollRangeToVisible(")
                    || $0.contains("navigateToLine(") || $0.contains("selectFindMatch(")
            }.count
            if n > 0 { found[file] = n }
        }
        XCTAssertEqual(found, classified)
    }

    // MARK: - A screenplay mounted already reading (fix 2, N2)

    /// **The first parse of a chapter that opens in a language knows it**: no
    /// translated script reaches the Scenes navigator (each scene twice, at
    /// surface offsets), the counts are the translation's, and leaving posts
    /// the source's script and counts.
    func test_aScreenplayMountedReadingPostsNoTranslatedScriptAndExitPostsTheSource() {
        let sourceText = "INT. HOUSE - DAY\n\nJOHN\nHello there."
        let mounted = [
            TranslationBadgeLayout.Entry(paragraphId: "s1", text: ".INT. KUĆA - DAN", source: "INT. HOUSE - DAY",
                                         status: .fresh,
                                         sourceSeparator: TranslationBadgeLayout.screenplaySourceSeparator),
            TranslationBadgeLayout.Entry(paragraphId: "s2", text: "JOHN\nZdravo.", source: "JOHN\nHello there.",
                                         status: .fresh,
                                         sourceSeparator: TranslationBadgeLayout.screenplaySourceSeparator),
        ]
        let surface = TranslationBadgeLayout.surface(entries: mounted)
        final class Box { var value: String; init(_ v: String) { value = v } }
        let box = Box(sourceText)
        let coordinator = EditorCoordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }), mode: ScreenplayMode(),
            theme: .light, typography: .screenplayDefaults,
            typewriterScroll: false, sentenceFocus: false, paragraphFocus: false)
        coordinator.scriptOriginProjectId = "proj-mount"
        var words: [Int] = []
        coordinator.onMetricsChanged = { words.append($0.wordCount) }
        var scripts: [FountainScript] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer counting the scoped script posts
            forName: .maughamScriptDidUpdate, object: nil, queue: nil) { note in
            if let script = note.object as? FountainScript { scripts.append(script) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        tv.string = surface
        tv.delegate = coordinator
        let control = EditorControl()
        control.translationLanguage = "sr"
        control.translationBadges = .init(entries: mounted)
        EditorSurface.mount(coordinator, on: tv, servesTranslation: true, control: control)
        XCTAssertTrue(scripts.isEmpty, "no translated script reaches the navigator")
        XCTAssertEqual(words.last, 6, "the translation's words — .INT. KUĆA - DAN · JOHN Zdravo. — never its source lines")
        XCTAssertFalse(tv.isEditable)
        // Leaving: the source lands, and its script and counts are posted.
        EditorSurface.reconcileTextBuffer(textView: tv, coordinator: coordinator, translationLanguage: nil,
                                          text: sourceText, undoCoherentApply: false, textIsTranslation: false)
        XCTAssertEqual(scripts.count, 1, "the source's script, once it has landed")
        XCTAssertEqual(scripts.last?.sceneSummaries().count, 1)
        XCTAssertEqual(words.last, 7, "and its counts")
    }

    // MARK: - Pasteboard (fix 2, N7)

    /// Every pasteboard writer takes the translation alone over a translation;
    /// over the source ⌘C is untouched.
    func test_everyPasteboardWriterTakesTheTranslationAndTheSourceCopiesAsEver() {
        let harness = EditorIntegrationHarness(initialText: source)
        let view = MaughamTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        view.string = source
        view.coordinator = harness.coordinator
        view.setSelectedRange(NSRange(location: 0, length: 10))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("copy-\(UUID().uuidString)"))
        // ⌘C's own call: `copy:` writes the view's writable types.
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "Source one", "⌘C in Source is AppKit's own")
        _ = reading(harness)
        view.string = translated
        view.setSelectedRange(NSRange(location: 0, length: (translated as NSString).length))
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), "Prevod jedan\n\nPrevod dva",
                       "the singular writer drops the grey lines")
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "Prevod jedan\n\nPrevod dva",
                       "and the plural (copy, drag-out, Services)")
    }
}
