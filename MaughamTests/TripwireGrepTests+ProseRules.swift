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
        let name: String
        let raw: [String]
        let code: [String]
    }

    /// Every `.swift` file under `roots`, masked. Dot-directories are skipped
    /// by name.
    static func maskedFiles(in roots: [URL]) throws -> [MaskedFile] {
        var files: [MaskedFile] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                if url.lastPathComponent.hasPrefix(".") { walker.skipDescendants(); continue }
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let masked = String(decoding: try SourceTree.checkedMask(text, path: url.path),
                                    as: UTF8.self)
                files.append(MaskedFile(
                    name: url.lastPathComponent,
                    raw: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                    code: masked.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
            }
        }
        return files
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

    // MARK: - Tripwire 9: no .onTapGesture in a sidebar list

    /// **The proxy**: a file that styles a list `.sidebar` declares no
    /// `.onTapGesture` anywhere. A row view in a file of its own is NOT seen —
    /// the census reads the file that holds the `List`, not every view the
    /// list hosts.
    static func sidebarTapGestureOffenders(in roots: [URL]) throws -> [String] {
        let sidebarFiles = try maskedFiles(in: roots).filter { file in
            file.code.contains { $0.contains(".listStyle(.sidebar)") || $0.contains("SidebarListStyle(") }
        }
        return codeLineOffenders(sidebarFiles) { $0.contains(".onTapGesture") }
    }

    /// **No `.onTapGesture` for clickable rows inside `List(.sidebar)`**
    /// (tripwire 9): hit-testing is unreliable there and it costs the row its
    /// single-click selection; use `Button(.plain)` or `List(selection:)`.
    func test_noTapGestureInASidebarListFile() throws {
        let offenders = try Self.sidebarTapGestureOffenders(in: SourceTree.productionRootURLs)
        XCTAssertEqual(offenders, [],
            "an `.onTapGesture` in a file holding a sidebar list (tripwire 9):\n"
            + offenders.joined(separator: "\n"))
    }

    func test_theSidebarTapGestureCensusFiresOnPlantedOffenders() throws {
        let dir = try Self.plantedDir("tw9")
        try """
        struct Side: View {
            var body: some View {
                List { Text("a").onTapGesture { open() } }
                    .listStyle(.sidebar)
                // .onTapGesture in a comment
            }
        }
        """.write(to: dir.appendingPathComponent("Side.swift"), atomically: true, encoding: .utf8)
        try """
        struct Plain: View {
            var body: some View { Text("a").onTapGesture { open() } }
        }
        """.write(to: dir.appendingPathComponent("Plain.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.sidebarTapGestureOffenders(in: [dir]),
                       [#"Side.swift:3: List { Text("a").onTapGesture { open() } }"#])
    }

    // MARK: - Tripwire 18: no d_ docId prefix

    /// A string literal starting `d_`: a prefix built (`"d_\(id)"`) or asked
    /// (`hasPrefix("d_")`). A docId carries its own prefix (`doc-`/`scene-`,
    /// ADR 0008) and no production code spells `d_` at all.
    static func docIdPrefixOffenders(in roots: [URL]) throws -> [String] {
        let files = try maskedFiles(in: roots)
        return files.flatMap { file in
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
