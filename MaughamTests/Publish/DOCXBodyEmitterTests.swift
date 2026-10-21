import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Report plan 4, Task 3: the OOXML body emitter turns one body's AST and
/// resolution into `word/document.xml`, `word/footnotes.xml`, the image
/// relationships and the media list the packager copies. Every part is read
/// back through `XMLDocument`, so a test asserts what Word gets, not a string
/// that happens to contain the right letters.
final class DOCXBodyEmitterTests: XCTestCase {

    // MARK: - fixtures

    /// A book of pieces, each `(id, paragraphs)`; display text is the join,
    /// so the paragraphs reconcile and every node carries its `¶id`.
    private struct Book: ProjectASTBuilder.Source {
        let pieces: [(id: String, paragraphs: [(id: String, text: String)])]
        var mode: ProjectAST.Mode = .prose
        var context: PublishContext = .empty
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            pieces.map { piece in
                .init(pieceID: piece.id, title: "Title \(piece.id)", mode: mode,
                      displayText: piece.paragraphs.map(\.text).joined(separator: "\n\n"),
                      paragraphs: piece.paragraphs)
            }
        }
        func publishContext() -> PublishContext { context }
    }

    private static func context(library: [ResearchItem] = []) -> PublishContext {
        PublishContext(library: CitationLibrary(items: library), profile: .report,
                       switches: (numberSections: true, listOfFigures: false, listOfTables: false),
                       projectURL: nil, piecePaths: [:])
    }

    private struct Emitted {
        let ast: ProjectAST
        let resolution: PublishResolution
        let body: DOCXBody
        let document: XMLDocument
        let footnotes: XMLDocument
    }

    /// One body of `book`: resolved over the whole book, emitting `subset`
    /// of it (all of it by default).
    private func body(_ book: Book, figureFiles: [String: [Int: URL]] = [:], bodyTag: String? = nil,
                      emitting subset: (ProjectAST) -> ProjectAST = { $0 }) throws -> DOCXBodyEmitter.Body {
        let ast = try ProjectASTBuilder.build(from: book)
        let resolution = PublishResolution.resolve(ast, context: book.context, bodyTag: nil,
                                                   imageAllowed: ["png", "pdf", "svg"])
        return DOCXBodyEmitter.Body(ast: subset(ast), resolution: resolution, bodyTag: bodyTag,
                                    figureFiles: figureFiles)
    }

    private func emit(_ book: Book, figureFiles: [String: [Int: URL]] = [:],
                      emitting subset: (ProjectAST) -> ProjectAST = { $0 }) throws -> Emitted {
        try emit([body(book, figureFiles: figureFiles, emitting: subset)])
    }

    private func emit(_ bodies: [DOCXBodyEmitter.Body]) throws -> Emitted {
        let body = DOCXBodyEmitter.emit(bodies: bodies, config: PublishConfig())
        let ast = bodies[0].ast
        let resolution = bodies[0].resolution
        let document = try XMLDocument(xmlString: Self.keepingSpaces(body.documentXML))
        let footnotes = try XMLDocument(xmlString: Self.keepingSpaces(body.footnotesXML))
        return Emitted(ast: ast, resolution: resolution, body: body,
                       document: document, footnotes: footnotes)
    }

    /// NSXML drops a whitespace-only text node under every option, so a
    /// `<w:t xml:space="preserve"> </w:t>` (which Word keeps) would read as
    /// empty: its spaces are parked in a private-use character for the parse
    /// and `text` turns them back.
    private static let parkedSpace: Character = "\u{E000}"
    private static func keepingSpaces(_ xml: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"(<w:t xml:space="preserve">)( +)(</w:t>)"#)
        let ns = xml as NSString
        var out = xml
        for m in pattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)).reversed() {
            let spaces = String(repeating: parkedSpace, count: m.range(at: 2).length)
            out = (out as NSString).replacingCharacters(in: m.range(at: 2), with: spaces)
        }
        return out
    }

    private func nodes(_ doc: XMLDocument, _ xpath: String) throws -> [XMLElement] {
        try doc.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
    }

    private func attr(_ e: XMLElement, _ name: String) -> String? {
        e.attribute(forName: name)?.stringValue
    }

    /// The visible text of an element: every `w:t`, in order.
    private func text(_ e: XMLElement) throws -> String {
        descendants(e, "w:t").compactMap(\.stringValue).joined()
            .replacingOccurrences(of: String(Self.parkedSpace), with: " ")
    }

    /// Every descendant element named `name`, in document order. Walked by
    /// hand: NSXML's element-relative `.//` XPath reads past the context
    /// node when it is the last of its siblings.
    private func descendants(_ e: XMLElement, _ name: String) -> [XMLElement] {
        (e.children ?? []).compactMap { $0 as? XMLElement }.flatMap { child in
            (child.name == name ? [child] : []) + descendants(child, name)
        }
    }

    /// The text a paragraph's bookmark `name` wraps, read in document order.
    private func bookmarked(_ name: String, in doc: XMLDocument) throws -> String? {
        for p in try paragraphs(doc) {
            var id: String?
            var text = ""
            for child in (p.children ?? []).compactMap({ $0 as? XMLElement }) {
                if child.name == "w:bookmarkStart", attr(child, "w:name") == name { id = attr(child, "w:id"); continue }
                if child.name == "w:bookmarkEnd", id != nil, attr(child, "w:id") == id { return text }
                if id != nil { text += try self.text(child) }
            }
        }
        return nil
    }

    /// Each REF field in `p`: the bookmark it names and the result it carries.
    private func references(in p: XMLElement) throws -> [(name: String, result: String)] {
        var out: [(String, String)] = []
        var name: String?
        var result: String?
        for run in (p.children ?? []).compactMap({ $0 as? XMLElement }) where run.name == "w:r" {
            if let instr = descendants(run, "w:instrText").first?.stringValue, instr.hasPrefix(" REF ") {
                name = String(instr.dropFirst(5).prefix { $0 != " " })
            }
            switch descendants(run, "w:fldChar").first.flatMap({ attr($0, "w:fldCharType") }) {
            case "separate": result = ""
            case "end":
                if let n = name, let r = result { out.append((n, r)) }
                name = nil; result = nil
            default: if result != nil { result! += try text(run) }
            }
        }
        return out
    }

    private func paragraphs(_ doc: XMLDocument) throws -> [XMLElement] {
        try nodes(doc, "//*[name()='w:body']//*[name()='w:p']")
    }

    private func style(_ p: XMLElement) throws -> String? {
        try nodes(p, "./*[name()='w:pPr']/*[name()='w:pStyle']").first.flatMap { attr($0, "w:val") }
    }

    /// An element-relative path, evaluated by hand (see `descendants`):
    /// `.//*[name()='x']`, or child steps `./*[name()='a']/*[name()='b']`
    /// whose last step may carry `[@*[name()='attr']='value']`.
    private func nodes(_ e: XMLElement, _ xpath: String) throws -> [XMLElement] {
        let step = try NSRegularExpression(
            pattern: #"\*\[name\(\)='([^']+)'\](?:\[@\*\[name\(\)='([^']+)'\]='([^']*)'\])?"#)
        func parse(_ s: String) -> (name: String, attr: (String, String)?) {
            let ns = s as NSString
            let m = step.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))!
            let name = ns.substring(with: m.range(at: 1))
            guard m.range(at: 2).location != NSNotFound else { return (name, nil) }
            return (name, (ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 3))))
        }
        if xpath.hasPrefix(".//") { return descendants(e, parse(String(xpath.dropFirst(3))).name) }
        var current = [e]
        for raw in xpath.dropFirst(2).split(separator: "/") {
            let (name, predicate) = parse(String(raw))
            current = current.flatMap { ($0.children ?? []).compactMap { $0 as? XMLElement } }
                .filter { element in
                    element.name == name && (predicate.map { attr(element, $0.0) == $0.1 } ?? true)
                }
        }
        return current
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("DOCXBody-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A one-page PDF of `width`×`height` points.
    private func pdf(width: CGFloat, height: CGFloat) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("DOCXBody-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func label(_ reference: String) -> ManuscriptLabel { ManuscriptLabel(reference: reference)! }

    /// Every report construct and every prose arm, in one piece.
    private func everyArm() throws -> (Book, [String: [Int: URL]]) {
        let chart = try file("chart.png", Self.png(width: 8, height: 4))
        let smith = ResearchItem(id: "r-smith", title: "Annual Report", type: .asset,
                                 citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                                        sourceTitle: "Annual Report", year: 2026))
        let book = Book(pieces: [("a", [
            ("a1b2", "# Introduction {#sec:intro}"),
            ("c3d4", "Plain *em* **strong** ~~gone~~ `code` and [[Wiki|shown]] text[^1]."),
            ("e5f6", "> A quoted line."),
            ("g7h8", "* * *"),
            ("j9k0", "- one\n- two"),
            ("m2n3", "1. first\n2. second"),
            ("p4q5", "```\nlet x = 1\nlet y = 2\n```"),
            ("r6s7", "| Quarter | Sales |\n|:--|--:|\n| Q1 | 100 |\nTable: Sales by quarter {#tbl:sales}"),
            ("t8v9", "![Revenue](chart.png){#fig:rev}"),
            ("w2x3", "See @fig:rev, @tbl:sales and @sec:intro [@smith2026, p. 3]."),
            ("y4z5", "## Detail"),
            ("b6c7", "[^1]: The first note."),
        ])], context: Self.context(library: [smith]))
        return (book, ["a": [8: chart]])
    }

    // MARK: - DOCXNames (R-4-3)

    func test_paragraphBookmark_isPPrefixed_andLegalForADigitLeadingId() {
        XCTAssertEqual(DOCXNames.paragraphBookmark("k3wq"), "p_k3wq")
        XCTAssertEqual(DOCXNames.paragraphBookmark("3abc"), "p_3abc",
                       "a ¶id may start with a digit; the name never does")
        XCTAssertEqual(DOCXNames.paragraphBookmark("a-b.c"), "p_a_b_c", "illegal characters map to _")
        XCTAssertEqual(DOCXNames.paragraphBookmark("é"), "p__")
        XCTAssertEqual(DOCXNames.paragraphBookmark("k3wq", bodyTag: "sr"), "p_sr_k3wq")
    }

    func test_labelBookmark_isKindQualified_andLegal() {
        XCTAssertEqual(DOCXNames.labelBookmark(label("fig:rev")), "l_fig_rev")
        XCTAssertEqual(DOCXNames.labelBookmark(label("tbl:q-3")), "l_tbl_q_3")
        XCTAssertEqual(DOCXNames.labelBookmark(label("sec:9lives")), "l_sec_9lives")
        XCTAssertEqual(DOCXNames.labelBookmark(label("fig:rev"), bodyTag: "pt-BR"), "l_pt_BR_fig_rev")
    }

    func test_aNameOverFortyCharacters_isTruncatedToThirtyOnePlusAHash() {
        let long = label("fig:" + String(repeating: "revenue", count: 7))
        let name = DOCXNames.labelBookmark(long)
        XCTAssertEqual(name.count, 40)
        XCTAssertTrue(name.hasPrefix(String("l_fig_\(long.name)".prefix(31)) + "_"), name)
        XCTAssertNotNil(name.range(of: "_[0-9a-f]{8}$", options: .regularExpression), name)
        XCTAssertEqual(DOCXNames.labelBookmark(long), name, "deterministic")

        // Two names sharing their first 31 characters, and two differing only
        // in `-` against `_`, still get different hashes.
        let sibling = label("fig:" + String(repeating: "revenue", count: 7) + "x")
        XCTAssertNotEqual(DOCXNames.labelBookmark(sibling), name)
        let dashed = label("fig:" + String(repeating: "re-venue", count: 6))
        let underscored = label("fig:" + String(repeating: "re_venue", count: 6))
        XCTAssertNotEqual(DOCXNames.labelBookmark(dashed), DOCXNames.labelBookmark(underscored))
        for n in [name, DOCXNames.labelBookmark(dashed)] {
            XCTAssertTrue(DOCXNames.isLegal(n), n)
        }
    }

    func test_disambiguated_appendsACounter_withinForty() {
        XCTAssertEqual(DOCXNames.disambiguated("l_fig_a_b", counter: 2), "l_fig_a_b_2")
        let forty = String(repeating: "a", count: 40)
        let bumped = DOCXNames.disambiguated(forty, counter: 12)
        XCTAssertEqual(bumped.count, 40)
        XCTAssertTrue(bumped.hasSuffix("_12"))
    }

    func test_isLegal_isWordsRule() {
        XCTAssertTrue(DOCXNames.isLegal("p_k3wq"))
        XCTAssertFalse(DOCXNames.isLegal("3abc"))
        XCTAssertFalse(DOCXNames.isLegal("a-b"))
        XCTAssertFalse(DOCXNames.isLegal(String(repeating: "a", count: 41)))
    }

    // MARK: - escaping

    func test_escape_coversTheFiveMarkupCharacters_andDropsIllegalControls() {
        XCTAssertEqual(OOXMLEscape.text("a & b < c > d \" e"), "a &amp; b &lt; c &gt; d &quot; e")
        XCTAssertEqual(OOXMLEscape.text("x\u{1}y\u{B}z\u{FFFE}w\u{FFFF}"), "xyzw")
        XCTAssertEqual(OOXMLEscape.text("tab\tnl\ncr\r"), "tab\tnl\ncr\r", "XML's own whitespace stays")
        XCTAssertEqual(OOXMLEscape.attribute("a\tb\nc\"d"), "a&#9;b&#10;c&quot;d")
    }

    func test_bodyText_isEscaped_controlsDropped_andTabsAreWordTabs() throws {
        let e = try emit(Book(pieces: [("a", [("a1b2", "A & B <c> \"d\"\u{1}\u{7} e\tf")])],
                              context: Self.context()))
        let p = try XCTUnwrap(paragraphs(e.document).last)
        XCTAssertEqual(try text(p), "A & B <c> \"d\" ef")
        XCTAssertEqual(try nodes(p, ".//*[name()='w:tab']").count, 1)
        XCTAssertFalse(e.body.documentXML.contains("\u{1}"))
    }

    // MARK: - every arm

    func test_everyArm_isWellFormed_andMapsToItsWordConstruct() throws {
        let (book, figures) = try everyArm()
        let e = try emit(book, figureFiles: figures)
        let ps = try paragraphs(e.document)
        let styled = try ps.map { (try style($0), try text($0)) }

        // Piece title, then the numbered `#` as Heading1 with its number.
        XCTAssertEqual(styled[0].0, "Heading1")
        XCTAssertEqual(styled[0].1, "Title a")
        XCTAssertEqual(styled[1].0, "Heading1")
        XCTAssertEqual(styled[1].1, "1 Introduction")
        XCTAssertTrue(styled.contains { $0.0 == "Heading2" && $0.1 == "1.1 Detail" }, "\(styled)")

        // Runs.
        let runs = e.body.documentXML
        XCTAssertTrue(runs.contains("<w:rPr><w:i/></w:rPr><w:t xml:space=\"preserve\">em</w:t>"))
        XCTAssertTrue(runs.contains("<w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">strong</w:t>"))
        XCTAssertTrue(runs.contains("<w:rPr><w:strike/></w:rPr><w:t xml:space=\"preserve\">gone</w:t>"))
        XCTAssertTrue(runs.contains("<w:rPr><w:rStyle w:val=\"CodeChar\"/></w:rPr><w:t xml:space=\"preserve\">code</w:t>"))
        XCTAssertTrue(styled.contains { $0.1.contains("and shown text") }, "a wiki link prints its display")

        // Blockquote, scene break, lists, verbatim.
        XCTAssertTrue(styled.contains { $0.0 == "Quote" && $0.1 == "A quoted line." })
        let sceneBreak = try XCTUnwrap(ps.first { (try? text($0)) == "* * *" })
        XCTAssertEqual(try nodes(sceneBreak, "./*[name()='w:pPr']/*[name()='w:jc']").first.flatMap { attr($0, "w:val") },
                       "center")
        let listed = try nodes(e.document, "//*[name()='w:numPr']/*[name()='w:numId']").compactMap { attr($0, "w:val") }
        XCTAssertEqual(listed, ["1", "1", "2", "2"], "each list its own w:num")
        XCTAssertEqual(e.body.lists, [DOCXList(numID: 1, ordered: false), DOCXList(numID: 2, ordered: true)])
        let code = try XCTUnwrap(ps.first { (try? style($0)) == "Code" })
        XCTAssertEqual(try text(code), "let x = 1let y = 2")
        XCTAssertEqual(try nodes(code, ".//*[name()='w:br']").count, 1)

        // Table, figure, footnote, citation, cross-references.
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:tbl']").count, 1)
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:drawing']").count, 1)
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:footnoteReference']").count, 1)
        XCTAssertTrue(styled.contains { $0.1 == "See Figure 1, Table 1 and Section 1 (Smith 2026, p. 3)." },
                      "\(styled.map(\.1))")
        let instr = try nodes(e.document, "//*[name()='w:instrText']").compactMap(\.stringValue)
        XCTAssertEqual(instr, [" SEQ Table \\* ARABIC ", " SEQ Figure \\* ARABIC ",
                               " REF l_fig_rev \\h ", " REF l_tbl_sales \\h ", " REF l_sec_intro \\h "])
    }

    func test_numberingPart_hasOneBulletAndOneDecimalAbstract_andANumPerList() throws {
        let xml = DOCXBodyEmitter.numberingPart([DOCXList(numID: 1, ordered: false),
                                                 DOCXList(numID: 2, ordered: true)])
        let doc = try XMLDocument(xmlString: xml)
        let formats = try doc.nodes(forXPath: "//*[name()='w:abstractNum']//*[name()='w:numFmt']")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "w:val")?.stringValue }
        XCTAssertEqual(formats, ["bullet", "decimal"])
        let nums = try doc.nodes(forXPath: "//*[name()='w:num']").compactMap { $0 as? XMLElement }
        XCTAssertEqual(nums.compactMap { attr($0, "w:numId") }, ["1", "2"])
        XCTAssertEqual(descendants(nums[1], "w:startOverride").count, 1,
                       "an ordered list restarts at 1")
    }

    func test_fountainArms_emitParagraphs() throws {
        var book = Book(pieces: [("s", [
            ("a1b2", "Title: The Film\nAuthor: Me"),
            ("c3d4", "INT. HOUSE - DAY"),
            ("e5f6", "She waits."),
            ("g7h8", "BOB\n(quietly)\nHello."),
            ("j9k0", "CUT TO:"),
            ("m2n3", "> THE END <"),
            ("p4q5", "~La la la"),
            ("r6s7", "==="),
            ("t8v9", "ANNA\nYes. ^"),
        ])], context: Self.context())
        book.mode = .fountain
        let e = try emit(book)
        let texts = try paragraphs(e.document).map { try text($0) }
        for expected in ["The Film", "INT. HOUSE - DAY", "She waits.", "BOB", "(quietly)", "Hello.",
                         "CUT TO:", "THE END", "La la la"] {
            XCTAssertTrue(texts.contains(expected), "\(expected) in \(texts)")
        }
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:br'][@*[name()='w:type']='page']").count, 1)
    }

    // MARK: - headings

    func test_headings_mapToHeading1to3_fromTheBooksShallowestLevel() throws {
        let e = try emit(Book(pieces: [("a", [
            ("a1b2", "## Top"), ("c3d4", "### Mid"), ("e5f6", "#### Low"), ("g7h8", "##### Lower"),
        ])], context: Self.context()))
        let headed = try paragraphs(e.document).dropFirst().map { (try style($0), try text($0)) }
        XCTAssertEqual(headed.map(\.0), ["Heading1", "Heading2", "Heading3", "Heading3"])
        XCTAssertEqual(headed.map(\.1), ["1 Top", "1.1 Mid", "1.1.1 Low", "Lower"])
    }

    // MARK: - bookmarks

    func test_everyNodeWithAParagraphId_hasABookmark_balancedUniqueAndLegal() throws {
        let (book, figures) = try everyArm()
        let e = try emit(book, figureFiles: figures)
        let starts = try nodes(e.document, "//*[name()='w:bookmarkStart']")
        let ends = try nodes(e.document, "//*[name()='w:bookmarkEnd']")
        let startIDs = starts.compactMap { attr($0, "w:id") }
        let endIDs = ends.compactMap { attr($0, "w:id") }
        XCTAssertEqual(Set(startIDs).count, startIDs.count, "ids unique")
        XCTAssertEqual(startIDs.sorted(), endIDs.sorted(), "every start has one end")
        let names = starts.compactMap { attr($0, "w:name") }
        XCTAssertEqual(Set(names).count, names.count, "names unique: \(names)")
        for name in names { XCTAssertTrue(DOCXNames.isLegal(name), name) }

        let section = try XCTUnwrap(e.ast.sections.first)
        for index in section.nodes.indices {
            guard let id = section.nodeParagraphs[index] else { continue }
            XCTAssertTrue(names.contains(DOCXNames.paragraphBookmark(id)), "node \(index) (\(id)) in \(names)")
        }
        for l in ["fig:rev", "tbl:sales", "sec:intro"] {
            XCTAssertTrue(names.contains(DOCXNames.labelBookmark(label(l))), l)
        }
        // Every REF names a bookmark that exists.
        let refs = try nodes(e.document, "//*[name()='w:instrText']").compactMap(\.stringValue)
            .filter { $0.hasPrefix(" REF ") }
            .map { String($0.dropFirst(5).prefix { $0 != " " }) }
        XCTAssertFalse(refs.isEmpty)
        for ref in refs { XCTAssertTrue(names.contains(ref), ref) }
    }

    func test_bookmarkEnd_closesInsideTheParagraphItOpened() throws {
        let (book, figures) = try everyArm()
        let e = try emit(book, figureFiles: figures)
        for start in try nodes(e.document, "//*[name()='w:bookmarkStart']") {
            let id = try XCTUnwrap(attr(start, "w:id"))
            let parent = try XCTUnwrap(start.parent as? XMLElement)
            XCTAssertEqual(parent.name, "w:p")
            XCTAssertEqual(try nodes(parent, "./*[name()='w:bookmarkEnd'][@*[name()='w:id']='\(id)']").count, 1,
                           "bookmark \(id) ends in its own paragraph")
        }
    }

    func test_aParagraphThatMadeSeveralNodes_bookmarksEach_withACounter() throws {
        let e = try emit(Book(pieces: [("a", [("a1b2", "First.\n# Then a heading")])],
                              context: Self.context()))
        let names = try nodes(e.document, "//*[name()='w:bookmarkStart']").compactMap { attr($0, "w:name") }
        XCTAssertEqual(e.ast.sections[0].nodes.count, 2, "premise: one ¶, two nodes")
        XCTAssertEqual(names, ["p_a1b2", "p_a1b2_2"])
    }

    func test_twoLabelsCollidingAfterMapping_getACounter_andEachRefFindsItsOwn() throws {
        let one = try file("one.png", Self.png(width: 2, height: 2))
        let e = try emit(Book(pieces: [("a", [
            ("a1b2", "![A](one.png){#fig:a-b}"),
            ("c3d4", "![B](one.png){#fig:a_b}"),
            ("e5f6", "See @fig:a-b and @fig:a_b."),
        ])], context: Self.context()), figureFiles: ["a": [0: one, 1: one]])
        let names = try nodes(e.document, "//*[name()='w:bookmarkStart']").compactMap { attr($0, "w:name") }
        XCTAssertTrue(names.contains("l_fig_a_b"))
        XCTAssertTrue(names.contains("l_fig_a_b_2"))
        let refs = try nodes(e.document, "//*[name()='w:instrText']").compactMap(\.stringValue)
            .filter { $0.hasPrefix(" REF ") }
        XCTAssertEqual(refs, [" REF l_fig_a_b \\h ", " REF l_fig_a_b_2 \\h "])
    }

    // MARK: - tables

    func test_table_isNative_withARepeatingHeader_aMatchingGrid_alignedCells_andASeqCaptionAbove() throws {
        let e = try emit(Book(pieces: [("a", [
            ("a1b2", "| A | B | C |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n| 4 |\nTable: Cap {#tbl:t}"),
        ])], context: Self.context()))
        let tbl = try XCTUnwrap(nodes(e.document, "//*[name()='w:tbl']").first)
        XCTAssertEqual(try nodes(tbl, "./*[name()='w:tblGrid']/*[name()='w:gridCol']").count, 3)
        let rows = try nodes(tbl, "./*[name()='w:tr']")
        XCTAssertEqual(rows.count, 3)
        for row in rows { XCTAssertEqual(try nodes(row, "./*[name()='w:tc']").count, 3, "padded to the grid") }
        XCTAssertEqual(try nodes(rows[0], "./*[name()='w:trPr']/*[name()='w:tblHeader']").count, 1)
        XCTAssertEqual(try nodes(rows[1], ".//*[name()='w:tblHeader']").count, 0)
        let jcs = try nodes(rows[1], "./*[name()='w:tc']/*[name()='w:p']/*[name()='w:pPr']/*[name()='w:jc']")
            .compactMap { attr($0, "w:val") }
        XCTAssertEqual(jcs, ["left", "center", "right"])

        // The caption is the paragraph right before the table.
        let caption = try XCTUnwrap(tbl.previousSibling as? XMLElement)
        XCTAssertEqual(try style(caption), "Caption")
        XCTAssertEqual(try text(caption), "Table 1. Cap")
        XCTAssertEqual(try nodes(caption, ".//*[name()='w:instrText']").first?.stringValue, " SEQ Table \\* ARABIC ")
        let mark = try XCTUnwrap(nodes(caption, "./*[name()='w:bookmarkStart'][@*[name()='w:name']='l_tbl_t']").first)
        XCTAssertNotNil(mark)
    }

    func test_aTableInsideABlockquote_printsItsLiteralSource() throws {
        let e = try emit(Book(pieces: [("a", [("a1b2", "> | A |\n> |---|\n> | 1 |")])],
                              context: Self.context()))
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:tbl']").count, 0)
        XCTAssertTrue(try paragraphs(e.document).contains { (try? text($0))?.contains("| A |") == true })
    }

    // MARK: - figures

    func test_figure_isAnInlineDrawing_sizedFromItsPixels_withASeqCaptionBelow() throws {
        let small = try file("small.png", Self.png(width: 8, height: 4))
        let big = try file("big.png", Self.png(width: 2000, height: 1000))
        let e = try emit(Book(pieces: [("a", [
            ("a1b2", "![Small](s.png){#fig:s}"), ("c3d4", "![Big](b.png)"), ("e5f6", "![Again](s.png)"),
        ])], context: Self.context()), figureFiles: ["a": [0: small, 1: big, 2: small]])

        let extents = try nodes(e.document, "//*[name()='wp:extent']").map {
            (Int(attr($0, "cx") ?? "") ?? 0, Int(attr($0, "cy") ?? "") ?? 0)
        }
        XCTAssertEqual(extents.count, 3)
        let dpi = try XCTUnwrap(DOCXImageGeometry.naturalInches(of: small))
        XCTAssertEqual(extents[0].0, Int((dpi.width * 914_400).rounded()))
        XCTAssertEqual(extents[0].0, extents[0].1 * 2, "aspect kept")
        XCTAssertEqual(extents[1].0, 5_486_400, "a wide image fits the 6-inch column")
        XCTAssertEqual(extents[1].1, 2_743_200)

        let docPr = try nodes(e.document, "//*[name()='wp:docPr']").compactMap { attr($0, "id") }
        XCTAssertEqual(Set(docPr).count, 3, "docPr ids unique: \(docPr)")

        XCTAssertEqual(e.body.media.count, 2, "the same image twice is one file")
        XCTAssertEqual(e.body.relationships.count, 2)
        for media in e.body.media {
            XCTAssertFalse(media.needsRaster)
            XCTAssertNotNil(media.name.range(of: "^[0-9a-f]{16}\\.png$", options: .regularExpression), media.name)
            XCTAssertTrue(e.body.relationships.contains { $0.target == "media/" + media.name })
        }
        let embeds = try nodes(e.document, "//*[name()='a:blip']").compactMap { attr($0, "r:embed") }
        for embed in embeds { XCTAssertTrue(e.body.relationships.contains { $0.id == embed }, embed) }

        // The caption follows the image's paragraph.
        let drawingParagraph = try XCTUnwrap(nodes(e.document, "//*[name()='w:drawing']").first?.parent?.parent as? XMLElement)
        let caption = try XCTUnwrap(drawingParagraph.nextSibling as? XMLElement)
        XCTAssertEqual(try style(caption), "Caption")
        XCTAssertEqual(try text(caption), "Figure 1. Small")
        XCTAssertEqual(try nodes(caption, ".//*[name()='w:instrText']").first?.stringValue, " SEQ Figure \\* ARABIC ")
    }

    func test_aPDFFigure_isStagedForRaster_andSizedFromItsMediabox() throws {
        let chart = try pdf(width: 144, height: 72)
        let svg = try file("d.svg", Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>".utf8))
        let e = try emit(Book(pieces: [("a", [("a1b2", "![C](c.pdf)"), ("c3d4", "![D](d.svg)")])],
                              context: Self.context()), figureFiles: ["a": [0: chart, 1: svg]])
        XCTAssertEqual(e.body.media.count, 2)
        for media in e.body.media {
            XCTAssertTrue(media.needsRaster)
            XCTAssertTrue(media.name.hasSuffix(".png"), media.name)
        }
        let extent = try XCTUnwrap(nodes(e.document, "//*[name()='wp:extent']").first)
        XCTAssertEqual(attr(extent, "cx"), "1828800", "144 pt is two inches")
        XCTAssertEqual(attr(extent, "cy"), "914400")
    }

    func test_aFigureWithoutAFile_printsItsLiteral_butKeepsItsLabelBookmark() throws {
        let e = try emit(Book(pieces: [("a", [("a1b2", "![Gone](gone.png){#fig:g}"), ("c3d4", "See @fig:g.")])],
                              context: Self.context()))
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:drawing']").count, 0)
        XCTAssertTrue(try paragraphs(e.document).contains { (try? text($0)) == "![Gone](gone.png) {#fig:g}" })
        let names = try nodes(e.document, "//*[name()='w:bookmarkStart']").compactMap { attr($0, "w:name") }
        XCTAssertTrue(names.contains("l_fig_g"), "a REF still lands: \(names)")
        XCTAssertTrue(try paragraphs(e.document).contains { (try? text($0)) == "See Figure 1." })
    }

    // MARK: - footnotes

    func test_footnoteIds_areTheResolutionsNumbers_andFootnotesHoldTheSeparators() throws {
        let e = try emit(Book(pieces: [
            ("a", [("a1b2", "One[^x] and two[^y], one again[^x]."),
                   ("c3d4", "[^x]: Note x."), ("e5f6", "[^y]: Note y with a nested[^z]."),
                   ("g7h8", "[^z]: Note z.")]),
            ("b", [("j9k0", "Three[^x]."), ("m2n3", "[^x]: B's x.")]),
        ], context: Self.context()))
        let refs = try nodes(e.document, "//*[name()='w:footnoteReference']").compactMap { attr($0, "w:id") }
        let numbers = e.resolution.footnoteNumbers
        XCTAssertEqual(refs, [numbers["a"]?["x"], numbers["a"]?["y"], numbers["b"]?["x"]].compactMap { $0.map(String.init) },
                       "a second reference to a note is not a second footnote")
        let notes = try nodes(e.footnotes, "//*[name()='w:footnote']")
        XCTAssertEqual(notes.compactMap { attr($0, "w:id") }, ["-1", "0"] + refs)
        XCTAssertEqual(attr(notes[0], "w:type"), "separator")
        XCTAssertEqual(attr(notes[1], "w:type"), "continuationSeparator")
        // The repeat reference prints its number as a superscript.
        let firstPara = try XCTUnwrap(paragraphs(e.document).first { (try? text($0))?.hasPrefix("One") == true })
        XCTAssertEqual(try text(firstPara), "One and two, one again\(numbers["a"]!["x"]!).")
        // The nested note's text lives inside the note that referenced it.
        let y = try XCTUnwrap(notes.first { attr($0, "w:id") == String(numbers["a"]!["y"]!) })
        let yText = try text(y)
        XCTAssertTrue(yText.contains("Note z."), yText)
        for note in notes.dropFirst(2) {
            XCTAssertEqual(try nodes(note, ".//*[name()='w:footnoteRef']").count, 1)
        }
    }

    // MARK: - unresolved markers

    func test_unresolvedMarkers_printLiterally() throws {
        let e = try emit(Book(pieces: [("a", [
            ("a1b2", "See @fig:nope, [@nobody] and a note[^none]."),
        ])], context: Self.context()))
        XCTAssertTrue(try paragraphs(e.document).contains {
            (try? text($0)) == "See @fig:nope, [@nobody] and a note[^none]."
        })
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:instrText']").count, 0)
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:footnoteReference']").count, 0)
    }

    // MARK: - References

    func test_references_closeTheBody_underAnUnnumberedHeading1_inBibliographyStyle() throws {
        let smith = ResearchItem(id: "r", title: "Annual Report", type: .asset,
                                 citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                                        sourceTitle: "Annual Report", year: 2026))
        let e = try emit(Book(pieces: [("a", [("a1b2", "As shown [@smith2026].")])],
                              context: Self.context(library: [smith])))
        let ps = try paragraphs(e.document)
        let heading = try XCTUnwrap(ps.dropLast().last)
        XCTAssertEqual(try style(heading), "Heading1")
        XCTAssertEqual(try text(heading), "References")
        let entry = try XCTUnwrap(ps.last)
        XCTAssertEqual(try style(entry), "Bibliography")
        XCTAssertEqual(try text(entry), e.resolution.references[0].map(\.text).joined())
        XCTAssertGreaterThan(try nodes(entry, ".//*[name()='w:i']").count, 0, "the title is italic")
    }

    // MARK: - OOXML element order

    /// Word refuses a `w:pPr`, `w:rPr` or `w:tblPr` whose children are out of
    /// the schema's sequence; every one the emitter writes is in order.
    func test_propertyChildren_followTheSchemaOrder() throws {
        let (book, figures) = try everyArm()
        var fountain = Book(pieces: [("s", [("a1b2", "INT. HOUSE"), ("c3d4", "BOB\n(aside)\nHi."),
                                            ("e5f6", "CUT TO:"), ("g7h8", "> MID <")])],
                            context: Self.context())
        fountain.mode = .fountain
        let orders: [String: [String]] = [
            "w:pPr": ["w:pStyle", "w:keepNext", "w:keepLines", "w:pageBreakBefore", "w:widowControl",
                      "w:numPr", "w:spacing", "w:ind", "w:jc"],
            "w:rPr": ["w:rStyle", "w:rFonts", "w:b", "w:i", "w:caps", "w:strike", "w:u", "w:vertAlign"],
            "w:tblPr": ["w:tblStyle", "w:tblW", "w:jc", "w:tblBorders", "w:tblLayout", "w:tblLook"],
        ]
        for e in [try emit(book, figureFiles: figures), try emit(fountain)] {
            for doc in [e.document, e.footnotes] {
                for (parent, order) in orders {
                    for props in try nodes(doc, "//*[name()='\(parent)']") {
                        let names = (props.children ?? []).compactMap(\.name)
                        let positions = try names.map { name -> Int in
                            try XCTUnwrap(order.firstIndex(of: name), "\(name) in \(parent) is not in the known order")
                        }
                        XCTAssertEqual(positions, positions.sorted(), "\(parent): \(names)")
                    }
                }
            }
        }
    }

    // MARK: - several bodies

    func test_twoBodies_shareEveryCounter_tagTheirNames_andBreakBetween() throws {
        let (book, figures) = try everyArm()
        let e = try emit([body(book, figureFiles: figures), body(book, figureFiles: figures, bodyTag: "sr")])
        func values(_ xpath: String, _ a: String) throws -> [String] {
            try nodes(e.document, xpath).compactMap { attr($0, a) }
        }
        for (xpath, a) in [("//*[name()='w:bookmarkStart']", "w:id"), ("//*[name()='w:bookmarkStart']", "w:name"),
                           ("//*[name()='wp:docPr']", "id"), ("//*[name()='w:footnoteReference']", "w:id")] {
            let all = try values(xpath, a)
            XCTAssertEqual(all.count, Set(all).count, "\(xpath)@\(a) unique: \(all)")
        }
        XCTAssertEqual(e.body.lists.map(\.numID), [1, 2, 3, 4])
        let names = try values("//*[name()='w:bookmarkStart']", "w:name")
        XCTAssertTrue(names.contains("p_a1b2") && names.contains("p_sr_a1b2"))
        XCTAssertTrue(names.contains("l_fig_rev") && names.contains("l_sr_fig_rev"))
        XCTAssertEqual(try nodes(e.document, "//*[name()='w:br'][@*[name()='w:type']='page']").count, 1)
        XCTAssertEqual(e.body.media.count, 1, "one image, one file, however many bodies show it")
        XCTAssertEqual(e.body.relationships.count, 1)
        let notes = try nodes(e.footnotes, "//*[name()='w:footnote']").compactMap { attr($0, "w:id") }
        XCTAssertEqual(notes, ["-1", "0"] + (try values("//*[name()='w:footnoteReference']", "w:id")))
        // The second body's captions restart their sequences.
        let seq = try nodes(e.document, "//*[name()='w:instrText']").compactMap(\.stringValue)
            .filter { $0.hasPrefix(" SEQ ") }
        XCTAssertEqual(seq, [" SEQ Table \\* ARABIC ", " SEQ Figure \\* ARABIC ",
                             " SEQ Table \\* ARABIC \\r 1 ", " SEQ Figure \\* ARABIC \\r 1 "])
    }

    // MARK: - fix round 1

    /// I1: every REF's precomputed result is the text its bookmark wraps, so
    /// a field update in Word changes nothing; a section reads "Section " as
    /// text and the number as the result.
    func test_everyReferenceResult_isTheTextItsBookmarkWraps() throws {
        let (book, figures) = try everyArm()
        let e = try emit(book, figureFiles: figures)
        let see = try XCTUnwrap(paragraphs(e.document).first { (try? text($0))?.hasPrefix("See ") == true })
        let refs = try references(in: see)
        XCTAssertEqual(refs.map(\.name), ["l_fig_rev", "l_tbl_sales", "l_sec_intro"])
        for ref in refs {
            XCTAssertEqual(ref.result, try bookmarked(ref.name, in: e.document), ref.name)
        }
        XCTAssertEqual(refs.last?.result, "1")
        XCTAssertEqual(try text(see), "See Figure 1, Table 1 and Section 1 (Smith 2026, p. 3).")
    }

    /// I2: a nested note prints in place without a numeral, and a later
    /// reference from the text makes it a footnote; a repeat prints the
    /// number Word shows.
    func test_aNestedNote_printsInPlace_andALaterReferenceMakesItAFootnote() throws {
        let e = try emit(Book(pieces: [("a", [
            ("a1b2", "A[^y]. Later[^z]. Again[^y]."),
            ("c3d4", "[^y]: Y with a nested[^z]."), ("e5f6", "[^z]: Zed."),
        ])], context: Self.context()))
        let refs = try nodes(e.document, "//*[name()='w:footnoteReference']").compactMap { attr($0, "w:id") }
        XCTAssertEqual(refs.count, 2)
        let text0 = try text(try XCTUnwrap(paragraphs(e.document).dropFirst().first))
        XCTAssertEqual(text0, "A. Later. Again1.", "a repeat prints Word's number; the nested note is no numeral")
        let notes = try nodes(e.footnotes, "//*[name()='w:footnote']")
        XCTAssertEqual(notes.compactMap { attr($0, "w:id") }, ["-1", "0"] + refs)
        XCTAssertEqual(try text(notes[2]), " Y with a nested (\u{2014} Zed.).")
        XCTAssertEqual(try text(notes[3]), " Zed.")
        // M1: the mark inside each note is superscript too.
        for note in notes.dropFirst(2) {
            let mark = try XCTUnwrap(descendants(note, "w:footnoteRef").first?.parent as? XMLElement)
            XCTAssertEqual(try nodes(mark, "./*[name()='w:rPr']/*[name()='w:vertAlign']").first.flatMap { attr($0, "w:val") },
                           "superscript")
        }
    }

    /// I2: a table's caption is emitted above the table, so its note can be
    /// Word's first even when the resolution counted the cell's first; a
    /// repeat reference prints Word's number for each.
    func test_aRepeatReference_printsTheNumberWordShows_evenAfterACaptionAboveItsTable() throws {
        let e = try emit(Book(pieces: [("a", [
            ("a1b2", "| A |\n|---|\n| cell[^c] |\nTable: Cap[^t] {#tbl:x}"),
            ("c3d4", "Repeat[^c] and[^t]."),
            ("e5f6", "[^c]: Cell note."), ("g7h8", "[^t]: Caption note."),
        ])], context: Self.context()))
        let refs = try nodes(e.document, "//*[name()='w:footnoteReference']").compactMap { attr($0, "w:id") }
        let numbers = try XCTUnwrap(e.resolution.footnoteNumbers["a"])
        let c = try XCTUnwrap(numbers["c"]), t = try XCTUnwrap(numbers["t"])
        XCTAssertEqual(refs, [String(t), String(c)], "the caption's note is Word's first")
        let repeatParagraph = try XCTUnwrap(paragraphs(e.document).first { (try? text($0))?.hasPrefix("Repeat") == true })
        XCTAssertEqual(try text(repeatParagraph), "Repeat2 and1.")
    }

    /// M3: a caption whose number is not the next one resets its sequence.
    func test_aSubsetsFirstCaption_resetsItsSequence() throws {
        let one = try file("one.png", Self.png(width: 2, height: 2))
        let book = Book(pieces: [("a", [("a1b2", "![A](a.png)")]), ("b", [("c3d4", "![B](b.png)"), ("e5f6", "![C](c.png)")])],
                        context: Self.context())
        let e = try emit(book, figureFiles: ["b": [0: one, 1: one]],
                         emitting: { ProjectAST(sections: [$0.sections[1]]) })
        let seq = try nodes(e.document, "//*[name()='w:instrText']").compactMap(\.stringValue)
        XCTAssertEqual(seq, [" SEQ Figure \\* ARABIC \\r 2 ", " SEQ Figure \\* ARABIC "])
    }
}
