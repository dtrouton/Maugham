import XCTest
@testable import Maugham

/// **No test builds a view host by hand** (shell p4 Task 1).
///
/// The whole-branch review's C1 was a dead feature hidden by tests: the
/// mounted `PulledUpView` probes were built without the `canvasDetails`
/// production always passes, so they took a branch production never takes.
/// The class is closed by one builder per host in `TestSupport/`
/// (`ViewHostFixtures.swift`, `RightColumnFixture.swift`) and by this census:
///
/// - outside `TestSupport/`, no test source builds `RightColumn`,
///   `PulledUpView`, `RightColumnControl`, `BinderView`,
///   `CollectionPiecesPane`, `SceneNavigatorPane` or `BinderPieceFold` in
///   code. A string literal naming one (a source-scanning census quoting
///   production) is on `quotedIn`, each with its reason;
/// - each fixture's call passes the same argument labels as the host's
///   production call site, and applies the same `.environment(\.…)` keys as
///   production applies around it. A new production argument fails here
///   until the fixture passes it.
@MainActor
final class HostBuilderCensusTests: XCTestCase {

    /// The hosts, by the name a construction spells.
    static let hosts = ["RightColumn", "PulledUpView", "RightColumnControl", "BinderView",
                        "CollectionPiecesPane", "SceneNavigatorPane", "BinderPieceFold",
                        "CentreTopLines"]

    /// **Test files that name a host inside a string literal**, never in code,
    /// each with its reason. An entry whose file no longer quotes a host fails
    /// (`test_theQuotedListIsLive`), so the list cannot outlive its reason.
    static let quotedIn: [String: String] = [
        "MaughamTests/WiringCensusTests.swift":
            "source scan: the right column's arms are counted by the calls production spells",
        "MaughamTests/ReviewRoundCockpitTests.swift":
            "source scan: reads the window's `recordActivePass` argument to `RightColumn(`",
        "MaughamTests/DetailColumnWidthTests.swift":
            "source scan: the frame census and its planted offenders quote `RightColumn(`; "
            + "its mounted arms already measure through `RightColumnFixture`",
        "MaughamTests/BinderPieceFoldTests.swift":
            "source scan: both tree hosts mount the fold with the window's tree state",
        "MaughamTests/HostBuilderCensusTests.swift":
            "this census: the hosts' names and the planted offender",
    ]

    // MARK: - The census

    func test_noTestBuildsAViewHostByHand() throws {
        let scan = try Self.scan(root: "MaughamTests", base: SourceTree.repoRoot)
        XCTAssertEqual(scan.inCode, [],
            "a test builds a view host by hand — build it through its one fixture "
            + "(`ViewHostFixtures.swift`, `RightColumnFixture`), which passes what "
            + "production passes:\n" + scan.inCode.joined(separator: "\n"))
        let unlisted = scan.quoted.filter { Self.quotedIn[$0.file] == nil }
        XCTAssertEqual(unlisted.map(\.description), [],
            "a host is named in a string literal in a file `quotedIn` does not list — "
            + "add it with its reason, or build the host through its fixture")
    }

    func test_theQuotedListIsLive() throws {
        let scan = try Self.scan(root: "MaughamTests", base: SourceTree.repoRoot)
        let quoting = Set(scan.quoted.map(\.file))
        for file in Self.quotedIn.keys.sorted() {
            XCTAssertTrue(quoting.contains(file),
                          "\(file) no longer quotes a host: drop it from `quotedIn`")
        }
    }

    /// **The planted offender and the control.** A file that builds
    /// `PulledUpView(` in code is seen; the same name inside a string is
    /// seen as quoted, never as code; and the fixture file itself — where the
    /// builds legitimately live — is seen building every host.
    func test_theCensusSeesAPlantedOffenderAndTheFixtures() throws {
        let root = TestTemp.root
        let dir = root.appendingPathComponent("MaughamTests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        func offender() {
            _ = PulledUpView(store: store)   // a hand build
            let quoted = "PulledUpView("
            // a comment naming BinderView( is neither
        }
        """.write(to: dir.appendingPathComponent("Offender.swift"), atomically: true, encoding: .utf8)
        let planted = try Self.scan(root: "MaughamTests", base: root)
        XCTAssertEqual(planted.inCode, ["MaughamTests/Offender.swift:2 PulledUpView("])
        XCTAssertEqual(planted.quoted.map(\.description), ["MaughamTests/Offender.swift:3 PulledUpView("])

        // The control: the fixtures, read without `TestSupport/`'s exemption.
        let fixtures = try Self.occurrences(
            in: SourceTree.read("MaughamTests/TestSupport/ViewHostFixtures.swift"),
            file: "ViewHostFixtures.swift")
        XCTAssertEqual(Set(fixtures.inCode.map { $0.split(separator: " ").last.map(String.init) ?? "" }),
                       Set(Self.hosts.filter { $0 != "RightColumn" }.map { $0 + "(" }),
                       "the census reads code: every host but the column is built in the fixture file")
        let column = try Self.occurrences(
            in: SourceTree.read("MaughamTests/TestSupport/RightColumnFixture.swift"),
            file: "RightColumnFixture.swift")
        XCTAssertEqual(column.inCode.count, 1, "the column is built once, in its fixture")
    }

    // MARK: - Parity with production

    /// Where an `.environment(\.…)` key applies to a host.
    enum Span {
        /// The text between two anchors (the first occurrence of each, the
        /// second searched after the first) in a file.
        case between(String, from: String, to: String)
        /// A whole file: what a host sets on its own body applies to the
        /// fold it mounts.
        case file(String)
        /// One declaration in `TestSupport/`, by its header.
        case declaration(String)
    }

    struct Host {
        let name: String
        /// How many production sites build it (the fold has two hosts).
        let productionSites: Int
        let productionEnvironment: [Span]
        let fixtureEnvironment: Span
    }

    /// The tree column in `ProjectWindow.body`, where `windowCanvas` is set.
    static let treeColumn = Span.between("Maugham/Views/ProjectWindow.swift",
                                         from: "binderColumn(store: store)", to: "} content: {")
    /// The right column in `ProjectWindow.body`.
    static let rightColumn = Span.between("Maugham/Views/ProjectWindow.swift",
                                          from: "} detail: {", to: ".overlay(alignment: .top)")
    /// `RightColumn.pane`, which wraps the control and the arm.
    static let pane = Span.between("Maugham/Views/RightColumn.swift",
                                   from: "var pane: some View {", to: "static func toggleTitle(")

    static let parity: [Host] = [
        Host(name: "RightColumn", productionSites: 1,
             productionEnvironment: [rightColumn],
             fixtureEnvironment: .file("MaughamTests/TestSupport/RightColumnFixture.swift")),
        Host(name: "PulledUpView", productionSites: 1,
             productionEnvironment: [
                rightColumn, pane,
                .between("Maugham/Views/RightColumn.swift",
                         from: "case .pulledUp, .centreDetails, .nothingPulledUp:",
                         to: "private var subjectLine")],
             fixtureEnvironment: .declaration("static func view(")),
        Host(name: "RightColumnControl", productionSites: 1,
             productionEnvironment: [rightColumn, pane],
             fixtureEnvironment: .declaration("static func control(")),
        Host(name: "BinderView", productionSites: 1,
             productionEnvironment: [treeColumn, .file("Maugham/Views/BinderPaneToggle.swift")],
             fixtureEnvironment: .declaration("static func binder(")),
        Host(name: "CollectionPiecesPane", productionSites: 1,
             productionEnvironment: [treeColumn, .file("Maugham/Views/CollectionBinderPaneToggle.swift")],
             fixtureEnvironment: .declaration("static func collection(")),
        Host(name: "SceneNavigatorPane", productionSites: 1,
             productionEnvironment: [treeColumn, .file("Maugham/Views/BinderPaneToggle.swift")],
             fixtureEnvironment: .declaration("static func scenes(")),
        Host(name: "BinderPieceFold", productionSites: 2,
             productionEnvironment: [treeColumn, .file("Maugham/Views/BinderPaneToggle.swift"),
                                     .file("Maugham/Views/CollectionBinderPaneToggle.swift"),
                                     .file("Maugham/Views/BinderView.swift"),
                                     .file("Maugham/Views/CollectionPiecesPane.swift")],
             fixtureEnvironment: .declaration("static func fold(")),
        Host(name: "CentreTopLines", productionSites: 1,
             productionEnvironment: [.between("Maugham/Views/ProjectWindow.swift",
                                              from: "private func contentColumn(",
                                              to: "private var intentStripLine")],
             fixtureEnvironment: .declaration("static func lines(")),
    ]

    func test_eachFixturePassesWhatProductionPasses() throws {
        XCTAssertEqual(Set(Self.parity.map(\.name)), Set(Self.hosts), "every host is checked")
        let production = try SourceTree.maskedSources(under: "Maugham")
        let support = try SourceTree.maskedSources(under: "MaughamTests/TestSupport")
        for host in Self.parity {
            let sites = Self.calls(of: host.name, in: production)
            XCTAssertEqual(sites.count, host.productionSites,
                           "\(host.name): production builds it at \(sites.map(\.file))")
            let fixtureSites = Self.calls(of: host.name, in: support)
            guard let fixture = fixtureSites.first, fixtureSites.count == 1 else {
                XCTFail("\(host.name): one fixture builds it, found \(fixtureSites.map(\.file))")
                continue
            }
            for site in sites {
                XCTAssertEqual(fixture.labels, site.labels,
                    "\(host.name): the fixture passes \(fixture.labels.sorted()) and "
                    + "\(site.file) passes \(site.labels.sorted()) — missing "
                    + "\(site.labels.subtracting(fixture.labels).sorted()), extra "
                    + "\(fixture.labels.subtracting(site.labels).sorted())")
            }
            let made = try host.productionEnvironment.reduce(into: Set<String>()) {
                $0.formUnion(Self.environmentKeys(try Self.text(of: $1)))
            }
            let fixed = Self.environmentKeys(try Self.text(of: host.fixtureEnvironment))
            XCTAssertEqual(fixed, made,
                           "\(host.name): production sets \(made.sorted()) around it, "
                           + "its fixture \(fixed.sorted())")
        }
    }

    /// The premise of the parity census, as a control: the label reader sees
    /// labels at the top level only, past closures and nested calls, and the
    /// environment reader sees key paths only.
    func test_theParityReadersReadWhatTheySay() {
        let call = "Foo(a: 1, b: bar(c: 2, d: [3, 4]), e: { x, y in f(g: x) }, h: \"i: j\")"
        let masked = String(decoding: SourceTree.mask(call), as: UTF8.self)
        XCTAssertEqual(Self.labels(afterOpenParen: masked, from: masked.index(after: masked.firstIndex(of: "(")!)),
                       ["a", "b", "e", "h"])
        XCTAssertEqual(Self.environmentKeys(".environment(\\.one, x).environment(roster).environment(\\.two, y)"),
                       ["one", "two"])
    }

    // MARK: - Readers

    struct Occurrence: CustomStringConvertible {
        let file: String
        let line: Int
        let token: String
        var description: String { "\(file):\(line) \(token)" }
    }

    struct Scan {
        var inCode: [String] = []
        var quoted: [Occurrence] = []
    }

    /// Every host built in code, and every host named inside a string, in the
    /// test sources under `root` outside `TestSupport/`.
    static func scan(root: String, base: URL) throws -> Scan {
        var scan = Scan()
        for file in try SourceTree.swiftFiles(under: root, base: base).sorted()
        where !file.contains("/TestSupport/") {
            let found = try occurrences(in: SourceTree.read(file, base: base), file: file)
            scan.inCode += found.inCode
            scan.quoted += found.quoted
        }
        return scan
    }

    /// The hosts named in `text`: in code (comments and strings masked), and
    /// inside a string literal (an odd number of quotes before it on its
    /// masked line — the masker keeps the quote characters).
    static func occurrences(in text: String, file: String) throws -> Scan {
        let masked = String(decoding: try SourceTree.checkedMask(text, path: file), as: UTF8.self)
        let codeLines = masked.components(separatedBy: "\n")
        let lines = text.components(separatedBy: "\n")
        var scan = Scan()
        for (index, line) in lines.enumerated() {
            let code = index < codeLines.count ? codeLines[index] : ""
            for host in hosts {
                let token = host + "("
                for range in ranges(of: token, in: line) {
                    let offset = line.utf8.distance(from: line.startIndex, to: range.lowerBound)
                    let codeBytes = Array(code.utf8)
                    let inCode = offset + token.utf8.count <= codeBytes.count
                        && String(decoding: codeBytes[offset..<(offset + token.utf8.count)], as: UTF8.self) == token
                    if inCode {
                        scan.inCode.append("\(file):\(index + 1) \(token)")
                    } else if codeBytes.prefix(offset).filter({ $0 == UInt8(ascii: "\"") }).count % 2 == 1 {
                        scan.quoted.append(Occurrence(file: file, line: index + 1, token: token))
                    }
                }
            }
        }
        return scan
    }

    /// Where `token` begins in `line`, not preceded by an identifier
    /// character (`RightColumn(` is not `MyRightColumn(`).
    static func ranges(of token: String, in line: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = line.startIndex
        while let range = line.range(of: token, range: from..<line.endIndex) {
            let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
            if before.map({ !($0.isLetter || $0.isNumber || $0 == "_") }) ?? true {
                out.append(range)
            }
            from = range.upperBound
        }
        return out
    }

    struct Call {
        let file: String
        let labels: Set<String>
    }

    /// Every construction of `host` in code, with its argument labels.
    static func calls(of host: String, in sources: [(path: String, text: String, masked: [UInt8])]) -> [Call] {
        var out: [Call] = []
        for source in sources {
            let masked = String(decoding: source.masked, as: UTF8.self)
            for range in ranges(of: host + "(", in: masked) {
                out.append(Call(file: source.path,
                                labels: labels(afterOpenParen: masked, from: range.upperBound)))
            }
        }
        return out
    }

    /// The top-level argument labels of the call whose `(` ends just before
    /// `start` in masked text.
    static func labels(afterOpenParen text: String, from start: String.Index) -> Set<String> {
        var depth = 0
        var segment = ""
        var segments: [String] = []
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            if c == ")" || c == "]" || c == "}" {
                if depth == 0 { segments.append(segment); break }
                depth -= 1
            }
            if c == "," && depth == 0 {
                segments.append(segment)
                segment = ""
            } else {
                segment.append(c)
            }
            i = text.index(after: i)
        }
        return Set(segments.compactMap { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let label = String(trimmed[..<colon])
            guard !label.isEmpty, label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
            return label
        })
    }

    /// The key paths of every `.environment(\.key, …)` in `text`.
    static func environmentKeys(_ text: String) -> Set<String> {
        var keys: Set<String> = []
        let marker = ".environment(\\."
        var from = text.startIndex
        while let range = text.range(of: marker, range: from..<text.endIndex) {
            let key = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            keys.insert(String(key))
            from = range.upperBound
        }
        return keys
    }

    /// The masked text of a span (comments never count as a modifier).
    static func text(of span: Span) throws -> String {
        func masked(_ path: String) throws -> String {
            String(decoding: try SourceTree.checkedMask(try SourceTree.read(path), path: path), as: UTF8.self)
        }
        switch span {
        case .file(let path):
            return try masked(path)
        case .between(let path, let from, let to):
            let text = try masked(path)
            guard let start = text.range(of: from),
                  let end = text.range(of: to, range: start.upperBound..<text.endIndex) else {
                throw SourceTree.LookupError(description: "\(path): no span from '\(from)' to '\(to)'")
            }
            return String(text[start.lowerBound..<end.lowerBound])
        case .declaration(let header):
            return try SourceTree.declaration(named: header, under: "MaughamTests/TestSupport")
        }
    }
}
