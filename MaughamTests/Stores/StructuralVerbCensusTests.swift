import XCTest
@testable import Maugham

/// **Every verb that awaits before it writes the manifest enters a structural
/// verb** (F7 fix round, review I1; widened by the final fix round's M4).
///
/// A verb that reads part of the structure, suspends (file surgery, a trash
/// move, a coordinated write) and then saves would undo a manifest adopted
/// from another device during the wait — the adopted chapter gone from memory
/// and disk and the incoming bytes archived nowhere. `beginStructuralVerb()`
/// is what makes `DocumentStore` hold such a manifest until the verb is done.
/// Remembering to call it is exactly the kind of rule a later verb forgets, so
/// this census derives the population from the code. Three shapes are in it:
///
/// 1. **Save** — a function with an `await` on a line before its first
///    `saveManifest()`.
/// 2. **Write** — a function with an `await` before a direct
///    `writeManifest(` call (the coordinated door `saveManifest` itself uses),
///    which bypasses `saveManifest`'s own verb bracket.
/// 3. **Mutate** — a function with an `await` before a MUTATION of the
///    window's manifest and no `saveManifest()` at all, leaving the save to its
///    caller. A mutation is a direct assignment to `manifest`/`self.manifest`
///    (or one of its fields), a collection verb on one of its fields, or a
///    call to a MUTATOR — a synchronous `ProjectStore*` function that itself
///    mutates the manifest directly. The mutators are DERIVED, not listed.
///
/// Every member must call `beginStructuralVerb()` or be in `allowed` by FILE
/// and FUNCTION, with its reason. A helper allowed for leaving the verb to its
/// caller is checked from the other side too: every production function that
/// calls it must itself be a verb.
///
/// **Its known limits**, stated precisely: a mutation of ANOTHER object's
/// manifest (`live.manifest.schemaVersion = …` in `DocumentStore`) is not a
/// mutation of the window's own copy by this spelling and is not seen; a
/// mutator that is itself `async`, or that mutates only through another
/// object, is not derived as one; and a mutation reached through a closure
/// stored and called later is invisible to a line scan.
final class StructuralVerbCensusTests: XCTestCase {

    private var sourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    /// Population members that may leave `beginStructuralVerb()` out, by
    /// `"<file>: <function>"`, each for a reason about THAT function.
    static let allowed: [String: String] = [
        // Mutate: helpers of `restoreTrashEntry`, which IS a verb and holds it
        // open across them. Their callers are checked below.
        "ProjectStore+Trash.swift: restoreStructureItem":
            "helper of restoreTrashEntry, which holds the verb open",
        "ProjectStore+Trash.swift: restoreResearchItem":
            "helper of restoreTrashEntry, which holds the verb open",
        "ProjectStore+Trash.swift: restorePriorVersion":
            "helper of restoreTrashEntry, which holds the verb open",
        "ProjectStore+Research.swift: trashResearchItemCore":
            "helper of deleteResearchItems, which holds the verb open",
        // Write: the schema gate and its heal. Both write the DISK manifest
        // they just read through `readManifest()` — which first waits for any
        // verb and held manifest to settle and takes on unannounced bytes —
        // raised to the current schema. Neither writes the window's copy, so
        // there is no in-memory structure for them to undo an adoption with,
        // and `DocumentStore` has no structural-verb bracket of its own.
        "DocumentStore+Registry.swift: gateOldBuildsOut":
            "writes the disk manifest it just read, raised; not the window's copy",
        "DocumentStore.swift: healTheSchemaGateIfNarrowed":
            "writes the disk manifest it just read, raised; not the window's copy",
        // Write: a design proposal's own backup manifest (its private static
        // `writeManifest(_:at:)`), not the project's.
        "ProposalPromotion.swift: approve":
            "writes a design proposal's backup manifest, not the project's",
    ]

    func test_everyVerbThatAwaitsBeforeItWritesTheManifestEntersAStructuralVerb() throws {
        let functions = try productionFunctions()
        let population = Self.population(in: functions)
        let offenders = population
            .filter { !$0.entersStructuralVerb && Self.allowed[$0.key] == nil }
            .map { "\($0.key) [\($0.shape)]" }
        XCTAssertEqual(offenders, [],
                       "these functions await before writing the manifest without beginStructuralVerb()")
        XCTAssertGreaterThan(population.filter { $0.shape == .save }.count, 5,
                             "the control: a scan that finds no save verb is reading nothing")
        XCTAssertFalse(population.filter { $0.shape == .mutate }.isEmpty,
                       "the control: the mutate rule finds nothing — it is reading nothing")

        // Every allow-list entry still names a population member, so a stale
        // entry cannot quietly excuse a later function of the same name.
        let keys = Set(population.map(\.key))
        XCTAssertEqual(Self.allowed.keys.filter { !keys.contains($0) }.sorted(), [],
                       "allow-list entries that no longer name a population member")
    }

    /// The other side of the helpers' allowance: whoever calls one must be a
    /// verb, or the helper's mutation lands outside any bracket.
    func test_everyCallerOfAnAllowedHelperIsItselfAVerb() throws {
        let functions = try productionFunctions()
        let helpers = Self.population(in: functions)
            .filter { $0.shape == .mutate && Self.allowed[$0.key] != nil }
            .map(\.name)
        XCTAssertFalse(helpers.isEmpty, "the control: no allowed helper was found")
        let offenders = Self.unbracketedCallers(of: helpers, in: functions)
        XCTAssertEqual(offenders, [],
                       "these call a helper that leaves the verb to its caller, without being a verb")
    }

    /// The planted offenders: each shape fed a function written the way
    /// `moveStructureItem` was before the fix, and the same function fixed.
    func test_theCensusFiresOnPlantedOffenders() {
        func shapes(_ text: String) -> [(Shape, Bool)] {
            Self.population(in: Self.functions(in: text, file: "ProjectStore+Planted.swift"))
                .map { ($0.shape, $0.entersStructuralVerb) }
        }
        let save = """
            func movePlanted() async throws {
                let copy = manifest.structure
                try await documentStore.relocate(plan: plan)
                manifest.structure = copy
                try await saveManifest()
            }
            """
        XCTAssertEqual(shapes(save).map(\.0), [.save])
        XCTAssertEqual(shapes(save).map(\.1), [false])
        XCTAssertEqual(
            shapes(save.replacingOccurrences(
                of: "let copy", with: "beginStructuralVerb(); defer { endStructuralVerb() }\n    let copy"))
                .map(\.1), [true])

        let write = """
            func gatePlanted() async throws {
                let data = try await readManifest()
                try await writeManifest(data)
            }
            """
        XCTAssertEqual(shapes(write).map(\.0), [.write])
        XCTAssertEqual(shapes(write).map(\.1), [false])

        let mutateDirect = """
            func restorePlanted() async throws {
                let entry = try await trashStore.restore(trashId: id)
                manifest.research.append(item)
            }
            """
        XCTAssertEqual(shapes(mutateDirect).map(\.0), [.mutate])

        let mutateThroughHelper = """
            func replacePlantedChildren(with items: [StructureItem]) {
                manifest.structure = items
            }
            func restoreThroughHelperPlanted() async throws {
                _ = try await trashStore.restore(trashId: id)
                replacePlantedChildren(with: [])
            }
            """
        XCTAssertEqual(shapes(mutateThroughHelper).map(\.0), [.mutate],
                       "the mutator is derived from its body, and its caller is the member")

        let clean = """
            func renamePlanted() async throws {
                manifest.title = "x"
                try await saveManifest()
            }
            func readPlanted() async throws {
                let manifest = try await readManifest()
                live.manifest.schemaVersion = 9
            }
            """
        XCTAssertEqual(shapes(clean).count, 0,
                       "saving without awaiting first, a local named manifest and another object's manifest are outside the population")

        // The helper rule: a caller of an allowed helper that is not a verb.
        let caller = Self.functions(in: """
            func unwrappedPlanted() async throws {
                _ = try await restoreStructureItem(item, entryId: id, pending: nil)
            }
            func wrappedPlanted() async throws {
                beginStructuralVerb(); defer { endStructuralVerb() }
                _ = try await restoreStructureItem(item, entryId: id, pending: nil)
            }
            """, file: "ProjectStore+Planted.swift")
        XCTAssertEqual(Self.unbracketedCallers(of: ["restoreStructureItem"], in: caller),
                       ["ProjectStore+Planted.swift: unwrappedPlanted"])
    }

    // MARK: - The scan

    enum Shape: String { case save, write, mutate }

    struct Function {
        let file: String
        let name: String
        let body: [String]
        var key: String { "\(file): \(name)" }
        var entersStructuralVerb: Bool { body.contains { $0.contains("beginStructuralVerb()") } }
    }

    struct Member {
        let file: String
        let name: String
        let shape: Shape
        let entersStructuralVerb: Bool
        var key: String { "\(file): \(name)" }
    }

    private func productionFunctions() throws -> [Function] {
        var all: [Function] = []
        let walker = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceDir, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            all.append(contentsOf: Self.functions(in: text, file: url.lastPathComponent))
        }
        return all
    }

    /// Every function's body, found by brace depth over code with string
    /// literals and line comments removed.
    static func functions(in text: String, file: String) -> [Function] {
        let lines = text.components(separatedBy: "\n")
        var found: [Function] = []
        var i = 0
        while i < lines.count {
            guard let name = functionName(in: lines[i]) else { i += 1; continue }
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
            found.append(Function(file: file, name: name, body: body))
            i += 1
        }
        return found
    }

    /// The three shapes over a set of functions. The mutators are derived
    /// from the same set, so a planted mutator is seen by a planted caller.
    static func population(in functions: [Function]) -> [Member] {
        let mutators = Set(functions.filter { f in
            f.file.hasPrefix("ProjectStore")
                && !f.body.contains { $0.contains("await") }
                && f.body.dropFirst().contains { mutatesDirectly($0) }
        }.map(\.name))

        var members: [Member] = []
        for f in functions where f.name != "saveManifest" && f.name != "writeManifest" {
            let firstAwait = f.body.firstIndex { $0.contains("await") }
            func member(_ shape: Shape) {
                members.append(Member(file: f.file, name: f.name, shape: shape,
                                      entersStructuralVerb: f.entersStructuralVerb))
            }
            guard let firstAwait else { continue }
            let firstSave = f.body.firstIndex { $0.contains("saveManifest()") }
            if let firstSave, firstAwait < firstSave {
                member(.save)
                continue
            }
            if let firstWrite = f.body.firstIndex(where: { writesManifest($0) }),
               firstAwait < firstWrite {
                member(.write)
                continue
            }
            if firstSave == nil,
               f.body.indices.contains(where: { k in
                   k > firstAwait && (mutatesDirectly(f.body[k])
                                      || callsAny(of: mutators, excluding: f.name, in: f.body[k]))
               }) {
                member(.mutate)
            }
        }
        return members
    }

    /// Functions calling any of `helpers` that do not enter a verb themselves.
    static func unbracketedCallers(of helpers: [String], in functions: [Function]) -> [String] {
        functions
            .filter { f in
                !helpers.contains(f.name)
                    && f.body.dropFirst().contains { callsAny(of: Set(helpers), excluding: f.name, in: $0) }
                    && !f.entersStructuralVerb
            }
            .map(\.key)
    }

    private static let directMutation = try! NSRegularExpression(pattern:
        #"(?<![.\w])(?<!let )(?<!var )(self\.)?manifest(\.[A-Za-z_]\w*)*\s*(=(?!=)|\+=|-=)"#
        + #"|(?<![.\w])(self\.)?manifest(\.[A-Za-z_]\w*)+\.(append|insert|remove|removeAll|removeFirst|removeLast|sort|swapAt)\("#)

    static func mutatesDirectly(_ line: String) -> Bool {
        line.contains("manifest") && directMutation.firstMatch(
            in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func writesManifest(_ line: String) -> Bool {
        line.contains("writeManifest(")
            && line.range(of: #"\bwriteManifest\("#, options: .regularExpression) != nil
            && functionName(in: line) == nil
    }

    private static func callsAny(of names: Set<String>, excluding own: String, in line: String) -> Bool {
        guard !names.isEmpty, line.contains("("), functionName(in: line) == nil else { return false }
        let alternatives = names.sorted().map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let calls = callPatterns.pattern(#"(?<![.\w])(?:self\.)?("# + alternatives + #")\("#)
        let range = NSRange(line.startIndex..., in: line)
        return calls.matches(in: line, range: range).contains { match in
            Range(match.range(at: 1), in: line).map { String(line[$0]) != own } ?? false
        }
    }

    /// Compiled once per pattern: the mutator set and the helper set are each
    /// ONE alternation asked of every line.
    private static let callPatterns = PatternCache()

    private final class PatternCache: @unchecked Sendable {
        private var compiled: [String: NSRegularExpression] = [:]
        private let lock = NSLock()
        func pattern(_ source: String) -> NSRegularExpression {
            lock.lock(); defer { lock.unlock() }
            if let hit = compiled[source] { return hit }
            let made = try! NSRegularExpression(pattern: source)
            compiled[source] = made
            return made
        }
    }

    private static let funcDeclaration = try! NSRegularExpression(pattern: #"\bfunc\s+(\w+)"#)

    private static func functionName(in line: String) -> String? {
        let code = stripped(line)
        guard code.contains("func"),
              let match = funcDeclaration.firstMatch(
                in: code, range: NSRange(code.startIndex..., in: code)),
              let range = Range(match.range(at: 1), in: code)
        else { return nil }
        return String(code[range])
    }

    private static func stripped(_ line: String) -> String {
        let noStrings = line.replacingOccurrences(
            of: #""[^"]*""#, with: "\"\"", options: .regularExpression)
        return noStrings.components(separatedBy: "//").first ?? ""
    }
}
