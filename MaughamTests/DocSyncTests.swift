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

    /// Enumerates `.keyboardShortcut("N", modifiers: [.command, .option])`
    /// occurrences in a source string, returning each as a `⌘⌥N` token.
    static func extractCommandOptionShortcutTokens(from sourceText: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\.keyboardShortcut\("([^"]+)",\s*modifiers:\s*\[\.command,\s*\.option\]\)"#
        ) else { return [] }
        let ns = sourceText as NSString
        let matches = regex.matches(in: sourceText, range: NSRange(location: 0, length: ns.length))
        return matches.map { "⌘⌥" + ns.substring(with: $0.range(at: 1)) }
    }

    /// Returns the subset of `tokens` that do NOT appear anywhere in `docText`.
    static func missingTokens(_ tokens: [String], in docText: String) -> [String] {
        tokens.filter { !docText.contains($0) }
    }

    func test_detailPaneToggleShortcutsDocumentedInReferenceMd() throws {
        let sourceText = try readFile("Maugham/Views/DetailPaneToggle.swift")
        let tokens = Self.extractCommandOptionShortcutTokens(from: sourceText)
        guard !tokens.isEmpty else {
            XCTFail("No .keyboardShortcut(\"N\", modifiers: [.command, .option]) occurrences found in "
                + "DetailPaneToggle.swift — source structure changed? (regex may need updating)")
            return
        }

        let referenceMd = try readFile("docs/guide/reference.md")
        let missing = Self.missingTokens(tokens, in: referenceMd)
        XCTAssertTrue(missing.isEmpty,
            "DetailPaneToggle.swift defines keyboard shortcut(s) \(missing) that are not documented "
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

    // MARK: - Test 3: DetailSegment case names mentioned in right-pane.md

    /// Enumerates `case <name>` lines from the `DetailSegment` enum source.
    static func extractEnumCaseNames(from sourceText: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*case\s+(\w+)"#) else { return [] }
        let ns = sourceText as NSString
        let matches = regex.matches(in: sourceText, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Case-insensitive substring check: each case name's raw spelling
    /// (e.g. "inbox") must appear somewhere in the doc text (e.g. "Inbox").
    static func missingCaseMentions(_ names: [String], in docText: String) -> [String] {
        let lowered = docText.lowercased()
        return names.filter { !lowered.contains($0.lowercased()) }
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

        let doctoredDoc = "The right column has modes: Inspector, Research, Outline, Tasks, Annotations, History, Palette, Translation."
        let missing = Self.missingCaseMentions(caseNames, in: doctoredDoc)
        XCTAssertEqual(missing, ["inbox"],
            "Self-check expected exactly the omitted \"inbox\" case to be reported missing. Got: \(missing).")
    }
}
