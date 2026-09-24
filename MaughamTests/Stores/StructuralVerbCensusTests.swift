import XCTest
@testable import Maugham

/// **Every verb that awaits before it saves the manifest enters a structural
/// verb** (F7 fix round, review I1).
///
/// A verb that reads part of the structure, suspends (file surgery, a trash
/// move, a coordinated write) and then saves would undo a manifest adopted
/// from another device during the wait — the adopted chapter gone from memory
/// and disk and the incoming bytes archived nowhere. `beginStructuralVerb()`
/// is what makes `DocumentStore` hold such a manifest until the verb is done.
/// Remembering to call it is exactly the kind of rule a later verb forgets, so
/// this census derives the population from the code: any production function
/// whose body has an `await` on a line before its first `saveManifest()` must
/// call `beginStructuralVerb()`.
///
/// **Its known limit**: a function that awaits and then mutates the manifest
/// but leaves the save to its caller is not seen. Four such helpers exist
/// today, each reached only from a caller that IS wrapped, which holds the
/// verb open across them: `restoreStructureItem`, `restoreResearchItem` and
/// `restorePriorVersion` (`ProjectStore+Trash.swift`, under
/// `restoreTrashEntry`) and `trashResearchItemCore`
/// (`ProjectStore+Research.swift`, under `deleteResearchItems`). A new
/// caller of any of the four must be a verb too.
final class StructuralVerbCensusTests: XCTestCase {

    private var sourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    func test_everyVerbThatAwaitsBeforeItSavesEntersAStructuralVerb() throws {
        var offenders: [String] = []
        var population = 0
        let walker = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceDir, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for verb in Self.verbsAwaitingBeforeSave(in: text) {
                population += 1
                if !verb.entersStructuralVerb {
                    offenders.append("\(url.lastPathComponent): \(verb.name)")
                }
            }
        }
        XCTAssertEqual(offenders, [],
                       "these verbs await before saving the manifest without beginStructuralVerb()")
        XCTAssertGreaterThan(population, 5,
                             "the control: a scan that finds no such verb is reading nothing")
    }

    /// The planted offender: the census's own shape, fed a verb written the
    /// way `moveStructureItem` was before the fix, and the same verb fixed.
    func test_theCensusFiresOnAPlantedOffender() {
        let offender = """
            func movePlanted() async throws {
                let copy = manifest.structure
                try await documentStore.relocate(plan: plan)
                manifest.structure = copy
                try await saveManifest()
            }
            """
        let fixed = """
            func movePlanted() async throws {
                beginStructuralVerb(); defer { endStructuralVerb() }
                let copy = manifest.structure
                try await documentStore.relocate(plan: plan)
                manifest.structure = copy
                try await saveManifest()
            }
            """
        let clean = """
            func renamePlanted() async throws {
                manifest.title = "x"
                try await saveManifest()
            }
            """
        XCTAssertEqual(Self.verbsAwaitingBeforeSave(in: offender).map(\.entersStructuralVerb), [false])
        XCTAssertEqual(Self.verbsAwaitingBeforeSave(in: fixed).map(\.entersStructuralVerb), [true])
        XCTAssertEqual(Self.verbsAwaitingBeforeSave(in: clean).count, 0,
                       "a verb that saves without awaiting first is outside the population")
    }

    // MARK: - The scan

    struct Verb { let name: String; let entersStructuralVerb: Bool }

    /// Functions whose body awaits on a line before its first `saveManifest()`.
    /// Bodies are found by brace depth over code with string literals and
    /// line comments removed; `saveManifest`'s own declaration is skipped.
    static func verbsAwaitingBeforeSave(in text: String) -> [Verb] {
        let lines = text.components(separatedBy: "\n")
        var verbs: [Verb] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let name = functionName(in: line),
                  name != "saveManifest" else { i += 1; continue }
            var depth = 0, started = false, j = i
            var body: [String] = []
            while j < lines.count {
                let code = stripped(lines[j])
                depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
                if code.contains("{") { started = true }
                body.append(code)
                if started && depth <= 0 { break }
                j += 1
            }
            if let firstSave = body.firstIndex(where: { $0.contains("saveManifest()") }),
               body[..<firstSave].contains(where: { $0.contains("await") }) {
                verbs.append(Verb(
                    name: name,
                    entersStructuralVerb: body.contains { $0.contains("beginStructuralVerb()") }))
            }
            i += 1
        }
        return verbs
    }

    private static func functionName(in line: String) -> String? {
        let code = stripped(line)
        guard let range = code.range(of: #"\bfunc\s+(\w+)"#, options: .regularExpression)
        else { return nil }
        return code[range].components(separatedBy: .whitespaces).last
    }

    private static func stripped(_ line: String) -> String {
        let noStrings = line.replacingOccurrences(
            of: #""[^"]*""#, with: "\"\"", options: .regularExpression)
        return noStrings.components(separatedBy: "//").first ?? ""
    }
}
