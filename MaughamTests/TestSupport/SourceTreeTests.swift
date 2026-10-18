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

    // (g)
    func test_findsProjectWindowInTheRealTree() throws {
        let files = try SourceTree.filesDeclaring("ProjectWindow", under: ["Maugham"])
        XCTAssertTrue(files.contains("Maugham/Views/ProjectWindow.swift"), "\(files)")
        XCTAssertTrue(SourceTree.productionRoots.contains("Maugham"))
        XCTAssertTrue(SourceTree.productionRoots.contains("MaughamPhone"))
        XCTAssertTrue(SourceTree.productionRoots.contains("Packages/MaughamCore/Sources/MaughamCore"))
    }
}
