import XCTest
@testable import Maugham

/// **The margin carries no model content** (shell p5 Task 2; ADR 0027 §1 as
/// amended 2026-11-22). Two censuses over the source:
///
/// 1. The overlay file draws no string: no text-drawing call of any kind.
/// 2. What is drawn beside the text — the margin's dots and the review
///    render's cards — asks ONE predicate, `NoteOwner.isAPersons`, through
///    `MarginMarks.drawnBesideTheText`: no other production file reads the
///    predicate, and every write of the review render's set and its pull
///    goes through `EditorHost.reviewRenderSet`.
final class MarginOverlayCensusTests: XCTestCase {

    private static let overlay = "Maugham/Editor/MarginOverlayView.swift"
    private static let marks = "Maugham/Editor/MarginMarks.swift"
    private static let host = "Maugham/Views/EditorHost.swift"

    /// Calls that draw words, or hang words on a mark, in code (comments
    /// and strings masked). A label is allowed only from the two fixed
    /// sources (`isAllowedLabel`).
    private static let textDrawing = [
        "draw(at:", "draw(in:", "draw(with:", "drawText", "NSAttributedString", "AttributedString(",
        "Text(", "CATextLayer", "NSTextField", "NSTextView(", "NSString(", ".string(", "drawGlyphs",
        "showGlyphs", "CTLine", "CTFrame",
        "toolTip", "addToolTip", "accessibilityValue", "setAccessibilityValue", "accessibilityHelp",
        "setAccessibilityHelp", "accessibilityTitle", "setAccessibilityTitle",
        "accessibilityCustomContent", "accessibilityAttributedLabel",
    ]

    private static func drawsText(_ masked: [UInt8]) -> [String] {
        let code = String(decoding: masked, as: UTF8.self)
        // A token counts as a whole name: `drawnBesideTheText(` is not `Text(`.
        var found = textDrawing.filter { token in
            var from = code.startIndex
            while let range = code.range(of: token, range: from..<code.endIndex) {
                from = range.upperBound
                guard range.lowerBound > code.startIndex,
                      let first = token.first, first.isLetter else { return true }
                let before = code[code.index(before: range.lowerBound)]
                if !(before.isLetter || before.isNumber || before == "_") { return true }
            }
            return false
        }
        // A label's whole argument must be one fixed label, or a choice
        // between the two (fix round 2, N4): nothing beside them.
        if labelArguments(code).contains(where: { !isAllowedLabel($0) }) {
            found.append("setAccessibilityLabel(")
        }
        // An override answers VoiceOver with whatever it returns.
        if code.range(of: #"func accessibilityLabel\(\s*\)"#, options: .regularExpression) != nil
            || code.range(of: #"var accessibilityLabel\b"#, options: .regularExpression) != nil {
            found.append("func accessibilityLabel(")
        }
        return found
    }

    /// Every `setAccessibilityLabel(…)`'s argument, whitespace folded.
    private static func labelArguments(_ code: String) -> [String] {
        var arguments: [String] = []
        var from = code.startIndex
        while let open = code.range(of: "setAccessibilityLabel(", range: from..<code.endIndex) {
            var depth = 1, index = open.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "(" { depth += 1 } else if code[index] == ")" { depth -= 1 }
                if depth > 0 { index = code.index(after: index) }
            }
            arguments.append(code[open.upperBound..<index]
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
            from = index < code.endIndex ? code.index(after: index) : code.endIndex
        }
        return arguments
    }

    private static let fixedLabel = #"(MarginMarks\.tickAccessibilityLabel|MarginMarks\.accessibilityLabel\(ofDots: [A-Za-z_]+\))"#

    private static func isAllowedLabel(_ argument: String) -> Bool {
        let pattern = "^(\(fixedLabel)|[A-Za-z_.]+ \\? \(fixedLabel) : \(fixedLabel))$"
        return argument.range(of: pattern, options: .regularExpression) != nil
    }

    /// The types the margin draws or describes itself through.
    private static let marginTypes = ["MarginOverlayView", "MarginMarkElement", "MarginPlace", "MarginGeometry", "MarginMarks"]

    /// **Every file the overlay draws or describes itself through** (fix
    /// round 1, M1): the files declaring or extending a margin type.
    private static func population() throws -> [(path: String, masked: [UInt8])] {
        var files: [(String, [UInt8])] = []
        for root in SourceTree.productionRoots {
            for file in try SourceTree.maskedSources(under: root) {
                let code = String(decoding: file.masked, as: UTF8.self)
                if marginTypes.contains(where: { type in
                    code.contains("class \(type)") || code.contains("struct \(type)")
                        || code.contains("enum \(type)") || code.contains("extension \(type)")
                }) {
                    files.append((file.path, file.masked))
                }
            }
        }
        return files
    }

    func test_theMarginOverlayDrawsNoString() throws {
        let files = try Self.population()
        XCTAssertTrue(files.contains { $0.path == Self.overlay }, "the control: the overlay is in the population")
        XCTAssertTrue(files.contains { String(decoding: $0.masked, as: UTF8.self).contains("override func draw(") },
                      "the control: a file that draws is read")
        for file in files {
            XCTAssertEqual(Self.drawsText(file.masked), [], "\(file.path) draws positions, never words")
        }

        let planted = SourceTree.mask("""
            override func draw(_ dirtyRect: NSRect) {
                (mark.body as NSString).draw(at: point, withAttributes: [:])
            }
            """)
        XCTAssertEqual(Self.drawsText(planted), ["draw(at:"], "a planted offender is caught")
        let tooltip = SourceTree.mask("""
            extension MarginOverlayView {
                func explain(_ finding: Diagnostic) { toolTip = finding.body }
                func describe(_ e: NSAccessibilityElement, _ n: Annotation) { e.setAccessibilityLabel(n.body) }
            }
            """)
        XCTAssertEqual(Self.drawsText(tooltip), ["toolTip", "setAccessibilityLabel("],
                       "a tooltip or a label carrying a note's words is caught")
        // N4: an allowed constant beside anything else, and an override.
        let mixed = SourceTree.mask("""
            element.setAccessibilityLabel(isTick ? MarginMarks.tickAccessibilityLabel : finding.body)
            """)
        XCTAssertEqual(Self.drawsText(mixed), ["setAccessibilityLabel("],
                       "a label mixing a fixed one with a note's words is caught")
        let overridden = SourceTree.mask("""
            final class MarginMarkElement: NSAccessibilityElement {
                override func accessibilityLabel() -> String? { body }
                override func accessibilityValue() -> Any? { body }
            }
            """)
        XCTAssertEqual(Self.drawsText(overridden).sorted(), ["accessibilityValue", "func accessibilityLabel("],
                       "an override of the label or value is caught")
        let comment = SourceTree.mask("""
            // never NSAttributedString or draw(at:) here
            let label = "Text(\\(name))"
            element.setAccessibilityLabel(MarginMarks.tickAccessibilityLabel)
            """)
        XCTAssertEqual(Self.drawsText(comment), [], "a comment, a string or a fixed label is not")
    }

    /// **A tick carries nothing but its paragraph** (fix round 1, M1): the
    /// types themselves have no field a model's words could ride in.
    func test_aTickCarriesNothingButItsParagraph() {
        XCTAssertTrue(Mirror(reflecting: MarginPlace.Mark.tick).children.isEmpty, "a tick has no payload")
        XCTAssertTrue(type(of: MarginMarks.none.ticks) == Set<String>.self, "ticks are paragraph ids")
        XCTAssertEqual(Self.fields(MarginMarks.none), ["dots", "ticks"])
        XCTAssertEqual(Self.fields(MarginMarks.Dot(paragraphId: "aa11", span: nil, annotationId: "n", name: "")),
                       ["paragraphId", "span", "annotationId", "name", "colour"],
                       "a dot: where, whose, and their colour — no words")
        XCTAssertEqual(Self.fields(MarginPlace(mark: .tick, paragraphId: "aa11", anchor: 0, tint: nil)),
                       ["mark", "paragraphId", "anchor", "tint"])
        let drawn = MarginOverlayView.Drawn(
            places: [MarginPlace(mark: .tick, paragraphId: "aa11", anchor: 0, tint: nil)],
            rect: .zero, hitRect: .zero, tintRects: [])
        XCTAssertEqual(Self.fields(drawn), ["places", "rect", "hitRect", "tintRects"], "N4: a drawn mark")
        XCTAssertEqual(Self.fields(MarginMarkElement(paragraphId: "aa11", isTick: true, names: [], coordinator: nil)),
                       ["paragraphId", "soleNoteId", "coordinator"],
                       "N4: VoiceOver's element — where, and (a one-note dot) which note's id")
        struct Planted { let paragraphId: String; let body: String }
        XCTAssertNotEqual(Self.fields(Planted(paragraphId: "aa11", body: "x")), ["paragraphId"],
                          "a planted field is caught")
    }

    private static func fields(_ value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }

    /// **The delivery path is in place** (fix round 1, I1): the window
    /// applies the margin's modifier once; it publishes the setting the menu
    /// checks, writes the menu's choice to `UIState`, builds the marks into
    /// the control and answers a click; the coordinator observes and applies
    /// them; `EditorHost` wires the one-pass ranges; To resolve holds a
    /// click's group as its caret group.
    func test_theMarginIsDeliveredThroughTheWindow() throws {
        func code(_ path: String) throws -> String {
            String(decoding: try SourceTree.checkedMask(SourceTree.read(path), path: path), as: UTF8.self)
        }
        let window = try code("Maugham/Views/ProjectWindow.swift")
        XCTAssertEqual(Self.occurrences(of: ".modifier(MarginMirrorModifier(", in: window), 1)
        let mirror = try code("Maugham/Views/EditorControlMirror.swift")
        for wire in [
            ".focusedSceneValue(\\.marginSetting, Self.publishedSetting(documentStore))",
            "Self.receiveSetting(note.userInfo, documentStore: documentStore)",
            ".onChange(of: key, initial: true)",
            "editorControl.margin = Self.marks(",
            "Self.paragraphJump(note.userInfo",
            "@FocusedValue(\\.marginSetting) private var current",
            "MarginMarks.isChecked(setting, current: current)",
            "MaughamEvent.postMarginSetting(setting)",
        ] {
            XCTAssertTrue(mirror.contains(wire), "the margin's window wiring: \(wire)")
        }
        XCTAssertTrue(try code("Maugham/MaughamApp.swift").contains("FocusedMarginItems()"), "View ▸ Margin")
        let coordinator = try code("Maugham/Editor/EditorCoordinator.swift")
        XCTAssertTrue(coordinator.contains("_ = control.margin"), "observed")
        XCTAssertTrue(coordinator.contains("setMargin(c.margin)"), "applied")
        XCTAssertTrue(try code("Maugham/Views/EditorHost.swift")
            .contains("marginParagraphRangesProvider: { doc.displayRanges() }"), "the one-pass ranges")
        let pane = try code("Maugham/Views/Resolve/ResolvePane.swift")
        XCTAssertTrue(pane.contains("caretPin = ResolveCaretPin(key: target, caretLocation: caretLocationNow)")
                      && pane.contains("caretGroup = target"), "a request's target is the caret group")

        let planted = "content.modifier(EditorControlMirrorModifier(membrane: m))"
        XCTAssertEqual(Self.occurrences(of: ".modifier(MarginMirrorModifier(", in: planted), 0,
                       "a window without the modifier is caught")
    }

    private static func occurrences(of token: String, in code: String) -> Int {
        code.components(separatedBy: token).count - 1
    }

    /// One predicate decides what is drawn beside the text.
    func test_whatIsDrawnBesideTheTextAsksOnePredicate() throws {
        var readers: [String] = []
        for root in SourceTree.productionRoots {
            for file in try SourceTree.maskedSources(under: root)
            where String(decoding: file.masked, as: UTF8.self).contains(".isAPersons") {
                readers.append(file.path)
            }
        }
        XCTAssertEqual(readers, [Self.marks], "the predicate is read in the margin's file alone")
        let marksCode = String(decoding: try SourceTree.checkedMask(
            SourceTree.read(Self.marks), path: Self.marks), as: UTF8.self)
        XCTAssertTrue(marksCode.contains("drawnBesideTheText(notes"),
                      "the dots come through the one filter")

        let hostCode = String(decoding: try SourceTree.checkedMask(
            SourceTree.read(Self.host), path: Self.host), as: UTF8.self)
        XCTAssertGreaterThan(Self.renderWrites(hostCode).count, 3,
                             "the control: EditorHost's pushes and pull are in the population")
        XCTAssertEqual(Self.unfilteredRenderWrites(hostCode), [],
                       "every write of the review render's set reads `reviewRenderSet`")
        XCTAssertTrue(hostCode.contains("MarginMarks.drawnBesideTheText("),
                      "and `reviewRenderSet` is the one filter")

        // Every other production writer of the control's set, by name — the
        // editor's own files carry it one way and produce none.
        var elsewhere: [String] = []
        for root in SourceTree.productionRoots {
            for file in try SourceTree.maskedSources(under: root)
            where file.path != Self.host && !file.path.hasPrefix("Maugham/Editor/") {
                let code = String(decoding: file.masked, as: UTF8.self)
                if code.contains("control.reviewAnnotations =") || code.contains("reviewAnnotationsProvider:") {
                    elsewhere.append(file.path)
                }
            }
        }
        XCTAssertEqual(elsewhere, [], "the review render's set is written by EditorHost alone")

        let planted = """
            control.reviewAnnotations = doc.annotations(filter: AnnotationFilter(statuses: [.open]))

            reviewAnnotationsProvider: { Self.reviewRenderSet(doc) },
            """
        XCTAssertEqual(Self.unfilteredRenderWrites(planted).count, 1,
                       "a planted unfiltered push is caught; the filtered pull is the control")
    }

    /// The lines that write the render's set: a push into the control, the
    /// pull's closure, and their continuation lines up to the value.
    private static func renderWrites(_ code: String) -> [String] {
        let lines = code.components(separatedBy: "\n")
        var writes: [String] = []
        for (index, line) in lines.enumerated()
        where line.contains("control.reviewAnnotations =") || line.contains("reviewAnnotationsProvider:") {
            writes.append(lines[index...].prefix(2).joined(separator: "\n"))
        }
        return writes
    }

    private static func unfilteredRenderWrites(_ code: String) -> [String] {
        renderWrites(code).filter { !$0.contains("reviewRenderSet(") }
    }

    /// **To resolve's selection reaches the margin with one writer**: the
    /// window's `resolveSelection` is assigned in one place, the closure
    /// `RightColumn` hands To resolve, and To resolve publishes what it shows
    /// on every change, from its first.
    func test_theSelectionTheTicksFollowHasOneWriter() throws {
        var writers: [String] = []
        for root in SourceTree.productionRoots {
            for file in try SourceTree.maskedSources(under: root) {
                let code = String(decoding: file.masked, as: UTF8.self)
                writers += Self.selectionWrites(code).map { "\(file.path): \($0)" }
            }
        }
        XCTAssertEqual(writers.count, 1, "\(writers)")
        XCTAssertTrue(writers.first?.contains(
            "onResolveSelectionShown: { resolveSelections = Self.recordingSelection($0, into: resolveSelections) }") == true,
                      "the one write is the published value, kept per piece")

        let pane = "Maugham/Views/Resolve/ResolvePane.swift"
        let paneCode = String(decoding: try SourceTree.checkedMask(SourceTree.read(pane), path: pane),
                              as: UTF8.self)
        XCTAssertTrue(paneCode.contains(
            ".onChange(of: ResolveShownSelection(scope: scope, selection: shownSelection), initial: true)"),
                      "To resolve publishes what it shows and over what, from its first value")
        XCTAssertTrue(paneCode.contains("onSelectionShown(shown)"))

        let planted = """
            onResolveSelectionShown: { resolveSelections = Self.recordingSelection($0, into: resolveSelections) },
            .onAppear { resolveSelections = [:] }
            """
        XCTAssertEqual(Self.selectionWrites(planted).count, 2, "a second writer is caught")
    }

    private static func selectionWrites(_ code: String) -> [String] {
        code.components(separatedBy: "\n").filter { $0.contains("resolveSelections = ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
