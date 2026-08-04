import XCTest
@testable import Maugham

/// Generation tests (audit §3.3 "generated-or-tested" — the same principle
/// EMISSION.md already applies to the publish contract). These three docs
/// claims are cheap to derive from source at test time; deriving them means
/// the doc can no longer silently drift out from under the code the way the
/// Task-15 audit found (tool count, keybinding table, right-pane mode list).
/// Each check has a companion self-check proving the parser WOULD fail on a
/// planted offender — the house pattern from `TripwireGrepTests`.
final class DocSyncTests: XCTestCase {

    // MARK: - Path resolution (mirrors TripwireGrepTests' #filePath pattern)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
    }

    private func readFile(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Test 1: MCP tool-count sync (CLAUDE.md + AREA.md vs MCPToolCatalog.all)

    /// Extracts the `NN` from CLAUDE.md's `**NN tools**` MCP-row claim.
    /// `nil` means the doc's phrasing changed shape — callers must fail
    /// loudly rather than silently skip the check.
    static func extractToolCountFromCLAUDEmd(_ text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\*\*(\d+) tools\*\*"#) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    /// Extracts the `NN` from `Maugham/MCP/AREA.md`'s `## Tool catalogue (NN)` heading.
    static func extractToolCountFromAREAmd(_ text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"Tool catalogue \((\d+)\)"#) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    func test_toolCountSyncedAcrossDocsAndCatalog() throws {
        let claudeMd = try readFile("CLAUDE.md")
        let areaMd = try readFile("Maugham/MCP/AREA.md")

        guard let claudeCount = Self.extractToolCountFromCLAUDEmd(claudeMd) else {
            XCTFail("Could not find \"**NN tools**\" in CLAUDE.md's MCP row — doc structure changed?")
            return
        }
        guard let areaCount = Self.extractToolCountFromAREAmd(areaMd) else {
            XCTFail("Could not find \"Tool catalogue (NN)\" heading in Maugham/MCP/AREA.md — doc structure changed?")
            return
        }

        let actual = MCPToolCatalog.all.count
        XCTAssertEqual(claudeCount, actual,
            "CLAUDE.md claims \(claudeCount) MCP tools but MCPToolCatalog.all has \(actual). "
            + "Update the \"**\(actual) tools**\" phrase in CLAUDE.md's MCP row.")
        XCTAssertEqual(areaCount, actual,
            "Maugham/MCP/AREA.md claims \(areaCount) MCP tools but MCPToolCatalog.all has \(actual). "
            + "Update the \"## Tool catalogue (\(actual))\" heading.")
    }

    /// Self-check: a doctored CLAUDE.md/AREA.md claiming counts one/two more
    /// than the real catalog size parses to those planted numbers, which
    /// would NOT equal the real catalog count — proving the assertion above
    /// would go red on drift, not silently pass. The planted numbers are
    /// derived from the live catalog count (not hardcoded) so this check
    /// keeps working as the catalog grows — a hardcoded literal collided
    /// with reality the moment the real count caught up to it (Task 10,
    /// move_research_item: catalog hit 48, the same number this self-check
    /// used to plant).
    func test_toolCountCheckWouldFireOnPlantedOffender() {
        let actual = MCPToolCatalog.all.count
        let plantedClaude = actual + 1
        let plantedArea = actual + 2
        let doctoredClaudeMd = "Transport = live-only Unix socket (ADR 0003). **\(plantedClaude) tools** (see AREA.md)."
        let doctoredAreaMd = "## Tool catalogue (\(plantedArea))\n"

        guard let claudeCount = Self.extractToolCountFromCLAUDEmd(doctoredClaudeMd) else {
            return XCTFail("Self-check: parser should extract a count from the doctored CLAUDE.md text.")
        }
        guard let areaCount = Self.extractToolCountFromAREAmd(doctoredAreaMd) else {
            return XCTFail("Self-check: parser should extract a count from the doctored AREA.md text.")
        }

        XCTAssertEqual(claudeCount, plantedClaude)
        XCTAssertEqual(areaCount, plantedArea)
        XCTAssertNotEqual(claudeCount, actual,
            "Self-check expected the planted \(plantedClaude) to disagree with the real catalog count.")
        XCTAssertNotEqual(areaCount, actual,
            "Self-check expected the planted \(plantedArea) to disagree with the real catalog count.")
    }

    // MARK: - Test 2: DetailPaneToggle keyboard-shortcut tokens vs reference.md

    /// Enumerates `.keyboardShortcut("N", modifiers: [ … ])` occurrences whose
    /// modifier list contains **both** `.command` and `.option`, returning each
    /// as a `⌘⌥N` token — or `⌘⌥⇧N` when the list also carries `.shift`.
    /// Uppercased: `KeyEquivalent` source literals for letters are lowercase
    /// (`"i"`, `"r"`, …, matching the pre-existing `"a"` for Annotations),
    /// but every doc/cheatsheet in this repo displays the macOS-conventional
    /// uppercase letter (`⌘⌥I`, `⌘N`, …) — digits pass through unaffected.
    ///
    /// **The modifier list is parsed as a SET, not matched as a literal, and
    /// that widening is this test's whole reason for existing in its current
    /// shape.** The original pattern spelled `\[\.command,\s*\.option\]`
    /// verbatim, so `[.command, .option, .shift]` did not match and
    /// **Toggle Review Mode (⌘⌥⇧R) shipped documented nowhere in
    /// `docs/guide/`** — the `2026-07-25-persona-shell.md` plan asked for the
    /// shortcut row to be amended `⌘⌥R` → `⌘⌥⇧R`, what landed REPLACED that row
    /// with `⌘⌥R | Research pane`, and the guard could not see the difference.
    /// The plan flagged the blind spot at the time and nobody widened it.
    ///
    /// A set also means a modifier list written in another order
    /// (`[.option, .command]`) is in scope, which a literal pattern would miss
    /// the same silent way.
    static func extractCommandOptionShortcutTokens(from sourceText: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\.keyboardShortcut\("([^"]+)",\s*modifiers:\s*\[([^\]]*)\]\)"#
        ) else { return [] }
        let ns = sourceText as NSString
        let matches = regex.matches(in: sourceText, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            let key = ns.substring(with: match.range(at: 1))
            let modifiers = Set(
                ns.substring(with: match.range(at: 2))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) })
            guard modifiers.contains(".command"), modifiers.contains(".option") else { return nil }
            // ⌘⌥⇧ is the order the roadmap, ADR 0025 and the View menu all
            // spell it in; a token in any other order would never be found in
            // the docs even when the row is there.
            return "⌘⌥" + (modifiers.contains(".shift") ? "⇧" : "") + key.uppercased()
        }
    }

    /// Returns the subset of `tokens` that do NOT appear anywhere in `docText`.
    static func missingTokens(_ tokens: [String], in docText: String) -> [String] {
        tokens.filter { !docText.contains($0) }
    }

    /// After the keyspace-migration task, `DetailPaneToggle.swift` declares no
    /// shortcuts at all — the View menu in `MaughamApp.swift` owns every pane
    /// shortcut (⌘⌥-letter) as the sole dispatch path, so that's the file this
    /// guard now reads from.
    func test_paneShortcutsDocumentedInReferenceMd() throws {
        let sourceText = try readFile("Maugham/MaughamApp.swift")
        let tokens = Self.extractCommandOptionShortcutTokens(from: sourceText)
        guard !tokens.isEmpty else {
            XCTFail("No .keyboardShortcut(\"N\", modifiers: [.command, .option]) occurrences found in "
                + "MaughamApp.swift — source structure changed? (regex may need updating)")
            return
        }
        // Anti-vacuity: a regex that matches nothing would make this whole
        // test pass without asserting anything, which is worse than deleting
        // it — the very failure mode this repoint exists to avoid. Assert a
        // floor, not equality: MaughamApp.swift also carries non-pane ⌘⌥
        // bindings (⌘⌥0 inspector column, ⌘⌥F find in project, ⌘⌥Z restore),
        // so the count exceeds `DetailSegment.allCases`.
        XCTAssertGreaterThanOrEqual(tokens.count, DetailSegment.allCases.count,
                                    "extracted \(tokens.count) ⌘⌥ shortcuts — expected at least "
                                    + "one per DetailSegment case; a regex that matches nothing "
                                    + "makes this whole test vacuous")
        // The CONTROL for the widening, and the reason it is asserted against
        // the real source rather than a fixture: a floor on the count cannot
        // tell a widened extractor from the narrow one, because ⌘⌥⇧R is a
        // single token on top of a set that already cleared the floor. Narrow
        // the modifier match back to a literal `[.command, .option]` and this
        // line goes red, which is exactly what did NOT happen when the row went
        // missing.
        XCTAssertTrue(tokens.contains("⌘⌥⇧R"),
                      "The extractor no longer sees Toggle Review Mode's "
                      + "[.command, .option, .shift] binding. Found: \(tokens).")

        let referenceMd = try readFile("docs/guide/reference.md")
        let missing = Self.missingTokens(tokens, in: referenceMd)
        XCTAssertTrue(missing.isEmpty,
            "MaughamApp.swift defines keyboard shortcut(s) \(missing) that are not documented "
            + "in docs/guide/reference.md's shortcut table. Found tokens: \(tokens).")
    }

    /// Self-check: a planted `.keyboardShortcut("9", ...)` extracts to "⌘⌥9",
    /// which is genuinely absent from the real reference.md — proving the
    /// missing-token check above would fire on real drift.
    func test_shortcutCheckWouldFireOnPlantedOffender() throws {
        let plantedSource = """
        Image(systemName: "questionmark")
            .tag(DetailSegment.inspector)
            .keyboardShortcut("9", modifiers: [.command, .option])
        """
        let tokens = Self.extractCommandOptionShortcutTokens(from: plantedSource)
        XCTAssertEqual(tokens, ["⌘⌥9"],
            "Self-check: parser should extract exactly the planted ⌘⌥9 token.")

        let referenceMd = try readFile("docs/guide/reference.md")
        let missing = Self.missingTokens(tokens, in: referenceMd)
        XCTAssertEqual(missing, ["⌘⌥9"],
            "Self-check expected the planted ⌘⌥9 token to be reported missing from the real reference.md.")
    }

    /// Self-check for the widening itself: a planted `.shift`-carrying binding
    /// is extracted as `⌘⌥⇧9` and reported missing from the real docs.
    ///
    /// Separate from the plant above because that one would pass unchanged
    /// against the NARROW extractor — it plants `[.command, .option]`, which the
    /// old pattern matched. A plant that does not fire is the finding, and the
    /// finding here is that nothing in the suite exercised the modifier list
    /// that Toggle Review Mode actually uses.
    func test_shortcutCheckWouldFireOnAPlantedShiftCarryingOffender() throws {
        let plantedSource = """
        Button("Toggle Something") { }
            .keyboardShortcut("9", modifiers: [.command, .option, .shift])
        Button("Reordered Modifiers") { }
            .keyboardShortcut("8", modifiers: [.option, .command])
        """
        let tokens = Self.extractCommandOptionShortcutTokens(from: plantedSource)
        XCTAssertEqual(tokens, ["⌘⌥⇧9", "⌘⌥8"],
            "Self-check: the widened parser should take the shift-carrying binding "
            + "as ⌘⌥⇧9 and the reordered list as ⌘⌥8. Got: \(tokens).")

        let referenceMd = try readFile("docs/guide/reference.md")
        XCTAssertEqual(Self.missingTokens(tokens, in: referenceMd), ["⌘⌥⇧9", "⌘⌥8"],
            "Self-check expected both planted tokens to be reported missing from the "
            + "real reference.md.")

        // …and the converse, so the widening is not a wall that reports
        // everything: the real ⌘⌥⇧R now IS documented, and must not report.
        XCTAssertEqual(Self.missingTokens(["⌘⌥⇧R"], in: referenceMd), [],
            "⌘⌥⇧R (Toggle Review Mode) is missing from docs/guide/reference.md's "
            + "shortcut table.")
    }

    /// **The second surface, and `reference.md` is the one that sends readers to
    /// it**: *\"The full list lives in the in-app cheatsheet: ⌘/ → Keyboard tab.\"*
    /// That cheatsheet is `KeyboardShortcuts.all`, hand-maintained by its own
    /// doc comment's admission, and it had the same hole — Toggle Review Mode
    /// appeared in neither. A guard on only the page that defers to the full
    /// list is half a guard.
    ///
    /// Read as a value rather than parsed as text, because it is compiled into
    /// the app this test already imports.
    func test_paneShortcutsDocumentedInTheInAppCheatsheet() throws {
        let sourceText = try readFile("Maugham/MaughamApp.swift")
        let tokens = Self.extractCommandOptionShortcutTokens(from: sourceText)
        XCTAssertGreaterThanOrEqual(tokens.count, DetailSegment.allCases.count,
                                    "extracted \(tokens.count) ⌘⌥ shortcuts — a regex that "
                                    + "matches nothing makes this test vacuous")

        let cheatsheet = KeyboardShortcuts.all.flatMap(\.items).map(\.shortcut)
        XCTAssertFalse(cheatsheet.isEmpty,
                       "KeyboardShortcuts.all lists nothing — this check would be vacuous.")

        let missing = tokens.filter { !cheatsheet.contains($0) }
        XCTAssertTrue(missing.isEmpty,
            "MaughamApp.swift defines keyboard shortcut(s) \(missing) that the in-app "
            + "cheatsheet (⌘/ → Keyboard, `KeyboardShortcuts.all`) does not list — and "
            + "docs/guide/reference.md points readers at that cheatsheet as the full "
            + "list. Cheatsheet entries: \(cheatsheet).")
    }

    /// Self-check: a token the cheatsheet genuinely does not carry is reported.
    func test_theCheatsheetCheckWouldFireOnAPlantedOffender() {
        let cheatsheet = KeyboardShortcuts.all.flatMap(\.items).map(\.shortcut)
        XCTAssertEqual(["⌘⌥⇧9"].filter { !cheatsheet.contains($0) }, ["⌘⌥⇧9"],
            "Self-check expected a planted ⌘⌥⇧9 to be absent from the real cheatsheet.")
        XCTAssertEqual(["⌘⌥⇧R"].filter { !cheatsheet.contains($0) }, [],
            "Self-check: the real ⌘⌥⇧R must be present, or the guard is a wall.")
    }

    // MARK: - Test 3: DetailSegment case names mentioned in right-pane.md

    /// Enumerates `case <name>` lines from the `DetailSegment` enum source.
    static func extractEnumCaseNames(from sourceText: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*case\s+(\w+)"#) else { return [] }
        let ns = sourceText as NSString
        let matches = regex.matches(in: sourceText, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Case-insensitive substring check: each case name's raw spelling
    /// (e.g. "inbox") must appear somewhere in the doc text (e.g. "Inbox") —
    /// **or**, for a camelCase name, its spelled-out form ("visualLanguage" →
    /// "visual language").
    ///
    /// The second spelling exists because `right-pane.md` is the writer's help,
    /// not a symbol index. Every case was one word until M1A, so the raw-name
    /// check had never met a multi-word one; requiring the literal
    /// `visualLanguage` in user-facing prose would document the identifier
    /// rather than the pane. The guard's job — a segment that ships with no
    /// mention at all goes red — is unchanged, and
    /// `test_segmentMentionCheckWouldFireOnPlantedOffender` still proves it.
    static func missingCaseMentions(_ names: [String], in docText: String) -> [String] {
        let lowered = docText.lowercased()
        return names.filter { name in
            !lowered.contains(name.lowercased())
                && !lowered.contains(spelledOut(name))
        }
    }

    /// "visualLanguage" → "visual language"; a single-word name is unchanged,
    /// so this can never make a one-word case easier to satisfy.
    static func spelledOut(_ camelCase: String) -> String {
        var out = ""
        for character in camelCase {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(Character(character.lowercased()))
        }
        return out
    }

    func test_detailSegmentCasesDocumentedInRightPaneMd() throws {
        let sourceText = try readFile("Maugham/Models/DetailSegment.swift")
        let caseNames = Self.extractEnumCaseNames(from: sourceText)
        guard !caseNames.isEmpty else {
            XCTFail("No `case <name>` lines found in DetailSegment.swift — source structure changed? "
                + "(regex may need updating)")
            return
        }

        let rightPaneMd = try readFile("docs/guide/right-pane.md")
        let missing = Self.missingCaseMentions(caseNames, in: rightPaneMd)
        XCTAssertTrue(missing.isEmpty,
            "DetailSegment case(s) \(missing) have no mention in docs/guide/right-pane.md. "
            + "All cases: \(caseNames).")
    }

    /// Self-check: a doctored right-pane.md with the "inbox" mention removed
    /// causes the real "inbox" case name to be reported missing — proving
    /// the check above would fire on real drift (e.g. a 9th segment added
    /// without a doc mention).
    func test_segmentMentionCheckWouldFireOnPlantedOffender() throws {
        let sourceText = try readFile("Maugham/Models/DetailSegment.swift")
        let caseNames = Self.extractEnumCaseNames(from: sourceText)
        XCTAssertTrue(caseNames.contains("inbox"),
            "Self-check precondition: DetailSegment should still have an `inbox` case.")

        let doctoredDoc = "The right column has modes: Inspector, Research, Outline, "
            + "Tasks, Annotations, History, Palette, Translation, Intent, Visual Language."
        let missing = Self.missingCaseMentions(caseNames, in: doctoredDoc)
        XCTAssertEqual(missing, ["inbox"],
            "Self-check expected exactly the omitted \"inbox\" case to be reported missing. Got: \(missing).")
    }

    /// Self-check for the spelled-out alternative: a multi-word case is
    /// satisfied by its prose spelling and by nothing weaker. Without the third
    /// assertion the relaxation could be a wall — "visual" alone must not pass,
    /// or a doc that merely says "visual" documents nothing.
    func test_spelledOutCaseNamesSatisfyTheMentionCheckAndNothingLessDoes() {
        XCTAssertEqual(Self.spelledOut("visualLanguage"), "visual language")
        XCTAssertEqual(Self.spelledOut("inbox"), "inbox",
                       "a one-word case must be unchanged, or this relaxation "
                       + "would weaken every existing check")

        XCTAssertEqual(
            Self.missingCaseMentions(["visualLanguage"], in: "a **Visual Language** mode"),
            [], "the prose spelling should satisfy the check")
        XCTAssertEqual(
            Self.missingCaseMentions(["visualLanguage"], in: "a `visualLanguage` case"),
            [], "the raw identifier should still satisfy the check")
        XCTAssertEqual(
            Self.missingCaseMentions(["visualLanguage"], in: "the visual mode, and language"),
            ["visualLanguage"],
            "neither half on its own may satisfy the check — that would make the "
            + "guard unfalsifiable for any compound name")
    }

    // MARK: - Test 4: the canvas's calibration figures (1C-c3 whole-branch review)

    /// The files that declare the figures `Maugham/Canvas/AREA.md` is allowed to
    /// quote in the notation — `CanvasMaterial` and `CanvasCardMetrics`.
    ///
    /// **Deliberately narrow.** These are the numbers the *writer* reads to decide
    /// where to move a knob, which is what makes a stale one expensive: a stale
    /// `1.2°` in that file and four others was read as current, went into the
    /// option preview he chose the tilt band from, and gave him a wrong upper
    /// bound. Everything else in that file — the prose, the counts, the measured
    /// timings — is out of scope, and the counts already have a working
    /// mitigation ("count the array, not this sentence").
    static let calibrationSourceFiles = [
        "Maugham/Canvas/CanvasMaterial.swift",
        "Maugham/Canvas/CanvasNode.swift",
        // 1C-d put an item card's geometry here — the gaps around a photograph
        // and its caption, and the clamp on a pathological aspect ratio. They are
        // `CanvasCardMetrics`' members like `inset`, and they live in this file
        // rather than beside it because measuring a line of text needs `NSFont`.
        "Maugham/Canvas/CanvasScrapMeasure.swift",
    ]

    /// One quoted figure: the constant's name and the value as the doc writes it.
    struct QuotedFigure: Equatable {
        let name: String
        /// One number for a scalar, three for an sRGB triple.
        let values: [Double]
    }

    /// Every figure pair in `text`: an inline code span holding a lowerCamelCase
    /// identifier, immediately followed by a parenthesised NUMERIC value.
    ///
    /// **"Numeric" is what keeps this out of the prose.** `` `rowOrdered` (a
    /// proximity walk over the y-sorted list) `` is a code span followed by a
    /// parenthesis and is not a figure; nothing but digits, dots, commas,
    /// spaces and a trailing unit matches. A pair that IS numeric must resolve
    /// to a real constant, which is what stops a rename from quietly taking the
    /// figure out of the guard's sight.
    static func quotedFigures(in text: String) -> [QuotedFigure] {
        let pattern = #"`([a-z][A-Za-z0-9]*)`\s*\(\s*([0-9., ]+?)\s*(?:°|pt|px)?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var found: [QuotedFigure] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let body = ns.substring(with: m.range(at: 2))
            let parts = body.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // A bare "1" or a trailing comma is not a figure; every part must
            // parse, and there must be one part or three.
            let numbers = parts.compactMap(Double.init)
            guard numbers.count == parts.count, numbers.count == 1 || numbers.count == 3 else {
                return
            }
            found.append(QuotedFigure(name: ns.substring(with: m.range(at: 1)), values: numbers))
        }
        return found
    }

    /// Every `static let NAME` in `source` whose value is a numeric literal or an
    /// `NSColor(srgbRed:green:blue:alpha:)` triple, as the same shape.
    ///
    /// Anything else — a derived value like `itemLabelOnlyHeight`, a system
    /// colour like `.textBackgroundColor`, an array — is simply absent, so a doc
    /// pair naming one fails as "no such figure" rather than passing blind.
    static func declaredFigures(in source: String) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        let scalar = try? NSRegularExpression(
            pattern: #"static let ([a-z][A-Za-z0-9]*)\s*:\s*(?:CGFloat|Double)\s*=\s*(-?[0-9.]+)\s*$"#)
        let colour = try? NSRegularExpression(
            pattern: #"static let ([a-z][A-Za-z0-9]*)\s*=\s*NSColor\(srgbRed:\s*([0-9.]+),\s*green:\s*([0-9.]+),\s*blue:\s*([0-9.]+)"#)
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            if let m = scalar?.firstMatch(in: line, range: whole),
               let v = Double(ns.substring(with: m.range(at: 2))) {
                out[ns.substring(with: m.range(at: 1))] = [v]
            } else if let m = colour?.firstMatch(in: line, range: whole) {
                let rgb = (1...3).compactMap { Double(ns.substring(with: m.range(at: $0 + 1))) }
                if rgb.count == 3 { out[ns.substring(with: m.range(at: 1))] = rgb }
            }
        }
        return out
    }

    /// Which quoted figures disagree with the source, and how.
    static func calibrationMismatches(quoted: [QuotedFigure],
                                      declared: [String: [Double]]) -> [String] {
        quoted.compactMap { figure in
            guard let actual = declared[figure.name] else {
                return "`\(figure.name)` \(figure.values) — no such numeric constant in "
                    + calibrationSourceFiles.joined(separator: " / ")
            }
            guard actual.count == figure.values.count else {
                return "`\(figure.name)` — the doc quotes \(figure.values.count) "
                    + "number(s) and the constant has \(actual.count)"
            }
            let agrees = zip(figure.values, actual).allSatisfy { abs($0 - $1) < 0.0005 }
            return agrees ? nil : "`\(figure.name)` — doc says \(figure.values), "
                + "source says \(actual)"
        }
    }

    /// A calibration figure quoted in `Maugham/Canvas/AREA.md` must be the value
    /// the constant actually has.
    ///
    /// The notation is required and is documented in that file: an inline code
    /// span naming the constant, immediately followed by the value in parentheses.
    /// Its limit is that a figure written as bare prose is invisible here — which
    /// is acceptable, because the notation is also what makes a stale number
    /// findable by eye, and that is how the `1.2°` was eventually caught.
    func test_theCalibrationFiguresInTheCanvasAreaFileMatchTheirConstants() throws {
        let doc = try readFile("Maugham/Canvas/AREA.md")
        var declared: [String: [Double]] = [:]
        for path in Self.calibrationSourceFiles {
            declared.merge(Self.declaredFigures(in: try readFile(path))) { a, _ in a }
        }
        XCTAssertNotNil(declared["maximumTiltDegrees"],
            "Self-check: the source parser found no `maximumTiltDegrees`, so it is "
            + "reading nothing and every comparison below is vacuous.")

        let quoted = Self.quotedFigures(in: doc)
        XCTAssertGreaterThanOrEqual(quoted.count, 4,
            "Only \(quoted.count) calibration figures are written in the notation. "
            + "Someone has un-converted them, and an unquoted figure is one this "
            + "test cannot see. Found: \(quoted.map(\.name)).")

        let mismatches = Self.calibrationMismatches(quoted: quoted, declared: declared)
        XCTAssertTrue(mismatches.isEmpty,
            "Maugham/Canvas/AREA.md quotes a calibration figure that no longer "
            + "matches its constant. A stale figure in that file reaches Denver's "
            + "design decisions — it is where he goes to find a knob:\n"
            + mismatches.joined(separator: "\n"))
    }

    /// Self-check: the parser fires on a drifted figure, on a renamed constant
    /// and on a triple quoted with the wrong channel — and does NOT fire on a
    /// prose parenthetical, which is the whole reason the value must be numeric.
    func test_theCalibrationFigureCheckWouldFireOnPlantedOffenders() throws {
        let declared: [String: [Double]] = [
            "maximumTiltDegrees": [1.0],
            "lightBase": [0.930, 0.915, 0.880],
        ]
        let doctored = """
        The band tops out at `maximumTiltDegrees` (1.2°), over a
        `lightBase` (0.930, 0.915, 0.500) ground, with `minimumTiltDegres` (0.4°)
        at the other end. `rowOrdered` (a proximity walk over the y-sorted list)
        is prose. `promotedMarkWidth` (3 pt) is a figure this fixture does not
        declare.
        """
        let quoted = Self.quotedFigures(in: doctored)
        XCTAssertEqual(quoted.map(\.name),
                       ["maximumTiltDegrees", "lightBase", "minimumTiltDegres",
                        "promotedMarkWidth"],
            "Self-check: the figure parser must take exactly the numeric pairs and "
            + "leave the prose parenthetical alone. Got: \(quoted).")

        let mismatches = Self.calibrationMismatches(quoted: quoted, declared: declared)
        XCTAssertEqual(mismatches.count, 4,
            "Self-check: the drifted scalar, the drifted channel, the misspelt name "
            + "and the undeclared constant should all report. Got:\n"
            + mismatches.joined(separator: "\n"))
        XCTAssertTrue(mismatches.contains { $0.contains("maximumTiltDegrees") && $0.contains("1.2") },
            "Self-check: the drifted 1.2° — the real incident — must fire.")
        XCTAssertTrue(mismatches.contains { $0.contains("lightBase") },
            "Self-check: a triple that agrees on two channels and not the third "
            + "must fire, or the guard reads only the first number.")
        XCTAssertTrue(mismatches.contains { $0.contains("minimumTiltDegres") },
            "Self-check: a figure naming no constant must fire — otherwise a "
            + "rename silently removes a figure from this guard's sight.")

        XCTAssertTrue(Self.calibrationMismatches(
            quoted: Self.quotedFigures(in: "`maximumTiltDegrees` (1.0°) and "
                                       + "`lightBase` (0.930, 0.915, 0.880)."),
            declared: declared).isEmpty,
            "Self-check: correct figures must not fire, or the guard is a wall.")
    }
}
