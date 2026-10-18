import XCTest

/// Pins `SourceTree`'s lookup rules against planted text under `TestTemp.root`,
/// so the rules are proved independently of whatever the production tree holds
/// today. One smoke check (`test_findsProjectWindowInTheRealTree`) reads the
/// real repo, to prove the public entry points are wired to `repoRoot`.
final class SourceTreeTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = TestTemp.root.appendingPathComponent("SourceTreeFixture", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func plant(_ relative: String, _ text: String) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // (a)
    func test_filesDeclaringFindsTheTypeAndItsExtensionButNotALongerName() throws {
        try plant("App/Views/ProjectWindow.swift", """
        import SwiftUI

        @MainActor
        public struct ProjectWindow: View {
            var body: some View { EmptyView() }
        }
        """)
        try plant("App/Views/ProjectWindow+Routes.swift", """
        extension ProjectWindow {
            static func route() {}
        }
        """)
        try plant("App/Other/ProjectWindowX.swift", """
        final class ProjectWindowX {}
        extension ProjectWindowX {}
        """)

        let files = try SourceTree.filesDeclaring("ProjectWindow", under: ["App"], base: base)
        XCTAssertEqual(files, [
            "App/Views/ProjectWindow+Routes.swift",
            "App/Views/ProjectWindow.swift",
        ])

        let source = try SourceTree.sourceOfType("ProjectWindow", under: ["App"], base: base)
        XCTAssertTrue(source.contains("static func route()"))
        XCTAssertTrue(source.contains("var body: some View"))
        XCTAssertFalse(source.contains("ProjectWindowX"))
    }

    func test_filesDeclaringSeesThroughAttributesAndModifiers() throws {
        try plant("App/A.swift", """
        @available(macOS 14, *) @MainActor final class Store: ObservableObject {}
        """)
        try plant("App/B.swift", """
        nonisolated public enum Store2 {}
        // class Store {}  — a comment never declares
        let text = "struct Store {}"
        """)
        let files = try SourceTree.filesDeclaring("Store", under: ["App"], base: base)
        XCTAssertEqual(files, ["App/A.swift"])
    }

    // (b)
    func test_filesDeclaringThrowsWhenNothingDeclaresTheType() throws {
        try plant("App/A.swift", "struct Something {}\n")
        XCTAssertThrowsError(
            try SourceTree.filesDeclaring("Nowhere", under: ["App"], base: base)
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Nowhere"), message)
            XCTAssertTrue(message.contains("App"), message)
        }
    }

    func test_readThrowsNamingAMissingPath() throws {
        XCTAssertThrowsError(try SourceTree.read("App/Missing.swift", base: base)) { error in
            XCTAssertTrue(String(describing: error).contains("App/Missing.swift"))
        }
    }

    // (c)
    func test_declarationIsBraceMatchedPastAClosingBraceInAString() throws {
        try plant("App/Views/Window.swift", #"""
        struct Window {
            private func manuscriptEditor(id: String) -> String {
                let close = "}"
                let nested = "{ \(id.isEmpty ? "}" : "{") }"
                if id.isEmpty {
                    return close // a stray } in a comment
                }
                /* and } in a block */
                return nested
            }

            func after() {}
        }
        """#)

        let body = try SourceTree.declaration(
            named: "private func manuscriptEditor(", under: "App", base: base)
        XCTAssertTrue(body.hasPrefix("    private func manuscriptEditor(id: String)"), body)
        XCTAssertTrue(body.contains("return nested"), body)
        XCTAssertTrue(body.hasSuffix("}"), body)
        XCTAssertFalse(body.contains("func after()"), body)
    }

    // (d)
    func test_declarationThrowsOnTwoMatches() throws {
        try plant("App/A.swift", """
        enum A {
            static func reviewCentreShowsBoard() -> Bool { true }
        }
        """)
        try plant("App/B.swift", """
        enum B {
            static func reviewCentreShowsBoard() -> Bool { false }
        }
        """)
        XCTAssertThrowsError(
            try SourceTree.declaration(
                named: "static func reviewCentreShowsBoard(", under: "App", base: base)
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("static func reviewCentreShowsBoard("), message)
            XCTAssertTrue(message.contains("App/A.swift"), message)
            XCTAssertTrue(message.contains("App/B.swift"), message)
        }
    }

    // (e)
    func test_declarationThrowsOnZeroMatches() throws {
        try plant("App/A.swift", "enum A { static func other() {} }\n")
        XCTAssertThrowsError(
            try SourceTree.declaration(named: "func missing(", under: "App", base: base)
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("func missing("), message)
            XCTAssertTrue(message.contains("App"), message)
        }
    }

    // (f)
    func test_aHeaderInsideACommentIsIgnored() throws {
        try plant("App/A.swift", """
        enum A {
            // static func board() was here once
            /* static func board() too */
            static func board() -> Int {
                1
            }
        }
        """)
        let body = try SourceTree.declaration(named: "static func board(", under: "App", base: base)
        XCTAssertTrue(body.hasPrefix("    static func board() -> Int {"), body)
        XCTAssertTrue(body.hasSuffix("}"), body)
    }

    func test_aDefaultClosureInTheParameterListDoesNotOpenTheBody() throws {
        try plant("App/A.swift", """
        struct Watch {
            public func settle(now: () -> Date = { Date() }, list: [() -> Void] = [{}]) {
                body()
                tail()
            }
        }
        """)
        let body = try SourceTree.declaration(named: "public func settle(", under: "App", base: base)
        XCTAssertTrue(body.contains("tail()"), body)
        XCTAssertTrue(body.hasSuffix("}"), body)
    }

    func test_braceInARawStringDoesNotCloseTheBody() throws {
        try plant("App/A.swift", ##"""
        enum A {
            func raw() -> String {
                let r = #"a "quoted" } and \(not) interpolated }"#
                return r + "after"
            }
            func next() {}
        }
        """##)
        let body = try SourceTree.declaration(named: "func raw(", under: "App", base: base)
        XCTAssertTrue(body.contains(#"return r + "after""#), body)
        XCTAssertFalse(body.contains("func next()"), body)
    }

    func test_braceInAMultilineStringDoesNotCloseTheBody() throws {
        try plant("App/A.swift", #"""
        enum A {
            func multi() -> String {
                let m = """
                } a "quote" and } again — café
                """
                return m
            }
            func next() {}
        }
        """#)
        let body = try SourceTree.declaration(named: "func multi(", under: "App", base: base)
        XCTAssertTrue(body.contains("return m"), body)
        XCTAssertTrue(body.contains("again — café"), body)
        XCTAssertFalse(body.contains("func next()"), body)
    }

    func test_aHeaderInsideAStringLiteralIsIgnored() throws {
        try plant("App/A.swift", """
        enum A {
            static let doc = "static func board() is the real one"
            static func board() -> Int { 1 }
        }
        """)
        let body = try SourceTree.declaration(named: "static func board(", under: "App", base: base)
        XCTAssertEqual(body, "    static func board() -> Int { 1 }")
    }

    func test_filesDeclaringToleratesCommentsAndNestedAttributeArguments() throws {
        try plant("App/A.swift", "@Wrap(f(1)) struct Qux {}\n")
        try plant("App/B.swift", "struct Qux2 {}\nextension /* why */ Qux {}\n")
        try plant("App/C.swift", "extension // why\nQux {}\n")
        try plant("App/D.swift", "struct Qux3 {}\nstruct NotQux {}\n")
        XCTAssertEqual(
            try SourceTree.filesDeclaring("Qux", under: ["App"], base: base),
            ["App/A.swift", "App/B.swift", "App/C.swift"])
    }

    // Task 5's helpers: the window by type, bans and counts by directory, folds.
    func test_windowSourceReadsEveryFileDeclaringTheWindow() throws {
        try plant("Maugham/Views/ProjectWindow.swift", "struct ProjectWindow: View { let a = 1 }\n")
        try plant("Maugham/Views/ProjectWindow+X.swift", "extension ProjectWindow {\n    // gone\n    func b() {}\n}\n")
        try plant("Maugham/Views/Other.swift", "struct Other { func c() {} }\n")
        let lines = try SourceTree.windowCodeLines(base: base)
        XCTAssertTrue(lines.contains { $0.contains("let a = 1") })
        XCTAssertTrue(lines.contains { $0.contains("func b()") })
        XCTAssertFalse(lines.contains { $0.contains("gone") }, "comments are out")
        XCTAssertFalse(lines.contains { $0.contains("func c()") }, "only the window's files")
    }

    func test_codeLinesContainingScansEachFileAndSkipsCommentsAndStrings() throws {
        // An unclosed block opener in a string in one file must not hide the
        // next file's offender: the scan is per file and masks strings.
        try plant("Maugham/Views/A.swift", "let p = \".maugham/x/*\"\nlet s = \"banned()\" // banned()\n")
        try plant("Maugham/Views/B.swift", "func f() { banned() }\n")
        XCTAssertEqual(try SourceTree.codeLines(containing: "banned(", base: base),
                       ["Maugham/Views/B.swift: func f() { banned() }"])
        XCTAssertThrowsError(try SourceTree.codeLines(containing: "banned(", under: "Nowhere", base: base),
                             "a ban over a missing root must fail, never pass empty")
    }

    func test_codeOccurrencesCountsCodeAtAWordBoundary() throws {
        try plant("Maugham/Views/A.swift", """
        // EditorHost( in a comment
        let s = "EditorHost("
        var a: some View { EditorHost(); StatementEditorHost(); EditorHost() }
        var b: some View { content.focusedSceneValue(x) }
        """)
        try plant("Maugham/Views/B.swift", "var c: some View { EditorHost() }\n")
        XCTAssertEqual(try SourceTree.codeOccurrences(of: "EditorHost(", base: base),
                       ["Maugham/Views/A.swift": 2, "Maugham/Views/B.swift": 1])
        XCTAssertEqual(try SourceTree.codeOccurrences(of: ".focusedSceneValue(", base: base),
                       ["Maugham/Views/A.swift": 1],
                       "a token opening with punctuation needs no boundary")
        let empty = base.appendingPathComponent("Maugham/Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SourceTree.codeOccurrences(of: "x", under: "Maugham/Empty", base: base),
                             "a count over a Swift-less root must fail, never read zero")
    }

    func test_keyedByTypeFoldsTheTypesDeclarationsAndThrowsOnAnUnresolvedKey() throws {
        try plant("Maugham/Views/ProjectWindow.swift", "struct ProjectWindow {}\n")
        try plant("Maugham/Views/ProjectWindow+X.swift", """
        extension ProjectWindow {
            func a() {}
        }
        struct Child {
            func b() {}
        }
        """)
        let roots = [base.appendingPathComponent("Maugham", isDirectory: true)]
        XCTAssertEqual(
            try SourceTree.keyedByType([SourceTree.Hit(file: "ProjectWindow+X.swift", line: 2),
                                        SourceTree.Hit(file: "Other.swift", line: 1)],
                                       typeKeys: ["type:ProjectWindow"], in: roots),
            ["type:ProjectWindow", "Other.swift"])
        XCTAssertEqual(
            try SourceTree.keyedByType([SourceTree.Hit(file: "ProjectWindow+X.swift", line: 5)],
                                       typeKeys: ["type:ProjectWindow"], in: roots),
            ["ProjectWindow+X.swift"],
            "a hit in a child view sharing the file is the file's own, not the type's")
        XCTAssertThrowsError(try SourceTree.keyedByType([SourceTree.Hit(file: "Other.swift", line: 1)],
                                                        typeKeys: ["type:NoSuchType"], in: roots))
    }

    // Plan 2 final review, I1: a type key claims DECLARATIONS, not files.
    func test_declarationRangesAreHeaderThroughBraceMatchedClose() throws {
        try plant("App/Mixed.swift", """
        import SwiftUI

        @MainActor
        extension Widget where T: Equatable {
            func a() { let s = "}" }
        }

        struct ChildView {
            func b() {}
        }

        private extension Widget {
            var c: Int { 1 }
        }
        // extension Widget { — a comment never declares
        """)
        let ranges = try SourceTree.declarationRanges(of: "Widget", under: ["App"], base: base)
        XCTAssertEqual(ranges, ["App/Mixed.swift": [4...6, 12...14]])
    }

    // Plan 2 final review, I2: access modifiers are not part of a header.
    func test_declarationIgnoresAccessModifiersOnBothSides() throws {
        try plant("App/A.swift", "struct A {\n    func f() { 1 }\n}\n")
        try plant("App/B.swift", "extension B {\n    fileprivate static func g() { 2 }\n}\n")
        XCTAssertEqual(try SourceTree.declaration(named: "private func f(", under: "App", base: base),
                       "    func f() { 1 }",
                       "a private header finds the declaration a split made internal")
        XCTAssertEqual(try SourceTree.declaration(named: "static func g(", under: "App", base: base),
                       "    fileprivate static func g() { 2 }")
        XCTAssertEqual(try SourceTree.declaration(named: "private static func g(", under: "App", base: base),
                       "    fileprivate static func g() { 2 }")
        // Uniqueness still holds across modifiers.
        try plant("App/C.swift", "struct C {\n    private func f() { 3 }\n}\n")
        XCTAssertThrowsError(try SourceTree.declaration(named: "func f(", under: "App", base: base))
        XCTAssertThrowsError(try SourceTree.declaration(named: "private func f(", under: "App", base: base))
        XCTAssertEqual(SourceTree.withoutAccessModifiers("@MainActor public final func h("),
                       "@MainActor final func h(")
    }

    // Plan 2 final review, M5: a file ending inside a string or comment is a
    // masker that lost its place, and is reported rather than read blind.
    func test_aFileEndingInsideAStringOrCommentIsReported() throws {
        try plant("Maugham/Views/Fine.swift", "let a = \"x\" // ok\n")
        XCTAssertNoThrow(try SourceTree.sources(under: "Maugham/Views", base: base))
        for (name, text) in [("Open.swift", "let a = 1\n/* never closed\nbanned()\n"),
                             ("String.swift", "let r = /\"/\nbanned()\n"),
                             ("Multiline.swift", "let s = \"\"\"\nbanned()\n")] {
            try plant("Maugham/Views/\(name)", text)
            XCTAssertThrowsError(try SourceTree.sources(under: "Maugham/Views", base: base)) { error in
                XCTAssertTrue(String(describing: error).contains(name), "\(error)")
            }
            XCTAssertThrowsError(try SourceTree.codeLines(containing: "banned(", base: base),
                                 "\(name): a ban must not read past the lost place")
            try FileManager.default.removeItem(at: base.appendingPathComponent("Maugham/Views/\(name)"))
        }
    }

    // (g)
    func test_findsProjectWindowInTheRealTree() throws {
        let files = try SourceTree.filesDeclaring("ProjectWindow", under: ["Maugham"])
        XCTAssertTrue(files.contains("Maugham/Views/ProjectWindow.swift"), "\(files)")
        XCTAssertTrue(SourceTree.productionRoots.contains("Maugham"))
        XCTAssertTrue(SourceTree.productionRoots.contains("MaughamPhone"))
        XCTAssertTrue(SourceTree.productionRoots.contains("Packages/MaughamCore/Sources/MaughamCore"))
    }
}
