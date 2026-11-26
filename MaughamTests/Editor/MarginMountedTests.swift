import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **View ▸ Margin, mounted** (shell p5 Task 2): the marks drawn on a real
/// `MaughamTextView` in a `TestWindow`, read synchronously — where they sit,
/// that they never move the manuscript's layout, that a click moves nothing
/// in the editor — and, over a real `Document`, what the window builds and
/// what the review render draws in read-through.
@MainActor
final class MarginMountedTests: XCTestCase {
    override class func setUp() { super.setUp(); FontWarmup.ensure() }

    // MARK: - The surface

    private static let paragraphs = [
        "The first paragraph runs long enough to wrap across more than one line of the column, so its layout has something to lose.",
        "The second paragraph is where the check flagged a sentence.",
        "The third paragraph is the writer's.",
    ]
    private static let ids = ["aa11", "bb22", "cc33"]
    private static var text: String { paragraphs.joined(separator: "\n\n") }

    private struct Surface {
        let harness: EditorIntegrationHarness
        let textView: MaughamTextView
        let control: EditorControl
        var coordinator: EditorCoordinator { harness.coordinator }
    }

    /// The coordinator on a `MaughamTextView` with a column, as
    /// `EditorSurface.makeNSView` attaches it; the paragraph providers as
    /// `EditorHost` wires them (here over the plain text); the control
    /// applied as `applyControl` applies it.
    private func surface(width: CGFloat = 700, column: CGFloat = 420) -> Surface {
        let harness = EditorIntegrationHarness(mode: ProseMode(), initialText: Self.text, cursorLocation: 0)
        let tv = MaughamTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        _ = tv.layoutManager
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        sv.documentView = tv
        let window = TestWindow.make(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                     contentView: sv, present: .unshown)
        addTeardownBlock { @MainActor in window.close() }
        tv.string = Self.text
        tv.delegate = harness.coordinator
        tv.coordinator = harness.coordinator
        let c = harness.coordinator
        c.documentId = "doc-a"
        c.marginParagraphRangesProvider = {
            Dictionary(uniqueKeysWithValues: Self.ids.compactMap { id in Self.range(of: id).map { (id, $0) } })
        }
        c.reviewParagraphTextProvider = { pid in Self.ids.firstIndex(of: pid).map { Self.paragraphs[$0] } }
        c.attach(to: tv)
        tv.columnWidth = column
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let control = EditorControl()
        return Surface(harness: harness, textView: tv, control: control)
    }

    private static func range(of pid: String) -> NSRange? {
        guard let index = ids.firstIndex(of: pid) else { return nil }
        let location = paragraphs[..<index].reduce(0) { $0 + ($1 as NSString).length + 2 }
        return NSRange(location: location, length: (paragraphs[index] as NSString).length)
    }

    private func apply(_ marks: MarginMarks, to s: Surface) {
        s.control.margin = marks
        s.coordinator.applyControl(s.control)
        s.textView.layoutManager?.ensureLayout(for: s.textView.textContainer!)
    }

    /// The manuscript's layout: the column's width and every line's rect.
    private func layout(_ tv: NSTextView) -> [NSRect] {
        guard let lm = tv.layoutManager, let container = tv.textContainer else { return [] }
        lm.ensureLayout(for: container)
        var rects: [NSRect] = [NSRect(x: 0, y: 0, width: container.size.width, height: tv.textContainerInset.width)]
        var glyph = 0
        while glyph < lm.numberOfGlyphs {
            var range = NSRange()
            rects.append(lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range))
            glyph = NSMaxRange(range)
        }
        return rects
    }

    private func firstLineRect(of pid: String, in tv: NSTextView) throws -> NSRect {
        let lm = try XCTUnwrap(tv.layoutManager)
        let location = try XCTUnwrap(Self.range(of: pid)).location
        var line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: location), effectiveRange: nil)
        line.origin.y += tv.textContainerOrigin.y
        return line
    }

    // MARK: - Where the marks sit, and that they move no text

    /// Everything Flagged with a finding on paragraph 2: one tick, beside
    /// paragraph 2's first line, past the column — and the manuscript's
    /// layout is the same with the margin on, and off again.
    func test_aFindingsTickSitsBesideItsParagraphAndReflowsNothing() throws {
        let s = surface()
        let before = layout(s.textView)
        XCTAssertGreaterThan(before.count, 4, "premise: the first paragraph wraps")
        XCTAssertNil(s.coordinator.marginOverlay, "Off: no overlay at all, today's editor")

        apply(MarginMarks(dots: [], ticks: ["bb22"]), to: s)
        let overlay = try XCTUnwrap(s.coordinator.marginOverlay)
        XCTAssertTrue(overlay.superview === s.textView)
        XCTAssertFalse(overlay.isHidden)
        let marks = overlay.visibleMarks()
        XCTAssertEqual(marks.map(\.isTick), [true], "one tick")
        XCTAssertEqual(marks.first?.paragraphId, "bb22")
        let line = try firstLineRect(of: "bb22", in: s.textView)
        let tick = try XCTUnwrap(marks.first?.rect)
        XCTAssertTrue(tick.minY >= line.minY && tick.maxY <= line.maxY, "on paragraph 2's first line: \(tick) in \(line)")
        let columnEdge = s.textView.textContainerOrigin.x + s.textView.textContainer!.size.width
        XCTAssertGreaterThanOrEqual(tick.minX, columnEdge, "in the trailing margin, never over the text")
        XCTAssertLessThanOrEqual(tick.maxX, s.textView.bounds.width)
        XCTAssertEqual(layout(s.textView), before, "the margin draws in space that exists")

        apply(.none, to: s)
        XCTAssertTrue(overlay.isHidden, "Off again: nothing drawn")
        XCTAssertEqual(overlay.visibleMarks(), [])
        XCTAssertEqual(layout(s.textView), before)
    }

    /// A person's dot sits outside the tick; its tint covers its words.
    func test_aDotSitsBesideItsWordsWithATint() throws {
        let s = surface()
        let before = layout(s.textView)
        // "third" in "The third paragraph…": graphemes 4..<9.
        let pencil = ReviewPalette().color(for: AnnotationAuthor(sourceKind: .human, displayName: "Denver"))
        apply(MarginMarks(dots: [.init(paragraphId: "cc33", span: 4..<9, annotationId: "n1", name: "Denver",
                                       colour: pencil)],
                          ticks: ["cc33"]), to: s)
        let marks = try XCTUnwrap(s.coordinator.marginOverlay).visibleMarks()
        XCTAssertEqual(marks.map(\.places).map { $0.map(\.mark) },
                       [[.tick], [.dot(annotationId: "n1", name: "Denver", colour: pencil)]])
        XCTAssertEqual(marks.last?.colour, pencil, "the dot is drawn in its person's pencil")
        XCTAssertEqual(marks.first?.colour, MarginOverlayView.dotColor, "a tick is no one's")
        let dot = try XCTUnwrap(marks.last)
        XCTAssertEqual(dot.places.first?.tint, NSRange(location: try XCTUnwrap(Self.range(of: "cc33")).location + 4, length: 5))
        XCTAssertFalse(dot.tintRects.isEmpty, "the words are tinted")
        XCTAssertGreaterThan(dot.rect.minX, marks[0].rect.maxX, "the dot clears the tick")
        XCTAssertEqual(layout(s.textView), before)
    }

    /// The window's floor: the narrowest trailing inset is the column's
    /// 16 pt minimum gutter, and both marks fit inside it.
    func test_theMarksFitTheNarrowestMargin() throws {
        let s = surface(width: 360, column: 700)
        XCTAssertEqual(s.textView.textContainerInset.width, 16, accuracy: 0.5, "premise: the floor gutter")
        apply(MarginMarks(dots: [.init(paragraphId: "bb22", span: nil, annotationId: "n1", name: "Ada")],
                          ticks: ["bb22"]), to: s)
        let columnEdge = s.textView.textContainerOrigin.x + s.textView.textContainer!.size.width
        for mark in try XCTUnwrap(s.coordinator.marginOverlay).visibleMarks() {
            XCTAssertGreaterThanOrEqual(mark.rect.minX, columnEdge, "\(mark.id)")
            XCTAssertLessThanOrEqual(mark.rect.maxX, s.textView.bounds.width, "\(mark.id)")
            XCTAssertGreaterThanOrEqual(mark.hitRect.minX, columnEdge, "\(mark.id): the click area too")
        }
    }

    /// Typing before a mark carries it with its paragraph; no document read.
    func test_anEditMovesTheMarksWithTheirParagraph() throws {
        let s = surface()
        apply(MarginMarks(dots: [], ticks: ["cc33"]), to: s)
        let anchor = try XCTUnwrap(s.coordinator.marginPlaces.first).anchor
        s.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "New. ")
        XCTAssertEqual(s.coordinator.marginPlaces.first?.anchor, anchor + 5)
        XCTAssertEqual(MarginPlace.shifted(10, editedRange: NSRange(location: 2, length: 0), delta: -3), 7)
        XCTAssertEqual(MarginPlace.shifted(3, editedRange: NSRange(location: 2, length: 0), delta: -3), 2,
                       "a mark inside deleted text collapses to the edit")
    }

    // MARK: - The click

    /// A mark's click — the button VoiceOver presses, the overlay's mouse
    /// path's one act — posts To resolve's event for its paragraph; the
    /// caret and the scroll do not move, and the text view never sees the
    /// click (the overlay takes it over a mark, and only there).
    func test_aClickOnAMarkShowsItsParagraphAndMovesNothing() throws {
        let s = surface()
        apply(MarginMarks(dots: [.init(paragraphId: "cc33", span: nil, annotationId: "n1", name: "Denver")],
                          ticks: ["bb22"]), to: s)
        s.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let origin = s.textView.enclosingScrollView?.contentView.bounds.origin
        let overlay = try XCTUnwrap(s.coordinator.marginOverlay)
        overlay.display()
        let marks = overlay.lastDrawn

        let tick = try XCTUnwrap(marks.first { $0.isTick })
        let atTick = overlay.convert(NSPoint(x: tick.rect.midX, y: tick.rect.midY), to: s.textView)
        XCTAssertTrue(overlay.hitTest(atTick) === overlay, "the overlay takes a click on a mark")
        let line = try firstLineRect(of: "bb22", in: s.textView)
        XCTAssertNil(overlay.hitTest(NSPoint(x: s.textView.textContainerOrigin.x + 20, y: line.midY)),
                     "the text keeps every other click")

        var heard: [(String, String)] = []
        var notes: [String?] = []
        let token = NotificationCenter.default.addObserver(  // adr-0021-ok: a test observing the post, not a production receiver
            forName: .maughamShowParagraphInResolve, object: nil, queue: nil) { note in
                if let asked = MaughamEvent.paragraphInResolve(of: note.userInfo) {
                    heard.append((asked.docId, asked.paragraphId))
                    notes.append(MaughamEvent.marginAnnotationId(of: note.userInfo))
                }
            }
        defer { NotificationCenter.default.removeObserver(token) }
        let elements = try XCTUnwrap(overlay.accessibilityChildren() as? [MarginMarkElement])
        XCTAssertEqual(elements.map { $0.accessibilityLabel() }, ["Flagged paragraph", "Note by Denver"],
                       "VoiceOver reads what each marks")
        XCTAssertEqual(elements.map { $0.accessibilityRole() }, [.button, .button])
        XCTAssertTrue(elements[0].accessibilityPerformPress())
        XCTAssertEqual(heard.map(\.0), ["doc-a"])
        XCTAssertEqual(heard.map(\.1), ["bb22"])
        XCTAssertEqual(notes, [nil], "a tick names no note")
        // The one-note dot's press names its note (closing round B, M5), so
        // To resolve shows THAT note whatever its filter.
        XCTAssertTrue(elements[1].accessibilityPerformPress())
        XCTAssertEqual(heard.map(\.1), ["bb22", "cc33"])
        XCTAssertEqual(notes, [nil, "n1"])
        XCTAssertEqual(s.textView.selectedRange(), NSRange(location: 3, length: 0), "the caret did not move")
        XCTAssertEqual(s.textView.enclosingScrollView?.contentView.bounds.origin, origin, "nor the scroll")
    }

    // MARK: - Fix round 1: the click's reach, the tint's end, VoiceOver's elements

    /// **M2** — a click at the very end of a flagged paragraph's first line,
    /// just inside the column, is the text's: the tick's hit area stops at
    /// the column's edge.
    func test_aClickAtTheEndOfAFlaggedLineIsTheTexts() throws {
        let s = surface()
        apply(MarginMarks(dots: [], ticks: ["bb22"]), to: s)
        let overlay = try XCTUnwrap(s.coordinator.marginOverlay)
        overlay.display()
        let y = try XCTUnwrap(overlay.lastDrawn.first).rect.midY
        let columnEdge = s.textView.textContainerOrigin.x + s.textView.textContainer!.size.width
        XCTAssertNil(overlay.hitTest(NSPoint(x: columnEdge - 1, y: y)),
                     "a click inside the column goes to the text")
        XCTAssertTrue(overlay.hitTest(NSPoint(x: columnEdge + 3, y: y)) === overlay,
                      "the control: the tick itself still takes its click")
    }

    /// **M10** — a hit test (every mouse move's cursor update) reads the
    /// rects the last draw cached: no layout query.
    func test_aHitTestReadsNoLayout() throws {
        let s = surface()
        apply(MarginMarks(dots: [], ticks: ["bb22", "cc33"]), to: s)
        let overlay = try XCTUnwrap(s.coordinator.marginOverlay)
        overlay.display()
        let reads = overlay.layoutReadCount
        XCTAssertGreaterThan(reads, 0, "premise: the draw read the layout")
        let tick = try XCTUnwrap(overlay.lastDrawn.first)
        for dy in stride(from: -20.0, through: 20.0, by: 2.0) {
            _ = overlay.hitTest(NSPoint(x: tick.rect.midX, y: tick.rect.midY + dy))
            _ = overlay.hitTest(NSPoint(x: 40, y: tick.rect.midY + dy))
        }
        XCTAssertEqual(overlay.layoutReadCount, reads, "forty-two hit tests, no layout read")
    }

    /// **M3** — typing at the end of a noted span does not grow its tint:
    /// the tint is the note's words, not what follows them.
    func test_typingAtTheEndOfANotedSpanDoesNotGrowItsTint() throws {
        let s = surface()
        apply(MarginMarks(dots: [.init(paragraphId: "cc33", span: 4..<9, annotationId: "n1", name: "Denver")],
                          ticks: []), to: s)
        let tint = try XCTUnwrap(s.coordinator.marginPlaces.first?.tint)
        s.textView.textStorage?.replaceCharacters(in: NSRange(location: NSMaxRange(tint), length: 0), with: "ly")
        XCTAssertEqual(s.coordinator.marginPlaces.first?.tint, tint, "the words typed after it are not the note's")
        s.textView.textStorage?.replaceCharacters(in: NSRange(location: tint.location + 2, length: 0), with: "x")
        XCTAssertEqual(s.coordinator.marginPlaces.first?.tint,
                       NSRange(location: tint.location, length: tint.length + 1), "typing inside it is")
    }

    /// **M4** — VoiceOver's elements are the same objects across queries,
    /// so its focus survives a redraw.
    func test_theMarksElementsAreStableAcrossQueries() throws {
        let s = surface()
        apply(MarginMarks(dots: [], ticks: ["bb22", "cc33"]), to: s)
        let overlay = try XCTUnwrap(s.coordinator.marginOverlay)
        overlay.display()
        let first = try XCTUnwrap(overlay.accessibilityChildren() as? [NSObject])
        overlay.display()
        let second = try XCTUnwrap(overlay.accessibilityChildren() as? [NSObject])
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(zip(first, second).allSatisfy { $0 === $1 }, "the same elements, not new ones")
    }

    /// **M8** — two notes beside one line are one mark, one element, one
    /// rect: "Notes", which says nothing of what they say.
    func test_twoNotesOnOneLineAreOneMark() throws {
        let s = surface()
        apply(MarginMarks(dots: [.init(paragraphId: "cc33", span: nil, annotationId: "n1", name: "Denver"),
                                 .init(paragraphId: "cc33", span: nil, annotationId: "n2", name: "Ada")],
                          ticks: []), to: s)
        let overlay = try XCTUnwrap(s.coordinator.marginOverlay)
        overlay.display()
        let elements = try XCTUnwrap(overlay.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(elements.map { $0.accessibilityLabel() }, ["Notes"])
    }

    // MARK: - VoiceOver's reach, from the text view (shell p5 Task 5 fix round 1, I2)

    /// The labels VoiceOver reaches walking down from the TEXT VIEW: its
    /// unignored children, recursively.
    private func spokenFromTheTextView(_ tv: NSTextView) -> [String] {
        var labels: [String] = []
        var queue: [Any] = NSAccessibility.unignoredChildren(from: tv.accessibilityChildren() ?? [])
        while !queue.isEmpty, labels.count < 500 {
            guard let object = queue.removeFirst() as? NSObject else { continue }
            func read(_ key: String) -> Any? {
                object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
            }
            if let label = read("accessibilityLabel") as? String, !label.isEmpty { labels.append(label) }
            queue += NSAccessibility.unignoredChildren(from: read("accessibilityChildren") as? [Any] ?? [])
        }
        return labels
    }

    /// **The text view hands VoiceOver every visible overlay's elements**
    /// beside its own: the margin's marks when the margin is shown, the
    /// translation's badges while a translation is read, both when both
    /// show, neither when neither does — and what the text view itself
    /// lists is kept.
    func test_theTextViewHandsVoiceOverEveryVisibleOverlaysElements() throws {
        let s = surface()
        let own = NSAccessibilityElement.element(withRole: .staticText, frame: .zero,
                                                 label: "The text view's own", parent: s.textView)
        s.textView.setAccessibilityChildren([own as Any])
        let marginLabels = ["Flagged paragraph", "Note by Denver"]
        func isBadge(_ label: String) -> Bool { label.hasPrefix("Out of date") || label.hasPrefix("Not translated yet") }

        // Neither shown.
        XCTAssertEqual(spokenFromTheTextView(s.textView), ["The text view's own"], "nothing but its own")

        // The margin shown.
        apply(MarginMarks(dots: [.init(paragraphId: "cc33", span: nil, annotationId: "n1", name: "Denver")],
                          ticks: ["bb22"]), to: s)
        try XCTUnwrap(s.coordinator.marginOverlay).display()
        let places = s.coordinator.marginPlaces
        var spoken = spokenFromTheTextView(s.textView)
        XCTAssertEqual(spoken.filter(marginLabels.contains), marginLabels, "the margin's marks: \(spoken)")
        XCTAssertTrue(spoken.contains("The text view's own"), "kept: \(spoken)")
        XCTAssertFalse(spoken.contains(where: isBadge), "\(spoken)")

        // A translation read: its badges, and (the buffer holds the
        // translation) no margin.
        let entries = [
            TranslationBadgeLayout.Entry(paragraphId: "aa11", text: "Prvi.", status: .stale),
            TranslationBadgeLayout.Entry(paragraphId: "bb22", text: "Drugi.", status: .fresh),
            TranslationBadgeLayout.Entry(paragraphId: "cc33", text: Self.paragraphs[2], status: .missing),
        ]
        EditorSurface.reconcileTextBuffer(textView: s.textView, coordinator: s.coordinator,
                                          translationLanguage: "sr",
                                          text: TranslationBadgeLayout.surface(entries: entries),
                                          undoCoherentApply: false)
        s.coordinator.setTranslationBadges(.init(entries: entries))
        s.coordinator.recomputeMarginPlaces()
        spoken = spokenFromTheTextView(s.textView)
        XCTAssertEqual(spoken.filter(isBadge).count, 2, "the badges: \(spoken)")
        XCTAssertTrue(spoken.contains("The text view's own"), "kept: \(spoken)")
        XCTAssertTrue(spoken.filter(marginLabels.contains).isEmpty, "no margin over a translation: \(spoken)")
        // The same badge elements answer every read (closing round B), so
        // VoiceOver's cursor survives a re-read.
        let badgeOverlay = try XCTUnwrap(s.coordinator.translationBadgeOverlay)
        let firstRead = try XCTUnwrap(badgeOverlay.accessibilityChildren() as? [NSObject])
        let secondRead = try XCTUnwrap(badgeOverlay.accessibilityChildren() as? [NSObject])
        XCTAssertEqual(firstRead.count, 2)
        XCTAssertTrue(zip(firstRead, secondRead).allSatisfy { $0 === $1 }, "the same elements, not new ones")

        // Both at once (forced — production empties the margin while a
        // translation holds the buffer): the rule unions, never replaces.
        // Placed inside the shorter translated text, so they lie on screen.
        s.coordinator.marginPlaces = places.enumerated().map { index, place in
            MarginPlace(mark: place.mark, paragraphId: place.paragraphId, anchor: index * 7, tint: nil)
        }
        s.coordinator.syncMarginOverlay()
        spoken = spokenFromTheTextView(s.textView)
        XCTAssertEqual(spoken.filter(isBadge).count, 2, "both: \(spoken)")
        XCTAssertFalse(spoken.filter(marginLabels.contains).isEmpty, "both: \(spoken)")
        XCTAssertTrue(spoken.contains("The text view's own"), "kept: \(spoken)")

        // Back to Source: no badge is spoken any more (closing round B).
        EditorSurface.reconcileTextBuffer(textView: s.textView, coordinator: s.coordinator,
                                          translationLanguage: nil, text: Self.text,
                                          undoCoherentApply: false)
        s.coordinator.setTranslationBadges(.empty)
        spoken = spokenFromTheTextView(s.textView)
        XCTAssertFalse(spoken.contains(where: isBadge), "back in Source, no badge: \(spoken)")
        XCTAssertTrue(spoken.contains("The text view's own"), "kept: \(spoken)")
    }

    // MARK: - M4 (closing round B): the ticks' lane beside the review rail

    /// **In read-through a tick never sits on a review card**: Everything
    /// Flagged's tick on ¶bb22 and the rail's card for a note on ¶bb22 are
    /// both drawn, and measured: the tick's click area ends before the card
    /// begins, so neither takes the other's click. Frames read synchronously
    /// off the real overlay and rail.
    func test_aTickHasItsOwnLaneBesideTheReviewRail() throws {
        let s = surface()
        let c = s.coordinator
        c.reviewParagraphRangeProvider = { Self.range(of: $0) }
        c.setReviewMode(true)
        let note = Annotation(id: "n-rail", kind: .comment, paragraphId: "bb22", body: "tighten this",
                              suggestedText: nil, priorText: nil, createdAt: Date(), createdBySession: nil,
                              status: .open, userResponse: nil, resolvedAt: nil, isStale: false,
                              author: AnnotationAuthor(sourceKind: .human, displayName: "Denver"))
        s.control.isReviewMode = true
        s.control.reviewAnnotations = [note]
        apply(MarginMarks(dots: [], ticks: ["bb22"]), to: s)
        let rail = try XCTUnwrap(c.marginRail)
        XCTAssertFalse(rail.isHidden, "premise: the review rail shows")
        rail.display()
        let card = try XCTUnwrap(rail.cardRect(forAnnotationId: "n-rail"), "premise: the rail drew the card")
        let cardInTextView = rail.convert(card, to: s.textView)
        let overlay = try XCTUnwrap(c.marginOverlay)
        overlay.display()
        let tick = try XCTUnwrap(overlay.lastDrawn.first { $0.isTick }, "premise: the tick is drawn")
        XCTAssertLessThanOrEqual(tick.hitRect.maxX, cardInTextView.minX,
                                 "the tick's click area \(tick.hitRect) ends before the card \(cardInTextView)")
        XCTAssertFalse(tick.rect.intersects(cardInTextView), "the tick is not drawn on the card")
    }

    // MARK: - Fix round 2: a delete across paragraphs

    /// A delete from mid ¶1 to mid ¶3 takes ¶2 — and its tick — away: the
    /// mark it collapsed is placed again from the document, and dropped.
    func test_aDeleteAcrossParagraphsDropsTheMarkItTookAway() async throws {
        let s = surface()
        var ranges = Dictionary(uniqueKeysWithValues: Self.ids.compactMap { id in Self.range(of: id).map { (id, $0) } })
        s.coordinator.marginParagraphRangesProvider = { ranges }
        apply(MarginMarks(dots: [], ticks: ["bb22"]), to: s)
        XCTAssertEqual(s.coordinator.marginPlaces.map(\.paragraphId), ["bb22"], "premise")
        let from = try XCTUnwrap(Self.range(of: "aa11")).location + 10
        let to = try XCTUnwrap(Self.range(of: "cc33")).location + 4
        s.textView.textStorage?.replaceCharacters(in: NSRange(location: from, length: to - from), with: "")
        // What the document now says: ¶1 and ¶3 are one paragraph; ¶2 is gone.
        ranges = ["aa11": NSRange(location: 0, length: (s.textView.string as NSString).length)]
        let dropped = await pumpUntil(deadline: 2) { s.coordinator.marginPlaces.isEmpty }
        XCTAssertTrue(dropped, "the tick of a paragraph that left the text is gone: \(s.coordinator.marginPlaces)")
    }

    /// The window's build drops a note whose paragraph left the text.
    func test_aMarkWhoseParagraphIsGoneIsNotBuilt() async throws {
        useIdentities()
        try makeBook()
        let doc = try await load()
        let second = try XCTUnwrap(doc.sequence.last)
        _ = try await doc.addReviewerAnnotation(kind: .comment, paragraphId: second, span: nil,
                                                body: "tighten", authorName: "Denver")
        XCTAssertEqual(MarginMirrorModifier.marks(key: key(doc, .peoplesNotes), document: doc, diagnostics: nil).dots.count,
                       1, "premise")
        doc.setFullText("First paragraph.")
        XCTAssertFalse(doc.sequence.contains(second), "premise: the paragraph left the text")
        let after = MarginMirrorModifier.marks(key: key(doc, .peoplesNotes), document: doc, diagnostics: nil)
        XCTAssertEqual(after.dots, [], "no dot for a paragraph that is gone")
        await doc.close()
    }

    // MARK: - Fix round 1, I3: one walk per placing, none for an unchanged rebuild

    /// Placing any number of marks reads the document's paragraph ranges in
    /// ONE pass, and never per mark; an equal rebuild places nothing.
    func test_placingTheMarksWalksTheDocumentOnce() throws {
        let s = surface()
        var walks = 0, perMark = 0
        let ranges = Dictionary(uniqueKeysWithValues: Self.ids.compactMap { id in Self.range(of: id).map { (id, $0) } })
        s.coordinator.marginParagraphRangesProvider = { walks += 1; return ranges }
        s.coordinator.reviewParagraphRangeProvider = { _ in perMark += 1; return nil }
        let marks = MarginMarks(dots: [.init(paragraphId: "aa11", span: nil, annotationId: "n1", name: "A"),
                                       .init(paragraphId: "cc33", span: nil, annotationId: "n2", name: "B")],
                                ticks: ["aa11", "bb22", "cc33"])
        apply(marks, to: s)
        XCTAssertEqual(walks, 1, "five marks, one pass")
        XCTAssertEqual(perMark, 0, "no walk per mark")
        XCTAssertEqual(s.coordinator.marginPlaces.count, 5)
        let placed = s.coordinator.marginPlacesRecomputeCount
        apply(MarginMarks(dots: marks.dots, ticks: marks.ticks), to: s)
        XCTAssertEqual(s.coordinator.marginPlacesRecomputeCount, placed, "an equal rebuild places nothing")
        XCTAssertEqual(walks, 1)
    }

    /// `Document.displayRanges` is `displayRange(forParagraphId:)` for every
    /// paragraph at once.
    func test_theOnePassRangesAreTheDocumentsOwn() async throws {
        useIdentities()
        try makeBook()
        let doc = try await load()
        let ranges = doc.displayRanges()
        XCTAssertEqual(ranges.count, doc.sequence.count)
        for pid in doc.sequence { XCTAssertEqual(ranges[pid], doc.displayRange(forParagraphId: pid)) }
        await doc.close()
    }

    /// **A burst that changes nothing the marks depend on rebuilds an equal
    /// value**: the window's build after typing in an un-noted paragraph is
    /// the same marks, so the coordinator places nothing.
    func test_aBurstElsewhereRebuildsTheSameMarks() async throws {
        useIdentities()
        try makeBook()
        let doc = try await load()
        let first = try XCTUnwrap(doc.sequence.first)
        _ = try await doc.addReviewerAnnotation(kind: .comment, paragraphId: first, span: nil,
                                                body: "tighten", authorName: "Denver")
        let before = MarginMirrorModifier.marks(key: key(doc, .peoplesNotes), document: doc, diagnostics: nil)
        XCTAssertEqual(before.dots.count, 1, "premise")
        doc.setFullText(doc.displayText.replacingOccurrences(of: "Second paragraph.", with: "Second paragraph, typed on."))
        let after = MarginMirrorModifier.marks(key: key(doc, .peoplesNotes), document: doc, diagnostics: nil)
        XCTAssertEqual(after, before, "nothing the marks depend on moved")
        await doc.close()
    }

    // MARK: - Fix round 1, I1: the menu's choice reaches UIState and the check marks

    func test_theMenusChoiceIsWrittenAndItsCheckFollows() async throws {
        useIdentities()
        try makeBook()
        let store = try await DocumentStore.open(url: projectURL)
        func checked() -> [MarginSetting] {
            MarginSetting.allCases.filter {
                MarginMarks.isChecked($0, current: MarginMirrorModifier.publishedSetting(store))
            }
        }
        XCTAssertEqual(checked(), [.off], "Off by default")
        MarginMirrorModifier.receiveSetting([MaughamEvent.marginSettingKey: MarginSetting.everythingFlagged.rawValue],
                                            documentStore: store)
        XCTAssertEqual(store.uiState.marginSetting, .everythingFlagged, "remembered in the project's UIState")
        XCTAssertEqual(checked(), [.everythingFlagged], "the menu's check follows")
        MarginMirrorModifier.receiveSetting([MaughamEvent.marginSettingKey: "loud"], documentStore: store)
        XCTAssertEqual(store.uiState.marginSetting, .everythingFlagged, "an unknown value changes nothing")
    }

    // MARK: - Over a real Document

    private var projectURL: URL!

    private func useIdentities() {
        projectURL = TestTemp.root.appendingPathComponent("margin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: projectURL.appendingPathComponent("manuscript"),
                                                 withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        addTeardownBlock { @MainActor in
            Document.localIdentitiesForTesting = nil
            Document.deviceStateForTesting = nil
            Document.registryCacheForTesting = nil
            Document.admissionMemoryForTesting = nil
        }
    }

    private static let docId = "doc-margin"
    private static let docPath = "manuscript/c1.md"

    private func makeBook() throws {
        try "First paragraph.\n\nSecond paragraph.\n".write(
            to: projectURL.appendingPathComponent(Self.docPath), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: Self.docId, title: "C1", type: .document, path: Self.docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
    }

    private func load() async throws -> Document {
        try await Document.load(url: projectURL.appendingPathComponent(Self.docPath), actor: .author,
                                session: "s", presenter: nil,
                                burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    /// The key as the window reads it (`MarginMirrorModifier.key`).
    private func key(_ doc: Document, _ setting: MarginSetting) -> MarginKey {
        MarginMirrorModifier.key(document: doc, diagnosticsVersion: 0, setting: setting, selection: [],
                                 focusMode: false, control: EditorControl(), localName: "Denver")
    }

    /// **The window's build over a real `Document`**: the writer's note is
    /// a dot, Claude's — through the writer's own Document, so the
    /// assistant's stream and key — is not.
    func test_theWindowBuildsADotForThePersonAndNotForClaude() async throws {
        useIdentities()
        try makeBook()
        let doc = try await load()
        let first = try XCTUnwrap(doc.sequence.first), second = try XCTUnwrap(doc.sequence.last)
        let mine = try await doc.addReviewerAnnotation(kind: .comment, paragraphId: first, span: nil,
                                                       body: "tighten", authorName: "Denver")
        let claudes = try await doc.addAnnotation(
            kind: .comment, paragraphId: second, body: "consider",
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"))

        let myNotes = MarginMirrorModifier.marks(key: key(doc, .peoplesNotes), document: doc, diagnostics: nil)
        XCTAssertEqual(myNotes.dots.map(\.annotationId), [mine])
        XCTAssertFalse(myNotes.dots.contains { $0.annotationId == claudes })
        XCTAssertEqual(MarginMirrorModifier.marks(key: key(doc, .off), document: doc, diagnostics: nil), .none)
        await doc.close()
    }

    /// **A seal arriving with no new op changes whose a note is**, and the
    /// marks follow without a reload: their key moves (`annotationsVersion`,
    /// bumped by the re-read) and the rebuilt marks carry the dot.
    func test_aSealArrivingDrawsTheDotWithoutAReload() async throws {
        useIdentities()
        try makeBook()
        let store = try await DocumentStore.open(url: projectURL)
        let bootstrapped = try await load()
        await bootstrapped.close()
        let other = LocalIdentities.softwareForTesting()
        _ = try await store.admit(device: other.author.fingerprint, label: "Ada", ownName: "Ada’s Mac",
                                  permit: .author(.book))
        await store.postureSettled()
        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("other-state.json")))
        let doc0 = try await load()
        let pid = try XCTUnwrap(doc0.sequence.first)
        let prior = try XCTUnwrap(doc0.paragraphs[pid])
        await doc0.close()
        // Ada's note on the first paragraph, stamped as Claude's: unsealed,
        // the stamp is all there is.
        let noteId = ULID.generate()
        try await theirs.append(Op(
            opId: noteId, docId: Self.docId, at: Date(), device: other.author.deviceId, session: "x",
            kind: .claudeComment, changes: [.init(paragraphId: pid, prior: prior, next: "")],
            provenance: .init(annotationBody: "a note of Ada’s",
                              authorSourceKind: AnnotationAuthor.SourceKind.claude.rawValue,
                              authorDisplayName: "Ada")))

        let doc = try await load()
        let before = key(doc, .peoplesNotes)
        XCTAssertEqual(MarginMirrorModifier.marks(key: before, document: doc, diagnostics: nil).dots, [],
                       "premise: no seal, a machine stamp — no dot")

        _ = try await theirs.sealChain(docId: Self.docId)
        try await doc.handleExternalLogChange()
        let after = key(doc, .peoplesNotes)
        XCTAssertNotEqual(after, before, "the key moved with no new op")
        XCTAssertEqual(MarginMirrorModifier.marks(key: after, document: doc, diagnostics: nil).dots.map(\.annotationId),
                       [noteId], "her seal says a person wrote it: a dot")
        await doc.close()
    }

    /// **Read-through draws a person's notes beside the text and not
    /// Claude's** (the owner's answer to Question 2): the review render's set
    /// holds the writer's note and not the assistant's; the coordinator
    /// draws a card for hers alone; Claude's is still in To resolve.
    func test_readThroughDrawsAPersonsCardAndNotClaudes() async throws {
        useIdentities()
        try makeBook()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await load()
        let first = try XCTUnwrap(doc.sequence.first), second = try XCTUnwrap(doc.sequence.last)
        let mine = try await doc.addReviewerAnnotation(kind: .comment, paragraphId: first, span: nil,
                                                       body: "tighten", authorName: "Denver")
        let claudes = try await doc.addAnnotation(
            kind: .comment, paragraphId: second, body: "consider",
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"))

        let control = EditorControl()
        control.readThroughDocIds = [Self.docId]
        XCTAssertTrue(control.reviewRenders(docId: Self.docId), "premise: read-through draws the review render")
        let drawn = EditorHost.reviewRenderSet(doc)
        XCTAssertEqual(drawn.map(\.id), [mine], "a person's note, and not Claude's")

        let harness = EditorIntegrationHarness(mode: ProseMode(), initialText: doc.displayText, cursorLocation: 0)
        let c = harness.coordinator
        c.reviewParagraphRangeProvider = { doc.displayRange(forParagraphId: $0) }
        c.reviewParagraphTextProvider = { doc.paragraph(id: $0) }
        c.setReviewMode(true)
        control.reviewAnnotations = drawn
        c.applyControl(control)
        XCTAssertEqual(c.resolvedReviewMarks.map(\.id), [mine], "one card, hers")

        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let read = ResolveReader.read(scope: .piece(docId: Self.docId, includesBookLevel: false),
                                      store: projectStore, documentStore: store, diagnostics: nil, figureChanges: [])
        XCTAssertTrue(read.items.contains { $0.id == "note:\(Self.docId)/\(claudes)" },
                      "Claude's note is still in To resolve")
    }
}
