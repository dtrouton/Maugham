import XCTest
import AppKit
@testable import Maugham

/// **What the writer and Claude read describes the window that ships**
/// (shell p5 Task 8). The bundled guide (`docs/guide/`, shown by Help and
/// served by `get_help`), the skills Claude reads (`docs/skills/`), the
/// sample projects and the two syntax sheets may not name a surface the
/// window no longer has: a persona or mode, the Inspector, the Department
/// desk, the translation review pane, a retired pane, This Piece / All
/// Pieces, ⌘4, a segment, Pull Up Previous, Lock Research or Toggle Review
/// Mode.
///
/// Every file in the corpus is read line by line, prose and code alike: a
/// retired word in a code span still sends the reader looking for it. An
/// allow-list entry names a file and a phrase with its reason; a file allowed
/// whole is one another task rewrites, and says which.
final class HelpWordsCensusTests: XCTestCase {
    /// The bundled corpus: directories walked whole, and single files.
    static let corpusDirectories = ["docs/guide", "docs/skills", "Maugham/Resources/Samples"]
    /// The syntax sheets: every `*-syntax.md` directly in this directory.
    static let syntaxSheetDirectory = "Maugham/Resources"
    static let textExtensions: Set<String> = ["md", "json", "fountain", "txt"]

    /// Each retired word, by the name a report uses, with its pattern.
    static let retired: [(name: String, pattern: String)] = [
        ("persona", #"[Pp]ersona(?!l|t)"#),
        ("mode by persona name", #"\b(Plan|Author|Review|Publish) ([Pp]ersona|[Mm]ode)\b"#),
        ("in a persona", #"\bin (Plan|Author|Review|Publish)\b(?! [Pp]asses)"#),
        ("Inspector", #"[Ii]nspector"#),
        ("Department", #"\bDepartment\b"#),
        ("desk", #"\b[Dd]esks?\b"#),
        ("translation review", #"\b[Tt]ranslation[ -][Rr]eview\b"#),
        ("review pane", #"\b[Rr]eview pane\b"#),
        ("retired pane", #"\b(Annotations|Diagnostics|Tasks|Intent|References|History|Translation|Inbox|Outline) [Pp]anes?\b"#),
        ("This Piece / All Pieces", #"\b(This Piece|All Pieces)\b"#),
        ("⌘4", #"⌘4"#),
        ("segment", #"\b[Ss]egment(s|ed)?\b"#),
        ("Pull Up Previous", #"Pull Up Previous"#),
        ("Lock Research", #"Lock Research"#),
        ("Toggle Review Mode", #"Toggle Review Mode|\b[Rr]eview [Mm]ode\b"#),
        // The owner's own name never ships in help (the lead's ruling, shell p5
        // Task 8 fix round 2): examples use Alex, Alex Moreno and Sam.
        ("the owner's name", #"(?i)\b(denver|trouton)\b"#),
        // Shell p5 Task 9: the rest of the window's old vocabulary, and the
        // owner's own books, which an example must not borrow.
        ("pane", #"\b[Pp]anes?\b"#),
        ("the tree", #"\b[Tt]he tree\b|\b(from|to|in) tree\b"#),
        ("the owner's own book", #"\b[Pp]laylist\b|Good Luck Babe|\bglb\b"#),
    ]

    /// The key that allows a whole file.
    static let allFile = "*"

    /// file → phrase → why it may say a retired word.
    static let allowed: [String: [String: String]] = [
        "Maugham/Resources/fountain-syntax.md": [
            "Marlowe sits at his desk.": "a scene's action line in the syntax example, not the retired desk",
        ],
    ]

    func test_noBundledHelpUsesARetiredWord() throws {
        let found = try Self.offenders()
        XCTAssertEqual(found, [], "bundled help names a surface the window no longer has "
                       + "(\(found.count) lines; by word: \(Self.countsByWord(found))):\n"
                       + found.joined(separator: "\n"))
    }

    // MARK: - The census

    static let patterns: [(name: String, regex: NSRegularExpression)] = retired.map {
        ($0.name, try! NSRegularExpression(pattern: $0.pattern))
    }

    /// Every corpus file read from `base`, repo-relative, sorted. Throws when
    /// the corpus is empty: a ban over nothing passes over anything.
    static func corpus(base: URL = SourceTree.repoRoot) throws -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        for dir in corpusDirectories {
            let root = base.appendingPathComponent(dir, isDirectory: true).resolvingSymlinksInPath()
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where textExtensions.contains(url.pathExtension) {
                let path = url.resolvingSymlinksInPath().path
                paths.append(dir + "/" + path.dropFirst(root.path.count + 1))
            }
        }
        let sheets = base.appendingPathComponent(syntaxSheetDirectory, isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: sheets.path)) ?? [] where name.hasSuffix("-syntax.md") {
            paths.append(syntaxSheetDirectory + "/" + name)
        }
        guard !paths.isEmpty else {
            throw SourceTree.LookupError(description: "the help corpus under \(base.path) is empty")
        }
        return paths.sorted()
    }

    /// Each offending line as `path:line: [word] text`, minus the allowed.
    static func offenders(base: URL = SourceTree.repoRoot,
                          allowed: [String: [String: String]] = allowed) throws -> [String] {
        var found: [String] = []
        for path in try corpus(base: base) {
            let allowedHere = allowed[path] ?? [:]
            guard allowedHere[allFile] == nil else { continue }
            let text = try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                for (name, regex) in patterns
                where !WordingCensusTests.allMatchesAllowed(regex, in: line, phrases: Array(allowedHere.keys)) {
                    found.append("\(path):\(index + 1): [\(name)] "
                                 + line.trimmingCharacters(in: .whitespaces).prefix(160))
                }
            }
        }
        return found
    }

    /// "word: count" for each retired word that has offenders, in table order.
    static func countsByWord(_ found: [String]) -> String {
        retired.compactMap { entry in
            let n = found.filter { $0.contains("[\(entry.name)]") }.count
            return n == 0 ? nil : "\(entry.name) \(n)"
        }.joined(separator: ", ")
    }

    // MARK: - Planted offenders and the control

    /// One planted line per retired word, each caught under its own name; a
    /// control of true sentences that pass; and an allow-list that covers
    /// only what it names.
    func test_theCensusCatchesEveryPlantedWordAndPassesTrueSentences() throws {
        let planted = [
            "Switch to the Plan persona.",
            "Open it in Review mode.",
            "Do this in Publish first.",
            "The Inspector shows the synopsis.",
            "The Publish Department compiles it.",
            "Press Compile on the desk.",
            "Turn on translation review.",
            "The review pane lists them.",
            "The Annotations pane lists notes.",
            "Choose This Piece or All Pieces.",
            "Press ⌘4 for Publish.",
            "Pick its segment above.",
            "Choose View ▸ Pull Up Previous.",
            "Choose Lock Research and Figures.",
            "Choose Toggle Review Mode.",
            "This Mac is on DENVER's chain; recognised as Denver Trouton.",
            "The right-hand pane lists them.",
            "Drag it in the tree.",
            "Compile Playlist-v1.0.pdf for the special-glb imprint.",
            "A desk lamp.",
        ]
        XCTAssertEqual(planted.count, Self.retired.count + 1,
                       "one planted line per retired word, and a second desk line for the allow-list control")
        let control = """
        # Writing with Claude
        Claude Desktop reads your book. The History of a chapter is pulled up with ⌃⌘H.
        A translated edition is read in Serbian; reviewing a draft is a pass.
        The desktop app, a deskilled reader and a segmentation fault are not the words.
        Planning comes first, then you author a chapter, review it and publish the book.
        The ladder is explained in Review Passes; Alex Moreno and Sam share the book.
        A window panel, a treetop and the binder's Research section; Lighthouse-v1.0.pdf.
        """
        let base = try SourceTree.plantedTree([
            "docs/guide/rogue.md": planted.joined(separator: "\n"),
            "docs/guide/clean.md": control,
            "docs/guide/index.json": #"[{"slug":"clean","title":"Writing with Claude","order":1}]"#,
            "docs/skills/rogue-skill/SKILL.md": "Open the Inspector.",
            "Maugham/Resources/Samples/novel/ch1.md": "She sat at her desk.",
            "Maugham/Resources/markdown-syntax.md": "Use the Tasks pane.",
            "Maugham/Resources/fountain-syntax.md": "INT. HOUSE — DAY",
            "Maugham/Resources/screenplay-syntax.md": "Open the review mode.",
        ])
        let found = try Self.offenders(base: base, allowed: [:])
        for (index, entry) in Self.retired.enumerated() {
            XCTAssertTrue(found.contains { $0.hasPrefix("docs/guide/rogue.md:\(index + 1): [\(entry.name)]") },
                          "planted line \(index + 1) is not caught as \(entry.name): \(found)")
        }
        XCTAssertFalse(found.contains { $0.hasPrefix("docs/guide/clean.md") },
                       "a true sentence was reported: \(found.filter { $0.hasPrefix("docs/guide/clean.md") })")
        XCTAssertTrue(found.contains { $0.hasPrefix("docs/skills/rogue-skill/SKILL.md:1: [Inspector]") },
                      "the skills are in the corpus")
        XCTAssertTrue(found.contains { $0.hasPrefix("Maugham/Resources/Samples/novel/ch1.md:1: [desk]") },
                      "the samples are in the corpus")
        XCTAssertTrue(found.contains { $0.hasPrefix("Maugham/Resources/markdown-syntax.md:1: [retired pane]") },
                      "the syntax sheets are in the corpus")
        XCTAssertTrue(found.contains { $0.hasPrefix("Maugham/Resources/screenplay-syntax.md:1: [Toggle Review Mode]") },
                      "every *-syntax.md sheet is in the corpus, and lower-case review mode is caught")

        // An allowed phrase covers its own match only; a whole-file entry covers the file.
        let narrowed = try Self.offenders(base: base, allowed: [
            "Maugham/Resources/Samples/novel/ch1.md": ["at her desk": "a sample's prose"],
            "docs/skills/rogue-skill/SKILL.md": [Self.allFile: "rewritten elsewhere"],
            "docs/guide/rogue.md": ["the desk": "x"],
        ])
        XCTAssertFalse(narrowed.contains { $0.hasPrefix("Maugham/Resources/Samples/") })
        XCTAssertFalse(narrowed.contains { $0.hasPrefix("docs/skills/") })
        XCTAssertFalse(narrowed.contains { $0.hasPrefix("docs/guide/rogue.md:6:") },
                       "the allowed phrase covers its match")
        XCTAssertTrue(narrowed.contains { $0.hasPrefix("docs/guide/rogue.md:\(planted.count): [desk]") },
                      "an allowed phrase covers no other line holding the same word")
    }

    // MARK: - What Claude and the tour read as values (shell p5 Task 9)

    /// The texts read as values, not files: the welcome tour's cards and
    /// every MCP tool's description and input schema, straight from
    /// `MCPToolCatalog.all`, so a description assembled from pieces is read
    /// whole. (The `initialize` response carries no server instructions; the
    /// bootstrap skill is in the file corpus.)
    static func valueCorpus() -> [(source: String, text: String)] {
        var values: [(source: String, text: String)] = []
        for slide in WelcomeSlide.all {
            values.append(("WelcomeSlide.\(slide.id.rawValue).heading", slide.heading))
            values.append(("WelcomeSlide.\(slide.id.rawValue).body", slide.body))
        }
        for tool in MCPToolCatalog.all {
            values.append(("\(tool.method).description", tool.description))
            values.append(("\(tool.method).inputSchema", tool.inputSchemaJSON))
        }
        return values
    }

    /// Each offending value as `source: [word] text`.
    static func valueOffenders(_ values: [(source: String, text: String)]) -> [String] {
        var found: [String] = []
        for (source, text) in values {
            for (name, regex) in patterns
            where regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                found.append("\(source): [\(name)] " + text.prefix(160))
            }
        }
        return found
    }

    func test_noTourCardOrMCPDescriptionUsesARetiredWord() {
        let values = Self.valueCorpus()
        XCTAssertEqual(values.count, 2 * WelcomeSlide.all.count + 2 * MCPToolCatalog.all.count)
        XCTAssertGreaterThan(MCPToolCatalog.all.count, 40, "premise: the catalog is read")
        let found = Self.valueOffenders(values)
        XCTAssertEqual(found, [], "a tour card or an MCP description names a surface the window no longer has "
                       + "(\(found.count); by word: \(Self.countsByWord(found))):\n" + found.joined(separator: "\n"))
    }

    func test_theValueCensusCatchesAPlantedValue() {
        let found = Self.valueOffenders([
            ("planted.description", "Shows in the Inspector."),
            ("control.description", "Shows in To resolve, beside the text, and in the chapter's fold in the binder."),
        ])
        XCTAssertEqual(found.count, 1, "\(found)")
        XCTAssertTrue(found.first?.hasPrefix("planted.description: [Inspector]") == true, "\(found)")
    }

    // MARK: - Every key the samples and the tour name is a real one

    /// Every key token in `text` (⌘, ⌃, ⌥ or ⇧ then a key), spelled as the
    /// menu walk spells it: ⌘ first, then ⌃⌥⇧, the key uppercased.
    static func keyTokens(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"[⌘⌃⌥⇧]+(Space|[A-Za-z0-9\\/\[\],.?↩↓↑←→=-])"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let whole = ns.substring(with: match.range)
            let key = ns.substring(with: match.range(at: 1))
            var token = ""
            for glyph in ["⌘", "⌃", "⌥", "⇧"] where whole.contains(glyph) { token += glyph }
            return token + key.uppercased()
        }
    }

    /// The tokens in each corpus text that are not in `bound`, as `where: token`.
    static func unboundKeys(_ texts: [(source: String, text: String)], bound: Set<String>) -> [String] {
        texts.flatMap { source, text in
            keyTokens(in: text).filter { !bound.contains($0) }.map { "\(source): \($0)" }
        }
    }

    /// **A sample names only keys the menus bind** — the real menu bar,
    /// walked as `MenuBarCensusTests` walks it.
    @MainActor
    func test_everyKeyASampleNamesIsBoundByTheMenus() throws {
        let bound = Set(MenuBarCensusTests.walk(NSApp.mainMenu).compactMap(\.token))
        XCTAssertTrue(bound.contains("⌘S"), "premise: the walk reached the app's menus")
        let samples = try Self.corpus().filter { $0.hasPrefix("Maugham/Resources/Samples/") }
        XCTAssertGreaterThanOrEqual(samples.count, 4, "premise: the samples are read")
        let texts = try samples.map { ($0, try SourceTree.read($0)) }
        XCTAssertGreaterThan(texts.flatMap { Self.keyTokens(in: $0.1) }.count, 5, "premise: the samples name keys")
        XCTAssertEqual(Self.unboundKeys(texts, bound: bound), [], "a sample names a key no menu item binds")
    }

    /// **No tour card names a key the cheat sheet does not list.**
    func test_everyKeyATourCardNamesIsOnTheCheatSheet() {
        let listed = Set(KeyboardShortcuts.all.flatMap(\.items).map(\.shortcut))
        let cards = WelcomeSlide.all.map { ("WelcomeSlide.\($0.id.rawValue)", $0.heading + " " + $0.body) }
        XCTAssertEqual(Self.unboundKeys(cards, bound: listed), [], "a tour card names a key the ⌘/ sheet does not list")
    }

    /// The control: modifiers in either order, the punctuation keys, and an
    /// unbound key caught; a lone ⌘ glyph and plain prose are not tokens.
    func test_theKeyCensusReadsTokensAsTheMenuSpellsThem() {
        XCTAssertEqual(Self.keyTokens(in: "Press ⌃⌘H, then ⌘⌥t, ⌘\\ and ⌘/; ⌘ alone is no key."),
                       ["⌘⌃H", "⌘⌥T", "⌘\\", "⌘/"])
        XCTAssertEqual(Self.unboundKeys([("planted.md", "Press ⌘⌥⇧9 or ⌘S.")], bound: ["⌘S"]),
                       ["planted.md: ⌘⌥⇧9"])
    }
}
