import XCTest
import MaughamCore
@testable import Maugham

/// **One word per thing** (shell p5 Task 6): every surface says the project's
/// own word for a piece (`PieceNoun`), a round's vocabulary is one
/// vocabulary, and the words for surfaces the window no longer has (the
/// inspector, a pane, the desk, the corkboard) are gone from what the writer
/// and Claude read.
///
/// The censuses read Swift STRING LITERALS (`SwiftLiterals`), single-line,
/// multi-line and raw, never comments; an interpolation's code is not the
/// literal's text (it reads as `…`), but a string nested inside it is a
/// literal of its own. Each allow-list entry is a file and a PHRASE with its
/// reason: a literal passes only when every match lies inside an allowed
/// phrase of that file (a whole literal is a phrase too), so a new use in an
/// allowed file, or a new sentence in an allowed literal, is still caught.
/// Backticked spans are code and blanked only in MCP text (`withoutCode`).
final class WordingCensusTests: XCTestCase {

    // MARK: - The piece's noun is never hard-coded

    static let chapterPattern = try! NSRegularExpression(pattern: #"\b[Cc]hapters?\b"#)

    /// file → phrase → why it may say "chapter". `allFile` allows every
    /// literal in the file.
    static let chapterAllowed: [String: [String: String]] = [
        "Maugham/Stores/ProjectFactory.swift": [
            "Chapter 1": "the first piece's title in a new Novel — a title the writer renames, not a noun",
        ],
        // The publishing contract Claude reads (EMISSION.md), where these
        // three are the typesetter's word, not the writer's piece.
        "Maugham/Publish/EmissionContract.swift": [
            "# Chapter Title": "the Markdown heading example's sample text",
            "chapter-numbered class": "a LaTeX document class that numbers by `\\chapter`",
            #"`\\chapter`"#: "LaTeX's sectioning command, by name",
            "chapter breaks": "a typesetting term for where a new chapter's page begins",
        ],
        "Maugham/Views/PieceNoun.swift": [
            allFile: "the one noun function: where the word for a novel's piece is spelled",
        ],
        "Maugham/Publish/SamplePageSelection.swift": [
            "chapter opener — \\u{2018}…\\u{2019}": "a typographic term: the page that opens a chapter in the designer's sample set",
        ],
    ]

    /// The key that allows a whole file.
    static let allFile = "*"

    func test_noUserFacingStringHardCodesAPieceNoun() throws {
        let offenders = try Self.offenders(pattern: Self.chapterPattern, allowed: Self.chapterAllowed)
        XCTAssertEqual(offenders, [], "a string names a piece by a fixed noun — ask `PieceNoun.of`:\n"
                       + offenders.joined(separator: "\n"))
    }

    /// The control: a planted literal, single-line, multi-line and inside an
    /// interpolation, is caught; a comment, an identifier and an allowed
    /// literal are not.
    func test_theChapterCensusCatchesPlantedLiterals() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/Rogue.swift": #"""
            // No chapters yet — a comment, not a string.
            let chapters = ["a"]
            let a = "No chapters yet"
            let b = """
                Open this
                Chapter to rewind it
                """
            let c = "\(chapters.count) \(flag ? "chapter" : "piece")"
            let d = "Chapter 1"
            let e = #"a chapter's raw line"#
            """#,
            "Maugham/Stores/ProjectFactory.swift": #"let t = "Chapter 1""#,
        ])
        XCTAssertEqual(try Self.offenders(pattern: Self.chapterPattern, allowed: Self.chapterAllowed, base: base), [
            "Maugham/Views/Rogue.swift:3: No chapters yet",
            "Maugham/Views/Rogue.swift:4: \n    Open this\n    Chapter to rewind it\n    ",
            "Maugham/Views/Rogue.swift:8: chapter",
            "Maugham/Views/Rogue.swift:9: Chapter 1",
            "Maugham/Views/Rogue.swift:10: a chapter's raw line",
        ])
    }

    // MARK: - Each project kind reads its own noun

    /// One kind of project, as the surfaces see it, and what each must say.
    private struct Kind {
        let name: String
        let book: PieceNoun.Book
        /// A piece in it (its path decides a Collection's script).
        let item: StructureItem
        let singular: String
        let plural: String
        let newGroup: String
    }

    private static let prose = StructureItem(id: "doc-a", title: "Arrival", type: .document, path: "manuscript/a.md")
    private static let script = StructureItem(id: "doc-a", title: "Arrival", type: .document,
                                              path: "manuscript/a.fountain")

    private static let kinds: [Kind] = [
        Kind(name: "Novel", book: .init(type: .novel), item: prose,
             singular: "chapter", plural: "chapters", newGroup: "New Part"),
        Kind(name: "Short Story", book: .init(type: .shortStory), item: prose,
             singular: "story", plural: "stories", newGroup: "New Group"),
        Kind(name: "Collection", book: .init(type: .collection), item: prose,
             singular: "piece", plural: "pieces", newGroup: "New Group"),
        Kind(name: "Collection (a screenplay piece)", book: .init(type: .collection), item: script,
             singular: "script", plural: "scripts", newGroup: "New Group"),
        Kind(name: "Screenplay", book: .init(type: .screenplay), item: script,
             singular: "script", plural: "scripts", newGroup: "New Group"),
        Kind(name: "Report (sections)", book: .init(type: .novel, profile: .report), item: prose,
             singular: "section", plural: "sections", newGroup: "New Part"),
        Kind(name: "Report (one document)", book: .init(type: .shortStory, profile: .report), item: prose,
             singular: "section", plural: "sections", newGroup: "New Part"),
    ]

    /// **Every surface that names a piece says the project's own word**
    /// (shell p5 Task 6): a table over the kinds, through each surface's own
    /// pure function fed what the window feeds it (`PieceNoun.of` over the
    /// item and the manifest's kind). "Filed in Brief" names no piece (shell
    /// p4 Task 6a), so it has no row here.
    @MainActor
    func test_eachProjectKindReadsItsOwnNoun() {
        for kind in Self.kinds {
            let noun = PieceNoun.of(kind.item, in: kind.book)
            let bookNoun = PieceNoun.of(nil, in: kind.book)
            let w = kind.singular, ws = kind.plural, k = kind.name
            let note = ResolveItem.note(ProjectAnnotation(docId: "doc-a", annotation: Annotation(
                id: "n", kind: .comment, paragraphId: nil, body: "n", suggestedText: nil, priorText: nil,
                createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil, status: .open,
                userResponse: nil, resolvedAt: nil, isStale: false, triage: nil)))
            let groups = ResolveGrouping.groups(
                ResolveSnapshot(items: [note], sequences: ["doc-a": []], paragraphText: [:], unreadableDocIds: []),
                scope: .piece(docId: "doc-a", includesBookLevel: false), structure: [kind.item],
                sceneIndex: nil, sceneTitles: [], figureNames: [:], book: kind.book)
            XCTAssertEqual(groups.first?.title, "Whole \(w)", "To resolve's whole-piece group, \(k)")
            XCTAssertEqual(ResolveHead.openThePieceLine(noun: noun.singular, hasItemsToAnswer: true),
                           "Open this \(w) to answer its notes", k)
            XCTAssertEqual(HistoryPane.rewindSlot(.author, documentIsOpen: false, pieceNoun: noun.singular),
                           .openToRewind("Open this \(w) to rewind it"), k)
            XCTAssertEqual(ResolvePieceInLanguage.runScopeLine(noun: noun.singular, language: "es", preflight: nil),
                           "Translates this \(w) into \(LanguageName.title("es")).", k)
            XCTAssertEqual(TranslationRunState.runTitle(noun), "Translate This \(w.prefix(1).uppercased() + w.dropFirst())", k)
            if kind.item.path == Self.prose.path {
                XCTAssertEqual(ReviewBoardPane.emptyTitle(bookNoun), "No \(ws) yet", "the board, \(k)")
                XCTAssertEqual(EditionStatusView.emptyDescription(bookNoun),
                               "Add \(ws) and Status shows where each one stands in this edition.", k)
                XCTAssertEqual(WordsByChapterSection.title(bookNoun), "Words by \(w)", "Statistics, \(k)")
                XCTAssertEqual(WordsByChapterSection.title(bookNoun, rowsHoldGroups: true),
                               "Words by \(bookNoun.group ?? "group") and \(w)", "Statistics with Parts, \(k)")
                XCTAssertEqual(WordsByChapterSection.title(bookNoun, rowsHoldGroups: true, rowsAreAllGroups: true),
                               "Words by \(bookNoun.group ?? "group")", "Statistics, all Parts, \(k)")
                XCTAssertEqual(ResolveEditionItems.runScopeLine(count: 2, noun: bookNoun, imprint: nil),
                               "Translates every \(w) of the book: 2 \(ws).", k)
                XCTAssertEqual(BinderView.newPieceTitle(bookNoun), "New \(w.prefix(1).uppercased() + w.dropFirst())",
                               "the binder's New item, \(k)")
                XCTAssertEqual(BinderView.newGroupTitle(bookNoun), kind.newGroup, k)
                XCTAssertEqual(ResearchHomeMenu.moveTitle(noun: bookNoun),
                               "Move to \(w.prefix(1).uppercased() + w.dropFirst())", "research's Move to, \(k)")
                XCTAssertEqual(BriefPartView.emptyLine(bookNoun),
                               "No \(w) in this \(bookNoun.group ?? "group") has decided anything yet.",
                               "Brief's Part line, \(k)")
            }
        }
    }

    /// **One verb per round** (fix round 1, I2 and M7): the board's chip is
    /// "Run Gould's Round", the Source's clear line names the button by its
    /// title, and a cancelled translation is a cancelled round.
    func test_theRoundVocabularyIsOneVocabulary() {
        XCTAssertEqual(RoundNarrative.runRoundTitle(editorName: "Gould"), "Run Gould\u{2019}s Round")
        XCTAssertEqual(ReviewRoundCockpit.runTitle, "Run Round")
        XCTAssertEqual(DesignRoundState.runTitle, "Run Design")
        XCTAssertTrue(ResolveEditionItems.clearLine(language: "en", isSource: true, hasRounds: false)
                        .contains(DesignRoundState.runTitle + " above"))
        XCTAssertEqual(TranslationRunState.cancelledLine, "Round cancelled. Nothing was written.")
    }

    /// The board's worded open-notes heading fits its column (ADR 0038's
    /// "Open" became "Notes open").
    @MainActor
    func test_theBoardsNotesOpenHeadingFitsItsColumn() {
        XCTAssertEqual(ReviewBoardOpenNotes.columnHeading, "Notes open")
        let width = (ReviewBoardOpenNotes.columnHeading as NSString)
            .size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width
        XCTAssertLessThanOrEqual(width, ReviewBoardPane.openNotesColumnWidth)
        XCTAssertLessThanOrEqual(ReviewBoardPane.intrinsicWidth(passCount: 4), ProjectWindow.centreColumnFloor,
                                 "four passes still fit the centre's floor")
    }

    // MARK: - No retired word

    /// The surfaces the window no longer has, by the words the writer would
    /// look for: the inspector, a pane, the old department and desk, the
    /// translation review, the synopsis and corkboard, a to-do called a Task
    /// in a title, and the left column called "the tree" (it is the binder).
    static let retiredPattern = try! NSRegularExpression(pattern: [
        #"[Ii]nspector"#, #"\b[Pp]anes?\b"#, #"Department"#, #"\b[Dd]esk\b"#,
        #"[Tt]ranslation review"#, #"[Rr]eview pane"#, #"[Ss]ynops"#, #"[Cc]orkboard"#,
        #"\bTasks?\b"#, #"\b[Tt]he tree\b"#, #"\b(from|to|in) tree\b"#,
    ].joined(separator: "|"))

    /// file → literal text → why it may say a retired word. A word in
    /// backticks is code (a wire field, a key) and is never read
    /// (`withoutCode`).
    static let retiredAllowed: [String: [String: String]] = [
        "Maugham/Models/MaughamNotifications.swift": [
            "maugham.toggleInspector": "a notification's name — a key, never shown",
        ],
        "Maugham/Views/PieceWriters.swift": [
            "inspector.writtenBy": "an accessibility identifier — a key, never shown",
        ],
        "Maugham/Publish/TranslationCoverage.swift": [
            "synopsis": "the Fountain element `= synopsis` by its grammar's name, not the retired Synopses surface",
        ],
        "Maugham/Views/WelcomeCarousel.swift": [
            allFile: "the welcome tour is Task 9's to rewrite (shell p5 plan): it still names Synopses and a corkboard",
        ],
    ]

    func test_noAppStringUsesARetiredWord() throws {
        let offenders = try Self.offenders(pattern: Self.retiredPattern, allowed: Self.retiredAllowed)
        XCTAssertEqual(offenders, [], "a string names a surface the window no longer has:\n"
                       + offenders.joined(separator: "\n"))
    }

    /// **A to-do is a to-do wherever the writer reads** (fix round 1, I1):
    /// no app string says "task" in either case. MCP keeps `task` as the
    /// wire noun (tool and field names, and the prose that explains them),
    /// so `Maugham/MCP/` is outside this census.
    static let taskPattern = try! NSRegularExpression(pattern: #"\b[Tt]asks?\b"#)

    func test_noAppStringCallsAToDoATask() throws {
        let offenders = try Self.offenders(pattern: Self.taskPattern, allowed: [:], excluding: ["Maugham/MCP/"])
        XCTAssertEqual(offenders, [], "say \u{201C}to-do\u{201D}:\n" + offenders.joined(separator: "\n"))
    }

    /// Planted offender and control: a lowercase "task" in a view and in a
    /// log line is caught; MCP's wire noun, "to-do", "multitasking" and a
    /// comment are not; a backticked word in an app string is still read
    /// (only MCP text blanks code spans).
    func test_theTaskAndPhraseCensusCatchPlantedOffenders() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/Rogue.swift": #"""
            let a = "Accept as task"
            let b = "change the to-do"
            let c = "multitasking"
            // a task, in a comment
            let d = "the `chapter` here is shown"
            let e = "Chapter breaks and a chapter-numbered class"
            """#,
            "Maugham/MCP/Tools/Rogue.swift": #"let f = "List tasks; `chapter` is a field""#,
        ])
        XCTAssertEqual(try Self.offenders(pattern: Self.taskPattern, allowed: [:], excluding: ["Maugham/MCP/"],
                                          base: base),
                       ["Maugham/Views/Rogue.swift:1: Accept as task"])
        XCTAssertEqual(try Self.offenders(pattern: Self.chapterPattern,
                                          allowed: ["Maugham/Views/Rogue.swift": ["chapter-numbered class": "x"]],
                                          base: base),
                       ["Maugham/Views/Rogue.swift:5: the `chapter` here is shown",
                        "Maugham/Views/Rogue.swift:6: Chapter breaks and a chapter-numbered class"],
                       "an allowed phrase covers only its own match; the code span is read in an app string; "
                       + "MCP's backticked field is not")
    }

    /// **MCP descriptions are read as values** (`MCPToolCatalog.all`), so a
    /// description built by concatenation or interpolation is read whole,
    /// and a piece is never a chapter there either.
    func test_noMCPToolDescriptionUsesARetiredWordOrAFixedPieceNoun() {
        var offenders: [String] = []
        for tool in MCPToolCatalog.all {
            for (label, text) in [("description", tool.description), ("schema", tool.inputSchemaJSON)] {
                let prose = Self.withoutCode(text)
                for pattern in [Self.retiredPattern, Self.chapterPattern] where Self.matches(pattern, prose) {
                    offenders.append("\(tool.method) \(label): \(Self.firstMatch(pattern, prose))")
                }
            }
        }
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }

    func test_theRetiredWordPatternCatchesEverySpellingAndNoInnocentWord() {
        for planted in ["Toggle inspector column", "Opens the Intent pane", "Pane-created task",
                        "the Publish Department", "the desk", "translation review", "Review pane",
                        "Synopses", "an Outline corkboard", "Archive Done Tasks", "Change Task Status",
                        "Choose one in the tree.", "Canvas from tree", "Back to tree"] {
            XCTAssertTrue(Self.matches(Self.retiredPattern, planted), "missed: \(planted)")
        }
        for innocent in ["Panel", "off-desktop", "a task", "Desktop", "the publish tree",
                         "the binder", "panelled",
                         "deskew", "street"] {
            XCTAssertFalse(Self.matches(Self.retiredPattern, innocent), "flagged: \(innocent)")
        }
    }

    // MARK: - One noun function

    /// `func pieceNoun…(` or `func noun(` that names a piece, anywhere but
    /// `PieceNoun.swift`. Named exceptions name something that is not a piece.
    static let nounFunctionPattern = try! NSRegularExpression(
        pattern: #"\bfunc\s+(\w*[Pp]ieceNoun\w*|noun|nouns)\s*[(<]"#)

    /// file → why its noun function does not name a piece.
    static let nounFunctionAllowed: [String: String] = [
        "Maugham/Views/PieceNoun.swift": "the one noun function",
        "Maugham/Views/ResearchVersionsSection.swift":
            "`ResearchVersionsModel.noun(for:)` names a research item's kind (note, table), not a piece",
        "Maugham/Compiler/RulingPerformer.swift":
            "`RulingPerformer.noun(_:)` names a statement's kind (intent, ruling), not a piece",
    ]

    func test_oneNounFunction() throws {
        let offenders = try Self.nounFunctionOffenders(base: SourceTree.repoRoot)
        XCTAssertEqual(offenders, [], "a second noun function — make it a caller of `PieceNoun.of`:\n"
                       + offenders.joined(separator: "\n"))
    }

    /// Planted offender and control: a static and a private `pieceNoun`, and a
    /// `noun(` are caught; a property, a call and a comment are not.
    func test_theNounFunctionCensusCatchesPlantedOffenders() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/Rogue.swift": """
            static func pieceNoun(isScript: Bool) -> String { "" }
            private func noun(_ x: Int) -> String { "" }
            var pieceNoun: String? = nil
            let n = FiledUnder.pieceNoun(item)
            // func pieceNoun(item) -> String
            func chapterPieceNounWord() -> String { "" }
            """,
            "Maugham/Views/PieceNoun.swift": "static func of(_ item: Int) -> PieceNoun { .chapter }\nfunc noun() {}\n",
        ])
        XCTAssertEqual(try Self.nounFunctionOffenders(base: base), [
            "Maugham/Views/Rogue.swift:1",
            "Maugham/Views/Rogue.swift:2",
            "Maugham/Views/Rogue.swift:6",
        ])
    }

    static func nounFunctionOffenders(base: URL) throws -> [String] {
        var offenders: [String] = []
        for path in try SourceTree.swiftFiles(under: "Maugham", base: base)
        where nounFunctionAllowed[path] == nil {
            for line in SourceScan.numberedCodeLines(of: try SourceTree.read(path, base: base))
            where matches(nounFunctionPattern, line.text) {
                offenders.append("\(path):\(line.number)")
            }
        }
        return offenders.sorted()
    }

    // MARK: - The census

    /// Every string literal under `Maugham/` matching `pattern`, minus the
    /// allowed ones, as `path:line: text`.
    static func offenders(pattern: NSRegularExpression, allowed: [String: [String: String]],
                          excluding: [String] = [],
                          base: URL = SourceTree.repoRoot) throws -> [String] {
        var offenders: [String] = []
        for path in try SourceTree.swiftFiles(under: "Maugham", base: base) {
            let allowedHere = allowed[path] ?? [:]
            guard allowedHere[allFile] == nil else { continue }
            guard !excluding.contains(where: path.hasPrefix) else { continue }
            let isMCP = path.hasPrefix("Maugham/MCP/")
            for literal in SwiftLiterals.extract(try SourceTree.read(path, base: base)) {
                let text = isMCP ? withoutCode(literal.text) : literal.text
                if !allMatchesAllowed(pattern, in: text, phrases: Array(allowedHere.keys)) {
                    offenders.append("\(path):\(literal.line): \(literal.text)")
                }
            }
        }
        return offenders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Whether every match of `pattern` in `text` lies inside an occurrence
    /// of one of `phrases` (true when nothing matches).
    static func allMatchesAllowed(_ pattern: NSRegularExpression, in text: String, phrases: [String]) -> Bool {
        let ns = text as NSString
        var allowedRanges: [NSRange] = []
        for phrase in phrases where !phrase.isEmpty {
            var from = 0
            while from < ns.length {
                let found = ns.range(of: phrase, options: [], range: NSRange(location: from, length: ns.length - from))
                guard found.location != NSNotFound else { break }
                allowedRanges.append(found)
                from = found.location + max(found.length, 1)
            }
        }
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).allSatisfy { match in
            allowedRanges.contains { NSLocationInRange(match.range.location, $0)
                && NSMaxRange(match.range) <= NSMaxRange($0) }
        }
    }

    /// `text` with every backticked span blanked — for MCP text only, where
    /// a word in backticks is code: a wire field (`synopsis`), a tool's
    /// parameter, that keeps its name whatever the writer calls the thing.
    /// An app string is shown as written, so nothing in it is exempt.
    static func withoutCode(_ text: String) -> String {
        text.replacingOccurrences(of: #"`[^`\n]*`"#, with: "``", options: .regularExpression)
    }

    static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func firstMatch(_ pattern: NSRegularExpression, _ text: String) -> String {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return "" }
        let lower = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper])
    }
}

/// **A Swift file's string literals, with the line each opens on** — what a
/// wording census reads. Skips `//` and nested `/* */` comments; reads `"…"`,
/// `"""…"""` and raw strings (`#"…"#`, any number of `#`); keeps escapes as
/// written; an interpolation's code reads as `…` in its literal, and a string
/// inside it is a literal of its own. A multi-line literal's text is its raw
/// content, indentation included.
enum SwiftLiterals {
    struct Literal: Equatable {
        let line: Int
        let text: String
    }

    static func extract(_ source: String) -> [Literal] {
        enum Context { case code(parens: Int), string(multiline: Bool, hashes: Int) }
        let chars = Array(source.unicodeScalars)
        var out: [Literal] = []
        var stack: [Context] = [.code(parens: 0)]
        var open: [(line: Int, text: String)] = []
        var line = 1
        var i = 0
        func at(_ k: Int, _ c: Unicode.Scalar) -> Bool { k < chars.count && chars[k] == c }
        func run(_ c: Unicode.Scalar, from start: Int) -> Int {
            var n = 0
            while at(start + n, c) { n += 1 }
            return n
        }
        while i < chars.count {
            let c = chars[i]
            switch stack[stack.count - 1] {
            case .code(let parens):
                if c == "/" && at(i + 1, "/") {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/" && at(i + 1, "*") {
                    var depth = 0
                    repeat {
                        if at(i, "/") && at(i + 1, "*") { depth += 1; i += 2 }
                        else if at(i, "*") && at(i + 1, "/") { depth -= 1; i += 2 }
                        else { if chars[i] == "\n" { line += 1 }; i += 1 }
                    } while depth > 0 && i < chars.count
                    continue
                }
                if c == "#" || c == "\"" {
                    let hashes = run("#", from: i)
                    if at(i + hashes, "\"") {
                        let multiline = run("\"", from: i + hashes) >= 3
                        i += hashes + (multiline ? 3 : 1)
                        stack.append(.string(multiline: multiline, hashes: hashes))
                        open.append((line, ""))
                        continue
                    }
                    i += max(hashes, 1)
                    continue
                }
                if stack.count > 1 {
                    if c == "(" { stack[stack.count - 1] = .code(parens: parens + 1) }
                    else if c == ")" {
                        if parens == 0 { stack.removeLast(); i += 1; continue }
                        stack[stack.count - 1] = .code(parens: parens - 1)
                    }
                }
                if c == "\n" { line += 1 }
                i += 1
            case .string(let multiline, let hashes):
                let quotes = multiline ? 3 : 1
                if c == "\\" && run("#", from: i + 1) >= hashes {
                    let after = i + 1 + hashes
                    if at(after, "(") {
                        open[open.count - 1].text += "…"
                        i = after + 1
                        stack.append(.code(parens: 0))
                        continue
                    }
                    let end = min(after + 1, chars.count)
                    open[open.count - 1].text += String(String.UnicodeScalarView(chars[i..<end]))
                    i = end
                    continue
                }
                if c == "\"" && run("\"", from: i) >= quotes && run("#", from: i + quotes) >= hashes {
                    i += quotes + hashes
                    stack.removeLast()
                    let done = open.removeLast()
                    out.append(Literal(line: done.line, text: done.text))
                    continue
                }
                if c == "\n" { line += 1 }
                open[open.count - 1].text.unicodeScalars.append(c)
                i += 1
            }
        }
        return out
    }
}
