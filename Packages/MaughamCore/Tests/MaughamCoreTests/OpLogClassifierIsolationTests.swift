import Foundation
import XCTest
@testable import MaughamCore

/// **The split moved code out of a `@MainActor` class, and isolation does not
/// travel with the text** (plan 6's whole-branch review, C1).
///
/// Every function that lived on `OpLogStore` was main-actor isolated by
/// inheritance. Moved verbatim into a plain `enum`, a SYNCHRONOUS function
/// still runs on its caller's executor, so nothing changes. An ASYNC one does
/// not: under Swift 5.10 a nonisolated async function always runs on the
/// generic executor (SE-0338), so each call becomes a real hop off main — a
/// suspension point inside `Document.load` that lets a seal delete a tail, or
/// an append move the remembered head, between two reads of one load.
/// `OpLogClassifier.loadFileDiagnosed` lost its isolation exactly that way and
/// no test reddened.
///
/// Two pins: a MEASUREMENT taken inside the function (the mirror of
/// `UnsignedDoorTests.test_theHeldLineWalkDoesNotRunOnTheMainThread`), and a
/// census over the six files the split created, so the next async function
/// moved into one of them has to say where it runs. `OpLogClassifier` is also
/// `@MainActor` at type level, pinned by its own census below; its file stays
/// in the list because a type nested in it does not inherit that attribute.
@MainActor
final class OpLogClassifierIsolationTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = TestTemp.root.appendingPathComponent("OCI-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        OpLogClassifier.loadFileObserverForTesting = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - The measurement

    /// `loadDiagnosed` reads each file through `loadFileDiagnosed`; the
    /// observer records where each read was standing. Every one is on main.
    func test_thePerFileLoadRunsOnTheMainActor() async throws {
        let state = OpLogDeviceState(fileURL: tmp.appendingPathComponent("state.json"))
        let store = OpLogStore(projectURL: tmp, state: state)
        for (id, device) in [("01HZK01", "m"), ("01HZK02", "n")] {
            try await store.append(Op(
                opId: id, docId: "doc-1", at: Date(timeIntervalSince1970: 0),
                device: device, session: "s", kind: .typingBurst,
                changes: [.init(paragraphId: ParagraphID.mint(), prior: nil, next: "x")]))
        }

        final class Where: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [Bool] = []
            func note(_ main: Bool) { lock.lock(); seen.append(main); lock.unlock() }
            var onMain: [Bool] { lock.lock(); defer { lock.unlock() }; return seen }
        }
        let place = Where()
        OpLogClassifier.loadFileObserverForTesting = {
            place.note(Thread.isMainThread)
        }

        let result = try await store.loadDiagnosed(docId: "doc-1")

        XCTAssertEqual(result.ops.count, 2, "premise: both files were read")
        XCTAssertEqual(place.onMain, [true, true],
                       "every per-file read ran on the main actor, atomic with appends and seals")
    }

    // MARK: - The census

    /// The files plan 6 split out of `OpLogStore.swift`. Each began life on a
    /// `@MainActor` class. `OpLogClassifier` is `@MainActor` at type level as
    /// well (`test_theClassifierIsMainActorAtTypeLevel`), and stays here: a
    /// type nested in it, or declared beside it, inherits nothing.
    private static let splitFiles = [
        "OpLogFiles", "StreamCensus", "StreamPositions",
        "OpLogClassifier", "LocalWritePermitBuilder", "SegmentSealer",
    ]

    /// Async functions in those files allowed to run off the main actor, by
    /// `File.swift:name`, each with its reason. Empty: none is.
    private static let offMainAllowed: [String: String] = [:]

    private static var sourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MaughamCore
            .appendingPathComponent("Sources/MaughamCore")
    }

    private static let funcDecl = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|package|nonisolated|static|class|final|override|mutating)\s+)*func\s+(\w+)"#)

    /// Every `async` function declared in `source` without `@MainActor` among
    /// its attributes (on its own line or the lines directly above), by name.
    /// The signature runs from `func` to its body's `{` (or the line's end),
    /// so an `async` on a wrapped line is still seen.
    static func asyncWithoutMainActor(in source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var offenders: [String] = []
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            guard let m = funcDecl.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let name = ns.substring(with: m.range(at: 1))
            var signature = ""
            var j = i
            while j < lines.count {
                if let brace = lines[j].firstIndex(of: "{") {
                    signature += lines[j][..<brace]
                    break
                }
                signature += lines[j] + " "
                j += 1
            }
            guard signature.range(of: #"\basync\b"#, options: .regularExpression) != nil
            else { continue }
            var attributes = line
            var k = i - 1
            while k >= 0, lines[k].trimmingCharacters(in: .whitespaces).hasPrefix("@") {
                attributes += " " + lines[k]
                k -= 1
            }
            if !attributes.contains("@MainActor") { offenders.append(name) }
        }
        return offenders
    }

    func test_everyAsyncFunctionInTheSplitFilesSaysItRunsOnTheMainActor() throws {
        var offenders: [String] = []
        for file in Self.splitFiles {
            let url = Self.sourceDir.appendingPathComponent("\(file).swift")
            let source = try String(contentsOf: url, encoding: .utf8)
            for name in Self.asyncWithoutMainActor(in: source)
            where Self.offMainAllowed["\(file).swift:\(name)"] == nil {
                offenders.append("\(file).swift:\(name)")
            }
        }
        XCTAssertEqual(offenders, [],
                       "an async function moved off a @MainActor class runs on the generic executor; mark it @MainActor or allow-list it with a reason")
    }

    // MARK: - The classifier, isolated at type level

    /// Why `typeName`, declared in `source`, does NOT keep every async member
    /// on the main actor: its declaration is missing or lacks a `@MainActor`
    /// attribute (on its line or the attribute lines directly above), or an
    /// async function in the file opts out with `nonisolated`.
    static func typeLevelMainActorOffenders(of typeName: String, in source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        let header = try! NSRegularExpression(
            pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|package|final)\s+)*(?:enum|struct|class)\s+"#
                + NSRegularExpression.escapedPattern(for: typeName) + #"\b"#)
        guard let at = lines.firstIndex(where: {
            header.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil
        }) else { return ["no declaration of \(typeName)"] }
        var attributes = lines[at]
        var k = at - 1
        while k >= 0, lines[k].trimmingCharacters(in: .whitespaces).hasPrefix("@") {
            attributes += " " + lines[k]
            k -= 1
        }
        var offenders = attributes.contains("@MainActor") ? [] : ["\(typeName) is not @MainActor"]
        // Every function whose own line says `nonisolated` and whose signature is async.
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            guard let m = funcDecl.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  line.range(of: #"\bnonisolated\b"#, options: .regularExpression) != nil
            else { continue }
            let name = ns.substring(with: m.range(at: 1))
            var signature = ""
            for next in lines[i...] {
                if let brace = next.firstIndex(of: "{") { signature += next[..<brace]; break }
                signature += next + " "
            }
            if signature.range(of: #"\basync\b"#, options: .regularExpression) != nil {
                offenders.append("nonisolated async \(name)")
            }
        }
        return offenders
    }

    /// **`OpLogClassifier` is `@MainActor` at type level** (tripwire 56), so an
    /// async function moved into it runs on the main actor unless it says
    /// `nonisolated` — which this refuses, the way the census above refuses an
    /// unattributed one.
    func test_theClassifierIsMainActorAtTypeLevel() throws {
        let url = Self.sourceDir.appendingPathComponent("OpLogClassifier.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(Self.typeLevelMainActorOffenders(of: "OpLogClassifier", in: source), [],
                       "OpLogClassifier keeps its async members on the main actor by its type-level @MainActor")
    }

    func test_theTypeLevelCensusCatchesPlantedOffenders() {
        let bare = """
            public enum Planted {
                static func sync() -> Int { 0 }
            }
            """
        XCTAssertEqual(Self.typeLevelMainActorOffenders(of: "Planted", in: bare),
                       ["Planted is not @MainActor"])
        let optedOut = """
            /// @MainActor named in prose above is not the attribute
            @MainActor
            public enum Planted {
                nonisolated static func walk() -> Int { 0 }
                public nonisolated static func away(
                    url: URL
                ) async -> Int { 0 }
                static func stays() async -> Int { 0 }
            }
            """
        XCTAssertEqual(Self.typeLevelMainActorOffenders(of: "Planted", in: optedOut),
                       ["nonisolated async away"])
        XCTAssertEqual(Self.typeLevelMainActorOffenders(of: "Missing", in: optedOut),
                       ["no declaration of Missing"])
    }

    /// The census against planted code: an unattributed async function fires,
    /// so does one whose `async` sits on a wrapped line; an attribute on the
    /// line above, on the same line, and a sync function do not.
    func test_theCensusCatchesAPlantedOffender() {
        let planted = """
            enum Planted {
                public static func bare(url: URL) async throws -> Int { 0 }
                public static func wrapped(
                    url: URL
                ) async -> Int {
                    0
                }
                @MainActor
                public static func above(url: URL) async throws -> Int { 0 }
                @discardableResult
                @MainActor
                static func stacked() async -> Int { 0 }
                @MainActor public static func inline() async -> Int { 0 }
                public static func sync(url: URL) throws -> Int { 0 }
                /// func prose() async is a comment, not a declaration
            }
            """
        XCTAssertEqual(Self.asyncWithoutMainActor(in: planted), ["bare", "wrapped"])
    }
}
