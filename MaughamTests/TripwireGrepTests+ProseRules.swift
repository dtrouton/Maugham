import XCTest

/// **Four rules that were prose only, now censused** (#114 F26): tripwires 1
/// (no `NSTextStorage` subclass), 5 (no popover for editor autocomplete),
/// 9 (no `.onTapGesture` in a sidebar list) and 18's `d_` half (no `d_`
/// docId prefix). Each scans every production root and has a planted control.
extension TripwireGrepTests {

    // MARK: - Shared walk

    /// One production file: its basename, its raw lines, and its lines with
    /// comments and string contents blanked (`SourceTree.checkedMask`), index
    /// for index.
    struct MaskedFile {
        /// `<root>/<relative path>`, as `SourceTree` spells it.
        let path: String
        let name: String
        let raw: [String]
        let code: [String]
    }

    /// Every `.swift` file under `roots`, masked, through
    /// `SourceTree.maskedSources` — which THROWS on a root that is missing or
    /// holds no Swift file, so a census can never pass over nothing.
    static func maskedFiles(in roots: [URL]) throws -> [MaskedFile] {
        try roots.flatMap { root in
            try SourceTree.maskedSources(under: root.lastPathComponent,
                                         base: root.deletingLastPathComponent())
                .map { source in
                    MaskedFile(
                        path: source.path,
                        name: (source.path as NSString).lastPathComponent,
                        raw: source.text.split(separator: "\n", omittingEmptySubsequences: false)
                            .map(String.init),
                        code: String(decoding: source.masked, as: UTF8.self)
                            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                }
        }
    }

    /// Every `.swift` file under `roots`, raw: a census that reads string
    /// literals has no use for a mask. Throws on an empty root, as above.
    static func rawFiles(in roots: [URL]) throws -> [(name: String, raw: [String])] {
        try roots.flatMap { root in
            let base = root.deletingLastPathComponent()
            let files = try SourceTree.swiftFiles(under: root.lastPathComponent, base: base)
            guard !files.isEmpty else {
                throw SourceTree.LookupError(description: "root '\(root.path)' holds no .swift file")
            }
            return try files.map { file in
                ((file as NSString).lastPathComponent,
                 try SourceTree.read(file, base: base)
                    .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            }
        }
    }

    /// `"<basename>:<line>: <raw text>"` for every CODE line of `files` that
    /// `matches`.
    static func codeLineOffenders(_ files: [MaskedFile], matches: (String) -> Bool) -> [String] {
        files.flatMap { file in
            file.code.indices.filter { matches(file.code[$0]) }.map {
                "\(file.name):\($0 + 1): \(file.raw[$0].trimmingCharacters(in: .whitespaces))"
            }
        }
    }

    private static func plantedDir(_ label: String) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Tripwire 1: no NSTextStorage subclass

    /// A class whose inheritance clause names `NSTextStorage`.
    static func nsTextStorageSubclassOffenders(in roots: [URL]) throws -> [String] {
        codeLineOffenders(try maskedFiles(in: roots)) {
            $0.range(of: #"\bclass\s+\w+\s*(<[^>]*>)?\s*:[^{]*\bNSTextStorage\b"#,
                     options: .regularExpression) != nil
        }
    }

    /// **No `NSTextStorage` subclass in production** (tripwire 1). Fronting
    /// several files with one subclass killed Phase 3d: AppKit's layout, undo
    /// and selection caches cannot be steered from a subclass. A subclass for
    /// any other purpose is still a reason to stop and read the row first.
    func test_noNSTextStorageSubclassInProduction() throws {
        let offenders = try Self.nsTextStorageSubclassOffenders(in: SourceTree.productionRootURLs)
        XCTAssertEqual(offenders, [],
            "an NSTextStorage subclass (tripwire 1) — read docs/tripwires.md row 1:\n"
            + offenders.joined(separator: "\n"))
    }

    func test_theNSTextStorageSubclassCensusFiresOnPlantedOffenders() throws {
        let dir = try Self.plantedDir("tw1")
        try """
        final class Fronted: NSTextStorage {}
        class Generic<T>: NSObject, NSTextStorage {}
        // class Commented: NSTextStorage {}
        let s: NSTextStorage = NSTextStorage()
        class func make(storage: NSTextStorage) {}
        let note = "class Quoted: NSTextStorage {}"
        """.write(to: dir.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.nsTextStorageSubclassOffenders(in: [dir])
                        .compactMap { SourceTree.Hit(offender: $0)?.line }, [1, 2])
    }

    // MARK: - Tripwire 5: no popover for editor autocomplete

    /// **Autocomplete code is the completion machinery, found by what it
    /// declares**: a file declaring a type whose name contains `Completion` or
    /// `Autocomplet`, or a type conforming to `CompletionSource`. Every other
    /// file — an editor pop-out, a grid, an inspector — is outside this rule.
    /// Narrow on purpose: the rule is about autocomplete, and an editor
    /// pop-out (the report grid's, say) may legitimately be a popover.
    static func autocompleteFiles(_ files: [MaskedFile]) -> [MaskedFile] {
        files.filter { file in
            file.code.contains {
                $0.range(of: #"\b(class|struct|enum|protocol|extension|actor)\s+\w*(Completion|Autocomplet)\w*\b"#,
                         options: .regularExpression) != nil
                || $0.range(of: #"\b(class|struct|enum|extension|actor)\s+[\w.]+[^{]*:[^{]*\bCompletionSource\b"#,
                            options: .regularExpression) != nil
            }
        }
    }

    /// `NSPopover` or SwiftUI `.popover(` in autocomplete code.
    static func autocompletePopoverOffenders(in roots: [URL]) throws -> [String] {
        codeLineOffenders(autocompleteFiles(try maskedFiles(in: roots))) {
            $0.contains("NSPopover") || $0.contains(".popover(")
        }
    }

    /// **No popover for editor autocomplete** (tripwire 5): its sizing is
    /// unreliable and it blocks input; the completion list is a plain `NSView`
    /// (`CompletionListView`). Scoped to the completion machinery only
    /// (`autocompleteFiles`), so a popover elsewhere is not this rule's.
    func test_noPopoverInEditorAutocomplete() throws {
        let files = try Self.maskedFiles(in: SourceTree.productionRootURLs)
        let scope = Set(Self.autocompleteFiles(files).map(\.name))
        for type in ["CompletionListView", "CompletionSource", "CompletionState",
                     "CitationCompletion", "CrossReferenceCompletion"] {
            for path in try SourceTree.filesDeclaring(type, under: SourceTree.productionRoots) {
                XCTAssertTrue(scope.contains((path as NSString).lastPathComponent),
                    "\(path) declares \(type) but the autocomplete scope did not read it: \(scope.sorted())")
            }
        }
        let offenders = try Self.autocompletePopoverOffenders(in: SourceTree.productionRootURLs)
        XCTAssertEqual(offenders, [],
            "a popover in editor autocomplete (tripwire 5) — a picker is a "
            + "`CompletionSource` shown in `CompletionListView`:\n" + offenders.joined(separator: "\n"))
    }

    func test_theAutocompletePopoverCensusFiresOnPlantedOffenders() throws {
        let dir = try Self.plantedDir("tw5")
        try """
        final class TagCompletion: CompletionSource {
            let p = NSPopover()
            // NSPopover in a comment
        }
        """.write(to: dir.appendingPathComponent("TagCompletion.swift"), atomically: true, encoding: .utf8)
        try """
        final class Picker: NSObject, CompletionSource {
            func show() { view.popover(isPresented: $x) { Text("a") } }
        }
        """.write(to: dir.appendingPathComponent("Picker.swift"), atomically: true, encoding: .utf8)
        try """
        final class ReportPopOut: NSView {
            let p = NSPopover()
        }
        """.write(to: dir.appendingPathComponent("ReportPopOut.swift"), atomically: true, encoding: .utf8)
        let offenders = try Self.autocompletePopoverOffenders(in: [dir])
        XCTAssertEqual(Set(offenders.map { String($0.prefix { $0 != ":" }) }),
                       ["TagCompletion.swift", "Picker.swift"],
                       "the two completion files fire; a popover outside autocomplete does not:\n"
                       + offenders.joined(separator: "\n"))
        XCTAssertEqual(offenders.count, 2, offenders.joined(separator: "\n"))
    }

    // MARK: - Tripwire 9: no tap gesture in a sidebar list

    /// The tap-gesture spellings `TreeTravelGestureAttachmentTests.tapGestureSpellings` measured
    /// eating a sidebar row's click: `.onTapGesture` and a `TapGesture(` handed
    /// to `.gesture`/`.simultaneousGesture`.
    static let sidebarTapSpellings = [".onTapGesture", "TapGesture("]

    /// **The proxy**: a file that styles a list `.sidebar` declares no tap
    /// gesture, and neither does any `*Row` view type that file instantiates
    /// — read by TYPE (`SourceTree.declarationRanges`), wherever it is
    /// declared, so a row in a file of its own is seen. A row built by some
    /// other name, or two hops away, is not.
    static func sidebarTapGestureScope(in roots: [URL]) throws
        -> (sidebarFiles: [MaskedFile], rowTypes: Set<String>, offenders: [String]) {
        let files = try maskedFiles(in: roots)
        let sidebarFiles = files.filter { file in
            file.code.contains { $0.contains(".listStyle(.sidebar)") || $0.contains("SidebarListStyle(") }
        }
        let rowPattern = try NSRegularExpression(pattern: #"\b([A-Z]\w*Row)\("#)
        var rowTypes: Set<String> = []
        for line in sidebarFiles.flatMap(\.code) {
            for match in rowPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                if let range = Range(match.range(at: 1), in: line) { rowTypes.insert(String(line[range])) }
            }
        }
        let isTap: (String) -> Bool = { line in sidebarTapSpellings.contains { line.contains($0) } }
        var offenders = Set(codeLineOffenders(sidebarFiles, matches: isTap))
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for type in rowTypes.sorted() {
            for root in roots {
                let ranges = try SourceTree.declarationRanges(
                    of: type, under: [root.lastPathComponent], base: root.deletingLastPathComponent())
                for (path, lines) in ranges {
                    guard let file = byPath[path] else { continue }
                    for range in lines {
                        for n in range where n - 1 < file.code.count && isTap(file.code[n - 1]) {
                            offenders.insert(
                                "\(file.name):\(n): \(file.raw[n - 1].trimmingCharacters(in: .whitespaces))")
                        }
                    }
                }
            }
        }
        return (sidebarFiles, rowTypes, offenders.sorted())
    }

    /// **No tap gesture for clickable rows inside `List(.sidebar)`**
    /// (tripwire 9): hit-testing is unreliable there and a double-tap costs
    /// the row its single-click selection; use `Button(.plain)` or
    /// `List(selection:)`. The tree's own rows are censused file by file in
    /// `TreeTravelGestureAttachmentTests.test_noTreeRowCarriesASwiftUITapGesture`.
    func test_noTapGestureInASidebarListFile() throws {
        let scope = try Self.sidebarTapGestureScope(in: SourceTree.productionRootURLs)
        let names = Set(scope.sidebarFiles.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["BinderView.swift", "TasksPane.swift"]),
            "the sidebar-list scope lost the panes it guards: \(names.sorted())")
        XCTAssertTrue(scope.rowTypes.isSuperset(of: ["BinderRow", "TaskRow"]),
            "the row types the sidebar lists build were not found: \(scope.rowTypes.sorted())")
        XCTAssertEqual(scope.offenders, [],
            "a tap gesture in a sidebar list or one of its row types (tripwire 9):\n"
            + scope.offenders.joined(separator: "\n"))
    }

    func test_theSidebarTapGestureCensusFiresOnPlantedOffenders() throws {
        let dir = try Self.plantedDir("tw9")
        try """
        struct Side: View {
            var body: some View {
                List { Text("a").onTapGesture { open() }; FancyRow(item: a) }
                    .listStyle(.sidebar)
                // .onTapGesture in a comment
            }
        }
        """.write(to: dir.appendingPathComponent("Side.swift"), atomically: true, encoding: .utf8)
        try """
        struct FancyRow: View {
            var body: some View {
                Text("b").simultaneousGesture(TapGesture(count: 2).onEnded { jump() })
            }
        }
        struct Plain: View {
            var body: some View { Text("c").onTapGesture { open() } }
        }
        """.write(to: dir.appendingPathComponent("Rows.swift"), atomically: true, encoding: .utf8)
        let scope = try Self.sidebarTapGestureScope(in: [dir])
        XCTAssertEqual(scope.rowTypes, ["FancyRow"])
        XCTAssertEqual(scope.offenders, [
            #"Rows.swift:3: Text("b").simultaneousGesture(TapGesture(count: 2).onEnded { jump() })"#,
            #"Side.swift:3: List { Text("a").onTapGesture { open() }; FancyRow(item: a) }"#,
        ], "the sidebar file and its row type fire; a view the list does not build does not")
    }

    func test_aCensusOverAnEmptyRootThrows() throws {
        let dir = try Self.plantedDir("empty-root")
        XCTAssertThrowsError(try Self.maskedFiles(in: [dir]))
        XCTAssertThrowsError(try Self.rawFiles(in: [dir]))
        XCTAssertThrowsError(try Self.maskedFiles(in: [dir.appendingPathComponent("missing")]))
    }

    // MARK: - Tripwire 18: no d_ docId prefix

    /// A string literal starting `d_`: a prefix built (`"d_\(id)"`) or asked
    /// (`hasPrefix("d_")`). A docId carries its own prefix (`doc-`/`scene-`,
    /// ADR 0008) and no production code spells `d_` at all.
    static func docIdPrefixOffenders(in roots: [URL]) throws -> [String] {
        try rawFiles(in: roots).flatMap { file in
            file.raw.indices.filter {
                !file.raw[$0].trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && file.raw[$0].contains(#""d_"#)
            }.map { "\(file.name):\($0 + 1): \(file.raw[$0].trimmingCharacters(in: .whitespaces))" }
        }
    }

    /// **No `d_` docId prefix, built or asked** (tripwire 18's `d_` half): a
    /// docId already carries its prefix, so prepending `d_` reads zero files
    /// and a `d_` predicate matches none — both broke the phone on the
    /// 2026-05-30 smoke. Mac, phone and Core are scanned; nothing is allowed.
    func test_noDocIdIsGivenADPrefix() throws {
        let offenders = try Self.docIdPrefixOffenders(in: SourceTree.productionRootURLs)
        XCTAssertEqual(offenders, [],
            "a `d_` docId literal (tripwire 18) — a docId carries its own prefix; "
            + "ask `OpLogStore` for ids and filenames:\n" + offenders.joined(separator: "\n"))
    }

    func test_theDocIdPrefixCensusFiresOnPlantedOffenders() throws {
        let dir = try Self.plantedDir("tw18")
        try #"""
        let id = "d_\(ulid)"
        let isDoc = name.hasPrefix("d_")
        // "d_" in a comment
        let fine = "doc-\(hex)"
        let word = "head_d_"
        """#.write(to: dir.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.docIdPrefixOffenders(in: [dir])
                        .compactMap { SourceTree.Hit(offender: $0)?.line }, [1, 2])
    }
}
