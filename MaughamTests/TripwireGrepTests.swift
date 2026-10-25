import XCTest

/// Mac-side reach-around tripwires (twin of TripwirePhoneGrepTest). Scans
/// Maugham/ in pure Swift (mirrors the phone approach; no Process spawn).
final class TripwireGrepTests: XCTestCase {

    // MARK: - Helpers

    /// Walk all .swift files under `dir`, returning offending lines for any
    /// pattern in `patterns`, skipping files in `allowed`, and skipping
    /// individual lines that match any `excludeLine` predicate.
    private func grepSwift(
        in dir: URL,
        patterns: [String],
        allowed: Set<String> = [],
        excludeLine: ((String) -> Bool)? = nil,
        extraOffender: ((String) -> Bool)? = nil
    ) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if allowed.contains(url.lastPathComponent) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                if let exclude = excludeLine, exclude(lineStr) { continue }
                let record = { offenders.append("\(url.lastPathComponent):\(i + 1): \(lineStr.trimmingCharacters(in: .whitespaces))") }
                var recorded = false
                for pat in patterns where lineStr.contains(pat) {
                    record(); recorded = true; break
                }
                if !recorded, let extra = extraOffender, extra(lineStr) { record() }
            }
        }
        return offenders
    }

    private var sourceDir: URL {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Maugham", isDirectory: true)
    }

    /// Like `grepSwift` but scans only the named files (by `lastPathComponent`)
    /// under `dir`. Used by the user-content-mover tripwire, which targets the
    /// specific `ProjectStore+*` seams that move user-editable paths. A named
    /// file the walk never meets is itself an offender (`missingScope`).
    private func grepSwift(
        in dir: URL,
        files: Set<String>,
        patterns: [String],
        excludeLine: ((String) -> Bool)? = nil
    ) throws -> [String] {
        let fm = FileManager.default
        var offenders: [String] = []
        var seen: Set<String> = []
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return Self.missingScope(files, seen: seen)
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard files.contains(url.lastPathComponent) else { continue }
            seen.insert(url.lastPathComponent)
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                if let exclude = excludeLine, exclude(lineStr) { continue }
                for pat in patterns where lineStr.contains(pat) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(lineStr.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return offenders + Self.missingScope(files, seen: seen)
    }

    /// `grepSwift`'s whole-file allow-list over several roots at once.
    /// `allowed` may hold `type:<TypeName>` keys (`SourceTree.expandingTypeKeys`),
    /// resolved across ALL the roots before any of them is walked — a type
    /// declared in Core allows its files wherever the census looks.
    private func grepSwift(
        in roots: [URL],
        patterns: [String],
        allowed: Set<String>,
        excludeLine: ((String) -> Bool)?,
        extraOffender: ((String) -> Bool)?
    ) throws -> [String] {
        let (allowance, unresolved) = SourceTree.expandingTypeKeys(allowed, in: roots)
        var offenders = unresolved
        for root in roots {
            // A type key allows its type's DECLARATIONS, not the files holding
            // them, so its hits are dropped per line rather than per file.
            offenders += try grepSwift(
                in: root, patterns: patterns, allowed: Set(allowance.plain.keys),
                excludeLine: excludeLine, extraOffender: extraOffender)
                .filter { offender in
                    guard let hit = SourceTree.Hit(offender: offender) else { return true }
                    return !allowance.allows(file: hit.file, line: hit.line)
                }
        }
        return offenders
    }

    /// Per-line hits summed per FILE — the view a self-check over a planted
    /// file compares, where no type key is in play.
    static func byFile<Value>(_ hits: [(hit: SourceTree.Hit, value: Value)],
                              combine: (Value, Value) -> Value) -> [String: Value] {
        var out: [String: Value] = [:]
        for (hit, value) in hits { out[hit.file] = out[hit.file].map { combine($0, value) } ?? value }
        return out
    }

    /// `byFile` for the per-spelling maps.
    static func byFile(_ hits: [(hit: SourceTree.Hit, value: [String: Int])]) -> [String: [String: Int]] {
        byFile(hits) { $0.merging($1, uniquingKeysWith: +) }
    }

    /// One offender per scoped file name the walk never met: a census whose
    /// file moved or was renamed reads nothing, and must say so rather than pass.
    static func missingScope(_ scope: Set<String>, seen: Set<String>) -> [String] {
        scope.subtracting(seen).sorted().map {
            "MISSING SCOPE: \($0) — the census reads nothing; the file moved or was renamed"
        }
    }

    /// `offenders` without the *type key names no file* line for each of
    /// `keys` — the type keys a planted control DELIBERATELY left unplanted.
    /// Any other unresolved key still shows.
    static func dropping(unplanted keys: [String], from offenders: [String]) -> [String] {
        let expected = Set(keys.map { "type key `\($0)` names no file" })
        return offenders.filter { !expected.contains($0) }
    }

    /// Wrap a planted file's text in `extension <type> { … }`, so a `type:`
    /// key claims its lines — the allowance follows the declaration, not the
    /// name, and covers only what is INSIDE the declaration.
    static func declare(_ type: String, in file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        try ("extension \(type) {\n" + text + "\n}\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - A scoped census fails when its scope is gone (foundations plan 2, Task 2)

    /// **A census scoped to a named file reads nothing once that file moves.**
    /// The walk used to skip a name it never met, so a rename or a split
    /// turned the census off with every assertion still green. Both file-scoped
    /// overloads now report each name they never saw, and every caller asserts
    /// its offenders are empty.
    func test_aFileScopedCensusFailsWhenItsFileIsMissing() throws {
        let dir = try plantedScopeDir()
        let offenders = try grepSwift(
            in: dir, files: ["A.swift", "B.swift"], patterns: ["nothing-matches-this"])
        XCTAssertEqual(offenders.filter { $0.hasPrefix("MISSING SCOPE: B.swift") }.count, 1,
            "a scoped file that is not there is an offender: \(offenders)")
        XCTAssertFalse(offenders.contains { $0.hasPrefix("MISSING SCOPE: A.swift") },
            "a scoped file that IS there is not: \(offenders)")
    }

    func test_anOnlyFilesCensusFailsWhenItsFileIsMissing() throws {
        let dir = try plantedScopeDir()
        let offenders = try grepSwift(
            in: [dir], patterns: ["nothing-matches-this"], allowedSpellings: [:],
            excludeLine: { _ in false }, onlyFiles: ["A.swift", "B.swift"])
        XCTAssertEqual(offenders.filter { $0.hasPrefix("MISSING SCOPE: B.swift") }.count, 1,
            "a scoped file that is not there is an offender: \(offenders)")
        XCTAssertFalse(offenders.contains { $0.hasPrefix("MISSING SCOPE: A.swift") },
            "a scoped file that IS there is not: \(offenders)")
    }

    // MARK: - A type key follows the code (foundations plan 2, Task 3)

    /// A planted `Widget` split across two files, and an unrelated third file,
    /// each carrying one `sanctioned(` call.
    private func plantedWidgetDir() throws -> URL {
        let dir = TestTemp.root
            .appendingPathComponent("type-key-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "struct Widget {\n    let a = sanctioned(1)\n}\n"
            .write(to: dir.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        try "extension Widget {\n    func b() { sanctioned(2) }\n}\n"
            .write(to: dir.appendingPathComponent("Widget+More.swift"), atomically: true, encoding: .utf8)
        try "struct Other {\n    let c = sanctioned(3)\n}\n"
            .write(to: dir.appendingPathComponent("Other.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    /// **(a) An allow-list keyed `type:Widget` lets the spelling through in
    /// every file declaring `Widget`, and nowhere else** — in both allow-list
    /// shapes, file-plus-spelling and a set of whole files.
    func test_aTypeKeyAllowsEveryFileDeclaringTheType() throws {
        let dir = try plantedWidgetDir()
        let spelled = try grepSwift(
            in: [dir], patterns: ["sanctioned("],
            allowedSpellings: ["type:Widget": ["sanctioned("]],
            excludeLine: { _ in false })
        XCTAssertEqual(spelled.count, 1, "only Other.swift is caught: \(spelled)")
        XCTAssertTrue(spelled.allSatisfy { $0.hasPrefix("Other.swift:") }, "\(spelled)")

        let whole = try grepSwift(
            in: [dir], patterns: ["sanctioned("], allowed: ["type:Widget"],
            excludeLine: nil, extraOffender: nil)
        XCTAssertEqual(whole.count, 1, "only Other.swift is caught: \(whole)")
        XCTAssertTrue(whole.allSatisfy { $0.hasPrefix("Other.swift:") }, "\(whole)")
    }

    /// **(b) In a count map a type key's count is the SUM over its files.**
    func test_aTypeKeyCountsTheSumOverItsFiles() throws {
        let dir = try plantedWidgetDir()
        let expected = ["type:Widget": 2, "Other.swift": 1]
        let two = try countedListFound(of: "sanctioned(", keyedLike: expected, in: [dir])
        XCTAssertEqual(two.found, expected, "one site in each Widget file sums to 2")
        XCTAssertTrue(two.offenders.isEmpty, "\(two.offenders)")

        try "struct Widget {\n    let a = sanctioned(1)\n    let d = sanctioned(4)\n}\n"
            .write(to: dir.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        let three = try countedListFound(of: "sanctioned(", keyedLike: expected, in: [dir])
        XCTAssertEqual(three.found["type:Widget"], 3)
        XCTAssertNotEqual(three.found, expected, "a third site in the type fails the count")
    }

    /// **(d) A type key never claims a phone file.** The Mac's censuses that
    /// scan `MaughamPhone/` allow-list Mac and Core types; a phone file
    /// declaring `extension Widget` is still caught, in every map shape.
    func test_aTypeKeyNeverClaimsAPhoneFile() throws {
        let dir = try plantedWidgetDir()
        let phone = dir.deletingLastPathComponent()
            .appendingPathComponent("\(dir.lastPathComponent)-phone/MaughamPhone")
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        try "extension Widget {\n    func p() { sanctioned(5) }\n}\n"
            .write(to: phone.appendingPathComponent("Widget+Phone.swift"),
                   atomically: true, encoding: .utf8)
        let roots = [dir, phone]

        let spelled = try grepSwift(
            in: roots, patterns: ["sanctioned("],
            allowedSpellings: ["type:Widget": ["sanctioned("]],
            excludeLine: { _ in false })
        XCTAssertTrue(spelled.contains { $0.hasPrefix("Widget+Phone.swift:") },
            "the phone extension is caught: \(spelled)")
        XCTAssertEqual(spelled.count, 2, "Other.swift and the phone file: \(spelled)")

        let whole = try grepSwift(
            in: roots, patterns: ["sanctioned("], allowed: ["type:Widget"],
            excludeLine: nil, extraOffender: nil)
        XCTAssertTrue(whole.contains { $0.hasPrefix("Widget+Phone.swift:") }, "\(whole)")

        let counted = try countedListFound(
            of: "sanctioned(", keyedLike: ["type:Widget": 2, "Other.swift": 1], in: roots)
        XCTAssertEqual(counted.found, ["type:Widget": 2, "Other.swift": 1, "Widget+Phone.swift": 1],
            "the phone file is counted under its own name, not the type's")
    }

    /// **(e) A plain key naming a file a type key also claims is an offender**
    /// — one rule for allow-lists and count maps alike.
    func test_aPlainKeyBesideATypeKeyThatClaimsItIsAnOffender() throws {
        let dir = try plantedWidgetDir()
        let message = "Widget+More.swift is named by itself and by `type:Widget`"
        let spelled = try grepSwift(
            in: [dir], patterns: ["no-such-spelling"],
            allowedSpellings: ["type:Widget": ["x"], "Widget+More.swift": ["y"]],
            excludeLine: { _ in false })
        XCTAssertEqual(spelled, [message])
        let whole = try grepSwift(
            in: [dir], patterns: ["no-such-spelling"],
            allowed: ["type:Widget", "Widget+More.swift"],
            excludeLine: nil, extraOffender: nil)
        XCTAssertEqual(whole, [message])
        let counted = try countedListFound(
            of: "sanctioned(", keyedLike: ["type:Widget": 2, "Widget+More.swift": 1], in: [dir])
        XCTAssertEqual(counted.offenders, [message])
    }

    /// **(f) A type key claims DECLARATIONS, not files** (plan 2 final
    /// review, I1). A file holding `extension Widget` and a child view: a hit
    /// inside the extension is the type's, a hit in the child view is the
    /// file's own — not allowed by `type:Widget`, and counted under its name —
    /// in every map shape.
    func test_aTypeKeyClaimsTheDeclarationNotTheFileHoldingIt() throws {
        let dir = try plantedWidgetDir()
        try """
        extension Widget {
            func b() { sanctioned(2) }
        }

        struct ChildView {
            func c() { sanctioned(9) }
        }
        """.write(to: dir.appendingPathComponent("Widget+More.swift"), atomically: true, encoding: .utf8)

        // (a) the child view's hit is NOT allowed by the type key…
        let spelled = try grepSwift(
            in: [dir], patterns: ["sanctioned("],
            allowedSpellings: ["type:Widget": ["sanctioned("]],
            excludeLine: { _ in false })
        XCTAssertEqual(Set(spelled), ["Widget+More.swift:6: func c() { sanctioned(9) }",
                                      "Other.swift:2: let c = sanctioned(3)"],
                       "the child view is caught; the extension is not: \(spelled)")
        let whole = try grepSwift(
            in: [dir], patterns: ["sanctioned("], allowed: ["type:Widget"],
            excludeLine: nil, extraOffender: nil)
        XCTAssertEqual(Set(whole), Set(spelled), "the whole-file shape agrees: \(whole)")

        // (b) …and the hit inside the extension IS: drop the child, and only
        // Other.swift is left.
        try "extension Widget {\n    func b() { sanctioned(2) }\n}\n"
            .write(to: dir.appendingPathComponent("Widget+More.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try grepSwift(
            in: [dir], patterns: ["sanctioned("],
            allowedSpellings: ["type:Widget": ["sanctioned("]],
            excludeLine: { _ in false }), ["Other.swift:2: let c = sanctioned(3)"])

        // The count shape: the child view is counted under its file.
        try "extension Widget {\n    func b() { sanctioned(2) }\n}\nstruct Child { let d = sanctioned(8) }\n"
            .write(to: dir.appendingPathComponent("Widget+More.swift"), atomically: true, encoding: .utf8)
        let counted = try countedListFound(
            of: "sanctioned(", keyedLike: ["type:Widget": 2, "Other.swift": 1], in: [dir])
        XCTAssertEqual(counted.found, ["type:Widget": 2, "Other.swift": 1, "Widget+More.swift": 1])
        XCTAssertTrue(counted.offenders.isEmpty, "\(counted.offenders)")
    }

    /// **Two type keys may share a file, but never a declaration.** A file
    /// holding `enum Ruling` and `extension Widget` answers to both keys,
    /// each for its own lines; a declaration nested inside another type key's
    /// is an offender.
    func test_twoTypeKeysShareAFileButNotADeclaration() throws {
        let dir = try plantedWidgetDir()
        try """
        enum Ruling {
            static func r() { sanctioned(5) }
        }
        extension Widget {
            func b() { sanctioned(2) }
        }
        """.write(to: dir.appendingPathComponent("Widget+More.swift"), atomically: true, encoding: .utf8)
        let shared = try countedListFound(
            of: "sanctioned(", keyedLike: ["type:Widget": 2, "type:Ruling": 1, "Other.swift": 1],
            in: [dir])
        XCTAssertEqual(shared.found, ["type:Widget": 2, "type:Ruling": 1, "Other.swift": 1])
        XCTAssertTrue(shared.offenders.isEmpty, "\(shared.offenders)")

        try "extension Widget {\n    enum Ruling { static func r() { sanctioned(5) } }\n}\n"
            .write(to: dir.appendingPathComponent("Widget+More.swift"), atomically: true, encoding: .utf8)
        let nested = try countedListFound(
            of: "sanctioned(", keyedLike: ["type:Widget": 2, "type:Ruling": 1], in: [dir])
        XCTAssertEqual(nested.offenders,
                       ["Widget+More.swift:1 is claimed by two type keys, `type:Ruling` and `type:Widget`"])
    }

    /// **(c) A type key that resolves to no file fails the census**, in every
    /// shape a key can take.
    func test_aTypeKeyNamingNoFileFailsTheCensus() throws {
        let dir = try plantedWidgetDir()
        let message = "type key `type:Nothing` names no file"
        let spelled = try grepSwift(
            in: [dir], patterns: ["no-such-spelling"],
            allowedSpellings: ["type:Nothing": ["x"]],
            excludeLine: { _ in false })
        XCTAssertEqual(spelled, [message])
        let whole = try grepSwift(
            in: [dir], patterns: ["no-such-spelling"], allowed: ["type:Nothing"],
            excludeLine: nil, extraOffender: nil)
        XCTAssertEqual(whole, [message])
        let counted = try countedListFound(
            of: "sanctioned(", keyedLike: ["type:Nothing": 1], in: [dir])
        XCTAssertEqual(counted.offenders, [message])
    }

    /// **Every production source root, and who scans it.** Keyed by
    /// repo-relative root, exactly as `SourceTree.productionRoots` names them;
    /// the value names the censuses that read it. A root missing here is code
    /// no census was ever pointed at — the moment to decide which must scan it.
    static let knownSourceRoots: [String: String] = [
        "Maugham": "sourceDir censuses + admissionRoots/deviceIdentityRoots/postureAskRoots/manifestEncodeRoots",
        "MaughamPhone": "TripwirePhoneGrepTest + admissionRoots/deviceIdentityRoots/postureAskRoots/manifestEncodeRoots",
        "Packages/MaughamCore/Sources/MaughamCore":
            "admissionRoots/deviceIdentityRoots/manifestEncodeRoots + the Packages/MaughamCore/Sources censuses",
    ]

    /// The roots `productionRoots` names that `knownSourceRoots` does not, and
    /// the entries `knownSourceRoots` keeps for roots that are gone.
    static func unclassifiedRoots(_ roots: [String]) -> (unclassified: [String], stale: [String]) {
        let known = Set(knownSourceRoots.keys), actual = Set(roots)
        return (actual.subtracting(known).sorted(), known.subtracting(actual).sorted())
    }

    func test_everyProductionRootIsClassified() {
        let (unclassified, stale) = Self.unclassifiedRoots(SourceTree.productionRoots)
        XCTAssertEqual(Set(Self.knownSourceRoots.keys), Set(SourceTree.productionRoots),
            "a new source root exists: decide which censuses must scan it, then name it here. "
            + "Unclassified: \(unclassified); named here but gone: \(stale)")
    }

    /// The control: a planted `Packages/Fake/Sources/Fake` is a root nobody
    /// classified, and is reported by name.
    func test_anUnclassifiedSourceRootIsReported() throws {
        let base = TestTemp.root.appendingPathComponent("roots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("Packages/Fake/Sources/Fake"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("Packages/MaughamCore/Sources/MaughamCore"),
            withIntermediateDirectories: true)
        let (unclassified, stale) = Self.unclassifiedRoots(SourceTree.productionRoots(base: base))
        XCTAssertEqual(unclassified, ["Packages/Fake/Sources/Fake"])
        XCTAssertEqual(stale, [])
    }

    /// A planted directory holding `A.swift` and nothing else.
    private func plantedScopeDir() throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "let a = 1\n".write(
            to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Op-log filename parsing tripwire

    /// Recurrence-tripper: prevents hand-rolled op-log filename/docId parsing
    /// from re-appearing in Mac source. The cross-surface contract registry is
    /// at docs/superpowers/notes/cross-surface-contracts.md.
    func test_noReachAroundOpLogFilenameParsing() throws {
        // OpLogStore lives in MaughamCore (not scanned). Mac files that legitimately
        // touch op-log/sidecar filenames go here; the Task 7 audit finalizes the list.
        let allowed: Set<String> = [
            "MaughamSidecarPath.swift",
        ]
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["hasPrefix(\"d_\")"],
            allowed: allowed
        )
        XCTAssertTrue(offenders.isEmpty,
            "Hand-rolled doc-id parsing in Maugham/. Use OpLogStore.docId(fromOpLogFilename:). "
            + "See docs/superpowers/notes/cross-surface-contracts.md:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - hashValue-in-persisted-id-construction tripwire

    /// Recurrence-tripper: forbids `hashValue` in on-disk id or path
    /// construction inside Maugham/. `String.hashValue` is seed-randomised per
    /// process (Swift SE-0206) — using it to derive a docId, filename, or any
    /// persisted key orphans the entire op log on every app restart. Use
    /// `StableHash.fnv1a64Hex` instead (finding 0.5 in the 2026-06-07 audit).
    ///
    /// Excluded patterns:
    ///   - Lines containing "Identifiable" or "Hashable" — these are in-memory
    ///     protocol conformances (e.g. `var id: Int { hashValue }` in
    ///     ProjectWindow.swift, a SwiftUI Identifiable on a never-persisted enum).
    ///   - Comment lines (// or ///  prefix after trim) — doc-comments that
    ///     explain the hazard are fine; the danger is in executable expressions.
    func test_noHashValueInPersistedIdConstruction() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: [".hashValue"],
            excludeLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Allow: in-memory Identifiable/Hashable conformances
                if trimmed.contains("Identifiable") || trimmed.contains("Hashable") { return true }
                // Allow: comment lines (the hazard note in DeviceSlug was a comment)
                if trimmed.hasPrefix("//") { return true }
                return false
            }
        )
        XCTAssertTrue(offenders.isEmpty,
            "`.hashValue` found in Maugham/ source outside allowed contexts. "
            + "hashValue is process-seed-randomised and must NOT be used to derive "
            + "on-disk ids, filenames, or any persisted key. "
            + "Use StableHash.fnv1a64Hex(_:) instead. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - Identity-string literal tripwire (tripwire 13)

    /// Recurrence-tripper: prevents hardcoded `"maugham"` / `"Maugham"` identity
    /// literals from reappearing in Maugham/ source outside the one sanctioned
    /// home (`BuildVariant.swift`). The six variant-dependent identity values
    /// (bundle id, display name, support-folder name, MCP socket path, Claude
    /// Desktop config key, MCP serverInfo.name) vary between stable and dev
    /// builds and MUST be derived from `BuildVariant.current`.
    ///
    /// Allowed exceptions (documented here as the authoritative list):
    ///   - `BuildVariant.swift` — the one canonical source of truth; excluded by
    ///     `allowedFiles`.
    ///   - `GitHubReleasesAPI.swift` — `repo: String = "Maugham"` is the GitHub
    ///     repository name. Dev and stable builds update from the SAME repo, so
    ///     this is a genuinely-constant string, not a variant identity value.
    ///     Routing it through BuildVariant would be wrong.
    ///   - `ProjectFolderPresenter.swift` — `"com.maugham.ProjectFolderPresenter"`
    ///     is an OperationQueue debug label. It does NOT match the exact quoted
    ///     patterns `"maugham"` or `"Maugham"` (it is a longer string containing
    ///     the substring), so it is not caught by this tripwire — no exclusion
    ///     needed. Noted here for audit completeness.
    func test_noHardcodedIdentityStringsInMacSources() throws {
        // The one sanctioned home for Maugham/ identity literals.
        let allowedFiles: Set<String> = ["BuildVariant.swift"]

        // Genuinely-constant literals that contain "maugham"/"Maugham" but are
        // NOT variant-identity values — excluded by line predicate.
        let isAllowedConstantLine: (String) -> Bool = { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Comment lines — tripwire explanation comments are fine.
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { return true }
            // GitHubReleasesAPI: repo name is constant across variants (both
            // stable and dev update from dtrouton/Maugham on GitHub). Hoisted
            // to `static let repo` so the trusted-URL check shares it (#67).
            if trimmed == "public static let repo = \"Maugham\"" { return true }
            return false
        }

        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["\"maugham\"", "\"Maugham\""],
            allowed: allowedFiles,
            excludeLine: isAllowedConstantLine
        )
        XCTAssertTrue(offenders.isEmpty,
            "Hardcoded \"maugham\"/\"Maugham\" identity strings found in Maugham/ "
            + "outside BuildVariant.swift. Route variant-dependent values through "
            + "BuildVariant.current (tripwire 13). If the literal is genuinely "
            + "constant (e.g. a GitHub repo path), add it to isAllowedConstantLine "
            + "with a reason. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - Typed user-content mover tripwire (tripwire 14)

    /// The `ProjectStore+*` seams that relocate/delete user-editable paths
    /// (manuscript `.md`/`.fountain`, Collection piece folders, research
    /// notes/folders). Every move/trash of such a path MUST go through
    /// `DocumentStore.relocate(plan:)` / `relocateUserContent(...)` / `trash(...)`,
    /// which run the close-before-FS-surgery discipline (close+unregister +
    /// `flushPendingSave`) INTERNALLY before any FS call. A raw `moveItem` /
    /// `moveToTrash` on a user path bypasses that discipline → phantom files
    /// (tripwire 14; findings 1.3 / 1.6).
    /// Computed (not a hardcoded list) so a NEW `ProjectStore+Foo.swift` seam is
    /// auto-covered by the guard — closing the allowlist ceiling the M3.1 review
    /// flagged. Every `ProjectStore+*.swift` under `Maugham/Stores/` is a
    /// candidate user-content mover and must route raw moves through the typed
    /// DocumentStore mover. Falls back to the known four if enumeration fails.
    private var userContentMoverFiles: Set<String> {
        let storesDir = sourceDir.appendingPathComponent("Stores", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storesDir.path)) ?? []
        let matched = names.filter {
            $0.hasPrefix("ProjectStore+") && $0.hasSuffix(".swift")
        }
        return matched.isEmpty
            ? ["ProjectStore+Structure.swift", "ProjectStore+CollectionPieces.swift",
               "ProjectStore+Research.swift", "ProjectStore+ResearchMove.swift",
               "ProjectStore+WikiLink.swift"]
            : Set(matched)
    }

    /// The forbidden raw-FS-mutation call shapes for user-content paths.
    private let userContentMoverPatterns = [
        ".moveItem(",
        ".moveToTrash(",
    ]

    /// Lines that legitimately use a raw move because they touch INTERNAL,
    /// non-user-edited paths — NOT the bug class. Excluded by:
    ///   - an explicit `// internal-move:` marker — the `promotePieceToProject`
    ///     flow stages into a temp `staging/` tree (and already runs its own
    ///     close+flush before staging), so those moves don't race a live
    ///     autosave. The marker is deliberately explicit (not a fragile
    ///     variable-name match) so each exclusion is auditable in the diff.
    ///   - comment lines — doc-comments that mention the hazard are fine.
    private func isInternalMoveLine(_ line: String) -> Bool {
        if line.contains("internal-move:") { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
            return true
        }
        return false
    }

    /// Recurrence-tripper: the next bespoke `fm.moveItem`/`moveToTrash` on a
    /// manuscript / piece-folder / research-note path re-introduces the
    /// close-before-FS-surgery bug class (tripwire 14, missed at findings
    /// 1.3 / 1.6). Route the move through the typed `DocumentStore` mover
    /// (`relocate(plan:)` / `relocateUserContent(perform:)` / `trash(...)`),
    /// using `coordinatedMove`/`coordinatedWrite` inside the `perform` closure.
    /// See `Maugham/Stores/AREA.md` → "Typed user-content mover".
    func test_noRawMoveOfUserContentOutsideTypedMover() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            files: userContentMoverFiles,
            patterns: userContentMoverPatterns,
            excludeLine: { [self] in isInternalMoveLine($0) }
        )
        XCTAssertTrue(offenders.isEmpty,
            "Raw FileManager.moveItem / moveToTrash on a user-content path in a "
            + "ProjectStore+* seam. Route it through the typed DocumentStore mover "
            + "(relocate(plan:) / relocateUserContent(perform:) / trash(...)) so the "
            + "close+unregister+flush discipline runs before the move (tripwire 14). "
            + "If this move is genuinely on an internal staging/scratch path, add "
            + "the token to isInternalMoveLine. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - No `.skipsHiddenFiles` in a production scan

    /// Recurrence-tripper: `.skipsHiddenFiles` honours the BSD `hidden` FLAG
    /// as well as a dot-prefixed name, and something outside Maugham sets
    /// that flag on files under `.maugham/` in a synced Documents folder
    /// (2026-08-27: `read_preview_page` reported no preview over a directory
    /// holding two). Skip dotfiles by NAME — `DotfileScan.isDotfile` — and
    /// nothing else. Comments may name the option; code may not pass it.
    func test_noSkipsHiddenFilesInProductionScans() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: [".skipsHiddenFiles"],
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        )
        XCTAssertTrue(offenders.isEmpty,
            "A production directory scan passes `.skipsHiddenFiles`, which also "
            + "drops files carrying the BSD `hidden` flag — a flag a sync daemon "
            + "sets under `.maugham/` behind Maugham's back. Pass `options: []` "
            + "and skip by name with `DotfileScan.isDotfile` (and `skipDescendants()` "
            + "for an enumerator). Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Control for the census above: the SAME grep, over a planted file,
    /// catches the code line and lets the comment line through.
    func test_noSkipsHiddenFilesInProductionScans_seesAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-hidden-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try """
        // `.skipsHiddenFiles` would hide the preview — a comment, allowed
        let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        """.write(to: tmp.appendingPathComponent("BadScan.swift"),
                 atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: [".skipsHiddenFiles"],
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        )
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the code line, got:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("options:") == true, offenders.description)
    }

    // MARK: - Palette write coordination tripwire (A1-High)

    /// The forbidden raw-write call shape for palette card writes. Matches
    /// both `.write(to: x)` on one line and a split `.write(\n    to: x)` —
    /// review finding A1-High caught two raw `rendered.write(to:atomically:)`
    /// calls that bypass NSFileCoordinator, which can conflict-twin a palette
    /// card under iCloud (tripwire 7). The one allowed spelling is the funnel
    /// `paletteCoordinatedWrite(_:to:)`.
    private let paletteWritePatterns = [".write("]

    /// The funnel's own fallback write (used when `documentStore == nil`,
    /// i.e. unit-test contexts) is marked so the grep can distinguish it from
    /// a reach-around raw write. See `Maugham/Stores/AREA.md`.
    private func isPaletteFunnelLine(_ line: String) -> Bool {
        line.contains("palette-coordinated-write:")
    }

    /// Recurrence-tripper: a raw `.write(to:)` on a palette card's rendered
    /// markdown in `ProjectStore+Palette.swift` skips NSFileCoordinator on a
    /// cloud-synced project file (tripwire 7 / A1-High). Route it through
    /// `paletteCoordinatedWrite(_:to:)`, which coordinates via
    /// `DocumentStore.performFileSave` when a `documentStore` back-ref is
    /// wired, matching the research-note save path.
    func test_noRawWriteInPaletteStore() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            files: ["ProjectStore+Palette.swift"],
            patterns: paletteWritePatterns,
            excludeLine: { [self] in isPaletteFunnelLine($0) }
        )
        XCTAssertTrue(offenders.isEmpty,
            "Raw `.write(to:` in ProjectStore+Palette.swift bypasses NSFileCoordinator "
            + "(A1-High). Route palette card writes through paletteCoordinatedWrite(_:to:), "
            + "which coordinates via DocumentStore.performFileSave when available. If this "
            + "is genuinely the funnel's own unit-test fallback, mark the line with "
            + "`// palette-coordinated-write: ...`. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - The toolchain has one home (imprints P3 Task 4)

    /// The two versions every compile stamps into a `Publication`: the running
    /// build's, and the bundled tectonic's.
    private var toolchainPatterns: [String] {
        ["CFBundleShortVersionString", "\"0.15.0\""]
    }

    /// The three areas that compile a book, and therefore the three that could
    /// grow a fifth spelling of the toolchain's versions.
    private var toolchainCensusDirs: [URL] {
        // `Views/Publish` joined the list in imprints P3 Task 5, when
        // `DeskCompileRunner` became the second production construction of
        // `CompileOrchestrator` — a compile stamp is minted in this directory
        // now, so a fifth spelling could grow here too.
        ["Publish", "MCP", "Compiler", "Views/Publish"].map {
            sourceDir.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// The files under those areas that legitimately read the build's version
    /// for something that is NOT a compile stamp — named one by one rather than
    /// pattern-matched, so a new file cannot join the list by accident.
    ///
    /// `MCPInitializeHandler` and `TestPingTool` report the app's version over
    /// the wire (the MCP handshake and the ping), and `ListMaughamToolsTool`
    /// stamps the catalogue listing. None of the three is a publication record,
    /// and none of them can drift a compile's stamp. `PublishToolchain` is the
    /// one home itself. (The About tab and the updater read the same key and
    /// live outside these three directories entirely.)
    private var toolchainAllowed: Set<String> {
        ["PublishToolchain.swift",
         "MCPInitializeHandler.swift",
         "ListMaughamToolsTool.swift",
         "TestPingTool.swift"]
    }

    /// **Tripwire: the toolchain's versions are spelled in exactly one place.**
    ///
    /// Before imprints P3 Task 4 there were FOUR — `CompileTools` twice,
    /// `PublicationTools` once and `DesignerEnvironment+Project` once, the last
    /// of which carried a comment admitting it was a fourth. A bumped tectonic
    /// in three of the four is a catalog where two records made by the same
    /// build disagree about what typeset them, and nothing reads back what a
    /// record claims, so the drift is invisible until somebody debugs a book
    /// with the wrong provenance in its stamp.
    func test_theToolchainsVersionsAreSpelledInExactlyOnePlace() throws {
        var offenders: [String] = []
        for dir in toolchainCensusDirs {
            offenders += try grepSwift(
                in: dir,
                patterns: toolchainPatterns,
                allowed: toolchainAllowed,
                excludeLine: { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
                })
        }
        XCTAssertTrue(offenders.isEmpty,
            "A compile's toolchain versions have one home: `PublishToolchain"
            + ".maughamVersion` and `PublishToolchain.tectonicVersion`. A second "
            + "spelling under Publish/, MCP/, Compiler/ or Views/Publish/ is "
            + "how two records "
            + "made by the same build come to disagree about what made them. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: it is not passing because the patterns
    /// match nothing. A planted file carrying each spelling is caught.
    func test_theToolchainCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-toolchain-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("SecondCompileSite.swift")
        try """
        enum SecondCompileSite {
            static let mauqham = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            static let tectonic = "0.15.0"
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: toolchainPatterns,
            allowed: toolchainAllowed,
            excludeLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
            })
        XCTAssertEqual(offenders.count, 2,
            "Self-check: both spellings should be caught. Got:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - The passless editor's name has one home (editorial letter P1)

    /// Lines that mention the constant but are not a USE of it: its own
    /// declaration, and any comment naming it.
    private func passlessNameNonUse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//")
            || trimmed.contains("static let passlessEditorName")
    }

    /// **Tripwire: `CompilerOrchestrator.passlessEditorName` has exactly ONE
    /// production use, and it is `AuthorReader`'s *nobody* arm.**
    ///
    /// Who reads a CHECK is one resolution (two loops P1, spec §2): the coach
    /// or nobody. A second site reaching for the constant is a second answer
    /// to "who signs this piece's notes" — and the answer it gives is always
    /// "Claude", which while the seat is held is wrong for every piece. The
    /// mint site is the one that used to hold it and now reads
    /// `AuthorReader.nobody.editorName` instead, so the fallback and the
    /// resolution cannot drift apart.
    func test_thePasslessEditorNameHasExactlyOneProductionUse() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["passlessEditorName"],
            excludeLine: { self.passlessNameNonUse($0) })
        XCTAssertEqual(
            offenders.compactMap { $0.split(separator: ":").first.map(String.init) },
            ["AuthorReader.swift"],
            "the passless name is read in one place \u{2014} AuthorReader's "
            + "nobody arm \u{2014} and every other site asks the resolution "
            + "instead. Offenders:\n" + offenders.joined(separator: "\n"))

        // The census above counts USES, so a second DECLARATION would slip
        // past it — and a second constant is the same defect wearing the
        // exclusion this test grants the first one.
        let declarations = try grepSwift(
            in: sourceDir,
            patterns: ["static let passlessEditorName"],
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        XCTAssertEqual(
            declarations.compactMap { $0.split(separator: ":").first.map(String.init) },
            ["CompilerOrchestrator.swift"],
            "the constant is declared once. Declarations:\n"
            + declarations.joined(separator: "\n"))
    }

    /// CONTROL for the census above: it is not passing because the pattern
    /// matches nothing. A planted second reader is caught, and the two shapes
    /// that are NOT uses — the declaration and a comment naming it — are not.
    func test_thePasslessEditorNameCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-passless-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        enum SecondReader {
            // A comment naming passlessEditorName is not a use.
            nonisolated static let passlessEditorName = "Claude"
            static func sign() -> String {
                CompilerOrchestrator.passlessEditorName
            }
        }
        """.write(to: tmp.appendingPathComponent("SecondReader.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: ["passlessEditorName"],
            excludeLine: { self.passlessNameNonUse($0) })
        XCTAssertEqual(offenders.count, 1,
            "Self-check: the planted read should be the one caught, and neither "
            + "the declaration nor the comment. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders[0].hasPrefix("SecondReader.swift:"), offenders[0])
    }

    // MARK: - The two readers never read each other's input (two loops P1)

    /// The two files the split lives in. Named rather than globbed, because
    /// the claim is about THESE resolutions: a third file reading either value
    /// is not what these censuses are about, and widening them to the whole
    /// tree would catch every legitimate reader of the board's memory.
    private static let checkReaderFiles: Set<String> = [
        "AuthorReader.swift", "CompilerEnvironment+Project.swift"
    ]
    private static let roundEditorFiles: Set<String> = [
        "RoundEditor.swift", "CompilerEnvironment+Project.swift"
    ]

    /// Lines that mention a value but are not a READ of it: any comment.
    /// The censuses below are about wiring, and both files explain themselves
    /// at length — a doc comment naming the value it deliberately does not
    /// read is the opposite of the defect.
    private func commentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
    }

    /// **Tripwire: the CHECK's reader never reads the review board's memory.**
    ///
    /// `ActivePassMemory` is where the writer's Review board records which
    /// pass a piece is parked in. That is the ROUND loop's input. A check that
    /// read it is exactly the defect two loops P1 removed: an Author ⌘R on a
    /// chapter parked in Gould's lane signed its notes "Gould" and filed them
    /// as a numbered round in a lane the writer was not standing in.
    ///
    /// So the memory may be named in exactly one place across the two files
    /// the split lives in — the `.round` arm of the production wiring — and
    /// `AuthorReader.swift` may not name it at all. Asserted structurally as
    /// well as by count, because a hit that MOVED from the round arm to the
    /// check arm would keep the count and lose the whole rule.
    func test_theCheckReaderNeverReadsTheBoardsMemory() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            files: Self.checkReaderFiles,
            patterns: ["activePassMemory"],
            excludeLine: { self.commentLine($0) })
        XCTAssertEqual(
            offenders.compactMap { $0.split(separator: ":").first.map(String.init) },
            ["CompilerEnvironment+Project.swift"],
            "the board's memory is read in ONE place across these two files, "
            + "and never by the check's own resolution. Offenders:\n"
            + offenders.joined(separator: "\n"))

        // …and that one read is inside the `roundEditor` closure. The count
        // above cannot tell a read that moved closures from one that did not.
        // Located by the two closure names, which is what the split left where
        // a `switch kind` used to be (two loops P2 Task 4).
        let wiring = try productionWiring()
        let check = try XCTUnwrap(wiring.range(of: "authorReader: {"),
                                  "find the check's closure by name if it moved")
        let round = try XCTUnwrap(wiring.range(of: "roundEditor: {",
                                               range: check.upperBound..<wiring.endIndex))
        XCTAssertFalse(
            wiring[check.upperBound..<round.lowerBound].contains("activePassMemory"),
            "the check's closure must not reach for the board's memory")
        XCTAssertTrue(
            wiring[round.lowerBound...].contains("activePassMemory"),
            "control: the round's closure is where it really is read")
    }

    /// The production wiring's own text, for the structural halves of the two
    /// censuses below — both ask WHERE a value is read, which a count cannot
    /// answer.
    private func productionWiring() throws -> String {
        try String(
            contentsOf: sourceDir
                .appendingPathComponent("Compiler/CompilerEnvironment+Project.swift"),
            encoding: .utf8)
    }

    /// **Tripwire: the ROUND's editor is never the coach.**
    ///
    /// The seat is the check loop's (`AuthorReader`). A round is a numbered
    /// entry in a named lane, and the coach has no lane a reviewer can select
    /// — filing her one is how an unassigned piece came to have rounds at all.
    /// `RoundEditor` refuses instead, and the refusal is the whole point, so
    /// neither it nor the round arm of the production wiring may name the
    /// seat.
    func test_theRoundEditorNeverReachesForTheCoachsSeat() throws {
        // **Both readers of the roster, not just the seat** (two loops P2 Task
        // 4). The check loop's answer is now the coach OR the writer's own
        // first reader, and a round that fell back to either is the same
        // defect: a lane is a pass the writer selected, and there is no
        // substitute for one.
        let offenders = try grepSwift(
            in: sourceDir,
            files: Self.roundEditorFiles,
            patterns: ["effectiveCoach", "firstReaderName"],
            excludeLine: { self.commentLine($0) })
        XCTAssertEqual(
            offenders, [],
            "a round is a stage's or it is refused \u{2014} neither the seat "
            + "nor the writer's first reader is a fallback, and naming one "
            + "here is how it becomes one. Offenders:\n"
            + offenders.joined(separator: "\n"))

        // …and the structural half, on the memory census's rule: the whole
        // roster is resolved inside `authorReader`, so the `roundEditor`
        // closure may not name `authorReader` either — reaching the resolution
        // is the same fallback wearing one more hop.
        let wiring = try productionWiring()
        let round = try XCTUnwrap(wiring.range(of: "roundEditor: {"),
                                  "find the round's closure by name if it moved")
        XCTAssertFalse(
            wiring[round.lowerBound...]
                .split(separator: "\n")
                .filter { !commentLine(String($0)) }
                .joined(separator: "\n")
                .contains("authorReader"),
            "the round's closure must not reach the check's resolution")
    }

    // MARK: - The coach is a case, not a flag (two loops P2 Task 4)

    /// **Tripwire: `isCoach` is gone, and it does not come back.**
    ///
    /// `CompilerOrchestrator.ActivePass` carried the flag while ONE
    /// `Environment` closure answered both loops: the coach had to arrive at
    /// the briefing dressed as a pass, because a pass was the only thing the
    /// seam could describe. She is an `AuthorReader.coach` now — a case, with a
    /// section of her own — and `ActivePass` is Review's alone, every value of
    /// it a rung of the ladder.
    ///
    /// A flag reintroduced anywhere under `Maugham/` is that seam coming back,
    /// and it comes back silently: the type still compiles, the briefing still
    /// assembles, and a check is once more briefed as the thing it is not.
    ///
    /// Comments are excluded on the two reader censuses' rule — a doc comment
    /// explaining why the flag is gone is the opposite of the defect, and both
    /// `ActivePass` and `passSection` say so at length.
    func test_isCoachIsGone() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["isCoach"],
            excludeLine: { self.commentLine($0) })
        XCTAssertEqual(
            offenders, [],
            "the coach is a case rather than a flag \u{2014} an ActivePass is "
            + "Review's alone. Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: it is not passing because the pattern
    /// matches nothing. A planted flag is caught; a comment naming it is not.
    func test_theIsCoachCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-iscoach-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct ActivePass {
            // A comment naming isCoach is not the flag.
            let isCoach: Bool
        }
        """.write(to: tmp.appendingPathComponent("ActivePass.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp, patterns: ["isCoach"], excludeLine: { self.commentLine($0) })
        XCTAssertEqual(offenders.count, 1,
            "Self-check: the planted flag should be the one caught, and not the "
            + "comment. Got:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders[0].hasPrefix("ActivePass.swift:"), offenders[0])
    }

    /// CONTROL for the two censuses above: they are not passing because the
    /// patterns match nothing. Planted offenders in both files are caught, and
    /// a comment naming either value is not.
    func test_theTwoReaderCensusesFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-two-readers-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        extension ProjectManifest {
            // A comment naming activePassMemory is not a read.
            var authorReader: AuthorReader {
                let stored = documentStore.uiState.activePassMemory
                return stored.isEmpty ? .nobody : .coach(ReviewPass.coachPreset)
            }
        }
        """.write(to: tmp.appendingPathComponent("AuthorReader.swift"),
                  atomically: true, encoding: .utf8)
        try """
        extension ProjectManifest {
            // A comment naming effectiveCoach is not a read.
            func roundEditor(forPiece piece: String) -> ReviewPass? {
                effectiveCoach
            }
        }
        """.write(to: tmp.appendingPathComponent("RoundEditor.swift"),
                  atomically: true, encoding: .utf8)

        // The planted tree holds only some of each census's scope, so the
        // scoped files it lacks are reported missing; this control counts hits.
        let memoryHits = try grepSwift(
            in: tmp, files: Self.checkReaderFiles,
            patterns: ["activePassMemory"],
            excludeLine: { self.commentLine($0) }).filter { !$0.hasPrefix("MISSING SCOPE:") }
        XCTAssertEqual(memoryHits.count, 1,
            "Self-check: the planted read should be the one caught, and not the "
            + "comment. Got:\n" + memoryHits.joined(separator: "\n"))
        XCTAssertTrue(memoryHits[0].hasPrefix("AuthorReader.swift:"), memoryHits[0])

        let seatHits = try grepSwift(
            in: tmp, files: Self.roundEditorFiles,
            patterns: ["effectiveCoach"],
            excludeLine: { self.commentLine($0) }).filter { !$0.hasPrefix("MISSING SCOPE:") }
        XCTAssertEqual(seatHits.count, 1,
            "Self-check: the planted seat read should be caught, and not the "
            + "comment. Got:\n" + seatHits.joined(separator: "\n"))
        XCTAssertTrue(seatHits[0].hasPrefix("RoundEditor.swift:"), seatHits[0])
    }

    // MARK: - A run's kind is minted from the persona in one place (two loops P1)

    /// Lines that mention the mint but are not a CALL of it: any comment
    /// naming it, and the string literals in the wiring censuses that assert
    /// on the modifier's source.
    private func runKindMintNonCall(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// **Tripwire: `RunKind.of(persona:)` is called in exactly ONE production
    /// file — `CompilerRunModifier.swift`, the run keys' delivery path.**
    ///
    /// Which loop a run belongs to is one decision, made at the keystroke from
    /// the key window's persona. A second site minting a kind is a second
    /// answer to "which verb is this", and the two would part company the
    /// moment the loops do — a surface holding a persona and reaching for the
    /// mint would file a round as a check, or worse, file a check as a round
    /// on a piece nobody is reading. Every other caller of `runRequested`
    /// belongs to one loop by construction and names it literally, which is a
    /// claim a reader can check; a second mint is one they cannot.
    func test_theRunKindIsMintedFromThePersonaInOneFile() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["RunKind.of(persona:"],
            excludeLine: { self.runKindMintNonCall($0) })
        XCTAssertEqual(
            Set(offenders.compactMap { $0.split(separator: ":").first.map(String.init) }),
            ["CompilerRunModifier.swift"],
            "the kind is minted from a persona in one place \u{2014} the run "
            + "keys' own modifier \u{2014} and every other caller says which "
            + "loop it belongs to literally. Offenders:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertEqual(
            offenders.count, 2,
            "…twice: \u{2318}R's arm and \u{2318}\u{21e7}R's. A single hit "
            + "means one keystroke stopped asking the persona. Hits:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: it is not passing because the pattern
    /// matches nothing. A planted second mint is caught, and a comment naming
    /// the call is not.
    func test_theRunKindMintCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-runkind-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct SecondMint {
            // A comment naming RunKind.of(persona: persona) is not a call.
            func run(persona: Persona) {
                orchestrator.runRequested(
                    docId: docId, kind: RunKind.of(persona: persona))
            }
        }
        """.write(to: tmp.appendingPathComponent("SecondMint.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: ["RunKind.of(persona:"],
            excludeLine: { self.runKindMintNonCall($0) })
        XCTAssertEqual(offenders.count, 1,
            "Self-check: the planted mint should be the one caught, and not "
            + "the comment. Got:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders[0].hasPrefix("SecondMint.swift:"), offenders[0])
    }

    // MARK: - Filing a research note has a known set of callers (editorial letter P1)

    /// Lines that mention the verb but are not a CALL of it: its own
    /// declaration, and any comment naming it.
    private func createResearchNoteNonCall(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//")
            || trimmed.hasPrefix("public func createResearchNote(")
    }

    /// **Tripwire: `ProjectStore.createResearchNote` has a KNOWN set of
    /// production callers, and Keep this letter is the newest of them.**
    ///
    /// A census rather than a ban: the verb is meant to be called, and the
    /// point of counting is that every caller is a place where a
    /// `ResearchScope` is chosen and a body is written afterwards. Both halves
    /// are easy to get wrong in a way nothing else catches — a
    /// `switch manifest.type` at the call site is a second copy of
    /// `ResearchScope.route`'s table (`PromotionPerformer`'s own rule, spec
    /// §6.2), and a body written with `try?` reports a successful file over an
    /// empty note (RULING-7, M8-IN-001/002, `InboxStore.promote`).
    ///
    /// **`BinderTreeSections.swift` is deliberately NOT here**, though it names
    /// the verb: its Research-section header calls
    /// `addResearchTextNote(parentId: nil)` directly, and its own comment says
    /// why — that section is the project's shared research in every project
    /// type, so it wants the destination the router would have picked rather
    /// than the routing. The comment exclusion is what keeps it out, and the
    /// control below proves the exclusion is real.
    func test_filingAResearchNoteHasAKnownSetOfCallers() throws {
        let callers = try grepSwift(
            in: sourceDir,
            patterns: ["createResearchNote("],
            excludeLine: { self.createResearchNoteNonCall($0) })
        XCTAssertEqual(
            Set(callers.compactMap { $0.split(separator: ":").first.map(String.init) }),
            ["BinderPieceFold.swift", "InboxStore.swift", "LetterKeep.swift",
             "PromotionPerformer.swift"],
            "a new caller of createResearchNote chooses a scope and owes a body "
            + "write \u{2014} add it here deliberately. Callers:\n"
            + callers.joined(separator: "\n"))
    }

    /// CONTROL for the census above: it is not passing because the pattern
    /// matches nothing. A planted fifth caller is caught, and the two shapes
    /// that are NOT calls — the declaration and a comment naming it — are not.
    func test_theResearchNoteCallerCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-research-note-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        extension ProjectStore {
            // A comment naming createResearchNote( is not a call.
            public func createResearchNote(
                scope: ResearchScope, title: String
            ) async throws -> ResearchItem { fatalError() }
        }
        enum FifthCaller {
            static func file(_ store: ProjectStore) async throws {
                _ = try await store.createResearchNote(scope: .shared, title: "T")
            }
        }
        """.write(to: tmp.appendingPathComponent("FifthCaller.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: ["createResearchNote("],
            excludeLine: { self.createResearchNoteNonCall($0) })
        XCTAssertEqual(offenders.count, 1,
            "Self-check: the planted call should be the one caught, and neither "
            + "the declaration nor the comment. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders[0].hasPrefix("FifthCaller.swift:"), offenders[0])
    }

    // MARK: - The lessons ledger is written from one file (editorial letter P2)

    /// Every `RulingPerformer` verb call site under `dir` whose ARGUMENT LIST
    /// names `.lessons`, as `file:line`.
    ///
    /// **All four verbs, not just the two the ledger uses** (fix round 1). The
    /// point of the census is that one file decides what happens to a lesson,
    /// and `revoke` is the sharpest way to break that from outside: a second
    /// file calling it with `kind: .lessons` would DELETE an entry, which is
    /// the one thing spec §6 says must never happen to one.
    ///
    /// **The span is found by anchor, never by a character budget.** These
    /// calls run to five and six lines, and `kind:` is the fourth label — a
    /// fixed window would either miss it or swallow the next statement. From
    /// the call's own open paren the scan balances parens forward to the
    /// matching close, so the text examined is exactly the arguments however
    /// they are wrapped.
    private func lessonsRulingCallSites(in dir: URL) throws -> [String] {
        try rulingCallSites(in: dir, naming: ".lessons")
    }

    /// The same scan aimed at the first reader's statement (two loops P2 Task
    /// 5). Parameterised rather than copied: the balancing scan is the subtle
    /// half, and a second copy of it would be free to drift into missing a
    /// wrapped `kind:` label that the first one catches.
    private func firstReaderRulingCallSites(in dir: URL) throws -> [String] {
        try rulingCallSites(in: dir, naming: ".firstReader")
    }

    /// Every `RulingPerformer` verb call site under `dir` whose argument list
    /// names `kindToken`, as `file:line`.
    private func rulingCallSites(in dir: URL, naming kindToken: String) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var sites: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let scalars = Array(text)
            for anchor in ["RulingPerformer.rule(", "RulingPerformer.edit(",
                           "RulingPerformer.revoke(", "RulingPerformer.restore("] {
                var searchFrom = text.startIndex
                while let found = text.range(
                    of: anchor, range: searchFrom..<text.endIndex) {
                    searchFrom = found.upperBound
                    let openAt = text.distance(
                        from: text.startIndex, to: found.upperBound) - 1
                    let lineStart = text.distance(
                        from: text.startIndex, to: found.lowerBound)
                    // A comment naming the verb is not a call of it.
                    let before = scalars[..<lineStart]
                    let lineBegan = before.lastIndex(where: \.isNewline)
                        .map { before.index(after: $0) } ?? before.startIndex
                    guard !String(before[lineBegan...])
                        .trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    else { continue }
                    guard let closeAt = Self.matchingParen(in: scalars, openAt: openAt)
                    else { continue }
                    let arguments = String(scalars[(openAt + 1)..<closeAt])
                    guard arguments.contains(kindToken) else { continue }
                    let number = scalars[..<lineStart].filter(\.isNewline).count + 1
                    sites.append("\(url.lastPathComponent):\(number)")
                }
            }
        }
        return sites.sorted()
    }

    /// The index of the `)` closing the `(` at `openAt`, or nil for a file this
    /// scan cannot balance (which would not compile).
    private static func matchingParen(in scalars: [Character], openAt: Int) -> Int? {
        var depth = 0
        var index = openAt
        while index < scalars.count {
            if scalars[index] == "(" { depth += 1 }
            if scalars[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// **Tripwire: the lessons ledger is written from ONE production file**
    /// (editorial letter P2, global constraint 14).
    ///
    /// The ledger is the writer's own prose and moves only by the writer's
    /// hand. Three surfaces press on it — Author's letter, Review's cockpit,
    /// and the queue's *This is a choice* — and each could spell
    /// `rule(…, kind: .lessons, forScope: .project, …)` for itself. The three
    /// spellings would then be free to disagree about the scope, the
    /// provenance or the choice marker, and every disagreement is silent: a
    /// choice filed at document scope simply never reaches a briefing.
    ///
    /// A census rather than a ban — the write is meant to happen, in
    /// `LessonLedgerVerbs`.
    func test_theLessonsLedgerIsWrittenFromOneFile() throws {
        let sites = try lessonsRulingCallSites(in: sourceDir)
        XCTAssertEqual(
            Set(sites.compactMap { $0.split(separator: ":").first.map(String.init) }),
            ["LessonLedgerVerbs.swift"],
            "a second production file spelling the ledger write is a second answer "
            + "to where a lesson lives. Route it through LessonLedgerVerbs. Sites:\n"
            + sites.joined(separator: "\n"))
        // **Non-vacuous.** A scanner that matched nothing would pass this
        // census for the wrong reason, and go on passing after the one real
        // write was deleted.
        XCTAssertFalse(
            sites.isEmpty,
            "the census found no ledger write at all \u{2014} LessonLedgerVerbs "
            + "must contain at least one")
    }

    /// CONTROL for the census above: a planted second writer is caught, and
    /// neither a `.intent` call beside it nor a comment naming the verb is.
    func test_theLessonsLedgerCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-lessons-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        enum SecondLedgerWriter {
            static func file(_ store: ProjectStore) async throws {
                // A comment naming RulingPerformer.rule( with .lessons is not a call.
                try await RulingPerformer.rule(
                    LessonsLedger.choiceText("Fragments"),
                    provenance: "from a letter",
                    kind: .lessons, forScope: .project,
                    store: store, world: nil)
            }

            static func clause(_ store: ProjectStore) async throws {
                try await RulingPerformer.rule(
                    "Every scene must turn.", provenance: "from a letter",
                    kind: .intent, forScope: .project,
                    store: store, world: nil)
            }
        }
        """.write(to: tmp.appendingPathComponent("SecondLedgerWriter.swift"),
                  atomically: true, encoding: .utf8)

        let sites = try lessonsRulingCallSites(in: tmp)
        XCTAssertEqual(
            sites.count, 1,
            "Self-check: the planted ledger write should be the one caught, and "
            + "neither the `.intent` call nor the comment. Got:\n"
            + sites.joined(separator: "\n"))
        XCTAssertEqual(sites.first, "SecondLedgerWriter.swift:4")
    }

    /// CONTROL, the sharp arm: a planted `revoke` carrying `.lessons` is caught
    /// too. It is the one call that would DELETE an entry, which spec §6 says
    /// must never happen to a lesson — and until fix round 1 the census
    /// anchored only `rule(` and `edit(`, so it would have sailed through.
    func test_theLessonsLedgerCensusCatchesARevokeToo() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-lessons-revoke-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        enum LedgerDeleter {
            static func drop(_ id: String, _ store: ProjectStore) async throws {
                try await RulingPerformer.revoke(
                    rulingId: id,
                    kind: .lessons, forScope: .project,
                    store: store, world: nil)
            }
        }
        """.write(to: tmp.appendingPathComponent("LedgerDeleter.swift"),
                  atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try lessonsRulingCallSites(in: tmp), ["LedgerDeleter.swift:3"],
            "a revoke against the ledger deletes a lesson, and the census must "
            + "see it")
    }

    // MARK: - The first reader's statement is written from one file (two loops P2)

    /// **Tripwire: the first reader's statement is written from ONE production
    /// file** (two loops P2 Task 5).
    ///
    /// Her statement is the writer's own prose about a person, and it moves
    /// only by the writer's hand — the rule every ruling destination keeps. The
    /// queue answers her notes into it, and the surfaces that could each grow a
    /// spelling of the same write are the ones the queue sits beside: Author's
    /// Diagnostics pane, Review's cockpit, the First Reader pane itself. Each
    /// would then be free to disagree about the scope or the provenance, and
    /// the disagreement is silent — an instruction filed at document scope
    /// simply never reaches her next briefing.
    ///
    /// A census rather than a ban: the write is meant to happen, in
    /// `FirstReaderRuling`.
    func test_theFirstReadersStatementIsWrittenFromOneFile() throws {
        let sites = try firstReaderRulingCallSites(in: sourceDir)
        XCTAssertEqual(
            Set(sites.compactMap { $0.split(separator: ":").first.map(String.init) }),
            ["FirstReaderRuling.swift"],
            "a second production file spelling the write into the first reader's "
            + "statement is a second answer to where her instructions live. Route "
            + "it through FirstReaderRuling. Sites:\n" + sites.joined(separator: "\n"))
        // **Non-vacuous**, for the lessons census's reason: a scanner matching
        // nothing would pass for the wrong reason, and go on passing after the
        // one real write was deleted.
        XCTAssertFalse(
            sites.isEmpty,
            "the census found no write into her statement at all \u{2014} "
            + "FirstReaderRuling must contain at least one")
    }

    // MARK: - A permit change reaches every machine of one writer (P3b Task 5)

    /// **The one spelling a surface may not use.** `DocumentStore.changePermit(
    /// person:to:)` is the single-record primitive; `changePermit(everyRecordOf:
    /// to:)` is the verb.
    static let singleRecordPermitVerb = "changePermit(person:"

    /// **A pane that demoted one machine of two would be worse than one that
    /// offered nothing** (fix round 1, I3; P3b Task 5).
    ///
    /// A permit lives on a person RECORD and a record is one device, but P2b's
    /// admission merges a typed label matching a known one under that label's
    /// own spelling — so a writer whose Mac and phone were both let in is two
    /// records the root has said are one person. Demote the Mac alone and she
    /// goes on writing manuscript text from the phone, applied by every reader,
    /// with nothing anywhere saying why.
    ///
    /// The plural verb pre-flights every record's outcome AND every record's
    /// sweep before a byte is written, so it is also the only one that can
    /// refuse the whole act. A view reaching past it gets neither.
    func test_noViewPressesTheSingleRecordPermitVerb() throws {
        let offenders = try grepSwift(
            in: sourceDir.appendingPathComponent("Views", isDirectory: true),
            patterns: [Self.singleRecordPermitVerb],
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A view calls the single-record permit verb. A permit lives on a "
            + "record and one writer can be two records (a Mac and a phone "
            + "merged under one label), so a surface must call "
            + "`changePermit(everyRecordOf:to:)` — which also pre-flights every "
            + "record's outcome and sweep before it writes. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL: the census fires on a planted press, and lets a comment naming
    /// the verb and a call of the PLURAL one through.
    func test_theSingleRecordPermitVerbCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-permitverb-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct HonestPane {
            func commit(_ store: DocumentStore, _ permit: Permit) async throws {
                // changePermit(person: fingerprint, to: permit) would be wrong here.
                try await store.changePermit(everyRecordOf: who, to: permit)
            }
        }
        """.write(to: tmp.appendingPathComponent("Honest.swift"),
                  atomically: true, encoding: .utf8)
        XCTAssertTrue(
            try grepSwift(in: tmp, patterns: [Self.singleRecordPermitVerb],
                          excludeLine: Self.admissionExcludeLine).isEmpty,
            "the plural verb and a comment are not offenders")

        try """
        struct HalfADemotion {
            func commit(_ store: DocumentStore, _ permit: Permit) async throws {
                try await store.changePermit(person: who, to: permit)
            }
        }
        """.write(to: tmp.appendingPathComponent("Planted.swift"),
                  atomically: true, encoding: .utf8)
        XCTAssertFalse(
            try grepSwift(in: tmp, patterns: [Self.singleRecordPermitVerb],
                          excludeLine: Self.admissionExcludeLine).isEmpty,
            "a planted press of the single-record verb must be caught")
    }

    // MARK: - The two repair verbs have one writer each (P3b Task 5)

    /// `RegistryPresence.writeOwnRecordAgain` is tripwire 41's third writer's
    /// verb and no view may reach a registry writer around it.
    static let ownRecordRepairPatterns = [
        "RegistryPresence.writeOwnRecordAgain", "RegistryAdmission.resignFromTimeline",
    ]

    /// **The two P3b repairs are store verbs, never view verbs** (tripwire 41).
    ///
    /// Both write a signed registry record — one through `RegistryPresence`,
    /// one through `RegistryAdmission` — and tripwire 41 puts the AUTHORITY for
    /// that behind three files. A view calling either directly would reach the
    /// signer without reaching the store's `settle`, so every open document in
    /// the project would go on applying by a table the folder no longer
    /// supports: a repair the writer made and cannot see.
    func test_theRepairVerbsAreReachedFromTheStoreOnly() throws {
        let offenders = try grepSwift(
            in: sourceDir.appendingPathComponent("Views", isDirectory: true),
            patterns: Self.ownRecordRepairPatterns,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A view calls a registry repair verb directly. Both write a signed "
            + "record and both must go through `DocumentStore`, which forgets "
            + "every resolved table afterwards. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: a planted second writer is caught, and
    /// neither an `.editionBrief` call beside it nor a comment naming the verb
    /// is.
    func test_theFirstReaderCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-firstreader-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        enum SecondReaderWriter {
            static func file(_ store: ProjectStore) async throws {
                // A comment naming RulingPerformer.rule( with .firstReader is not a call.
                try await RulingPerformer.rule(
                    "Keep the sisters formal.",
                    provenance: "answering her note",
                    kind: .firstReader, forScope: .project,
                    store: store, world: nil)
            }

            static func edition(_ store: ProjectStore) async throws {
                try await RulingPerformer.rule(
                    "Usted throughout.", provenance: "answered a translator query",
                    kind: .editionBrief("es"), forScope: .project,
                    store: store, world: nil)
            }
        }
        """.write(to: tmp.appendingPathComponent("SecondReaderWriter.swift"),
                  atomically: true, encoding: .utf8)

        let sites = try firstReaderRulingCallSites(in: tmp)
        XCTAssertEqual(
            sites.count, 1,
            "Self-check: the planted write should be the one caught, and neither "
            + "the edition-brief call nor the comment. Got:\n"
            + sites.joined(separator: "\n"))
        XCTAssertEqual(sites.first, "SecondReaderWriter.swift:4")
    }

    /// CONTROL, the sharp arm: a planted `revoke` and a planted `edit` carrying
    /// `.firstReader` are caught too. They are the calls that would DELETE or
    /// REWRITE an instruction the writer made, which is the sharpest way to
    /// break the single-writer rule from outside — and a census anchored on
    /// `rule(` alone would sail past both.
    func test_theFirstReaderCensusCatchesARevokeAndAnEditToo() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-firstreader-revoke-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        enum InstructionMangler {
            static func drop(_ id: String, _ store: ProjectStore) async throws {
                try await RulingPerformer.revoke(
                    rulingId: id,
                    kind: .firstReader, forScope: .project,
                    store: store, world: nil)
            }

            static func change(_ id: String, _ store: ProjectStore) async throws {
                try await RulingPerformer.edit(
                    rulingId: id, newText: "Something else",
                    kind: .firstReader, forScope: .project,
                    store: store, world: nil)
            }
        }
        """.write(to: tmp.appendingPathComponent("InstructionMangler.swift"),
                  atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try firstReaderRulingCallSites(in: tmp),
            ["InstructionMangler.swift:10", "InstructionMangler.swift:3"],
            "a revoke or an edit against her statement rewrites an instruction "
            + "the writer made, and the census must see both")
    }

    // MARK: - The process signals have two surfaces (editorial letter P3, constraint 29)

    /// The files under `Maugham/Views/` that may name `ProcessSignals` or
    /// `ProjectPractice`: the `statistics/` directory, which IS the Practice
    /// section; `ProjectStatisticsWindow.swift`, that section's own host, which
    /// derives the value and hands it down; and `LetterSection.swift`, the
    /// letter's own surface, whose register note names the type it must never
    /// say out loud.
    private static let processSignalsSurfaces: Set<String> = [
        "ProjectStatisticsWindow.swift", "LetterSection.swift",
    ]

    /// Every mention of the process signals under `dir`, as `file:line: text`.
    ///
    /// A MENTION, not a read: a doc comment counts. Constraint 29 is about
    /// where these numbers may appear at all, so a file that has started
    /// talking about them is the thing worth catching, whichever side of a
    /// `//` it is on.
    ///
    /// `exempting` is a parameter rather than a constant so the production
    /// check can run the SAME scan with nothing exempted and prove the census
    /// is looking at something.
    private func processSignalsSites(
        in dir: URL, exempting: Set<String> = processSignalsSurfaces
    ) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var sites: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // The whole `statistics/` directory is the surface, so it is
            // exempted by PATH rather than by listing its files — a section
            // added beside `PracticeSection` is part of the same surface.
            if url.pathComponents.contains("statistics") { continue }
            if exempting.contains(url.lastPathComponent) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text
                .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                guard lineText.contains("ProcessSignals")
                        || lineText.contains("ProjectPractice") else { continue }
                sites.append(
                    "\(url.lastPathComponent):\(index + 1): "
                    + lineText.trimmingCharacters(in: .whitespaces))
            }
        }
        return sites
    }

    /// **The signals reach two surfaces and no others** (global constraint 29,
    /// spec §5, constitution must #2). The Statistics window's Practice section
    /// and the briefing/letter — never the footer, the tree, the editor or a
    /// badge.
    ///
    /// The rule is a rule about the WRITER'S ATTENTION, not about tidiness: a
    /// number telling someone their frontier has not moved in three sessions is
    /// a judgement, and a judgement that follows them around the window while
    /// they are trying to write is the thing must #2 forbids. It reaches them
    /// in the window they opened and the letter they asked for, or not at all.
    func test_theProcessSignalsNameThemselvesOnTwoSurfacesOnly() throws {
        let viewsDir = sourceDir.appendingPathComponent("Views", isDirectory: true)

        // **Non-vacuous by construction**: the same scan with nothing exempted
        // must find the exempt files themselves. A scanner that had stopped
        // matching — a renamed type, a narrowed walk — would answer the empty
        // set here and the assertion below would go on passing for the wrong
        // reason.
        let unexempted = try processSignalsSites(in: viewsDir, exempting: [])
        XCTAssertEqual(
            Set(unexempted.compactMap { $0.split(separator: ":").first.map(String.init) }),
            Self.processSignalsSurfaces,
            "the census stopped seeing the files it is written around. Sites:\n"
            + unexempted.joined(separator: "\n"))

        let offenders = try processSignalsSites(in: viewsDir)
        XCTAssertTrue(offenders.isEmpty,
            "the process signals must not reach a third surface under "
            + "Maugham/Views/ (global constraint 29): they are read in the "
            + "Statistics window's Practice section and in the letter, and "
            + "nowhere else \u{2014} not the footer, not the tree, not the "
            + "editor, not a badge. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: a planted badge is caught, and neither
    /// exemption shape is.
    func test_theProcessSignalsCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-process-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(
            at: tmp.appendingPathComponent("statistics"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct EditorStatusFooter: View {
            let signals: ProcessSignals
        }
        """.write(to: tmp.appendingPathComponent("EditorStatusFooter.swift"),
                  atomically: true, encoding: .utf8)
        // CONTROLS: the surface's own directory, and a named exemption.
        try "struct AnotherSection { let practice: ProjectPractice? }"
            .write(to: tmp.appendingPathComponent("statistics/AnotherSection.swift"),
                   atomically: true, encoding: .utf8)
        try "// LetterSection names ProcessSignals only to say it never draws it."
            .write(to: tmp.appendingPathComponent("LetterSection.swift"),
                   atomically: true, encoding: .utf8)

        let sites = try processSignalsSites(in: tmp)
        XCTAssertEqual(
            sites.count, 1,
            "Self-check: the planted footer should be the one caught, and "
            + "neither the statistics/ file nor the exempt letter. Got:\n"
            + sites.joined(separator: "\n"))
        XCTAssertTrue(
            sites.first?.hasPrefix("EditorStatusFooter.swift:2") == true,
            sites.first ?? "nothing caught")
    }

    // MARK: - The stage word has one source (editorial letter P3, constraint 28)

    /// Every READ of `DraftStage.laneWord` under `dir`, as `file:line: text`.
    /// A comment naming it is not a read of it, and the declaration itself
    /// (`var laneWord`) carries no leading dot, so it is not one either.
    private func laneWordReadSites(in dir: URL) throws -> [String] {
        try grepSwift(
            in: dir, patterns: [".laneWord"],
            excludeLine: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            })
    }

    /// **The stage word is read in two view files and nowhere else** (global
    /// constraint 28). The word rides the ONE lane string every reader already
    /// calls — the kept letter's own heading and the letter's signature — so a
    /// third file spelling it is a third place the lane's wording could drift,
    /// and the drift would be silent: two surfaces saying the same round two
    /// ways.
    ///
    /// **`ReviewRoundCockpit` was the first of the two until two loops P1 Task
    /// 8, and its absence is the point of that task.** Review's lane line
    /// names a stage editor and a round; the draft stage is derived for a
    /// CHECK and doses Author's letter, so the word there was the other loop's
    /// copy on Review's strip. It survives where it is a fact about a run that
    /// happened — a kept letter's heading and the letter's own signature.
    ///
    /// A caller who needs the stage in a line takes it as a `DraftStage?` and
    /// hands it to one of those two, exactly as `QueueLedgerVerbs.provenance`
    /// does.
    func test_theStageWordIsReadFromTwoViewFilesOnly() throws {
        let sites = try laneWordReadSites(in: sourceDir)
        XCTAssertEqual(
            Set(sites.compactMap { $0.split(separator: ":").first.map(String.init) }),
            ["LetterKeep.swift", "LetterSection.swift"],
            "the lane's spelling must not multiply \u{2014} pass a `DraftStage?` "
            + "to `LetterKeep.laneLine` or `LetterSection.signature` instead. "
            + "Sites:\n"
            + sites.joined(separator: "\n"))
        // **Non-vacuous by construction**, unlike the ledger census beside it:
        // a scanner matching nothing answers the EMPTY set, which is not the
        // two-element set above, so this cannot pass for the wrong reason and
        // cannot go on passing after the word stops being drawn at all.
    }

    /// CONTROL for the census above: a planted third speller is caught, and a
    /// comment naming the property is not.
    func test_theStageWordCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-laneword-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        enum ThirdLaneSpeller {
            // A comment naming stage.laneWord is not a read of it.
            static func line(_ stage: DraftStage) -> String {
                "round 3 \\u{00b7} \\(stage.laneWord)"
            }
        }
        """.write(to: tmp.appendingPathComponent("ThirdLaneSpeller.swift"),
                  atomically: true, encoding: .utf8)

        let sites = try laneWordReadSites(in: tmp)
        XCTAssertEqual(
            sites.count, 1,
            "Self-check: the planted read should be the one caught, and not the "
            + "comment above it. Got:\n" + sites.joined(separator: "\n"))
        XCTAssertTrue(
            sites.first?.hasPrefix("ThirdLaneSpeller.swift:4") == true,
            sites.first ?? "nothing caught")
    }

    // MARK: - The translation read is never swallowed (P2a D0)

    /// Every production site that swallows a `TranslationStore.loadMerged`
    /// refusal. Whole-text rather than line-based, because the call is split
    /// across lines almost everywhere it appears — `try?` on one line and the
    /// call on the next would walk straight past a line scanner. Two shapes:
    /// a `try?` in front of the call, and a `?? []` behind it. A comment
    /// naming either is not a call. Shared with the self-check below.
    private func loadMergedSwallowSites(in dirs: [URL]) throws -> [String] {
        let patterns = [
            #"try\?\s*(?://[^\n]*\n\s*)*(?:TranslationStore\s*\.\s*)?loadMerged\s*\("#,
            #"loadMerged\s*\((?:[^()]|\([^()]*\))*\)\s*\?\?\s*\[\]"#,
        ]
        var offenders: [String] = []
        for dir in dirs {
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let ns = text as NSString
                for pattern in patterns {
                    let regex = try NSRegularExpression(pattern: pattern)
                    regex.enumerateMatches(
                        in: text, range: NSRange(location: 0, length: ns.length)
                    ) { match, _, _ in
                        guard let match else { return }
                        let upTo = ns.substring(to: match.range.location)
                        let lineNumber = upTo.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
                        let start = (upTo as NSString).range(of: "\n", options: .backwards).location
                        let lineStart = start == NSNotFound ? 0 : start + 1
                        let end = ns.range(
                            of: "\n", options: [],
                            range: NSRange(location: match.range.location,
                                           length: ns.length - match.range.location)).location
                        let line = ns.substring(
                            with: NSRange(location: lineStart,
                                          length: (end == NSNotFound ? ns.length : end) - lineStart))
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("//") { return }
                        offenders.append("\(url.lastPathComponent):\(lineNumber): \(trimmed)")
                    }
                }
            }
        }
        return offenders
    }

    /// Every production call of `loadMerged`, however it is spelled — the
    /// non-vacuity control for the census below.
    private func loadMergedCallSites(in dirs: [URL]) throws -> [String] {
        var sites: [String] = []
        for dir in dirs {
            sites += try grepSwift(
                in: dir, patterns: ["TranslationStore.loadMerged("],
                excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        }
        return sites
    }

    /// **Tripwire: a `TranslationStore.loadMerged` refusal is never swallowed**
    /// (P2a D0; RULING-54 for the translation sidecar).
    ///
    /// Since P1b a document's translation is spread over one file per (device,
    /// ACTOR) — the pipeline's own beside the author's review edits — so a read
    /// that steps over the file it could not open answers with a PARTLY
    /// translated document: the author's edits standing over source paragraphs
    /// the pipeline had already translated. Every derivation downstream reads
    /// those as `missing`, the compile gate falls back to source text under
    /// `allow_stale`, and a half-Spanish book is published with nothing said.
    /// The store refuses; a caller that answers `[]` for it puts the silence
    /// back one level up, where nothing can see it.
    ///
    /// A ban rather than a census: there is no site where substituting an
    /// empty read is the right answer. Refuse (the runs, the gate, the two MCP
    /// readers), degrade by NAME (`EditionStatus`' `unreadable`, which both the
    /// desk and `translation_status` draw), or show the sentence (the editor's
    /// review pane, the desk's pre-flight figure).
    func test_translationLoadMergedIsNeverSwallowed() throws {
        let dirs = Self.translationReadRoots(repoRoot: repoRoot)
        let offenders = try loadMergedSwallowSites(in: dirs)
        XCTAssertTrue(
            offenders.isEmpty,
            "a production site swallows the translation read. `try?` or `?? []` "
            + "here answers with a document that is part-translated by an "
            + "accident of permissions. Refuse, degrade by name, or show the "
            + "sentence. Offenders:\n" + offenders.joined(separator: "\n"))
        // **Non-vacuous.** A scanner pointed at the wrong roots would find no
        // offenders for the wrong reason, and go on passing forever.
        XCTAssertFalse(
            try loadMergedCallSites(in: dirs).isEmpty,
            "the census found no `TranslationStore.loadMerged` call at all — "
            + "check the roots before believing the empty offender list")
    }

    /// CONTROL for the census above: both planted swallows are caught, and
    /// neither the honest `try` beside them nor a comment naming the verb is.
    func test_theTranslationReadCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-translationread-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        enum SecondTranslationReader {
            // A comment naming try? TranslationStore.loadMerged( is not a call.
            static func swallowed(_ docId: String, _ projectURL: URL) -> [TranslationRecord] {
                try? TranslationStore.loadMerged(
                    forDocId: docId, language: "es", in: projectURL) ?? []
            }

            static func coalesced(_ docId: String, _ projectURL: URL) -> [TranslationRecord] {
                (try? TranslationStore.loadMerged(forDocId: docId, language: "es", in: projectURL)) ?? []
            }

            static func honest(_ docId: String, _ projectURL: URL) throws -> [TranslationRecord] {
                try TranslationStore.loadMerged(
                    forDocId: docId, language: "es", in: projectURL)
            }
        }
        """.write(to: tmp.appendingPathComponent("SecondTranslationReader.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try loadMergedSwallowSites(in: [tmp])
        let lines = Set(offenders.compactMap {
            $0.split(separator: ":").dropFirst().first.map(String.init)
        })
        XCTAssertEqual(
            lines, ["4", "9"],
            "Self-check: the two planted swallows should be caught, and neither "
            + "the honest `try` nor the comment. Got:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - Meta-tests: tripwires fire on planted offenders (task 4.8 / test gap #14)

    /// Self-check: prove the op-log filename tripwire FIRES on a planted
    /// `hasPrefix("d_")` call. Writes a synthetic Swift file into a temp dir
    /// and confirms the grep catches it (guarding against a tripwire that
    /// silently never matches).
    func test_opLogFilenameTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-docid-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("BadParser.swift")
        try """
        func parseDocId(_ filename: String) -> Bool {
            return filename.hasPrefix(\"d_\")  // hand-rolled — should be caught
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: ["hasPrefix(\"d_\")"]
        )
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly one offender for hasPrefix(\"d_\"). Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("hasPrefix") == true,
            "Self-check: the planted hasPrefix(\"d_\") call should be the one caught.")
    }

    /// Self-check: prove the `hashValue` tripwire FIRES on a planted offender.
    /// Confirms the pattern catches a bare `.hashValue` expression and that the
    /// allowed exclusions (Hashable conformance, comment lines) still pass.
    func test_hashValueTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-hashvalue-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("BadIdBuilder.swift")
        try """
        // This is allowed: var id: Int { hashValue }  // Hashable conformance
        // Also allowed: comment explaining the hazard — .hashValue is randomised
        func buildDocId(_ s: String) -> String {
            return String(s.hashValue)  // forbidden: persisted id from hashValue
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: [".hashValue"],
            excludeLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("Identifiable") || trimmed.contains("Hashable") { return true }
                if trimmed.hasPrefix("//") { return true }
                return false
            }
        )
        // Only the executable expression fires; comment + Hashable lines are excluded.
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the executable .hashValue call to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("String(s.hashValue)") == true,
            "Self-check: the planted String(s.hashValue) offender should be the one caught.")
    }

    /// Self-check: prove the tripwire FIRES on a planted offender. Writes a
    /// synthetic Swift file with a forbidden raw move into a temp dir and
    /// confirms the grep catches it (and that the staging-exclusion still lets
    /// a legitimate internal move through).
    func test_userContentMoverTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("ProjectStore+Structure.swift")
        try """
        func bad() throws {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            try FileManager.default.moveItem(at: staging, to: dest) // internal-move: staging
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        // The planted tree holds one of the scoped files, so the rest are
        // reported missing; this control counts hits.
        let offenders = try grepSwift(
            in: tmp,
            files: userContentMoverFiles,
            patterns: userContentMoverPatterns,
            excludeLine: { [self] in isInternalMoveLine($0) }
        ).filter { !$0.hasPrefix("MISSING SCOPE:") }
        // The bare oldURL→newURL move fires; the marked internal move is excluded.
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the non-staging move to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("oldURL") == true,
            "Self-check: the planted oldURL→newURL offender should be the one caught.")
    }

    /// Self-check: prove the palette-write tripwire FIRES on a planted raw
    /// write, and that the funnel's own marked fallback write is excluded.
    func test_paletteWriteTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-palette-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("ProjectStore+Palette.swift")
        try """
        func bad() throws {
            try rendered.write(to: fileURL, atomically: true, encoding: .utf8)
            try text.write(  // palette-coordinated-write: fallback direct write for unit-test contexts
                to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            files: ["ProjectStore+Palette.swift"],
            patterns: paletteWritePatterns,
            excludeLine: { [self] in isPaletteFunnelLine($0) }
        )
        // The bare rendered.write fires; the marked funnel fallback is excluded.
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the unmarked raw write to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("rendered.write") == true,
            "Self-check: the planted rendered.write offender should be the one caught.")
    }

    // MARK: - Sealed-segment name tripwire (ADR 0016)

    /// Recurrence-tripper: segment filenames/extension are built ONLY by
    /// `OpLogStore.segmentFileURL` (MaughamCore). A hand-rolled ".mzseg"
    /// template in Maugham/ is the same reach-around class as the phone's
    /// doc-id parser bug. Sealing is invoked ONLY via sealTailIfNeeded on
    /// the device's own slug (CLAUDE.md tripwire 17 footnote).
    func test_noHandRolledSegmentNamesInMacSources() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: [".mzseg"],
            allowed: ["MaughamSidecarPath.swift"],   // routes by suffix, sanctioned
            excludeLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
            }
        )
        XCTAssertTrue(offenders.isEmpty,
            "Hand-rolled .mzseg segment naming in Maugham/. Use "
            + "OpLogStore.segmentFileURL / opLogFileURLs (MaughamCore). "
            + "See docs/superpowers/notes/cross-surface-contracts.md. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    func test_segmentNameTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-mzseg-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try """
        func badSegmentName(_ docId: String) -> String {
            return "\\(docId).mac.seg0001.mzseg"
        }
        """.write(to: tmp.appendingPathComponent("BadSeg.swift"),
                  atomically: true, encoding: .utf8)
        let offenders = try grepSwift(in: tmp, patterns: [".mzseg"])
        XCTAssertEqual(offenders.count, 1)
    }

    // MARK: - Manuscript-body read tripwire (ADR 0018)

    /// Concrete file-read call shapes that could pull a manuscript body off
    /// disk, bypassing the op log. Substring-matched against each source line.
    /// SHARED between the production check and the planted-offender self-test —
    /// the previous per-test duplication (finding F9) is gone; there is exactly
    /// one place to widen the pattern set.
    static let adr0018ReadPatterns: [String] = [
        "String(contentsOf",
        "Data(contentsOf",
        "contentsOfFile",
        ".contents(atPath",
        "FileHandle(forReadingFrom",
        ".resourceBytes",
    ]

    /// Compromise on `URL.lines` (spec F9 flagged it as false-positive-prone):
    /// a bare `.lines` substring is far too greppy — the in-memory
    /// `FountainScript.lines` property appears 25+ times across the editor and
    /// renderers and has nothing to do with disk I/O, while the codebase has
    /// ZERO `URL.lines` async reads. So instead of a substring pattern we flag
    /// only the async-line-read SHAPE: a line that mentions both `.lines` and
    /// `await` (the `for try await … in url.lines` `AsyncLineSequence`
    /// signature). Synchronous `for … in script.lines` iteration carries no
    /// `await` and is not flagged; a real `URL.lines` read would carry `await`
    /// and trip here.
    static func adr0018IsAsyncURLLinesRead(_ line: String) -> Bool {
        line.contains(".lines") && line.contains("await")
    }

    /// A line is exempt when it carries an explicit `// adr-0018-ok: <reason>`
    /// annotation (a legitimate non-manuscript read whose reason is stated
    /// inline) or is a pure comment line (explanatory prose, no executable
    /// read). SHARED between the production check and the self-test.
    static func adr0018ExcludeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("// adr-0018-ok:") { return true }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { return true }
        return false
    }

    /// ADR 0018 (finding F9 rewrite): manuscript content/sequence/anchors are
    /// read ONLY from the op log (DerivedManuscript / the live Document) —
    /// never the `.md`/`.fountain` file. The old guard scanned only the 8 files
    /// that once held the original offenders, for 3 patterns; new files, other
    /// read APIs, and MaughamCore all evaded it. This one scans EVERY
    /// production `.swift` under `Maugham/` AND
    /// `Packages/MaughamCore/Sources/` for the widened pattern set, and every
    /// non-comment file-read hit MUST carry a `// adr-0018-ok: <reason>`
    /// annotation stating what the read actually is (research note, manifest,
    /// session/UI state, publish asset, help doc, inbox, checksum bytes, an
    /// op-log file — which IS the source of truth — or one of the two
    /// sanctioned manuscript sites: the echo/divergence reads in
    /// Document+Load.swift and the external-change detector in
    /// DocumentStore.swift). The phone twin lives in TripwirePhoneGrepTest.
    func test_noManuscriptFileReadsOutsideReconciler() throws {
        let coreDir = repoRoot
            .appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true)
        var offenders = try grepSwift(
            in: sourceDir,
            patterns: Self.adr0018ReadPatterns,
            excludeLine: Self.adr0018ExcludeLine,
            extraOffender: Self.adr0018IsAsyncURLLinesRead
        )
        offenders += try grepSwift(
            in: coreDir,
            patterns: Self.adr0018ReadPatterns,
            excludeLine: Self.adr0018ExcludeLine,
            extraOffender: Self.adr0018IsAsyncURLLinesRead
        )
        XCTAssertTrue(offenders.isEmpty,
            "A production file reads a manuscript body off disk without justification. "
            + "Route through DerivedManuscript (closed doc) or the live Document (open doc). "
            + "If the read is genuinely NOT a manuscript-as-truth (research note, manifest, "
            + "session/UI state, publish asset, help doc, inbox, checksum bytes, an op-log "
            + "file, or a sanctioned echo/external-change site), annotate the line with "
            + "`// adr-0018-ok: <reason>` saying what the read is. "
            + "See docs/adr/0018-manuscript-reads-derive-from-oplog.md. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the ADR 0018 tripwire FIRES on a planted offender.
    /// Writes a synthetic file with an unannotated `String(contentsOf:` and
    /// confirms the grep catches it; also confirms an annotated sibling line
    /// AND an `.resourceBytes`/async-`.lines` sibling behave correctly (the
    /// exclusion + widened-pattern + compound-`.lines` logic is sound). Shares
    /// the pattern list and exclusion predicate with the production check.
    func test_manuscriptReadTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-adr0018-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("SomeNewFile.swift")
        try """
        func readManuscript(at url: URL) throws -> String {
            // Forbidden — manuscript body bypasses the op log:
            return try String(contentsOf: url, encoding: .utf8)
        }
        func readResearch(at url: URL) throws -> String {
            return try String(contentsOf: url, encoding: .utf8) // adr-0018-ok: research-note read
        }
        func streamManuscript(at url: URL) async throws {
            for try await _ in url.lines {}  // widened: URL.lines async read must fire
        }
        func streamScript(_ script: FountainScript) {
            for line in script.lines {}  // must NOT fire — sync in-memory property
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: Self.adr0018ReadPatterns,
            excludeLine: Self.adr0018ExcludeLine,
            extraOffender: Self.adr0018IsAsyncURLLinesRead
        )
        // The unannotated String(contentsOf:) and the async URL.lines read fire;
        // the annotated line and the synchronous script.lines line are excluded.
        XCTAssertEqual(offenders.count, 2,
            "Self-check expected exactly the unannotated contentsOf: call and the "
            + "async URL.lines read to fire. Got:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("String(contentsOf: url") },
            "Self-check: the planted unannotated String(contentsOf:) should be caught.")
        XCTAssertTrue(offenders.contains { $0.contains("url.lines") },
            "Self-check: the planted async URL.lines read should be caught.")
        XCTAssertFalse(offenders.contains { $0.contains("script.lines") },
            "Self-check: synchronous script.lines iteration must NOT fire.")
    }

    /// **A figure's render is never read as truth** (report plan 6a Task 8):
    /// `figures/<name>.csv` is derived from the figure's op log exactly as a
    /// manuscript's `.md` is, so a production-shaped read of one with no
    /// `// adr-0018-ok:` reason fires the census, in each read shape; a
    /// deliberate import input that says so goes through; and with the
    /// offending reads taken away the planted file is clean.
    func test_manuscriptReadTripwireFiresOnAPlantedFigureRenderRead() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-adr0018-figure-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let reasoned = """
        func importCSV(from research: URL) throws -> String {
            try String(contentsOf: research, encoding: .utf8) // adr-0018-ok: a research CSV, the Import input — never a figure's render
        }
        """
        let offending = """
        func figureTable(_ projectURL: URL) throws -> String {
            try String(contentsOf: projectURL.appendingPathComponent("figures/x.csv"), encoding: .utf8)
        }
        func figureBytes(_ projectURL: URL) -> Data? {
            FileManager.default.contents(atPath: projectURL.appendingPathComponent("figures/x.csv").path)
        }
        """
        let planted = tmp.appendingPathComponent("FigureReader.swift")
        func offenders() throws -> [String] {
            try grepSwift(
                in: tmp,
                patterns: Self.adr0018ReadPatterns,
                excludeLine: Self.adr0018ExcludeLine,
                extraOffender: Self.adr0018IsAsyncURLLinesRead)
        }

        try (reasoned + "\n" + offending).write(to: planted, atomically: true, encoding: .utf8)
        let caught = try offenders()
        XCTAssertEqual(caught.count, 2,
            "Self-check: both unreasoned reads of figures/x.csv fire, the reasoned "
            + "import does not. Caught:\n" + caught.joined(separator: "\n"))
        XCTAssertTrue(caught.allSatisfy { $0.contains("figures/x.csv") })

        try reasoned.write(to: planted, atomically: true, encoding: .utf8)
        XCTAssertEqual(try offenders(), [], "and taken away, the file is clean")
    }

    // MARK: - Dev-only TestMCPToolCatalog registration tripwire

    /// Repo root, computed the same way `sourceDir` does (2x
    /// `deletingLastPathComponent()` off this file's `#filePath`), but without
    /// appending `Maugham/` — used to reach `Maugham/MaughamApp.swift` itself.
    /// The three production trees a translation read can live in. The phone
    /// has no `loadMerged` caller today, and it is in the list precisely so
    /// that the first one it grows is judged by this census rather than
    /// arriving unwatched.
    static func translationReadRoots(repoRoot: URL) -> [URL] {
        ["Maugham", "MaughamPhone", "Packages/MaughamCore/Sources"]
            .map { repoRoot.appendingPathComponent($0, isDirectory: true) }
    }

    private var repoRoot: URL {
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Tripwire 33: no new press-then-wait test

    /// **A test that presses a mounted control and then waits for its effect
    /// is the shape behind every red CI run in the sixty before 2026-09-05.**
    /// `TranslationRoundReportTests` (twice, the second press landing on a
    /// container the first press's Task still had disabled),
    /// `StatementEditorMountTests` (a barging gate granted out of order three
    /// attempts running), `AnnotationsPaneChoiceTests`' Keep end-to-end
    /// (hardened once, back within a fortnight) — none of them said anything
    /// about the code, and each cost a re-run or a human read of the log. The
    /// flake-triage session cut seventy-seven of them and kept the ones named
    /// below: at most one per file, chosen for the most synchronous effect,
    /// where a button-to-closure wiring would otherwise have no guard at all —
    /// plus `StatementDraftHandoffTests`' two, which pin the words-never-lost
    /// invariant and press a KEYSTROKE rather than a button.
    ///
    /// **A new one fails here.** Pin the decision windowlessly (a pure
    /// predicate, a verbs suite, a source census) and assert only that the
    /// control is DRAWN. If a press is the only way to guard a wiring, add the
    /// test to `pressThenWaitRepresentatives` in the same commit, with its
    /// effect a closure append rather than a store write, and say in its doc
    /// comment why no windowless pin exists.
    ///
    /// The scan is per test function: a press call (`press(` as a statement,
    /// or a raw `accessibilityPerformPress` perform) followed by
    /// `pumpUntil(` / `waitUntil(` / `pump(` / `waitOut(` before the
    /// function's closing brace, comment lines ignored. (`waitOut(` joined in
    /// plan 3's C14: a fixed wait is the same shape as a poll.) A synthesised
    /// mouse CLICK is the same defect by another input, and has its own arm
    /// below — `clickRepresentatives`. Mount-and-read tests, censuses and
    /// measurements do not match, and the self-check below says so.
    static let pressThenWaitRepresentatives: Set<String> = [
        "AnnotationsPaneChoiceTests.swift test_theSheetCommitsTheWriterSentence",
        "AnnotationsPaneChoiceTests.swift test_theSheetRefusesABlankHeadingBeforeTheVerbIsCalled",
        "AssistantColumnTests.swift test_theColumnNamesWhatIsBeingStudiedAndCanBeClosed",
        "DepartmentPaneTests.swift test_theSheetOffersTheBooksOwnLanguageCheckedAndCompilesIt",
        "LetterSectionTests.swift test_addToIntentCallsTheHostsHandler",
        "PracticeSectionTests.swift test_pressingAHotspotRowOpensThatRowsOwnChapter",
        "ReferencesPaneTests.swift test_theShelfDrawsARowPerPinAndAClickPromotesIt",
        "ReviewRoundCockpitTests.swift test_clearingTheAskReachesTheHostAndStartsNoRun",
        "StatementDraftHandoffTests.swift test_aMintThatDepositedTheWritersCharacterKeepsItsStatement",
        // Found when the arm learned `waitOut(` (plan 3, C14): the same file's
        // words-never-lost invariant — a mint that FOUND its statement must never
        // delete it on rollback — with the same keystroke press as its siblings.
        "StatementDraftHandoffTests.swift test_aMintThatFoundItsStatementNeverRollsItBack",
        "StatementDraftHandoffTests.swift test_aMintThatNeitherBoundNorDepositedLeavesNoStatement",
    ]

    /// Every `File.swift test_name` under `dir` whose body presses and then
    /// waits. Pure over the text, so the self-check can plant offenders.
    static func pressThenWaitTests(under dir: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var hits: [String] = []
        for case let url as URL in walker
        where url.pathExtension == "swift" && !url.path.contains("/TestSupport/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            var name: String?
            var pressed = false
            var waited = false
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.hasPrefix("func test_") {
                    let rest = trimmed.dropFirst("func ".count)
                    name = String(rest.prefix { $0 == "_" || $0.isLetter || $0.isNumber })
                    pressed = false; waited = false
                    continue
                }
                if line == "    }" {
                    if let n = name, pressed, waited { hits.append("\(url.lastPathComponent) \(n)") }
                    name = nil; pressed = false; waited = false
                    continue
                }
                guard name != nil else { continue }
                if Self.isPressCall(trimmed) { pressed = true }
                else if pressed, Self.isWaitCall(trimmed) { waited = true }
            }
        }
        return hits.sorted()
    }

    private static func isPressCall(_ trimmed: String) -> Bool {
        if trimmed.contains("accessibilityPerformPress\")") { return true }
        var s = Substring(trimmed)
        for prefix in ["_ = ", "try ", "await "] where s.hasPrefix(prefix) { s = s.dropFirst(prefix.count) }
        // `try await press(` and `_ = try press(` both reduce to `press(`.
        for prefix in ["try ", "await "] where s.hasPrefix(prefix) { s = s.dropFirst(prefix.count) }
        return s.hasPrefix("press(")
    }

    private static func isWaitCall(_ trimmed: String) -> Bool {
        for token in ["pumpUntil(", "waitUntil(", "pump(", "waitOut("] where trimmed.contains(token) {
            return true
        }
        return false
    }

    func test_noNewTestPressesAControlAndThenWaitsForItsEffect() throws {
        let testsDir = repoRoot.appendingPathComponent("MaughamTests", isDirectory: true)
        let found = Set(try Self.pressThenWaitTests(under: testsDir))
        let offenders = found.subtracting(Self.pressThenWaitRepresentatives).sorted()
        XCTAssertTrue(offenders.isEmpty,
            "A test presses a mounted control and then waits for an asynchronous "
            + "effect — the shape behind every red CI run before 2026-09-05. Pin "
            + "the decision without a window and assert only that the control is "
            + "drawn; if a press is genuinely the only guard of a wiring, add it to "
            + "`pressThenWaitRepresentatives` in the same commit and say why. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
        let retired = Self.pressThenWaitRepresentatives.subtracting(found).sorted()
        XCTAssertTrue(retired.isEmpty,
            "The allow-list names a representative that no longer presses and "
            + "waits (renamed, cut, or converted) — take it off the list so the "
            + "list stays a census rather than a memory:\n"
            + retired.joined(separator: "\n"))
    }

    /// Self-check: fires on a planted press-then-poll, a planted raw perform
    /// followed by a fixed pump, and a planted `try await press(`; stays quiet
    /// on a mount-and-read test, a press with no wait, a wait with no press,
    /// and prose naming both.
    func test_thePressThenWaitGuardFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-pressthenwait-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        final class SomeSuite: XCTestCase {
            func test_pollsAfterAPress() async throws {
                let window = TestWindow.mount(Text("x"))
                press(try axButtons(labelled: "Go", in: window)[0])
                _ = await pumpUntil(deadline: 3) { box.count == 1 }
            }
            func test_sleepsAfterARawPerform() {
                _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
                pump(0.3)
                XCTAssertEqual(box.count, 1)
            }
            func test_awaitsAPressThenWaits() async throws {
                try await press("Go", in: window)
                waitUntil({ done }, timeout: 2)
            }
            func test_waitsOutAfterAPress() async throws {
                press(try axButtons(labelled: "Go", in: window)[0])
                await waitOut(0.3)
            }
        }
        """.write(to: tmp.appendingPathComponent("SomeSuite.swift"),
                  atomically: true, encoding: .utf8)
        try """
        /// Prose: press( then pumpUntil( is the shape this guard is about.
        final class Innocent: XCTestCase {
            func test_mountsAndReads() async throws {
                let window = TestWindow.mount(Text("x"))
                pump(0.3)
                XCTAssertEqual(try axButtons(labelled: "Go", in: window).count, 1)
            }
            func test_pressesWithoutWaiting() throws {
                press(try axButtons(labelled: "Go", in: window)[0])
                XCTAssertEqual(box.count, 1)   // synchronous effect
            }
            func test_waitsBeforeThePress() async throws {
                _ = await pumpUntil(deadline: 3) { ready }
                // press(…) discussed in a comment only
                XCTAssertTrue(ready)
            }
        }
        """.write(to: tmp.appendingPathComponent("Innocent.swift"),
                  atomically: true, encoding: .utf8)

        let found = try Self.pressThenWaitTests(under: tmp)
        XCTAssertEqual(found, [
            "SomeSuite.swift test_awaitsAPressThenWaits",
            "SomeSuite.swift test_pollsAfterAPress",
            "SomeSuite.swift test_sleepsAfterARawPerform",
            "SomeSuite.swift test_waitsOutAfterAPress",
        ])
    }

    // MARK: - Tripwire 33, the click arm

    /// **The click arm (plan 3 carry C14).** A synthesised mouse click is the
    /// press's twin — a real `NSEvent` pair through a mounted window, then a
    /// wait for what it did — and it was outside the census because its waits
    /// live where a body scan cannot see them: inside the helper that builds
    /// the event (`waitOut`, a `pump` after the pair), or in an `until:`
    /// closure handed to it. The click itself is visible everywhere, so the arm
    /// censuses the CLICK (ruling C14-1), not the click-then-wait.
    ///
    /// **Every click test is named here, with why it survives.** A click stays
    /// only where it guards what no windowless test can — a hit area, the real
    /// delivery path, a cold click — one representative per wiring per file.
    /// A new one fails `test_noNewTestClicksOutsideTheNamedRepresentatives`:
    /// pin its decision without a window (a pure predicate, a source census, a
    /// mount-and-read that the control is DRAWN), or, if a click really is the
    /// only guard, add it here in the same commit with the reason beside it.
    static let clickRepresentatives: Set<String> = [
        // The real entry point: `CanvasEventNSView.mouseDown(with:)` takes first
        // responder, and every other canvas test clicks through the seam that
        // does not. Synchronous — the override is called directly, nothing waits.
        "CanvasEventViewTests.swift test_aClickTakesFirstResponderSoTheKeyboardReachesTheCanvas",
        // The real delivery path, reached through the superclass file's
        // `sendRealDrag`: ⇧ is read off the event inside `mouseDown(with:)`, and
        // the seam every other canvas test drives takes the flag by hand — the
        // 1C-a shape. Sent synchronously, pumped once; nothing polls.
        "CanvasViewMountingRegionTests.swift test_aShiftDragBetweenTwoCardsReachesTheSceneThroughTheRealEventPath",
        // A hit area: the door's live band swept down (and across) the icon.
        // SwiftUI hit-tests inside one hosting view, so no `hitTest` can see it.
        "PaletteWallDoorHitAreaTests.swift test_theWholeOpenWallIconOpensTheWall",
        // The sweep's control — without a miss it can see, the sweep asserts nothing.
        "PaletteWallDoorHitAreaTests.swift test_control_theSweepCanSeeAMiss",
        // The real delivery path: the door's click through the real
        // `PaletteWallModifier`, whose persona observer is what the press's
        // token ordering exists to survive.
        "PaletteWallDoorTests.swift test_pressingTheDoorInPlanLandsTheWriterInAuthorWithTheWallOpen",
        // The real delivery path: the only proof the altitude overlay's card can
        // be reached by a mouse at all (a `Button(.plain)` in a `LazyVGrid`).
        "ProjectAltitudeCentreTests.swift test_clickingACorkboardCardOpensThatChapterInTheHostThatWasAlreadyUp",
        // The real delivery path: a slugline `Button` inside Plan's `List(.sidebar)`.
        "ProjectSubjectReachabilityTests.swift test_aSluglineOnPlansTreePostsTheScreenplaysNavigation",
        // The real delivery path, one per control on the board: a chip carries
        // its own cell's two ids, and a count its own row's piece.
        "ReviewBoardPaneTests.swift test_aChipClickCarriesItsOwnCellsIdentity",
        "ReviewBoardPaneTests.swift test_aCountClickCarriesItsOwnRowsPiece",
        // The real delivery path: a chip clicked through the window's layered
        // board, over the corkboard it covers, making the hop.
        "ReviewBoardRoutingTests.swift test_aChipClickOpensThatChapterInTheHostAndRemembersThePass",
        // The real delivery path: a scene row's `Button` still takes the click
        // inside a `List(selection:)` — `selectRowIndexes` never reaches a Button.
        "SceneNavigatorProjectRowTests.swift test_clickingASceneNavigatesAndTakesTheSubjectOffTheProject",
        // A hit area: the chevron's four edges, a fresh window per sample.
        "SectionChevronTests.swift test_theWholeChevronIsClickableTopToBottom",
        // A hit area: a click on the row's NAME selects (stage 3b's regression,
        // invisible to a `rect.midX` click) — and, with the watcher installed,
        // stays one click: the persona does not move.
        "TreeTravelTests.swift test_aSingleClickOnTheRowsNameSelectsIt",
        // The real delivery path: the travel is an `NSEvent` local monitor
        // reading `clickCount == 2`, which only `NSApp`'s own dispatch runs.
        "TreeTravelTests.swift test_aDoubleClickOnTheRowsNameTravelsToAuthor",
    ]

    /// Every `File.swift test_name` under `dir` whose body synthesises a mouse
    /// click. Pure over the text, so the self-check can plant offenders.
    ///
    /// A test function is a CLICK test when its body builds or sends a
    /// `.leftMouseDown`/`.leftMouseUp` event or calls `mouseDown(with:)`
    /// itself, or calls a helper that does. The helpers are derived, transitively
    /// (a helper that reaches the event through another helper counts), and
    /// never listed, from two places only:
    ///
    /// - functions defined IN THE SAME FILE as the test; and
    /// - functions defined in the file that declares a SUPERCLASS of a class in
    ///   the test's file (`class X: Base` here → the file declaring
    ///   `class Base`), up the chain — which is how the canvas-mounting family
    ///   reaches `CanvasViewMountingCase`'s `sendRealDrag`/`sendRealClick`.
    ///
    /// A helper of the same name in an UNRELATED file is not followed: the arm
    /// reads a call by its spelling, and following spellings across the tree
    /// would count every `click(` as the one that happens to build an event.
    ///
    /// **Out of scope: the canvas's `applyMouseDown`/`applyMouseUp` seam.** It
    /// is a direct synchronous call into `CanvasEventNSView`, not an `NSEvent`
    /// through a window, so there is no delivery for a wait to hide behind —
    /// the seam exists precisely because synthesised events were unreliable.
    ///
    /// Comment lines and the bodies of multi-line string literals are not code
    /// and are skipped (the self-checks' planted files live in literals).
    static func clickTests(under dir: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        struct Scanned {
            let name: String
            let functions: [(name: String, body: [String])]
            let classes: [(name: String, superclass: String?)]
        }
        var files: [Scanned] = []
        for case let url as URL in walker
        where url.pathExtension == "swift" && !url.path.contains("/TestSupport/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            files.append(Scanned(name: url.lastPathComponent,
                                 functions: Self.functionBodies(in: text),
                                 classes: Self.declaredClasses(in: text)))
        }
        var fileDeclaring: [String: Int] = [:]
        for (index, file) in files.enumerated() {
            for declared in file.classes { fileDeclaring[declared.name] = index }
        }

        // A file's helpers: seeded by its own event-builders plus whatever its
        // superclasses' files export, then closed under its own functions.
        var memo: [Int: Set<String>] = [:]
        func helpers(of index: Int, visiting: Set<Int>) -> Set<String> {
            if let known = memo[index] { return known }
            var found = Set(files[index].functions
                .filter { !$0.name.hasPrefix("test_") && Self.buildsAMouseClick($0.body) }
                .map(\.name))
            for declared in files[index].classes {
                guard let base = declared.superclass, let baseFile = fileDeclaring[base],
                      baseFile != index, !visiting.contains(baseFile) else { continue }
                found.formUnion(helpers(of: baseFile, visiting: visiting.union([index])))
            }
            var grew = true
            while grew {
                grew = false
                for function in files[index].functions
                where !function.name.hasPrefix("test_") && !found.contains(function.name)
                    && found.contains(where: { Self.calls($0, in: function.body) }) {
                    found.insert(function.name)
                    grew = true
                }
            }
            memo[index] = found
            return found
        }

        var hits: [String] = []
        for index in files.indices {
            let reachable = helpers(of: index, visiting: [])
            for function in files[index].functions where function.name.hasPrefix("test_") {
                if Self.buildsAMouseClick(function.body)
                    || reachable.contains(where: { Self.calls($0, in: function.body) }) {
                    hits.append("\(files[index].name) \(function.name)")
                }
            }
        }
        return hits.sorted()
    }

    /// Every `class Name: Super` a file declares (`class func`/`class var`
    /// are members, not declarations), with its first inherited type.
    private static func declaredClasses(in text: String) -> [(name: String, superclass: String?)] {
        var result: [(name: String, superclass: String?)] = []
        var inString = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let delimiters = Self.stringDelimiterCount(in: trimmed)
            if inString || delimiters % 2 == 1 {
                if delimiters % 2 == 1 { inString.toggle() }
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            let words = trimmed.split(separator: " ")
            guard let at = words.firstIndex(of: "class"), at + 1 < words.count else { continue }
            let modifiers: Set<Substring> = ["final", "private", "fileprivate", "internal",
                                             "public", "open"]
            guard words[..<at].allSatisfy({ modifiers.contains($0) || $0.hasPrefix("@") })
            else { continue }
            let rest = words[(at + 1)...].joined(separator: " ")
            let name = rest.prefix { $0 == "_" || $0.isLetter || $0.isNumber }
            guard !name.isEmpty, name != "func", name != "var", name != "let" else { continue }
            var superclass: String?
            if let colon = rest.firstIndex(of: ":") {
                let after = rest[rest.index(after: colon)...].drop { $0 == " " }
                let first = after.prefix { $0 == "_" || $0.isLetter || $0.isNumber }
                if !first.isEmpty { superclass = String(first) }
            }
            result.append((String(name), superclass))
        }
        return result
    }

    private static let mouseClickTokens = [".leftMouseDown", ".leftMouseUp", "mouseDown(with:"]

    private static func buildsAMouseClick(_ body: [String]) -> Bool {
        body.contains { line in mouseClickTokens.contains { line.contains($0) } }
    }

    /// Whether `body` calls `name(` — `name` not the tail of a longer
    /// identifier, so `click(` is not found in `doubleClick(`.
    private static func calls(_ name: String, in body: [String]) -> Bool {
        let needle = name + "("
        for line in body {
            var searchFrom = line.startIndex
            while let found = line.range(of: needle, range: searchFrom..<line.endIndex) {
                if found.lowerBound == line.startIndex { return true }
                let before = line[line.index(before: found.lowerBound)]
                if !(before.isLetter || before.isNumber || before == "_") { return true }
                searchFrom = found.upperBound
            }
        }
        return false
    }

    /// Every `func` in `text` with the code lines of its body (trimmed; comment
    /// lines and string-literal bodies removed). A body runs from its
    /// declaration to the first code line at or left of the declaration's own
    /// indentation — its closing brace, or, for a body-less declaration, the
    /// next member. A line opening with `)` is a multi-line signature's close,
    /// not the end. Nested functions are part of their enclosing body.
    private static func functionBodies(in text: String) -> [(name: String, body: [String])] {
        var result: [(name: String, body: [String])] = []
        var current: (name: String, indent: Int, body: [String])?
        var inString = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let delimiters = Self.stringDelimiterCount(in: trimmed)
            if inString || delimiters % 2 == 1 {
                if delimiters % 2 == 1 { inString.toggle() }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
            let indent = line.prefix { $0 == " " }.count
            if let open = current, indent <= open.indent, !trimmed.hasPrefix(")") {
                result.append((open.name, open.body))
                current = nil
                if trimmed.hasPrefix("}") { continue }
            }
            if current == nil, let name = Self.declaredFunctionName(trimmed) {
                let opens = trimmed.filter { $0 == "{" }.count
                if opens > 0, opens == trimmed.filter({ $0 == "}" }).count {
                    result.append((name, [trimmed]))   // a one-line body
                } else {
                    current = (name, indent, [])
                }
                continue
            }
            current?.body.append(trimmed)
        }
        if let open = current { result.append((open.name, open.body)) }
        return result
    }

    /// How many multi-line string delimiters open or close on `line` — three
    /// quotes not escaped by a backslash (`\"""` inside a literal is content).
    private static func stringDelimiterCount(in line: String) -> Int {
        let delimiter = String(repeating: "\"", count: 3)
        var count = 0
        var searchFrom = line.startIndex
        while let found = line.range(of: delimiter, range: searchFrom..<line.endIndex) {
            let escaped = found.lowerBound > line.startIndex
                && line[line.index(before: found.lowerBound)] == "\\"
            if !escaped { count += 1 }
            searchFrom = found.upperBound
        }
        return count
    }

    /// The name a line declares with `func`, whatever modifiers precede it.
    private static func declaredFunctionName(_ trimmed: String) -> String? {
        guard let range = trimmed.range(of: "func ") else { return nil }
        let head = trimmed[..<range.lowerBound]
        let modifiers = head.split(separator: " ")
        let allowed: Set<Substring> = ["private", "fileprivate", "internal", "public",
                                       "static", "class", "override", "final",
                                       "nonisolated", "mutating", "@MainActor",
                                       "@discardableResult", "@objc", "@available"]
        guard modifiers.allSatisfy({ allowed.contains($0) || $0.hasPrefix("@") }) else {
            return nil
        }
        let name = trimmed[range.upperBound...].prefix { $0 == "_" || $0.isLetter || $0.isNumber }
        return name.isEmpty ? nil : String(name)
    }

    func test_noNewTestClicksOutsideTheNamedRepresentatives() throws {
        let testsDir = repoRoot.appendingPathComponent("MaughamTests", isDirectory: true)
        let found = Set(try Self.clickTests(under: testsDir))
        let offenders = found.subtracting(Self.clickRepresentatives).sorted()
        XCTAssertTrue(offenders.isEmpty,
            "A test synthesises a mouse click — tripwire 33's click arm. A click "
            + "is a press through the window, and its wait hides in the helper "
            + "or an `until:` closure. Pin the decision without a window and "
            + "assert only that the control is drawn; if a click is genuinely the "
            + "only guard (a hit area, the real delivery path, a cold click), add "
            + "it to `clickRepresentatives` in the same commit, with the reason. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
        let retired = Self.clickRepresentatives.subtracting(found).sorted()
        XCTAssertTrue(retired.isEmpty,
            "`clickRepresentatives` names a test that no longer clicks (renamed, "
            + "cut, or converted) — take it off the list so the list stays a "
            + "census rather than a memory:\n" + retired.joined(separator: "\n"))
    }

    /// Self-check for the click arm. Fires on a click through an in-file helper
    /// (and through a helper that only reaches the event by calling another
    /// in-file helper), on a direct `mouseDown(with:)`, on a test that builds
    /// the event itself, and on a test whose class inherits a harness whose
    /// FILE defines the clicking helper. **Stays quiet on a test calling a
    /// helper of the same name defined in an UNRELATED file** — the arm follows
    /// the test's own file and its superclasses' files only, so
    /// `OtherSuite.swift`'s `click(` and `sendRealClick(` must not be counted,
    /// and they are planted here to prove it. Also quiet on prose naming the
    /// event, on a helper that is never called, and on a planted offender
    /// inside a string literal.
    func test_theClickArmFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-click-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        final class ClickSuite: XCTestCase {
            func test_clicksThroughAnInFileHelper() async throws {
                await click(at: .zero, in: window)
                XCTAssertTrue(done)
            }
            func test_clicksThroughAHelperOfAHelper() async throws {
                await tap(row: 2, in: window)
            }
            func test_callsTheOverrideDirectly() throws {
                view.mouseDown(with: event)
            }
            func test_buildsTheEventItself() throws {
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                              modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1)
                window.sendEvent(down!)
            }
            func test_neverClicks() throws {
                // click(at:) is discussed here and .leftMouseDown too
                XCTAssertEqual(unclicked(), 1)
                let text = \"""
                    func test_plantedInAString() { view.mouseDown(with: e) }
                    \"""
                XCTAssertFalse(text.isEmpty)
            }
            private func tap(row: Int, in window: NSWindow) async {
                await click(at: CGPoint(x: 0, y: row), in: window)
            }
            private func click(at point: CGPoint, in window: NSWindow) async {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    _ = type
                }
            }
            private func unused() {
                view.mouseDown(with: event)
            }
            private func unclicked() -> Int { 1 }
        }
        """.write(to: tmp.appendingPathComponent("ClickSuite.swift"),
                  atomically: true, encoding: .utf8)
        try """
        class ClickHarness: XCTestCase {
            func sendRealClick(in window: NSWindow, at point: CGPoint) {
                window.sendEvent(mouseEvent(.leftMouseDown, at: point)!)
            }
            func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? { nil }
        }
        """.write(to: tmp.appendingPathComponent("ClickHarness.swift"),
                  atomically: true, encoding: .utf8)
        try """
        @MainActor
        final class HarnessSuite: ClickHarness {
            func test_clicksThroughTheSuperclassFilesHelper() throws {
                sendRealClick(in: window, at: .zero)
            }
            func test_neverReachesTheHarnessesClick() throws {
                XCTAssertNotNil(window)
            }
        }
        """.write(to: tmp.appendingPathComponent("HarnessSuite.swift"),
                  atomically: true, encoding: .utf8)
        try """
        final class OtherSuite: XCTestCase {
            func test_callsAClickDefinedInAnotherFile() async throws {
                await click(at: .zero, in: window)
                XCTAssertTrue(done)
            }
            func test_callsTheHarnessesSpellingWithoutInheritingIt() throws {
                sendRealClick(in: window, at: .zero)
            }
            private func sendRealClick(in window: NSWindow, at point: CGPoint) {}
            private func click(at point: CGPoint, in window: NSWindow) async {
                window.performClose(nil)
            }
        }
        """.write(to: tmp.appendingPathComponent("OtherSuite.swift"),
                  atomically: true, encoding: .utf8)

        let found = try Self.clickTests(under: tmp)
        XCTAssertEqual(found, [
            "ClickSuite.swift test_buildsTheEventItself",
            "ClickSuite.swift test_callsTheOverrideDirectly",
            "ClickSuite.swift test_clicksThroughAHelperOfAHelper",
            "ClickSuite.swift test_clicksThroughAnInFileHelper",
            "HarnessSuite.swift test_clicksThroughTheSuperclassFilesHelper",
        ], "the click arm must fire on every planted click and on nothing else "
            + "— `HarnessSuite` inherits `ClickHarness`, so the superclass FILE's "
            + "`sendRealClick` counts; `OtherSuite.swift`'s `click(` and "
            + "`sendRealClick(` share only a SPELLING with helpers in files it "
            + "does not inherit from, so counting them would be the arm guessing")
    }

    /// Recurrence-tripper: `TestMCPToolCatalog` is a dev-only tool catalog for
    /// Claude Code (test MCP) that must NEVER ship in the stable binary. Its
    /// registration in `MaughamApp.swift` is wrapped in `#if MAUGHAM_DEV_BUILD`.
    /// This guards against a future edit accidentally hoisting the call outside
    /// that block (or deleting the block while leaving the call).
    func test_testMCPCatalog_registeredOnlyUnderDevFlag() throws {
        let appURL = repoRoot.appendingPathComponent("Maugham/MaughamApp.swift")
        let app = try String(contentsOf: appURL, encoding: .utf8)

        guard let range = app.range(of: "TestMCPToolCatalog.register") else {
            XCTFail("TestMCPToolCatalog.register call not found in MaughamApp.swift — "
                + "either it was renamed (update this tripwire) or the dev-only test "
                + "MCP registration was removed entirely.")
            return
        }

        let before = app[..<range.lowerBound]
        let lastIf = before.range(of: "#if MAUGHAM_DEV_BUILD", options: .backwards)
        let lastEndif = before.range(of: "#endif", options: .backwards)

        XCTAssertNotNil(lastIf,
            "TestMCPToolCatalog.register must be preceded by a #if MAUGHAM_DEV_BUILD "
            + "guard, or the dev-only test MCP catalog could ship in the stable binary.")

        if let lastIf {
            // The nearest preceding #endif (if any) must close BEFORE the nearest
            // preceding #if MAUGHAM_DEV_BUILD opens — i.e. the #if block containing
            // the registration is still open at the call site.
            if let lastEndif {
                XCTAssertTrue(lastIf.lowerBound > lastEndif.lowerBound,
                    "The nearest #if MAUGHAM_DEV_BUILD before TestMCPToolCatalog.register "
                    + "is already closed by an earlier #endif — the registration call is "
                    + "outside the dev-only gate.")
            }
        }
    }

    // MARK: - ADR 0021: no raw maugham.* posts/subscriptions outside the wrapper

    /// Whole-file regex patterns (the codebase splits post(/publisher( across
    /// lines, so line-based grep misses them). SHARED with the self-test.
    /// The gap between the open-paren and the argument label tolerates
    /// whitespace AND interposed line comments — `(?://[^\n]*\s*)*` — so a
    /// split call with a trailing comment on its first line (the
    /// `// adr-0021-ok:` annotation itself, or any unrelated comment) still
    /// MATCHES and is then judged by the match-start-line exemption. Without
    /// the comment arm, ANY comment in the gap silently broke the match and an
    /// unannotated violation could land undetected. Do NOT widen the gap
    /// beyond whitespace + line comments (a bare `addObserver\(` would
    /// false-positive every system-notification observer).
    static let adr0021PostPattern = "NotificationCenter\\.default\\.post\\("
    static let adr0021SubscribePatterns = [
        "publisher\\(\\s*(?://[^\\n]*\\s*)*for:\\s*\\.maugham",
        "addObserver\\(\\s*(?://[^\\n]*\\s*)*forName:\\s*\\.maugham",
    ]

    /// Scan whole file text for regex matches; report `file:line`. A match
    /// whose LINE carries `// adr-0021-ok:` is exempt; comment-only lines are
    /// exempt.
    private func scanWholeText(
        in dirs: [URL], patterns: [String], allowed: Set<String>
    ) throws -> [String] {
        var offenders: [String] = []
        for dir in dirs {
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if allowed.contains(url.lastPathComponent) { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for pattern in patterns {
                    let regex = try NSRegularExpression(pattern: pattern)
                    let ns = text as NSString
                    regex.enumerateMatches(
                        in: text, range: NSRange(location: 0, length: ns.length)
                    ) { match, _, _ in
                        guard let match else { return }
                        let upTo = ns.substring(to: match.range.location)
                        let lineNumber = upTo.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
                        let lineStart = (upTo as NSString).range(
                            of: "\n", options: .backwards).location
                        let lineStartIndex = lineStart == NSNotFound ? 0 : lineStart + 1
                        let lineEnd = ns.range(
                            of: "\n", options: [],
                            range: NSRange(location: match.range.location,
                                           length: ns.length - match.range.location)).location
                        let lineEndIndex = lineEnd == NSNotFound ? ns.length : lineEnd
                        let line = ns.substring(
                            with: NSRange(location: lineStartIndex,
                                          length: lineEndIndex - lineStartIndex))
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.contains("// adr-0021-ok:") { return }
                        if trimmed.hasPrefix("//") { return }
                        offenders.append(
                            "\(url.lastPathComponent):\(lineNumber): \(trimmed)")
                    }
                }
            }
        }
        return offenders
    }

    /// ADR 0021: every `maugham.*` post/subscription goes through the
    /// MaughamEvent wrapper, which forces a delivery scope at the post site.
    /// A raw NotificationCenter post/subscription is the unscoped-broadcast
    /// defect class that shipped ≥3 times (rewind retrofit, script.did.update,
    /// toggleInspector). If a raw call is genuinely NOT a maugham event
    /// (e.g. posting an Apple system notification), annotate the line with
    /// `// adr-0021-ok: <reason>`.
    func test_noRawMaughamPostsOrSubscriptionsOutsideWrapper() throws {
        let testsDir = repoRoot.appendingPathComponent("MaughamTests", isDirectory: true)
        let offenders = try scanWholeText(
            in: [sourceDir, testsDir],
            patterns: [Self.adr0021PostPattern] + Self.adr0021SubscribePatterns,
            allowed: ["MaughamEvent.swift", "MaughamEvent+Receive.swift",
                      "TripwireGrepTests.swift"])
        XCTAssertTrue(offenders.isEmpty,
            "Raw NotificationCenter post/subscription outside the MaughamEvent "
            + "wrapper (ADR 0021). Post with MaughamEvent.post(_:to:) — every event "
            + "declares its scope — and receive via .onKeyWindowCommand / "
            + ".onDocumentEvent / .onProjectEvent / .onGlobalEvent / "
            + "MaughamEvent.observe. If this is genuinely not a maugham.* event, "
            + "annotate with // adr-0021-ok: <reason> — place the annotation on "
            + "the line where the call STARTS (the `NotificationCenter.default.…(` "
            + "line), not on a split argument line. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the ADR 0021 tripwire FIRES on planted offenders —
    /// a raw post, a LINE-SPLIT publisher(for: .maugham…) subscription, an
    /// addObserver(forName: .maugham…), and a line-split addObserver with an
    /// UNRELATED comment interposed in the gap (the comment must not break the
    /// match) — and that an annotated line and a comment line are exempt,
    /// INCLUDING split calls whose match-start line carries the
    /// `// adr-0021-ok:` annotation (the annotation is itself an interposed
    /// comment; the pattern must match through it so the exemption path — not
    /// regex breakage — is what passes them).
    func test_adr0021TripwireFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-adr0021-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        func bad1() {
            NotificationCenter.default.post(name: .maughamToggleInspector, object: nil)
        }
        var bad2: some View {
            EmptyView().onReceive(NotificationCenter.default.publisher(
                for: .maughamOpenRewind)) { _ in }
        }
        func bad3() {
            _ = NotificationCenter.default.addObserver(forName: .maughamNavigateToScene,
                object: nil, queue: .main) { _ in }
        }
        func bad4() {
            // An interposed UNRELATED comment must not break the match —
            // this unannotated split observer is a real violation and must fire.
            _ = NotificationCenter.default.addObserver( // listen for changes
                forName: .maughamScriptDidUpdate,
                object: nil, queue: .main) { _ in }
        }
        func fine() {
            NotificationCenter.default.post(name: someSystemName, object: nil) // adr-0021-ok: planted exemption
            // comment mentioning NotificationCenter.default.post( is fine
        }
        func fineSplitObserver() {
            _ = NotificationCenter.default.addObserver( // adr-0021-ok: planted split-observer exemption
                forName: .maughamOpenRewind,
                object: nil, queue: .main) { _ in }
        }
        var fineSplitPublisher: some View {
            EmptyView().onReceive(NotificationCenter.default.publisher( // adr-0021-ok: planted split-publisher exemption
                for: .maughamOpenRewind)) { _ in }
        }
        """.write(to: tmp.appendingPathComponent("BadEventUser.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try scanWholeText(
            in: [tmp],
            patterns: [Self.adr0021PostPattern] + Self.adr0021SubscribePatterns,
            allowed: [])
        XCTAssertEqual(offenders.count, 4,
            "Self-check expected the raw post, the line-split publisher, the "
            + "addObserver, and the comment-interposed split addObserver to fire "
            + "(and only those). Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("// listen for changes") },
            "Self-check: the split addObserver with an unrelated interposed comment "
            + "must fire — a comment in the gap must not break the pattern. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertFalse(offenders.contains { $0.contains("adr-0021-ok") },
            "Self-check: annotated split calls must pass via the match-start-line "
            + "exemption, not fire. Got:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - ParagraphID.mint() guard (oplog-growth birthday-collision lesson)

    /// Recurrence-tripper: `ParagraphID.mint()` is 4 random chars over a
    /// ~1.05M space — at manuscript scale collisions are LIKELY, not rare
    /// (the 2026-06-10 paste crash: minting ~650 ids into a ~1,300-paragraph
    /// doc had ≈60% odds of a birthday collision, silently merging two
    /// paragraphs under one identity in the op log). Every production site
    /// that introduces an id into an existing population MUST call
    /// `ParagraphID.mintUnique(excluding:)` instead. Substring match on
    /// `ParagraphID.mint(` does NOT match `ParagraphID.mintUnique(` — the
    /// character after `mint` differs (`(` vs `U`) — so the safe call is
    /// never flagged. `ParagraphID.swift` itself is allowlisted since its
    /// internal `mint()` calls (from `mintUnique`, and the definition of
    /// `mint()` itself) are bare, unqualified, and legitimate.
    static let paragraphIDMintPattern = "ParagraphID.mint("

    func test_noBareParagraphIDMintInProduction() throws {
        let coreDir = repoRoot
            .appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true)
        var offenders = try grepSwift(
            in: sourceDir,
            patterns: [Self.paragraphIDMintPattern])
        offenders += try grepSwift(
            in: coreDir,
            patterns: [Self.paragraphIDMintPattern],
            allowed: ["ParagraphID.swift"])
        XCTAssertTrue(offenders.isEmpty,
            "Bare ParagraphID.mint() call in production. At manuscript scale this is a "
            + "likely birthday collision (oplog-growth milestone, 2026-06-10 paste crash) "
            + "that silently merges two paragraphs under one identity. Use "
            + "ParagraphID.mintUnique(excluding:) instead, seeding `excluding` with the "
            + "existing id population. Offenders:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - The app's own socket is the effective one (2026-09-06)

    /// **`MaughamApp` names `TestHost.mcpSocketPath` and never the variant's
    /// path directly.** The app binds a socket on every launch and unlinks it
    /// twice — once before `bind`, once at `willTerminate` — and the gate runs
    /// seven full copies of the app at a time. Reading
    /// `BuildVariant.current.mcpSocketPath` in this file is therefore not a
    /// style question: it is a gate that deletes the socket file the writer's
    /// own open dev app is listening on, leaving every compiler run afterwards
    /// with `mcp_servers: [{maugham-dev, failed}]` and no red anywhere.
    ///
    /// Scoped to this one file on purpose. `HelpClaudeDesktopSheet` and the
    /// three `*Environment+Project` files legitimately name the variant's path
    /// — they tell an OUTSIDE process (Claude Desktop, the bridge binary the
    /// spawned `claude -p` runs) where the real app listens, which is the
    /// production path whatever this process is.
    static let appSocketOffender = "BuildVariant.current.mcpSocketPath"

    func test_theAppBindsTheEffectiveSocketPathAndNotTheVariantsOwn() throws {
        let offenders = try grepSwift(
            in: sourceDir, files: ["MaughamApp.swift"],
            patterns: [Self.appSocketOffender])
        XCTAssertTrue(offenders.isEmpty,
            "MaughamApp must reach its socket through `TestHost.mcpSocketPath`, which "
            + "hands a test host a per-process path. Binding or unlinking the variant's "
            + "own path from a gate deletes the open dev app's socket. Offenders:\n"
            + offenders.joined(separator: "\n"))

        let text = try String(
            contentsOf: sourceDir.appendingPathComponent("MaughamApp.swift"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("TestHost.mcpSocketPath"),
            "the scan reads a file that still resolves a socket path at all")
        XCTAssertTrue(text.contains("MCPServer("),
            "…and still starts the server this census is about")
    }

    /// Self-check: the census fires on a planted read of the variant's path.
    func test_theAppSocketCensusWouldFireOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-app-socket-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("MaughamApp.swift")
        try """
        struct MaughamApp {
            var mcpSocketPath: String { BuildVariant.current.mcpSocketPath }
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp, files: ["MaughamApp.swift"],
            patterns: [Self.appSocketOffender])
        XCTAssertEqual(offenders.count, 1,
            "Self-check: a planted variant-path read in MaughamApp should be caught. Got:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - ColdCall never bridges (translation pipeline spec §11)

    /// **`ColdCall` is sealed by construction and stays that way.** A sealed
    /// session is handed no `--mcp-config` (Task 1's pin); this census keeps
    /// the ONE production spawner of sealed sessions from ever writing a
    /// bridge config or asking for the bridged confinement — the two ways a
    /// later edit could hand the reader the source it must not see.
    func test_coldCallNeverBridges() throws {
        let file = sourceDir.appendingPathComponent("Compiler/ColdCall.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for forbidden in ["writeMCPConfig", ".bridged(", "--mcp-config", "CompilerAllowlist"] {
            XCTAssertFalse(text.contains(forbidden),
                           "ColdCall.swift must not contain `\(forbidden)` — a cold call is "
                           + "blind by construction, never by allowlist")
        }
        XCTAssertTrue(text.contains("confinement: .sealed"),
                      "the scan reads the file rather than always answering true")
    }

    /// **The converse: `confinement: .sealed` is spelled in production by
    /// `ColdCall` and the session type alone.** A fourth file asking for a
    /// sealed session is a fifth cold caller the spec's four (reader,
    /// collator, gloss, Ask the collator) do not name — it goes through
    /// `ColdCall`, not around it. The pattern is the full spawn-site spelling
    /// (`confinement: .sealed`), not the bare `.sealed` token, so a future
    /// `isSealed`/`segment.sealed` elsewhere in the tree cannot trip this
    /// census with a misleading message.
    func test_theOnlySealedSpawnerIsColdCall() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["confinement: .sealed"],
            allowed: ["ColdCall.swift", "ClaudeCLISession.swift"])
        XCTAssertTrue(offenders.isEmpty,
                      "a sealed session is spawned through ColdCall only. Offenders:\n"
                      + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the sealed-spawner census FIRES on a planted
    /// `confinement: .sealed` outside the allow-list. Without this the
    /// census above had no planted-offender companion, unlike its siblings.
    func test_theSealedSpawnerCensusWouldFireOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-sealed-spawner-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("SecondSealedSpawner.swift")
        try """
        enum SecondSealedSpawner {
            static func spawn() {
                _ = ClaudeCLISession(model: "haiku", confinement: .sealed, preamble: nil)
            }
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: ["confinement: .sealed"],
            allowed: ["ColdCall.swift", "ClaudeCLISession.swift"])
        XCTAssertEqual(offenders.count, 1,
            "Self-check: a planted sealed spawner outside the allow-list should be "
            + "caught. Got:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - The spot-checks mint nothing (translation pipeline P4 Task 6)

    /// **Spec §12's line, as a census.** Gloss and Ask the collator are two
    /// questions the writer asks about one paragraph, and the answer is drawn
    /// and nothing else: what the author does with it — Keep mine, Make it a
    /// rule — is a separate verb they press.
    ///
    /// The distance between "the verbs write, the check does not" and "the
    /// check writes what it found" is one plausible convenience, and nothing in
    /// a type signature refuses it: `SpotCheck` is handed the `ProjectStore` and
    /// the `DocumentStore` it needs to BRIEF a call, which are the same two
    /// objects a mint would be written through. So the file is scanned for the
    /// four doors instead. `coldCall.call(` proves the scan reads a file that
    /// still asks a question at all.
    /// The four write doors, plus the bridge spelling `ColdCall` is already
    /// forbidden. One list, read by the census and by its planted-offender
    /// companion, so adding a door here arms both.
    static let spotCheckWriteDoors = [
        "RulingPerformer", "addAnnotation", "TranslationRoundStore",
        "writeMCPConfig", ".bridged(",
    ]

    /// The census itself, over whatever directory it is handed — which is what
    /// lets the companion below plant an offender and run the REAL scan on it
    /// rather than a copy of it.
    private func spotCheckMintOffenders(in dir: URL) throws -> [String] {
        try grepSwift(in: dir, files: ["SpotCheck.swift"],
                      patterns: Self.spotCheckWriteDoors)
    }

    func test_aSpotCheckMintsNothing() throws {
        let offenders = try spotCheckMintOffenders(in: sourceDir)
        XCTAssertTrue(offenders.isEmpty,
                      "a spot-check answers a question; the author's own verb is what "
                      + "writes. Offenders:\n" + offenders.joined(separator: "\n"))

        let file = sourceDir.appendingPathComponent("Compiler/SpotCheck.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("coldCall.call("),
                      "the scan reads the file rather than always answering true")
    }

    /// Self-check: prove the mint census FIRES on a planted door — through the
    /// same function, so a door added to `spotCheckWriteDoors` cannot leave this
    /// companion green over a list it no longer shares.
    func test_theSpotCheckCensusWouldFireOnAPlantedMint() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-spot-check-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        @MainActor
        enum SpotCheck {
            static func gloss() async {
                try? await RulingPerformer.rule("it drifted", provenance: "spot-check")
            }
        }
        """.write(to: tmp.appendingPathComponent("SpotCheck.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try spotCheckMintOffenders(in: tmp)
        XCTAssertEqual(offenders.count, 1,
            "Self-check: a planted mint should be caught. Got:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - EditorSurface mount census (M1A: two editors in one window)

    /// Every production site that mounts an `EditorSurface`. Adding one is the
    /// moment to answer a question that has no default answer:
    /// **can this surface be on screen at the same time as another editor?**
    ///
    /// It went unasked once and cost two defects at once (see
    /// `Maugham/Editor/AREA.md`, "Two editors in one window"): the second editor
    /// shared the window's `UndoManager`, so taking it down wiped the
    /// manuscript's ⌘Z history, and both coordinators answered the window's
    /// key-window commands, so the pane flipped into review chrome on ⌘⌥R.
    /// `EditorSurfaceConfiguration.isSecondEditorInItsWindow` is the answer, and
    /// its default is the safe-for-today one rather than the safe-in-general
    /// one — which is exactly why a warning in a doc comment would not hold.
    ///
    /// A CENSUS, not an allow/deny grep: `EditorSurface(` is not a forbidden
    /// token, so only an exact expected set can fail on a fourth.
    static let editorSurfaceMountSites: Set<String> = [
        // The manuscript editor. Primary in its window.
        "EditorHost.swift",
        // A research note in the centre column. Primary in its window — it
        // replaces the manuscript editor rather than sitting beside it.
        "ResearchNoteEditor.swift",
        // M1A's Intent / Visual Language panes, in the right column. The only
        // one that is a SECOND editor, and the only one setting the flag.
        "StatementEditorHost.swift",
    ]

    func test_everyEditorSurfaceMountIsAccountedFor() throws {
        let sites = try grepSwift(
            in: sourceDir,
            patterns: ["EditorSurface("],
            excludeLine: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
            })
        let files = Set(sites.map { String($0.prefix(while: { $0 != ":" })) })
        XCTAssertEqual(files, Self.editorSurfaceMountSites,
            "The set of files mounting an EditorSurface has changed. A NEW one must "
            + "answer: can it be on screen at the same time as another editor? If so "
            + "it is a second editor and must set "
            + "`isSecondEditorInItsWindow: true` — otherwise taking it down wipes the "
            + "manuscript's undo stack and it answers ⌘⌥R. Then add it above with "
            + "which it is. Found:\n" + sites.joined(separator: "\n"))
    }

    /// Self-check: the census fires on a planted fourth mount. Without this the
    /// test could be reading nothing and reporting an empty set that happens to
    /// have been written down as empty.
    func test_theEditorSurfaceCensusFiresOnAPlantedFourthMount() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-editorsurface-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct SomeNewPane: View {
            var body: some View {
                EditorSurface(text: $text, configuration: config)
            }
        }
        """.write(to: tmp.appendingPathComponent("SomeNewPane.swift"),
                  atomically: true, encoding: .utf8)
        try """
        /// A doc comment naming EditorSurface( is not a mount.
        struct Innocent: View { var body: some View { Text("hi") } }
        """.write(to: tmp.appendingPathComponent("Innocent.swift"),
                  atomically: true, encoding: .utf8)

        let sites = try grepSwift(
            in: tmp,
            patterns: ["EditorSurface("],
            excludeLine: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
            })
        let files = Set(sites.map { String($0.prefix(while: { $0 != ":" })) })
        XCTAssertEqual(files, ["SomeNewPane.swift"],
            "Self-check: the census must see the planted mount and must NOT count "
            + "the doc comment. Found: \(sites)")
        XCTAssertNotEqual(files, Self.editorSurfaceMountSites,
            "Self-check expected the planted set to disagree with the real one.")
    }

    // MARK: - Test windows are presented by the fixture only

    /// The tokens by which a test presents a window on its own. The first
    /// three are construction tokens — every `NSWindow`/`NSPanel` designated
    /// initialiser (and every subclass's) has to pass `backing:` and `defer:`,
    /// whatever the class is called, so a new file-private subclass can't slip
    /// past a class-name grep. (`backing:` alone is too broad: the canvas
    /// raster helpers take a `backing: NSColor?`.) The three ordering calls
    /// are the presentation tokens.
    static let windowPresentationTokens = [
        "backing: .buffered", "defer: false)", "defer: true)",
        "orderFront(", "makeKeyAndOrderFront(", "orderFrontRegardless",
    ]

    private static func isWindowPresentationProse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
    }

    /// Recurrence-tripper: fifty-six test files each built and ordered front
    /// their own visible window at the screen's origin, and across seven
    /// parallel workers that made every gate paint over the developer's
    /// screen (2026-08-27). `TestWindow` (MaughamTests/TestSupport) is the one
    /// place a window is constructed and presented — hidden, mouse-ignoring,
    /// out of Mission Control — and this guard is what keeps a fifty-seventh
    /// hand-rolled mount from reopening it.
    func test_noWindowIsPresentedOutsideTheTestWindowFixture() throws {
        let testsDir = repoRoot.appendingPathComponent("MaughamTests", isDirectory: true)
        let offenders = try grepSwift(
            in: testsDir,
            patterns: Self.windowPresentationTokens,
            allowed: ["TestWindow.swift", "TripwireGrepTests.swift"],
            excludeLine: Self.isWindowPresentationProse)
        XCTAssertTrue(offenders.isEmpty,
            "A test constructs or presents an NSWindow on its own. Every test "
            + "window goes through `TestWindow.make`/`.mount` (hidden, mouse-"
            + "ignoring, out of Mission Control) so a gate never paints over the "
            + "developer's screen; pass your window subclass as `type` if the "
            + "suite needs one. A window that must be built by hand is presented "
            + "with `TestWindow.present`, and its construction is accounted for "
            + "in this test's allow-list. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: the guard fires on a planted construction, a planted
    /// `orderFront`, and a planted subclass with a name no grep would know —
    /// and stays quiet on prose.
    func test_theTestWindowGuardFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-testwindow-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        final class SomeSuite: XCTestCase {
            private final class QuietWindow: NSWindow {}
            func test_x() {
                let w = QuietWindow(contentRect: .zero, styleMask: [.titled],
                                    backing: .buffered, defer: false)
                w.orderFront(nil)
            }
        }
        """.write(to: tmp.appendingPathComponent("SomeSuite.swift"),
                  atomically: true, encoding: .utf8)
        try """
        /// Prose naming makeKeyAndOrderFront( and backing: is not a mount.
        final class Innocent: XCTestCase {
            func test_y() { let w = TestWindow.make(contentRect: .zero); w.orderOut(nil) }
        }
        """.write(to: tmp.appendingPathComponent("Innocent.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: Self.windowPresentationTokens,
            excludeLine: Self.isWindowPresentationProse)
        let files = Set(offenders.map { String($0.prefix(while: { $0 != ":" })) })
        XCTAssertEqual(files, ["SomeSuite.swift"],
            "Self-check: the guard must see the planted construction and "
            + "orderFront, and must not count the doc comment or the fixture "
            + "call. Found: \(offenders)")
        XCTAssertEqual(offenders.count, 2,
            "Self-check: one construction line and one orderFront line. Found: \(offenders)")
    }

    // MARK: - applyExternalText call-site census (tripwire 7)

    /// A line is exempt when it's the function's own definition (`func
    /// applyExternalText(`, in EditorCoordinator.swift) or a comment —
    /// tripwire 7's whole point is that a call site outside the one
    /// sanctioned caller (EditorSurface.swift's `updateNSView`, the
    /// cloud-conflict resolution path) is a binding race; prose that merely
    /// discusses `applyExternalText` (and there is a lot of it — tripwires
    /// 2/3/6/7 are cross-referenced throughout Editor/) is not a call.
    private func isApplyExternalTextNonCallLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { return true }
        if trimmed.contains("func applyExternalText(") { return true }
        return false
    }

    /// Recurrence-tripper: `EditorCoordinator.applyExternalText` exists ONLY
    /// for cloud-conflict resolution (CLAUDE.md tripwire 7); a second
    /// production call site is a binding race of the same shape that drove
    /// three cursor races in the `EditorHost` triad (tripwire 6). Unlike the
    /// other tripwires here, this is a CENSUS, not an allow/deny grep — the
    /// one legitimate call (EditorSurface.swift's `updateNSView`) must be
    /// present exactly once, and adding a second must fail even though
    /// `applyExternalText(` isn't a forbidden token in isolation.
    func test_applyExternalTextHasExactlyOneProductionCallSite() throws {
        let callSites = try grepSwift(
            in: sourceDir,
            patterns: ["applyExternalText("],
            excludeLine: { [self] in isApplyExternalTextNonCallLine($0) }
        )
        XCTAssertEqual(callSites.count, 1,
            "Expected exactly ONE production call site of applyExternalText( — "
            + "EditorSurface.swift's updateNSView (the sanctioned cloud-conflict "
            + "resolution path, tripwire 7). A second call site is a binding race "
            + "(tripwire 6/7 class of bug, EditorHost.swift AREA.md). Found:\n"
            + callSites.joined(separator: "\n"))
        XCTAssertTrue(callSites.first?.contains("EditorSurface.swift") == true,
            "The one call site should be in EditorSurface.swift. Got:\n"
            + callSites.joined(separator: "\n"))
    }

    /// Self-check: prove the census FIRES when a second call site is planted
    /// (the real defect this test guards against — an allow/deny grep for a
    /// forbidden token wouldn't catch a second occurrence of a REQUIRED one).
    func test_applyExternalTextCensusFiresOnPlantedSecondCallSite() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-applyexternaltext-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        /// Doc-comment mentioning applyExternalText( is not a call.
        func applyExternalText(_ text: String, preserveUndoStack: Bool = false) {
            // definition — excluded
        }
        """.write(to: tmp.appendingPathComponent("EditorCoordinator.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct EditorSurface {
            func updateNSView() {
                context.coordinator.applyExternalText(text, preserveUndoStack: true)
            }
        }
        """.write(to: tmp.appendingPathComponent("EditorSurface.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct RewindSheet {
            func apply() {
                // A second, forbidden call site — planted offender.
                coordinator.applyExternalText(restored, preserveUndoStack: false)
            }
        }
        """.write(to: tmp.appendingPathComponent("RewindSheet.swift"),
                  atomically: true, encoding: .utf8)

        let callSites = try grepSwift(
            in: tmp,
            patterns: ["applyExternalText("],
            excludeLine: { [self] in isApplyExternalTextNonCallLine($0) }
        )
        XCTAssertEqual(callSites.count, 2,
            "Self-check expected two call sites (EditorSurface + planted RewindSheet) "
            + "with the definition and doc-comment excluded. Got:\n"
            + callSites.joined(separator: "\n"))
        XCTAssertTrue(callSites.contains { $0.contains("RewindSheet.swift") },
            "Self-check: the planted second call site in RewindSheet.swift should fire.")
    }

    // MARK: - ContentUnavailableView frame guard (tripwire 15)

    /// A runaway stop for the span walk below — no real call site is anywhere
    /// near this long, and a malformed file must not make the scan walk a
    /// whole file looking for a frame chain that would then satisfy the guard
    /// from somewhere else entirely.
    private static let contentUnavailableViewSpanLimit = 60

    /// Recurrence-tripper: every `ContentUnavailableView` in `Maugham/` must
    /// chain `.frame(maxWidth: .infinity` onto ITSELF. Canonical examples:
    /// HistoryPane, AnnotationsPane, ProjectAltitudePane (CLAUDE.md tripwire 15).
    ///
    /// **This census used to be two-thirds blind, and M3 P1 Task 7 is what
    /// found it** (2026-08-15). It matched the literal `"ContentUnavailableView("`
    /// only, so the trailing-closure form —
    /// `ContentUnavailableView { Label(…) } description: { Text(…) }`, which is
    /// what `ProjectAltitudePane`, `ResearchNoteEditor`, `CollectionPiecesPane`
    /// and the new `ReviewBoardPane` all use — was never inspected at all; and
    /// even had it matched, that form's frame chain lands FIVE lines after the
    /// opener, outside the fixed 4-line lookahead the scan used. Three of the
    /// panes CLAUDE.md names as canonical examples of tripwire 15 were being
    /// guarded by nothing, and a tidy-up dropping their frame chain would have
    /// shipped green — which is the same failure the 1C-c1 directory widening
    /// (below) was written to end. A vacuous census is no guard.
    ///
    /// The fix is in two parts, and both matter: the opener is recognised in
    /// BOTH syntactic forms, and the lookahead is no longer a line count. The
    /// scan now walks the construct to the end of its own modifier chain
    /// (`contentUnavailableViewSpan`), so a call site is measured by its
    /// SHAPE rather than by how many lines its arguments happen to take —
    /// there is no length at which a pane silently stops being checked.
    func test_contentUnavailableViewAlwaysChainsFullFrame() throws {
        // **`Maugham/`, not `Maugham/Views`.** 1C-c1's docs sweep found the scan
        // pointed at one directory while the panes it protects had spread out of
        // it: both canvas inspector panes live in `Maugham/Canvas/`, so the
        // full-frame chain was correct there and enforced nowhere. A tidy-up
        // dropping it would have shipped green, and this is a bug that has
        // recurred four or more times. Any new pane anywhere under the app target
        // is now covered by default, which is the point — a rule that only holds
        // in the directory it was written in is a rule about a directory.
        let appDir = repoRoot.appendingPathComponent("Maugham", isDirectory: true)

        // **Non-vacuity, by name rather than by count.** The reason this census
        // sat blind for milestones is that a scan finding nothing and a scan
        // looking at nothing read identically from the outside. These four
        // panes use the trailing-closure form, so ALL FOUR were invisible to
        // the old scan; if a future edit narrows the opener again, this fails
        // before the emptiness of `offenders` can be mistaken for safety.
        let inspected = try Self.contentUnavailableViewSites(in: appDir)
        for pane in ["Maugham/Views/ProjectAltitudePane.swift",
                     "Maugham/Views/Review/ReviewBoardPane.swift",
                     "Maugham/Views/ResearchNoteEditor.swift",
                     "Maugham/Views/CollectionPiecesPane.swift"] {
            XCTAssertTrue(inspected.contains { $0.path == pane },
                "\(pane) holds a trailing-closure ContentUnavailableView that "
                + "this census did not even look at. Inspected: "
                + "\(Set(inspected.map(\.path)).sorted().joined(separator: ", "))")
        }

        let offenders = inspected.filter { !$0.hasFrame }.map(\.description)
        XCTAssertTrue(offenders.isEmpty,
            "a ContentUnavailableView (either syntactic form) with no "
            + ".frame(maxWidth: .infinity anywhere in its own modifier chain "
            + "(tripwire 15). "
            + "SwiftUI sizes ContentUnavailableView to intrinsic content, so an "
            + "unframed one lets the enclosing pane's toolbar float to window "
            + "center — this has recurred 4+ times. Canonical examples: "
            + "HistoryPane, AnnotationsPane, ProjectAltitudePane. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Shared scan: walk every `.swift` file in `dir`, and for each
    /// `ContentUnavailableView` opener — `(` for the argument form, `{` for
    /// the trailing-closure form — look for the required frame chain anywhere
    /// in that construct's OWN span (`contentUnavailableViewSpan`). SHARED
    /// between the production check and the self-tests.
    ///
    /// **Offenders are reported by PATH, not by basename.** Over the 103 files
    /// of one directory a basename was unambiguous; over the 338 of the whole
    /// app target — `Views/`, `Canvas/`, `Editor/`, `Stores/`, `MCP/`,
    /// `Publish/` — two panes can share a name and the message would not say
    /// which one to open. The path is taken relative to `dir`'s PARENT, so the
    /// production scan reports `Maugham/Canvas/RegionInspector.swift` and the
    /// self-check's temporary directory still reads sensibly; anything that
    /// does not sit under that base falls back to the basename rather than
    /// printing an absolute path from someone else's machine.
    static func findFramelessContentUnavailableViews(in dir: URL) throws -> [String] {
        try contentUnavailableViewSites(in: dir).filter { !$0.hasFrame }.map(\.description)
    }

    /// One inspected call site. Carries `hasFrame` rather than only the
    /// offenders, so the production test can assert the census LOOKED at the
    /// panes it is supposed to protect — the assertion that would have caught
    /// this guard's blindness years earlier than Task 7 did.
    struct ContentUnavailableViewSite {
        let path: String
        let line: Int
        let text: String
        let hasFrame: Bool

        var description: String { "\(path):\(line): \(text)" }
    }

    static func contentUnavailableViewSites(in dir: URL) throws -> [ContentUnavailableViewSite] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        // Resolved on BOTH sides, or the prefix match is defeated by a symlink
        // in the path — `/var` against the enumerator's `/private/var` is the
        // one this test hit, and a repo checked out under a symlinked home is
        // the same shape in production. Without it the fallback silently hands
        // back basenames, which is the thing this is here to stop.
        let base = dir.deletingLastPathComponent().resolvingSymlinksInPath().path
        var sites: [ContentUnavailableViewSite] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            for (i, line) in lines.enumerated() where opensContentUnavailableView(line) {
                let span = contentUnavailableViewSpan(from: i, in: lines)
                // Comment lines don't count — a comment merely DISCUSSING the
                // frame chain (e.g. explaining why one is missing) must not
                // satisfy the requirement. Caught in dev: an early self-check
                // fixture's own explanatory comment contained the frame
                // substring and silently passed a frameless CUV.
                let hasFrame = lines[span].contains {
                    let trimmed = $0.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") else { return false }
                    return trimmed.contains(".frame(maxWidth: .infinity")
                }
                let resolved = url.resolvingSymlinksInPath().path
                let shown = resolved.hasPrefix(base + "/")
                    ? String(resolved.dropFirst(base.count + 1))
                    : url.lastPathComponent
                sites.append(ContentUnavailableViewSite(
                    path: shown, line: i + 1,
                    text: line.trimmingCharacters(in: .whitespaces),
                    hasFrame: hasFrame))
            }
        }
        return sites
    }

    /// **Both syntactic forms open a `ContentUnavailableView`**: the argument
    /// form `ContentUnavailableView("…", systemImage: …)` and the
    /// trailing-closure form `ContentUnavailableView { Label(…) } description:
    /// { … }`. Recognised by the first non-space character after the type name,
    /// so `ContentUnavailableView{` and a line break before the brace are the
    /// same opener — and a mere MENTION of the type (this file is full of them,
    /// and so is `CollectionPiecesPane`'s doc comment) is not an opener at all.
    static func opensContentUnavailableView(_ line: String) -> Bool {
        var searchStart = line.startIndex
        while let hit = line.range(of: "ContentUnavailableView", range: searchStart..<line.endIndex) {
            let rest = line[hit.upperBound...].drop { $0 == " " }
            if rest.first == "(" || rest.first == "{" { return true }
            searchStart = hit.upperBound
        }
        return false
    }

    /// **The lines the construct opening at `start` actually occupies** — its
    /// arguments and trailing closures, plus every modifier chained onto it.
    ///
    /// This replaces the fixed 4-line lookahead the scan used until 2026-08-15,
    /// and the difference is not a tuning: a line count silently stops checking
    /// a call site as soon as its arguments grow, which is exactly how the
    /// trailing-closure form (frame chain at distance 5) would have gone
    /// unguarded even once the opener was matched. A span asks the question of
    /// the whole construct however long it is.
    ///
    /// Bracket depth is counted with string literals removed, because a title
    /// like `"Nothing here (yet)"` would otherwise leave the walk permanently
    /// unbalanced. The walk stops when depth returns to zero AND the next line
    /// of code does not continue the chain with a leading `.` — so a SIBLING
    /// view's `.frame(maxWidth: .infinity` can never satisfy a frameless pane
    /// above it (`test_theGuardReadsTheTrailingClosureFormToo` plants exactly
    /// that).
    static func contentUnavailableViewSpan(from start: Int, in lines: [String]) -> ClosedRange<Int> {
        let limit = min(lines.count - 1, start + contentUnavailableViewSpanLimit)
        var depth = 0
        var opened = false
        var end = start
        var j = start

        while j <= limit {
            for character in strippingStringLiterals(lines[j]) {
                switch character {
                case "(", "{", "[": depth += 1; opened = true
                case ")", "}", "]": depth -= 1
                default: break
                }
            }
            end = j

            if opened && depth <= 0 {
                guard let next = nextCodeLine(after: j, in: lines, limit: limit),
                      lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(".")
                else { break }
                j = next          // the chained modifier is part of this construct
                continue
            }
            j += 1
        }
        return start...end
    }

    /// The next line that is neither blank nor a whole-line comment, or nil.
    private static func nextCodeLine(after index: Int, in lines: [String],
                                     limit: Int) -> Int? {
        var k = index + 1
        while k <= limit {
            let trimmed = lines[k].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("//") { return k }
            k += 1
        }
        return nil
    }

    /// `line` with the contents of its string literals removed, so brackets
    /// inside a title or a description cannot unbalance the depth walk. An
    /// escaped quote (`\"`) does not close a literal.
    private static func strippingStringLiterals(_ line: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for character in line {
            if inString {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            out.append(character)
        }
        return out
    }

    /// **An offender names its PATH, so two panes sharing a basename are
    /// distinguishable.** Over one directory the basename was enough; the scan
    /// now covers the whole app target — `Views/`, `Canvas/`, `Editor/`,
    /// `Stores/`, `MCP/`, `Publish/` — where a repeated name is ordinary, and a
    /// failure message naming `Inspector.swift` twice tells the reader nothing
    /// about which file to open.
    ///
    /// Two frameless panes with the SAME file name in different subdirectories
    /// is the fixture, because that is the only shape that can fail: under
    /// `lastPathComponent` both offenders render as one identical string, so the
    /// set below collapses to a single element.
    func test_aFramelessPaneIsReportedByPathSoTwoOfTheSameNameAreDistinguishable() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-cuv-path-selfcheck-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        let frameless = """
        struct Pane: View {
            var body: some View {
                ContentUnavailableView("Nothing here", systemImage: "tray")
            }
        }
        """
        for area in ["Views", "Canvas"] {
            let dir = tmp.appendingPathComponent(area, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try frameless.write(to: dir.appendingPathComponent("Inspector.swift"),
                                atomically: true, encoding: .utf8)
        }

        let offenders = try Self.findFramelessContentUnavailableViews(in: tmp)
        XCTAssertEqual(offenders.count, 2,
            "control: both planted panes must be caught, or the distinctness "
            + "assertion below is about one string. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertEqual(Set(offenders).count, 2,
            "two frameless panes in different directories report as the SAME "
            + "string, so the message cannot say which file to open — the scan "
            + "now covers 338 files across six directories, where a repeated "
            + "basename is ordinary. Got:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.hasPrefix("\(tmp.lastPathComponent)/Canvas/") },
            "the path is reported relative to the scanned root's PARENT, so a "
            + "production offender reads Maugham/Canvas/RegionInspector.swift "
            + "rather than an absolute path from someone else's machine. Got:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the frame guard FIRES on a planted frameless
    /// `ContentUnavailableView` and does NOT fire on one whose frame chain
    /// sits at the edge of the window (distance 4, matching real call sites
    /// like DetailPaneToggle.swift).
    func test_contentUnavailableViewFrameGuardFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-cuv-frame-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct GoodPane: View {
            var body: some View {
                ContentUnavailableView(
                    "No items",
                    systemImage: "tray",
                    description: Text("Nothing here yet."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        struct BadPane: View {
            var body: some View {
                ContentUnavailableView("Nothing here", systemImage: "tray")
                // No full-frame modifier anywhere nearby — the toolbar
                // will float to window center (tripwire 15).
            }
        }
        struct CommentTrapPane: View {
            var body: some View {
                ContentUnavailableView("Comment trap", systemImage: "tray")
                // Merely MENTIONING .frame(maxWidth: .infinity in a comment
                // must not satisfy the guard — this pane is still frameless.
            }
        }
        """.write(to: tmp.appendingPathComponent("SelfCheckPane.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try Self.findFramelessContentUnavailableViews(in: tmp)
        XCTAssertEqual(offenders.count, 2,
            "Self-check expected the frameless BadPane and CommentTrapPane to "
            + "fire — the latter proves a comment merely containing the frame "
            + "substring doesn't satisfy the guard. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("Nothing here") },
            "Self-check: the planted frameless BadPane offender should be caught.")
        XCTAssertTrue(offenders.contains { $0.contains("Comment trap") },
            "Self-check: the planted CommentTrapPane offender should be caught "
            + "even though a nearby COMMENT contains the frame substring.")
    }

    /// **The trailing-closure form is a `ContentUnavailableView` too** — the
    /// hole this census carried until 2026-08-15, and the reason it is worth a
    /// test of its own rather than three more panes in the fixture above.
    ///
    /// `ContentUnavailableView { Label(…) } description: { Text(…) }` is the
    /// form `ProjectAltitudePane`, `ResearchNoteEditor`, `CollectionPiecesPane`
    /// and `ReviewBoardPane` all use, and the old scan matched neither its
    /// opener (`ContentUnavailableView(` with a paren) nor, had it matched, its
    /// frame chain — which lands FIVE lines down, past the fixed lookahead.
    /// Three panes CLAUDE.md names as canonical examples of tripwire 15 were
    /// guarded by nothing at all.
    ///
    /// Three fixtures, in three files so the offenders are distinguishable by
    /// path (their opener lines are byte-identical):
    /// - the compliant brace form, which must NOT fire — the assertion that the
    ///   span really does reach a frame chain further down than any line count;
    /// - the frameless brace form, which must fire;
    /// - **a frameless brace form whose SIBLING carries the frame chain**, which
    ///   must fire too. This is the control on the widening itself: a span that
    ///   ran past the construct's own modifiers would find the neighbour's
    ///   `.frame(maxWidth: .infinity` and call an unframed pane compliant, which
    ///   is a worse census than the blind one it replaced.
    func test_theGuardReadsTheTrailingClosureFormToo() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-cuv-brace-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let good = """
        struct GoodTrailingClosurePane: View {
            var body: some View {
                ContentUnavailableView {
                    Label("Nothing to review yet", systemImage: "checklist")
                } description: {
                    Text("Add chapters and their passes appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        """
        try good.write(to: tmp.appendingPathComponent("GoodTrailingClosure.swift"),
                       atomically: true, encoding: .utf8)

        try """
        struct BadTrailingClosurePane: View {
            var body: some View {
                ContentUnavailableView {
                    Label("Nothing here", systemImage: "tray")
                } description: {
                    Text("And no frame chain anywhere on it.")
                }
            }
        }
        """.write(to: tmp.appendingPathComponent("BadTrailingClosure.swift"),
                  atomically: true, encoding: .utf8)

        try """
        struct SiblingFramePane: View {
            var body: some View {
                VStack {
                    ContentUnavailableView {
                        Label("Still frameless", systemImage: "tray")
                    } description: {
                        Text("The frame below belongs to the sibling.")
                    }
                    Text("A neighbour")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        """.write(to: tmp.appendingPathComponent("SiblingFrame.swift"),
                  atomically: true, encoding: .utf8)

        // The premise, stated as an assertion: the compliant fixture's frame
        // chain is further from its opener than the old 4-line lookahead
        // reached, so this test would have been green over a broken guard.
        let goodLines = good.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let openerAt = try XCTUnwrap(goodLines.firstIndex { Self.opensContentUnavailableView($0) })
        let frameAt = try XCTUnwrap(goodLines.firstIndex { $0.contains(".frame(maxWidth: .infinity") })
        XCTAssertGreaterThan(frameAt - openerAt, 4,
            "premise: the trailing-closure form's frame chain must sit outside "
            + "the old fixed lookahead, or this fixture is not the shape that "
            + "was going unchecked")

        let offenders = try Self.findFramelessContentUnavailableViews(in: tmp)
        XCTAssertEqual(offenders.count, 2,
            "expected exactly the two frameless brace-form panes. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("BadTrailingClosure.swift") },
            "the frameless trailing-closure form must fire — this is the form "
            + "the census could not see at all until 2026-08-15. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("SiblingFrame.swift") },
            "a frameless pane whose SIBLING carries the frame chain must still "
            + "fire, or the span runs past the construct's own modifiers and "
            + "the widening has made the census weaker. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertFalse(offenders.contains { $0.contains("GoodTrailingClosure.swift") },
            "the compliant trailing-closure form was reported as an offender — "
            + "the span stops before the frame chain it actually has. Got:\n"
            + offenders.joined(separator: "\n"))
    }

    /// The opener recogniser, on its own: both forms open one, and a mere
    /// MENTION of the type does not. Prose about `ContentUnavailableView` is
    /// ordinary in this codebase (`CollectionPiecesPane`'s doc comment, the
    /// `InboxPane` tripwire note, and this very file), and an opener test that
    /// fired on the word would put every one of them in the offender list.
    func test_theOpenerRecogniserReadsBothFormsAndNoMereMention() {
        XCTAssertTrue(Self.opensContentUnavailableView(
            #"ContentUnavailableView("No items", systemImage: "tray")"#))
        XCTAssertTrue(Self.opensContentUnavailableView("            ContentUnavailableView {"))
        XCTAssertTrue(Self.opensContentUnavailableView("ContentUnavailableView{"))
        XCTAssertTrue(Self.opensContentUnavailableView("ContentUnavailableView ("),
                      "a space before the paren is still an opener")
        XCTAssertFalse(Self.opensContentUnavailableView(
            "/// measured here, because `ContentUnavailableView` is a system view"),
            "a mention in prose is not a call site")
        XCTAssertFalse(Self.opensContentUnavailableView(
            "        // Tripwire #15: empty-state panes need BOTH the inner ContentUnavailableView"))
    }

    // MARK: - Paragraph-id literal alphabet lint (tripwire 8)

    /// The `ParagraphID` alphabet (CLAUDE.md tripwire 8): digits + lowercase
    /// letters minus the visually-ambiguous `i`/`l`/`o`/`u`.
    /// `ParagraphID.parseComment` rejects any id outside this set at
    /// Bootstrap/RenderFilter time; a permissive in-memory test literal
    /// hides the mismatch until then. Case-sensitive by construction — the
    /// alphabet contains no uppercase members, so an uppercase id (even one
    /// using only otherwise-valid letters, e.g. `"ABCD"`) is correctly a
    /// violation, not merely a normalization nit.
    static let paragraphIdAlphabet = Set("0123456789abcdefghjkmnpqrstvwxyz")

    /// Matches a 4-char id token immediately after a `¶` anchor marker,
    /// bounded on both sides so it can't be fooled: `(?![0-9A-Za-z])`
    /// prevents truncating a legitimate 5-char id fixture (e.g.
    /// `¶abcde` elsewhere in the suite) into a false 4-char hit, and
    /// requiring the match to start right at `¶` means a 2-char placeholder
    /// like `¶id` never matches at all (both by design — the task scope is
    /// 4-char literals specifically).
    static let paragraphIdAnchorTokenPattern = "¶([0-9A-Za-z]{4})(?![0-9A-Za-z])"

    /// Matches a raw `ParagraphID("xxxx")` 4-char construction literal. No
    /// production call site exists today — `ParagraphID` is a static-function
    /// namespace (`Packages/MaughamCore/Sources/MaughamCore/ParagraphID.swift`),
    /// not a constructible type — so this guards the SHAPE against a future
    /// refactor that adds one; exercised by the self-check below.
    static let paragraphIdConstructorTokenPattern = "ParagraphID\\(\"([0-9A-Za-z]{4})\"\\)"

    /// Matches a `paragraphId: "xxxx"` keyword-argument literal — the shape
    /// used to construct `Op` values directly in tests (158 occurrences
    /// across the suite as of the 2026-07-11 audit; all 22 distinct values
    /// were clean, but the shape itself crosses the `.md` ↔ op-log boundary
    /// exactly like the other two, and wasn't covered until this pass). The
    /// quote marks bound the match exactly, so a 3- or 5-char value simply
    /// doesn't match (no lookahead needed, unlike the anchor pattern).
    static let paragraphIdKeywordArgTokenPattern = "paragraphId:\\s*\"([0-9A-Za-z]{4})\""

    /// A line is exempt when it's a comment (doc-comments illustrating the
    /// anchor FORMAT with an uppercase `¶XXXX` placeholder — e.g.
    /// ProjectASTBuilderTests.swift's "carry `<!-- ¶XXXX -->` anchors" prose —
    /// aren't literal ids), or when it deliberately tests REJECTION of a
    /// malformed id. `ParagraphIDTests.test_parseComment_rejectsMalformed`
    /// feeds `¶ABCD` (uppercase — outside the alphabet by construction) into
    /// `XCTAssertNil` specifically to prove the parser rejects it; that's the
    /// tripwire 8 contract being exercised, not violated.
    static func isAllowedParagraphIdLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { return true }
        if trimmed.contains("XCTAssertNil") { return true }
        return false
    }

    /// Scan every `.swift` file under `dirs` for 4-char paragraph-id literals
    /// matching any of the three token patterns, and report every one whose
    /// characters aren't a subset of `paragraphIdAlphabet`. SHARED between
    /// the production check and the self-test. `allowed` skips files by
    /// `lastPathComponent` — the production call excludes
    /// `TripwireGrepTests.swift` itself (ADR-0021-tripwire precedent): its
    /// self-check test embeds a planted bad-alphabet literal as literal
    /// source text, which would otherwise self-match this very scan.
    static func scanParagraphIdAlphabetViolations(
        in dirs: [URL], allowed: Set<String> = []
    ) throws -> [String] {
        let regexes = try [
            paragraphIdAnchorTokenPattern,
            paragraphIdConstructorTokenPattern,
            paragraphIdKeywordArgTokenPattern,
        ].map { try NSRegularExpression(pattern: $0) }
        var offenders: [String] = []
        for dir in dirs {
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if allowed.contains(url.lastPathComponent) { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let lineStr = String(line)
                    if isAllowedParagraphIdLine(lineStr) { continue }
                    let ns = lineStr as NSString
                    for regex in regexes {
                        regex.enumerateMatches(
                            in: lineStr, range: NSRange(location: 0, length: ns.length)
                        ) { match, _, _ in
                            guard let match, match.numberOfRanges > 1 else { return }
                            let token = ns.substring(with: match.range(at: 1))
                            if !Set(token).isSubset(of: paragraphIdAlphabet) {
                                offenders.append(
                                    "\(url.lastPathComponent):\(i + 1): [\(token)] "
                                    + lineStr.trimmingCharacters(in: .whitespaces))
                            }
                        }
                    }
                }
            }
        }
        return offenders
    }

    /// Recurrence-tripper: a 4-char paragraph-id literal in a test file that
    /// isn't drawn from `ParagraphID`'s alphabet is a latent Bootstrap/
    /// RenderFilter rejection waiting to happen the moment that test crosses
    /// the `.md` ↔ op-log boundary for real (CLAUDE.md tripwire 8). Scans all
    /// three test targets — MaughamTests, MaughamPhoneTests,
    /// Packages/MaughamCore/Tests — for all three literal shapes: `¶xxxx`
    /// anchor comments, `ParagraphID("xxxx")` constructions, and
    /// `paragraphId: "xxxx"` `Op`-construction keyword arguments.
    func test_paragraphIdLiteralsInTestsUseValidAlphabet() throws {
        let dirs = [
            repoRoot.appendingPathComponent("MaughamTests", isDirectory: true),
            repoRoot.appendingPathComponent("MaughamPhoneTests", isDirectory: true),
            repoRoot.appendingPathComponent("Packages/MaughamCore/Tests", isDirectory: true),
        ]
        let offenders = try Self.scanParagraphIdAlphabetViolations(
            in: dirs, allowed: ["TripwireGrepTests.swift"])
        XCTAssertTrue(offenders.isEmpty,
            "4-char paragraph-id literal outside ParagraphID's alphabet "
            + "([0-9a-hjkmnp-tv-z]) found in a test target (tripwire 8). Use "
            + "ParagraphID.mint() or a literal drawn from that alphabet — "
            + "ParagraphID.parseComment rejects anything else at "
            + "Bootstrap/RenderFilter time. If this is deliberately testing "
            + "REJECTION of a malformed id, the containing assertion should be "
            + "an XCTAssertNil (exempted). Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the alphabet lint FIRES on a planted bad-alphabet
    /// anchor literal, a planted bad-alphabet `ParagraphID("...")`
    /// construction, AND a planted bad-alphabet `paragraphId: "..."`
    /// keyword-argument literal, and does NOT fire on a comment-prose
    /// placeholder, a deliberate `XCTAssertNil`-guarded malformed-rejection
    /// literal, or a valid literal.
    func test_paragraphIdAlphabetLintFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-paragraphid-alphabet-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        final class PlantedTests: XCTestCase {
            // Doc-comment placeholder, not a literal: <!-- ¶XXXX --> anchors.
            func test_good() {
                let md = "<!-- ¶a3f9 --> text"
            }
            func test_badAnchor() {
                // "ilou" hits all four excluded letters: i, l, o, u.
                let md = "<!-- ¶ilou --> text"
            }
            func test_badConstructor() {
                let id = ParagraphID("ilou")
            }
            func test_badKeywordArg() {
                let op = Op.insert(paragraphId: "ilou", text: "x", sequence: 1)
            }
            func test_rejectsMalformed() {
                XCTAssertNil(ParagraphID.parseComment("<!-- ¶ABCD -->"))
            }
        }
        """.write(to: tmp.appendingPathComponent("PlantedTests.swift"),
                  atomically: true, encoding: .utf8)

        let dirs = [tmp]
        let offenders = try Self.scanParagraphIdAlphabetViolations(in: dirs)
        XCTAssertEqual(offenders.count, 3,
            "Self-check expected exactly the bad anchor, bad constructor, and "
            + "bad keyword-arg literals to fire (comment placeholder and "
            + "XCTAssertNil-guarded rejection test excluded). Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("[ilou]") && $0.contains("¶ilou") },
            "Self-check: the planted bad anchor literal should be caught.")
        XCTAssertTrue(offenders.contains { $0.contains("[ilou]") && $0.contains("ParagraphID(\"ilou\")") },
            "Self-check: the planted bad ParagraphID(\"...\") construction should be caught.")
        XCTAssertTrue(offenders.contains { $0.contains("[ilou]") && $0.contains("paragraphId: \"ilou\"") },
            "Self-check: the planted bad paragraphId: \"...\" keyword-arg literal should be caught.")
        XCTAssertFalse(offenders.contains { $0.contains("a3f9") },
            "Self-check: the valid literal must NOT fire.")
        XCTAssertFalse(offenders.contains { $0.contains("ABCD") },
            "Self-check: the XCTAssertNil-guarded rejection literal must NOT fire.")
    }

    // MARK: - `XCTAssertNil` through an optional chain (1C-c3 whole-branch review)

    /// The marker that exempts a line. Same spelling as `adr-0018-ok:` and
    /// `adr-0021-ok:`, so an exemption is a decision with a name on it rather
    /// than a silence.
    static let nilChainMarker = "nil-chain-ok:"

    /// Every offending line under `dir`: a `?.` reaching the subject of an
    /// assertion that a value is absent — `XCTAssertNil(`, or the equality
    /// spelling `XCTAssertEqual(…, nil)` — with no exemption marker.
    ///
    /// **Why this shape is a defect.** `XCTAssertNil(scene.node(a)?.author)`
    /// passes when node `a` was never there at all — `Optional.none` satisfies it
    /// exactly as a present node with a nil field does. So the assertion is true
    /// for a reason other than the one its message names, and the failure it was
    /// written to catch (the decoder dropping the node, the store not saving it)
    /// is the failure it cannot see. `try XCTUnwrap(scene.node(a)).author` says
    /// the same thing and fails on absence. **Four instances of this shape
    /// shipped across four tasks of 1C-c3, each implementer having been warned
    /// about the last** — which is `memory/feedback_prose_loses_to_a_test.md`'s
    /// case for a census over a better comment.
    ///
    /// **Its reach, stated plainly, because it must not be sold as retiring the
    /// class.** It catches the one greppable shape. It cannot catch "the
    /// assertion is true for a reason other than the one named" in general — a
    /// fixture whose region never drove the union it was meant to force, an
    /// empty-vs-empty comparison after an undo, a `message.contains("1")`. Those
    /// need a reader.
    ///
    /// **It scans two spellings, because absence has two.**
    /// `XCTAssertEqual(scene.node(a)?.author, nil)` false-passes on a missing
    /// node exactly as `XCTAssertNil` does — same defect, different words — so
    /// the equality-against-`nil` form is scanned too. The census read
    /// `XCTAssertNil` only for one commit, and its doc asserted flatly that
    /// `XCTAssertEqual` chains "cannot false-pass on absence"; that is true of
    /// `XCTAssertEqual(…?.author, .claude)`, where `Optional.none != .some(x)`
    /// keeps the assertion honest, and false of the `nil` expectation. No
    /// instance of the equality spelling existed when the gap was found, so it
    /// was a hole in the guard rather than a live defect — which is the only
    /// kind of hole a census gets to close cheaply. A chain against a **non**-nil
    /// expectation still does not fire, and should not.
    ///
    /// **Line-based, and the limit is real**: an assertion wrapped so that the
    /// `?.` lands on a later line is invisible to it — and so is
    /// `XCTAssertEqual(x?.y,` with its `nil` on the line below, which is the
    /// same limit costing twice now that there are two spellings. The marker is honoured on
    /// the offending line OR on the line immediately above it, because these
    /// assertions are long and pushing the marker onto a 100-column line is how a
    /// convention stops being followed.
    static func scanNilChainAssertions(in dir: URL,
                                       allowed: Set<String> = []) throws -> [String] {
        var offenders: [String] = []
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in walker where url.pathExtension == "swift" {
            if allowed.contains(url.lastPathComponent) { continue }
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                guard trimmed.contains("?.") else { continue }
                // Both spellings of "this is absent". The `nil` expectation is
                // matched with its delimiter attached so that `, nil)` and
                // `, nil, "message")` both fire and an identifier ending in
                // `nil` does not.
                let assertsAbsence = trimmed.contains("XCTAssertNil(")
                    || (trimmed.contains("XCTAssertEqual(")
                        && (trimmed.contains(", nil)") || trimmed.contains(", nil,")))
                guard assertsAbsence else { continue }
                let previous = i > 0 ? lines[i - 1] : ""
                if line.contains(nilChainMarker) || previous.contains(nilChainMarker) { continue }
                offenders.append("\(url.lastPathComponent):\(i + 1): \(trimmed)")
            }
        }
        return offenders
    }

    /// Census: no `XCTAssertNil` reaches its subject through `?.` in this
    /// directory's tests.
    ///
    /// **Scoped to `MaughamTests/Canvas` deliberately.** Eighty-two instances
    /// exist across the three test trees, and a census that lands red on all of
    /// them on day one gets a blanket annotation rather than eighty-two
    /// decisions. This is the tree where the shape recurred four times in one
    /// slice, and it is the tree that is clean.
    func test_noXCTAssertNilReachesItsSubjectThroughAnOptionalChain() throws {
        let dir = repoRoot.appendingPathComponent("MaughamTests/Canvas", isDirectory: true)
        let offenders = try Self.scanNilChainAssertions(in: dir)
        XCTAssertTrue(offenders.isEmpty,
            "An assertion of absence — XCTAssertNil, or XCTAssertEqual(…, nil) — "
            + "whose subject is reached through `?.` passes when the "
            + "subject is ABSENT, which is usually the failure the assertion was "
            + "written to catch. Use `try XCTUnwrap(subject).field` — or, if the "
            + "chain's own nil really is the assertion, add `// \(Self.nilChainMarker) "
            + "<reason>` on that line or the one above it. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Planted-offender companion, for the reason every census here has one: **a
    /// census over a forbidden token is exactly the shape that passes while
    /// blind.** A scan that walked the wrong directory, or matched a pattern no
    /// line can contain, reports zero offenders and looks identical to a clean
    /// tree.
    ///
    /// Six plants and three controls, one per rule the scan has to get right.
    /// Two of the plants are the equality-against-`nil` spelling, which is the
    /// arm that matters most here: it was added to the scan against a tree with
    /// no instance of it, so the real census cannot tell a working clause from a
    /// clause that matches nothing.
    func test_theNilChainCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-nil-chain-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        final class PlantedTests: XCTestCase {
            func test_plainOffender() throws {
                XCTAssertNil(scene.node(a)?.author, "still the writer's")
            }
            func test_offenderWithAMessageOnTheNextLine() throws {
                XCTAssertNil(scene.region(r)?.boundPieceID,
                             "nothing of its own")
            }
            func test_offenderThroughAThrowingSubject() throws {
                XCTAssertNil(try roundTrip(s).node(a)?.promotedItemID)
            }
            func test_offenderOnACollection() throws {
                XCTAssertNil(scene.lines.first?.label)
            }
            func test_theEqualitySpellingOfTheSameDefect() throws {
                XCTAssertEqual(scene.node(a)?.promotedItemID, nil)
            }
            func test_theEqualitySpellingWithAMessage() throws {
                XCTAssertEqual(scene.region(r)?.boundPieceID, nil, "nothing of its own")
            }
            func test_exemptOnTheSameLine() throws {
                XCTAssertNil(nodes.first { $0.frame?.contains(p) == true }) // \(Self.nilChainMarker) predicate
            }
            func test_exemptOnTheLineAbove() throws {
                // \(Self.nilChainMarker) the chain's own nil is the assertion
                XCTAssertNil(nodes.first { $0.frame?.contains(p) == true })
            }
            func test_theFixedShape() throws {
                XCTAssertNil(try XCTUnwrap(scene.node(a)).author)
            }
            func test_aSafeChain() throws {
                XCTAssertEqual(scene.node(a)?.author, .claude)
            }
            // XCTAssertNil(scene.node(a)?.author) in a comment is not code.
        }
        """.write(to: tmp.appendingPathComponent("PlantedTests.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try Self.scanNilChainAssertions(in: tmp)
        XCTAssertEqual(offenders.count, 6,
            "Self-check: exactly the six planted offenders should fire. Got:\n"
            + offenders.joined(separator: "\n"))
        for expected in ["node(a)?.author", "region(r)?.boundPieceID",
                         "roundTrip(s).node(a)?.promotedItemID", "lines.first?.label"] {
            XCTAssertTrue(offenders.contains { $0.contains(expected) },
                          "Self-check: the planted `\(expected)` should be caught.")
        }
        XCTAssertTrue(offenders.contains {
            $0.contains("XCTAssertEqual") && $0.contains("promotedItemID, nil)")
        }, "Self-check: the equality spelling of absence should be caught — it "
           + "false-passes on a missing node exactly as XCTAssertNil does.")
        XCTAssertTrue(offenders.contains {
            $0.contains("XCTAssertEqual") && $0.contains("nil, \"nothing of its own\"")
        }, "Self-check: the equality spelling with a trailing message should be "
           + "caught, or the clause only matches assertions nobody explains.")
        XCTAssertFalse(offenders.contains { $0.contains("XCTUnwrap") },
                       "Self-check: the FIXED shape must not fire, or the census "
                       + "punishes the repair it is asking for.")
        XCTAssertFalse(offenders.contains { $0.contains(".claude") },
                       "Self-check: a chain against a NON-nil expectation cannot "
                       + "false-pass on absence and must not fire — "
                       + "Optional.none != .some(x).")
        XCTAssertFalse(offenders.contains { $0.contains("in a comment") },
                       "Self-check: a commented-out assertion is not code.")
    }

    // MARK: - Segmented-picker child uniformity (2026-07-25 smoke, defect C)

    /// A segmented `Picker` whose `ForEach` emits more than one KIND of child
    /// is a shipped-bug shape. The `if let symbol { Image } else { Text }`
    /// spelling makes a `_ConditionalContent` whose branch is cached per
    /// position; the picker updates its `NSSegmentedControl` in place, so the
    /// first list reshape (a persona change) leaves stale branches on the wrong
    /// indices — the binder rendered `Pieces | 🎨Research | 🎨`, and a persona
    /// with no Palette segment showed a palette icon that selected Research.
    ///
    /// **One picker left, and it is the right pane's.** The binder's own
    /// (`BinderSegmentPicker`) was the surface the defect was FOUND on, and it
    /// died with the strip in shell-finish stage 2b Task 7 — every persona's
    /// left column is the project's tree now, so there is nothing there to pick
    /// between. `DetailPaneToggle` has the identical shape and the identical
    /// exposure, which is why the rule outlives the file it was written for.
    func test_segmentedPickerForEachBodiesHaveNoConditionalChildren() throws {
        for relative in ["Views/DetailPaneToggle.swift"] {
            let content = try String(
                contentsOf: sourceDir.appendingPathComponent(relative), encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            var insidePicker = false
            var insideForEach = false
            var depth = 0
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // Skip doc comments — they discuss the very shape we ban.
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                if line.contains("Picker(") { insidePicker = true; depth = 0 }
                guard insidePicker else { continue }
                if insideForEach {
                    XCTAssertFalse(
                        line.hasPrefix("if ") || line.hasPrefix("} else")
                            || line.hasPrefix("else ") || line.contains(" ? ") ,
                        "\(relative):\(i + 1) — a segmented Picker's ForEach body must emit ONE "
                        + "kind of child. A conditional here is _ConditionalContent, whose branch "
                        + "is cached per position; the first list reshape puts a stale child on "
                        + "the wrong segment (2026-07-25 smoke, defect C). Move the variation "
                        + "INSIDE one child expression, or change every segment together.")
                }
                if line.contains("ForEach(") { insideForEach = true; depth = 0 }
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                if insideForEach && depth <= 0 { insideForEach = false; insidePicker = false }
            }
        }
    }

    // MARK: - Coercion call-site census (persona pane-selection wiring)

    /// Recurrence-tripper: DetailPaneToggle has two critical segment-snapping call
    /// sites that MUST consult different `visibleSegments` lists — swapping them is
    /// a shipped-bug shape (happened 3 times on this branch, Critical at merge gate).
    /// The distinction:
    ///   - `.onAppear` calls `snapSegmentIntoPicker()`, which calls `mountSelection()`
    ///     and MUST eventually consult `visibleSegments(..., including:)` — the
    ///     selection-carrying list. This preserves out-of-persona pane selections
    ///     reached via ⌘⌥ shortcuts, even when the current persona doesn't register them.
    ///   - `.onChange(of: persona)` calls `coerceSegmentIntoView(of:)`, which MUST
    ///     consult `visibleSegments(persona:)` WITHOUT `including:` —
    ///     the bare registry. On persona change, coercion is the intent and an
    ///     out-of-persona pane is deliberately dropped.
    /// If those function calls are swapped between the two event handlers, the suite
    /// still passes because the tests pin the pure functions, not the wiring. A census
    /// (plus a plainly-written failure message) is the only guard.
    func test_coercionCallSitesCensus() throws {
        let fileURL = sourceDir.appendingPathComponent("Views/DetailPaneToggle.swift")
        let content = try String(contentsOf: fileURL, encoding: .utf8)

        // Check 1: `.onAppear` MUST call `snapSegmentIntoPicker()`
        guard let onAppearRange = content.range(of: ".onAppear") else {
            XCTFail("Could not find .onAppear in DetailPaneToggle.swift")
            return
        }
        let afterOnAppear = content[onAppearRange.lowerBound...]
        let nextModifierEnd = afterOnAppear.range(of: "}")?.lowerBound ?? afterOnAppear.endIndex
        let onAppearBody = String(afterOnAppear[..<nextModifierEnd])
        let onAppearHasSnapSegmentIntoPicker = onAppearBody.contains("snapSegmentIntoPicker()")
        XCTAssertTrue(onAppearHasSnapSegmentIntoPicker,
            ".onAppear MUST call snapSegmentIntoPicker() (which uses the selection-carrying list). "
            + "If this is false, the event handler may have been rewired to call coerceSegmentIntoView "
            + "instead (which uses the bare registry). Swapping these is a Critical shipped-bug shape.")

        // Check 2: `.onChange(of: persona)` MUST call `coerceSegmentIntoView(`
        guard let onPersonaChangeRange = content.range(of: ".onChange(of: persona)") else {
            XCTFail("Could not find .onChange(of: persona) in DetailPaneToggle.swift")
            return
        }
        let afterPersonaChange = content[onPersonaChangeRange.lowerBound...]
        let personaModifierEnd = afterPersonaChange.range(of: "}")?.lowerBound ?? afterPersonaChange.endIndex
        let onPersonaChangeBody = String(afterPersonaChange[..<personaModifierEnd])
        let onPersonaChangeHasCoerce = onPersonaChangeBody.contains("coerceSegmentIntoView(")
        XCTAssertTrue(onPersonaChangeHasCoerce,
            ".onChange(of: persona) MUST call coerceSegmentIntoView() (which uses the bare registry). "
            + "If this is false, the event handler may have been rewired to call snapSegmentIntoPicker "
            + "instead (which uses the selection-carrying list). Swapping these is a Critical shipped-bug shape.")
    }

    /// Self-check: prove the census FIRES when the two call sites are swapped
    /// (the real defect this test guards against). Plants a synthetic file with
    /// the calls reversed and confirms the test fails with useful guidance.
    func test_coercionCallSitesCensusFiresOnPlantedSwap() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-coercion-swapped-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Plant a synthetic file with the call sites swapped (the bug)
        let planted = tmp.appendingPathComponent("DetailPaneToggle.swift")
        try """
        struct DetailPaneToggle<Inspector: View>: View {
            func snapSegmentIntoPicker() {
                // WRONG: calling with bare list instead of including:
                let snapped = Self.mountSelection(segment, persona: persona)
                if snapped != segment { segment = snapped }
            }

            private func coerceSegmentIntoView(of persona: Persona) {
                // WRONG: calling with including: instead of bare list
                let visible = Self.visibleSegments(persona: persona, including: segment)
                let coerced = Self.snappedSelection(segment, in: visible, fallback: persona.defaultPane)
                if coerced != segment { segment = coerced }
            }

            static func mountSelection(
                _ current: DetailSegment,
                persona: Persona
            ) -> DetailSegment {
                let carrying = visibleSegments(
                    persona: persona, including: current)
                return snappedSelection(current, in: carrying, fallback: persona.defaultPane)
            }
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        // Run the census check
        let content = try String(contentsOf: planted, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var visibleSegmentsCalls: [(line: Int, text: String, hasIncluding: Bool)] = []
        for (i, line) in lines.enumerated() {
            if line.contains("visibleSegments(") {
                let hasIncluding = line.contains("including:") ||
                    (i + 1 < lines.count && lines[i + 1].contains("including:"))
                visibleSegmentsCalls.append((line: i + 1, text: line.trimmingCharacters(in: .whitespaces), hasIncluding: hasIncluding))
            }
        }

        // With the swapped calls, we should have:
        // - Line with "WRONG: calling with including:" in coerceSegmentIntoView = 1 (with including)
        // - Line in mountSelection inside the let carrying statement = 1 (with including)
        // Total = 2, but count of "with including" should still be 2, which violates the census
        let withIncluding = visibleSegmentsCalls.filter { $0.hasIncluding }
        XCTAssertEqual(withIncluding.count, 2,
            "Self-check: with the swapped call sites, there should be TWO calls "
            + "with 'including:', which violates the census. The test should fail "
            + "when this happens. Got \(withIncluding.count) calls with including.")
    }

    /// Self-check: prove the guard FIRES on a planted bare `ParagraphID.mint()`
    /// call and does NOT fire on the safe `ParagraphID.mintUnique(excluding:)`
    /// sibling.
    func test_paragraphIDMintTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-mint-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        func badPaste(count: Int) -> [String] {
            return (0..<count).map { _ in ParagraphID.mint() }
        }
        func goodPaste(count: Int, existing: Set<String>) -> [String] {
            var used = existing
            return (0..<count).map { _ in
                let id = ParagraphID.mintUnique(excluding: used)
                used.insert(id)
                return id
            }
        }
        """.write(to: tmp.appendingPathComponent("PlantedMintOffender.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: [Self.paragraphIDMintPattern])
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the bare ParagraphID.mint() call to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("ParagraphID.mint()") },
            "Self-check: the planted bare ParagraphID.mint() should be caught.")
        XCTAssertFalse(offenders.contains { $0.contains("mintUnique") },
            "Self-check: ParagraphID.mintUnique(excluding:) must NOT fire.")
    }

    // MARK: - InboxConvention choke-point (E5a)

    /// Recurrence-tripper: `InboxStore`'s inbox asset subdir literals
    /// (`"images"`/`"audio"`) must resolve through `InboxConvention`
    /// (MaughamCore) — the exact phone-v0.1.1-class reach-around the cross-
    /// surface contract registry exists to kill, sitting outside it until
    /// now. A raw `"images"`/`"audio"` string literal here means the
    /// subdir↔kind mapping diverged from the phone writer's independently
    /// hardcoded copy. Phone twin: `TripwirePhoneGrepTest.
    /// test_noRawInboxSubdirLiteralsInInboxCaptureWriter`.
    func test_noRawInboxSubdirLiteralsInInboxStore() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            files: ["InboxStore.swift"],
            patterns: ["\"images\"", "\"audio\""])
        XCTAssertTrue(offenders.isEmpty,
            "Raw inbox asset subdir literal (\"images\"/\"audio\") in InboxStore.swift. "
            + "Route through InboxConvention.assetSubdir(for:) / "
            + "assetURL(kind:filename:inboxDir:) (MaughamCore) — the single source of "
            + "truth shared with the phone writer (InboxCaptureWriter). See "
            + "docs/superpowers/notes/cross-surface-contracts.md. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the tripwire FIRES on planted raw subdir literals.
    func test_inboxSubdirLiteralTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-inbox-subdir-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("InboxStore.swift")
        try """
        func assetURL(for entry: InboxEntry) -> URL? {
            let subdir: String
            switch entry.kind {
            case .image: subdir = "images"
            case .audio: subdir = "audio"
            case .text: return nil
            }
            return inboxDir.appendingPathComponent(subdir)
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            files: ["InboxStore.swift"],
            patterns: ["\"images\"", "\"audio\""])
        XCTAssertEqual(offenders.count, 2,
            "Self-check expected both the images and audio literal to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("\"images\"") },
            "Self-check: the planted \"images\" literal should be caught.")
        XCTAssertTrue(offenders.contains { $0.contains("\"audio\"") },
            "Self-check: the planted \"audio\" literal should be caught.")
    }

    // MARK: - The canvas's undo bracket, reached from another column

    /// Files that DEFINE the bracket rather than reach it from outside. Both
    /// necessarily spell every verb; censusing them would say nothing.
    private static let canvasBracketDefiners: Set<String> = [
        "CanvasModel.swift", "CanvasUndo.swift",
    ]

    /// The one view that IS the canvas — the file tripwire 57's walk reads,
    /// and the one file allowed to build a surface helper. The census below
    /// skips the whole surface (`CanvasSourceCensus.surfaceFiles`): the view
    /// and the helpers it builds per call are inside its own bracket by
    /// construction, so they use the inside verbs.
    private static let theCanvasViewFile = "CanvasView.swift"

    /// Every `CanvasModel` entry point that changes state the undo stack owns,
    /// EXCEPT the one that is safe from another column.
    ///
    /// **`withScene` and the two scrap-text mutators are the point of this
    /// list, not an afterthought.** They are `internal`, they are the primitives
    /// `mutate` wraps, and a surface written as `model.withScene { … }` changes
    /// the scene and schedules the save with **no undo bracket at all** — which
    /// is strictly worse than nesting, and which a census of `mutate` alone
    /// records as nothing, because that file's verb set comes up empty and it
    /// never enters the dictionary. Censusing one spelling of the invariant is
    /// not censusing the invariant.
    ///
    /// **Bare member names, with no trailing `(`.** The paren spelling misses the
    /// call that matters most: `withScene`'s only argument is its closure, so an
    /// outside caller writes `model.withScene { … }` with a trailing closure and
    /// no paren at all — and a pattern of `.withScene(` sails straight past the
    /// worst case in the list. Caught by the self-check below, which is why that
    /// companion exists.
    ///
    /// **`renameGesture` is here because a verb this census does not know is a
    /// verb it cannot report.** Slice 3 added it (`CanvasUndo.renameGesture`,
    /// forwarded by `CanvasModel`) for the sweep, whose name is only knowable at
    /// the end of the gesture. A file in another column calling **only** that verb
    /// produced an empty verb set, never entered the dictionary, and passed — the
    /// blind spot this list's own doc comment warns about, arriving through a new
    /// member rather than a new spelling. It is an inside verb on the same terms
    /// as the others: it does nothing at all at depth 0, so an outside caller
    /// reaching for it has silently written no undo step and no name.
    private static let canvasInsideVerbs = [
        "mutate", "beginGesture", "endGesture", "breakGesture", "renameGesture",
        "withScene", "setScrapText", "removeScrapText",
    ]
    private static let canvasOutsideVerb = "mutateFromInspector"

    /// Which bracket verbs each production file *outside* the canvas surface
    /// uses. Only files that could hold a `CanvasModel` at all are considered,
    /// so an unrelated `.mutate(` elsewhere in the app cannot land here.
    private func canvasBracketCensus(in dir: URL) throws -> [String: [String]] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        // The surface is skipped by its path under `dir` (`Canvas/<file>`), not by
        // basename, so a same-named file in another folder is still censused.
        let root = dir.resolvingSymlinksInPath().path + "/"
        let surfacePaths = Set(CanvasSourceCensus.surfaceFiles.map { "Canvas/\($0)" })
        var census: [String: [String]] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            let full = url.resolvingSymlinksInPath().path
            let relative = full.hasPrefix(root) ? String(full.dropFirst(root.count)) : full
            guard !surfacePaths.contains(relative),
                  !Self.canvasBracketDefiners.contains(name) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("CanvasModel") else { continue }
            var found: Set<String> = []
            for line in Self.codeLines(of: text) {
                for verb in Self.canvasInsideVerbs + [Self.canvasOutsideVerb]
                where Self.callsOnAnInstance(verb, in: line) {
                    found.insert(verb)
                }
            }
            if !found.isEmpty { census[name] = found.sorted() }
        }
        return census
    }

    /// Whether `line` calls `verb` on an INSTANCE rather than on a type.
    ///
    /// Two filters, and both earn their place:
    ///
    /// - **The receiver must be lowercase-initial.** `CanvasModel`'s verbs are
    ///   instance methods, so the receiver is `model.`, `canvasModel.`,
    ///   `self.model.`. A capitalised receiver is a static call on some other
    ///   type — `TreeWalk` and `ScreenplayLineMutator` both vend a `mutate`, and
    ///   `ProjectWindow` (which names `CanvasModel`, so it is in the candidate
    ///   set) already calls `TreeWalk.find`/`collect`. One ordinary
    ///   `TreeWalk.mutate(id:in:)` added there would otherwise fail this census
    ///   with a message about undo brackets. A rule rather than a name list, so
    ///   an unrelated type added later needs no maintenance here.
    /// - **The character after the name must not continue an identifier**, or
    ///   `mutate` would match `mutateFromInspector` and the safe verb would be
    ///   recorded as the unsafe one. It is deliberately allowed to be `(` OR a
    ///   space OR `{`, so a trailing-closure call is caught.
    private static func callsOnAnInstance(_ verb: String, in line: String) -> Bool {
        var search = line[...]
        while let hit = search.range(of: "." + verb) {
            let continues = line[hit.upperBound...].first.map {
                $0.isLetter || $0.isNumber || $0 == "_"
            } ?? false
            let receiver = line[..<hit.lowerBound]
                .reversed()
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !continues, let initial = receiver.last, initial.isLowercase || initial == "_" {
                return true
            }
            search = line[hit.upperBound...]
        }
        return false
    }

    /// Source lines with comments removed, so a verb NAMED in a doc comment is
    /// not counted as a call. Both files in this census discuss the other verb
    /// at length in prose, which is the whole point of them.
    ///
    /// `SourceScan`'s, since 1C-d Task 11's fix round put the same filter under
    /// `PromotionCommandTests`' wiring census — where it had been missing, and
    /// where its absence was measured. One implementation for every census in
    /// the suite; this stays as the name the callers here already use.
    private static func codeLines(of text: String) -> [String] {
        SourceScan.codeLines(of: text)
    }

    /// **A scene change made from another column must use `mutateFromInspector`,
    /// never `mutate`** — and the two verbs are not interchangeable in either
    /// direction.
    ///
    /// The failure is silent and has now been reached twice in one slice, from
    /// opposite sides. 1C-b Task 6 shipped a ⌫ that opened a bracket inside an
    /// open one; Task 7's inspector reached the same state from the other
    /// column. In both, the nested `beginGesture` takes no snapshot and the
    /// nested `endGesture` registers nothing, so **the edit is on no undo step
    /// at all** — and rides into whatever step the open gesture eventually
    /// closes, where a ⌘Z aimed at a sentence takes something else with it.
    ///
    /// Why the two verbs differ, which is the thing the next author needs:
    ///
    /// - **From the canvas**, a mutation arriving mid-gesture is the writer's
    ///   own gesture, and the right answer is to REFUSE — see
    ///   `CanvasKeyHandler.deleteSelection`'s `isInGesture` guard. Closing it would
    ///   end a bracket the writer still believes they hold.
    /// - **From another column**, there is no gesture of the caller's own to
    ///   protect, so close-run-reopen is correct, and it is exactly what
    ///   `CanvasUndo.undo()` already does.
    ///
    /// This is a CENSUS, not a ban: it names the call sites, so adding a
    /// legitimate one is a deliberate edit here rather than a mystery failure.
    ///
    /// 1C-c2 added the third: `PromotionPerformer` writes the promoted mark from
    /// outside the canvas, and `beginPromotion` can run while a focused scrap
    /// holds "Edit Scrap" open.
    ///
    /// 1C-c3 added the fifth, and **its repro is the sharpest here**:
    /// `CanvasClaudeWrite` is reached from an MCP call, which arrives from outside
    /// the window entirely. The inspector entries at least require the writer's
    /// hand to be in the window; this one needs nothing but a message on a socket
    /// while the writer types.
    ///
    /// 1C-d added the sixth, `CanvasDrop`, and it is the entry most likely to be
    /// argued out of this list by its delivery site: a research row dropped on the
    /// canvas *is* delivered to `CanvasView`. The site is not what this census
    /// turns on — a bracket **of its own** is. A drag that starts in the binder
    /// never reaches `CanvasClickHandler.handleClick`, which is the only caller of
    /// `commitActiveEdit`, so double-click bare canvas, type, then drag a research
    /// row in without touching the canvas again and the drop lands at depth 1 with
    /// nothing on either side able to close the writer's "Edit Scrap". That is the
    /// inspector's case exactly, arriving through a gesture instead of a button.
    func test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly() throws {
        let census = try canvasBracketCensus(in: sourceDir)
        XCTAssertEqual(
            census,
            ["CanvasCapture.swift": [Self.canvasOutsideVerb],
             "CanvasClaudeWrite.swift": [Self.canvasOutsideVerb],
             "CanvasDrop.swift": [Self.canvasOutsideVerb],
             "LineInspector.swift": [Self.canvasOutsideVerb],
             "PromotionPerformer.swift": [Self.canvasOutsideVerb],
             "RegionInspector.swift": [Self.canvasOutsideVerb],
             "ScrapInspector.swift": [Self.canvasOutsideVerb]],
            "The canvas's undo bracket is reached from outside the canvas surface "
            + "(`CanvasSourceCensus.surfaceFiles`: `CanvasView.swift` and the helpers "
            + "it builds per call) by the inspector column only, using exactly one verb.\n\n"
            + "If you have ADDED a surface that changes the canvas scene: it must "
            + "use `CanvasModel.mutateFromInspector`, and it belongs in the "
            + "expectation above. `mutate`/`beginGesture`/`endGesture` nest "
            + "inside the \"Edit Scrap\" gesture a focused scrap holds open — "
            + "nothing outside `CanvasClickHandler.handleClick` closes it, and a "
            + "double-click never reassigns the selection. Repro: double-click a "
            + "region's CHROME BAR — click 1 selects it, click 2 mints a scrap "
            + "and opens the bracket. NOT a card: AppKit sends clickCount 1 "
            + "first and that click selects the card. Nested, your edit "
            + "registers NO undo step and rides into the writer's next one.\n\n"
            + "The sharper repro, and it needs no gesture at all: an MCP call "
            + "arriving while the writer is inside a scrap. Nothing on that side "
            + "of the window closes their bracket, and nothing on this side has "
            + "one of its own to protect — so a write from a tool is the same "
            + "case as the inspector's, minus the requirement that anyone be "
            + "touching the app. That is CanvasClaudeWrite.swift above.\n\n"
            + "CanvasCapture.swift is the same case from a third direction "
            + "(1C-d, spec §8A.4): a capture sent from the Inbox pane in the "
            + "other column, or DRAGGED out of it, and neither has a bracket of "
            + "its own — a drag that begins in a pane never reaches "
            + "`CanvasClickHandler.handleClick`, which is the only thing that runs "
            + "`commitActiveEdit`.\n\n"
            + "From the canvas itself the answer is the opposite — refuse "
            + "mid-gesture (`deleteSelection`'s `isInGesture` guard), because "
            + "closing the bracket would end one the writer still holds.\n\n"
            + "Found:\n\(census)")
    }

    /// The converse, so the two verbs cannot simply be swapped: the canvas
    /// surface uses the inside verbs and never the outside one. Reaching for
    /// `mutateFromInspector` from `CanvasView` would close a bracket the writer
    /// is still inside.
    ///
    /// The surface is `CanvasSourceCensus.surfaceFiles` — the view and the
    /// helpers it builds per call — so a `.mutate(` that moves into a helper is
    /// still found, and each file is checked on its own so the message names
    /// the one that reached for the outside verb.
    func test_theCanvasSurfaceItselfUsesTheInsideVerbs() throws {
        var mutating: [String] = []
        for name in CanvasSourceCensus.surfaceFiles {
            let code = Self.codeLines(of: try CanvasSourceCensus.source(at: "Maugham/Canvas/\(name)"))
            if code.contains(where: { $0.contains(".mutate(") }) { mutating.append(name) }
            XCTAssertFalse(code.contains { $0.contains(Self.canvasOutsideVerb) },
                "\(name) is on the canvas surface and must NOT use \(Self.canvasOutsideVerb): "
                + "close-run-reopen from inside the canvas ends a gesture the writer "
                + "is still in the middle of.")
        }
        XCTAssertFalse(mutating.isEmpty,
            "No file on the canvas surface (\(CanvasSourceCensus.surfaceFiles)) calls "
            + "`.mutate(` any more. The surface mutates through the inside verb; if "
            + "that call moved to a new file, add the file to "
            + "`CanvasSourceCensus.surfaceFiles` so the census above knows where it went.")
    }

    /// **The surface's helpers are named by `CanvasView` only** (tripwire 32).
    ///
    /// The census above skips every file in `CanvasSourceCensus.surfaceFiles`,
    /// because the view and the helpers it builds per call are inside its own
    /// bracket. That exemption is only safe while nothing else can reach into
    /// a surface file. Three routes would, and each is closed here:
    ///
    /// - **Naming a helper type.** Every type declared in a surface file other
    ///   than `CanvasView.swift` is NAMED (`TypeName`, identifier-guarded,
    ///   comments stripped) only in `CanvasView.swift` and in its own file. That
    ///   covers building one, holding one (`let handler: CanvasKeyHandler`) and
    ///   calling a static member that takes the model
    ///   (`CanvasKeyHandler.delete(model:)`), all of which reach `mutate` or
    ///   `beginGesture` from another column through a file the census never reads.
    /// - **Extending another type.** A surface file other than `CanvasView.swift`
    ///   extends only `CanvasView` or a type it declares itself: an
    ///   `extension CanvasModel { func f() { mutate(…) } }` there would be
    ///   callable as `model.f()` from any column.
    /// - **A top-level function**, callable from anywhere, for the same reason.
    ///
    /// And inside `CanvasView.swift` itself, a helper is named only in a
    /// `private var x: T { T(…) }` computed property: tripwire 57's walk follows
    /// that property, so a frozen view value handed in is caught. A helper held
    /// in `@State`, or made by a factory method and stored, would escape it.
    ///
    /// One helper never builds another: a helper is built only in a `CanvasView`
    /// computed property and handed what it needs. A sibling surface file may
    /// HOLD one it was handed, as a stored `let x: T` line (optionally `private`,
    /// `fileprivate` or `internal`) under `Maugham/Canvas/`, and nothing more.
    /// **A held helper is frozen for any later work its holder schedules**: a
    /// `Task` or escaping closure in the holder would read the held helper's
    /// build-time values, so a file that holds a helper contains no `Task {`,
    /// `Task.detached`, `DispatchQueue` or `@escaping`.
    /// Only top-level types count as helpers; a nested type is unreachable from
    /// another file. The planted companion below proves each route fires.
    func test_theCanvasSurfaceHelpersAreBuiltByCanvasViewOnly() throws {
        let census = try Self.canvasSurfaceHelperCensus(
            base: sourceDir.deletingLastPathComponent(),
            surfaceFiles: CanvasSourceCensus.surfaceFiles)
        XCTAssertGreaterThan(census.walked, 100,
            "the walk found almost nothing — a census over an empty tree "
            + "passes for the wrong reason")
        XCTAssertEqual(census.offenders, [], Self.surfaceHelperReachedFromElsewhere(census.offenders))
    }

    /// Self-check, one planted case per route: building a helper, building it
    /// through `.init(`, holding one, calling its static member, a surface file
    /// extending `CanvasModel`, a top-level function in a surface file, and in
    /// `CanvasView.swift` a helper held in `@State` or made by a factory method.
    /// Controls: a doc comment naming the helper, a longer identifier that
    /// merely contains its name, the helper named in its own file and in
    /// `CanvasView.swift`'s building computed property, a sibling surface file
    /// holding it as a bare `let` (one that builds it fires), an extension of the
    /// file's own type and of `CanvasView`, a nested function, and a
    /// `class func` in a helper class
    /// (which must not register a type called `func`). The hold's carve-out is
    /// pinned narrow: a sibling surface file holding the helper as a `var`,
    /// taking it as a parameter or calling its static member fires, and so does
    /// the bare `let` hold in a same-named file outside `Maugham/Canvas/`. The
    /// two `CanvasKeyGrip.swift` copies share a name (the list matches by name)
    /// but hold different helpers, so the one offender, `names PlantedKeyClock`,
    /// says WHICH copy fired: an inverted path condition would report
    /// `names PlantedKeyHandler` instead. Matching is by path for the view and
    /// the helper's home too: a `CanvasView.swift` and a `PlantedKeyHandler.swift`
    /// under `Maugham/Views/` both fire. A `private let` hold is accepted, but a
    /// holder that schedules work (`Task {`, `@escaping`) fires. A nested type
    /// (`ClickTarget`) is no helper, so naming it elsewhere stays quiet. A type
    /// NOT on the list is not checked at all, and a missing listed file throws.
    func test_theCanvasSurfaceHelperCensusFiresOnAPlantedBuilder() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Canvas/CanvasView.swift": """
                struct CanvasView: View {
                    let model: CanvasModel
                    private var keyHandler: PlantedKeyHandler { PlantedKeyHandler(model: model) }
                    @State private var pass: PlantedKeyHandler?
                    func makeKeys() -> PlantedKeyHandler { PlantedKeyHandler(model: model) }
                }
                """,
            "Maugham/Canvas/PlantedKeyHandler.swift": """
                /// Built per call by CanvasView; never write PlantedKeyHandler(model:) elsewhere.
                @MainActor
                struct PlantedKeyHandler {
                    let model: CanvasModel
                    private enum ClickTarget { case none }
                    static func delete(model: CanvasModel) { model.mutate("Delete") { _ in } }
                    func again() -> PlantedKeyHandler { PlantedKeyHandler(model: model) }
                    func outer() { func inner() {} ; inner() }
                }
                final class PlantedKeyClock {
                    class func now() -> Int { 0 }
                    class var rate: Int { 1 }
                }
                extension PlantedKeyHandler { func more() {} }
                extension CanvasView { var keys: Int { 0 } }
                extension CanvasModel {
                    func deleteFromAnywhere() { mutate("Delete") { _ in } }
                }
                private func deleteEverything(_ model: CanvasModel) { model.mutate("Delete") { _ in } }
                """,
            "Maugham/Canvas/CanvasKeyGrip.swift": """
                struct CanvasKeyGrip {
                    let keys: PlantedKeyHandler
                }
                """,
            "Maugham/Canvas/CanvasKeyRebuilder.swift": """
                struct CanvasKeyRebuilder {
                    let keys: PlantedKeyHandler
                    func again() { _ = PlantedKeyHandler(model: keys.model) }
                }
                """,
            "Maugham/Canvas/CanvasKeyScheduler.swift": """
                struct CanvasKeyScheduler {
                    private let keys: PlantedKeyHandler
                    func later() { Task { _ = keys } }
                    func after(_ work: @escaping () -> Void) {}
                }
                """,
            "Maugham/Views/CanvasView.swift": """
                struct ElsewhereView {
                    let keys: PlantedKeyHandler
                }
                """,
            "Maugham/Views/PlantedKeyHandler.swift": """
                struct Namesake {
                    func f(_ model: CanvasModel) { _ = PlantedKeyHandler(model: model) }
                }
                """,
            "Maugham/Canvas/CanvasKeyVarHolder.swift": """
                struct CanvasKeyVarHolder {
                    var keys: PlantedKeyHandler
                }
                """,
            "Maugham/Canvas/CanvasKeyTaker.swift": """
                struct CanvasKeyTaker {
                    func take(_ keys: PlantedKeyHandler) {}
                }
                """,
            "Maugham/Canvas/CanvasKeyCaller.swift": """
                struct CanvasKeyCaller {
                    let model: CanvasModel
                    func f() { PlantedKeyHandler.delete(model: model) }
                }
                """,
            "Maugham/Views/CanvasKeyGrip.swift": """
                struct ClockGrip {
                    let clock: PlantedKeyClock
                }
                """,
            "Maugham/Canvas/RegionInspector.swift": """
                struct RegionInspector {
                    let model: CanvasModel
                    func delete() { _ = PlantedKeyHandler(model: model).deleteSelection() }
                }
                """,
            "Maugham/Canvas/ScrapInspector.swift": """
                struct ScrapInspector {
                    let model: CanvasModel
                    func delete() { _ = PlantedKeyHandler.init(model: model) }
                }
                """,
            "Maugham/Canvas/LineInspector.swift": """
                // PlantedKeyHandler(model:) is the view's to build, not this file's.
                struct LineInspector {
                    let model: CanvasModel
                    func delete() { PlantedKeyHandler.delete(model: model) }
                }
                """,
            "Maugham/Canvas/ItemInspector.swift": """
                struct ItemInspector {
                    let handler: PlantedKeyHandler
                }
                """,
            "Maugham/Views/Unrelated.swift": """
                struct Unrelated {
                    let rows = PlantedKeyHandlerRows()
                    let target: ClickTarget? = nil
                    func f() { var (a, b) = (1, 2); a += b }
                }
                """,
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let planted = try Self.canvasSurfaceHelperCensus(
            base: base, surfaceFiles: ["CanvasView.swift", "PlantedKeyHandler.swift",
                                       "CanvasKeyGrip.swift", "CanvasKeyRebuilder.swift",
                                       "CanvasKeyVarHolder.swift", "CanvasKeyTaker.swift",
                                       "CanvasKeyCaller.swift", "CanvasKeyScheduler.swift"])
        XCTAssertEqual(planted.walked, 16, "Self-check: the walk read the planted tree")
        XCTAssertEqual(planted.offenders, [
            "CanvasKeyCaller.swift names PlantedKeyHandler",
            "CanvasKeyGrip.swift names PlantedKeyClock",
            "CanvasKeyRebuilder.swift names PlantedKeyHandler",
            "CanvasKeyScheduler.swift holds a sibling helper and schedules work: @escaping",
            "CanvasKeyScheduler.swift holds a sibling helper and schedules work: Task {",
            "CanvasKeyTaker.swift names PlantedKeyHandler",
            "CanvasKeyVarHolder.swift names PlantedKeyHandler",
            "CanvasView.swift names PlantedKeyHandler",
            "CanvasView.swift names PlantedKeyHandler outside a building computed property: "
                + "@State private var pass: PlantedKeyHandler?",
            "CanvasView.swift names PlantedKeyHandler outside a building computed property: "
                + "func makeKeys() -> PlantedKeyHandler { PlantedKeyHandler(model: model) }",
            "ItemInspector.swift names PlantedKeyHandler",
            "LineInspector.swift names PlantedKeyHandler",
            "PlantedKeyHandler.swift declares a top-level func",
            "PlantedKeyHandler.swift extends CanvasModel",
            "PlantedKeyHandler.swift names PlantedKeyHandler",
            "RegionInspector.swift names PlantedKeyHandler",
            "ScrapInspector.swift names PlantedKeyHandler",
        ], "Self-check: every route from another column into a surface file must "
            + "fire — building, holding, a static call, an extension of another "
            + "type, a top-level function, and in the view a helper held in `@State` "
            + "or made by a factory, and a sibling surface file building one, holding "
            + "it as a `var`, taking it as a parameter or calling its static member, "
            + "and a bare `let` hold outside `Maugham/Canvas/`, a `CanvasView.swift` or "
            + "a helper's namesake in another folder, and a holder that schedules work "
            + "— and no control may (the `keyHandler` computed property, a sibling's "
            + "held `let` or `private let`, and a nested `ClickTarget` named elsewhere "
            + "stay quiet).")

        let offTheList = try Self.canvasSurfaceHelperCensus(
            base: base, surfaceFiles: ["CanvasView.swift"])
        XCTAssertEqual(offTheList.offenders, [],
            "control: a file NOT on the surface list is not a surface file, so "
            + "what it declares or extends is not this census's business")

        XCTAssertThrowsError(try Self.canvasSurfaceHelperCensus(
            base: base, surfaceFiles: ["CanvasView.swift", "CanvasGone.swift"]),
            "a listed surface file that is not on disk must throw, not pass")
    }

    /// `CanvasSourceCensus.surfaceFiles` is derived, not trusted: after
    /// `CanvasView.swift` it must be exactly the `Maugham/Canvas/` files that
    /// declare (or extend) a type `CanvasView.swift` builds in a
    /// `private var x: T { T(…) }` property. A helper built but not listed would
    /// leave its file outside every surface ban and the construction census; a
    /// file listed but no longer built is a stale entry.
    func test_theCanvasSurfaceListIsExactlyTheFilesTheViewBuildsFrom() throws {
        let mismatches = try Self.canvasSurfaceListMismatches(
            base: sourceDir.deletingLastPathComponent(),
            surfaceFiles: CanvasSourceCensus.surfaceFiles)
        XCTAssertEqual(mismatches, [], Self.surfaceListDrifted(mismatches))
    }

    /// Self-check: a helper built but unlisted, a helper split into an unlisted
    /// extension file, a helper declared outside `Maugham/Canvas/`, and a listed
    /// file the view builds nothing from all fire. Controls: a builder in a
    /// comment, and the matching list.
    func test_theCanvasSurfaceListCheckFiresOnAnUnlistedHelper() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Canvas/CanvasView.swift": """
                struct CanvasView: View {
                    private var pass: CanvasListedPass { CanvasListedPass() }
                    private var missed: CanvasMissedHandler {
                        CanvasMissedHandler()
                    }
                    private var stray: CanvasStray { CanvasStray() }
                    // private var ghost: CanvasGhost { CanvasGhost() }
                }
                """,
            "Maugham/Canvas/CanvasListedPass.swift": "struct CanvasListedPass {}\n",
            "Maugham/Canvas/CanvasListedPass+Split.swift": "extension CanvasListedPass { func f() {} }\n",
            "Maugham/Canvas/CanvasMissedHandler.swift": "struct CanvasMissedHandler {}\n",
            "Maugham/Canvas/CanvasStale.swift": "struct CanvasStale {}\n",
            "Maugham/Canvas/CanvasGhost.swift": "struct CanvasGhost {}\n",
            "Maugham/Views/CanvasStray.swift": "struct CanvasStray {}\n",
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(try Self.canvasSurfaceListMismatches(
            base: base, surfaceFiles: ["CanvasView.swift", "CanvasListedPass.swift", "CanvasStale.swift"]), [
            "CanvasView.swift builds CanvasStray, declared in Maugham/Views/CanvasStray.swift, outside Maugham/Canvas/",
            "CanvasView.swift builds a helper declared in CanvasListedPass+Split.swift, which surfaceFiles does not list",
            "CanvasView.swift builds a helper declared in CanvasMissedHandler.swift, which surfaceFiles does not list",
            "surfaceFiles lists CanvasStale.swift, which declares no type CanvasView.swift builds",
        ], "Self-check: an unlisted helper file, an unlisted split of a listed helper, a "
            + "helper outside Maugham/Canvas/ and a stale entry must each fire; a builder "
            + "in a comment must not")

        XCTAssertEqual(try Self.canvasSurfaceListMismatches(
            base: base, surfaceFiles: ["CanvasView.swift", "CanvasListedPass.swift",
                                       "CanvasListedPass+Split.swift", "CanvasMissedHandler.swift"]), [
            "CanvasView.swift builds CanvasStray, declared in Maugham/Views/CanvasStray.swift, outside Maugham/Canvas/",
        ], "control: once every built helper's files are listed, only the stray remains")

        XCTAssertEqual(try Self.canvasSurfaceListMismatches(
            base: base, surfaceFiles: ["CanvasListedPass.swift", "CanvasView.swift",
                                       "CanvasListedPass+Split.swift", "CanvasMissedHandler.swift"]).first,
            "surfaceFiles does not start with CanvasView.swift",
            "the view's own file must lead the list")
    }

    private static func surfaceListDrifted(_ mismatches: [String]) -> String {
        "`CanvasSourceCensus.surfaceFiles` no longer matches what `CanvasView.swift` "
        + "builds. Every file declaring a type the view builds in a "
        + "`private var x: T { T(…) }` property must be on the list (else the surface "
        + "bans and tripwire 32's construction census never read it), and nothing "
        + "else after `CanvasView.swift`. Add or remove the entry.\n"
        + mismatches.joined(separator: "\n")
    }

    /// The surface list derived from `CanvasView.swift` (comments stripped):
    /// each type `T` built in a `private var x: T { T(` property, resolved by
    /// `SourceTree.filesDeclaring` to every file declaring or extending it.
    /// Returns how `surfaceFiles` differs from that set, sorted.
    private static func canvasSurfaceListMismatches(
        base: URL, surfaceFiles: [String]
    ) throws -> [String] {
        let viewCode = CanvasSourceCensus.commentsStripped(
            try SourceTree.read("Maugham/Canvas/\(theCanvasViewFile)", base: base))
        let builder = try NSRegularExpression(
            pattern: #"\bprivate\s+var\s+[A-Za-z_]\w*\s*:\s*([A-Z][A-Za-z0-9_]*)\s*\{\s*\1\("#)
        let built = Set(builder.matches(in: viewCode, range: NSRange(viewCode.startIndex..., in: viewCode))
            .compactMap { Range($0.range(at: 1), in: viewCode).map { String(viewCode[$0]) } })

        var mismatches: [String] = []
        var derived: Set<String> = []
        let canvas = "Maugham/Canvas/"
        for type in built {
            for path in try SourceTree.filesDeclaring(type, under: ["Maugham"], base: base) {
                let name = String(path.dropFirst(canvas.count))
                guard path.hasPrefix(canvas), !name.contains("/") else {
                    mismatches.append("\(theCanvasViewFile) builds \(type), declared in \(path), outside \(canvas)")
                    continue
                }
                if name != theCanvasViewFile { derived.insert(name) }
            }
        }
        let listed = Set(surfaceFiles.dropFirst())
        for name in derived.subtracting(listed) {
            mismatches.append("\(theCanvasViewFile) builds a helper declared in \(name), which surfaceFiles does not list")
        }
        for name in listed.subtracting(derived) {
            mismatches.append("surfaceFiles lists \(name), which declares no type \(theCanvasViewFile) builds")
        }
        mismatches.sort()
        if surfaceFiles.first != theCanvasViewFile {
            mismatches.insert("surfaceFiles does not start with \(theCanvasViewFile)", at: 0)
        }
        return mismatches
    }

    private static func surfaceHelperReachedFromElsewhere(_ offenders: [String]) -> String {
        "A canvas surface file is reachable from outside `CanvasView.swift` (tripwire 32). "
        + "The bracket census skips every file in `CanvasSourceCensus.surfaceFiles`, "
        + "so a helper named from another column — built, held, or called "
        + "statically — or an extension or top-level function in a surface file "
        + "reaches the inside verbs (`mutate`, `beginGesture`, `withScene`) where "
        + "nothing checks it: the nested-bracket defect, with the edit on no undo "
        + "step. Build a helper only in a `CanvasView` computed property "
        + "(`private var x: T { T(…) }`, which tripwire 57's walk follows) and keep "
        + "its file to its own types. A sibling surface file may hold one it was "
        + "handed as a stored `let x: T` (optionally `private`, `fileprivate` or "
        + "`internal`) on a line of its own, and then schedules no later work "
        + "(`Task {`, `Task.detached`, `DispatchQueue`, `@escaping`): that work "
        + "would read the held helper's build-time values. From another column, call "
        + "`CanvasModel.mutateFromInspector`.\n" + offenders.joined(separator: "\n")
    }

    /// The three routes into a surface file other than `CanvasView.swift`,
    /// comments stripped:
    /// - every production file under `<base>/Maugham/` that NAMES a type
    ///   declared there at top level (`struct`/`class`/`enum`/`actor`,
    ///   uppercase-initial), other than `Maugham/Canvas/CanvasView.swift` and the
    ///   type's own file, both matched by path — except that another surface
    ///   file may hold one as a stored `let x: T` line (the drag handler holds
    ///   the layout pass the view built), and a file that does schedules no
    ///   later work;
    /// - an `extension` of anything but `CanvasView` or a type the file declares;
    /// - a top-level `func`;
    /// - inside `CanvasView.swift`, a helper type named anywhere but a
    ///   `private var x: T { T(` computed property that builds it.
    /// Top level is column 0, which is how every file here is indented.
    /// Throws when a listed surface file is missing.
    private static func canvasSurfaceHelperCensus(
        base: URL, surfaceFiles: [String]
    ) throws -> (offenders: [String], walked: Int) {
        let canvasDir = base.appendingPathComponent("Maugham/Canvas", isDirectory: true)
        let attributesAndModifiers = #"(?:@\w+(?:\([^)]*\))?\s+)*"#
            + #"(?:(?:public|private|fileprivate|internal|package|final|indirect)\s+)*"#
        // Uppercase-initial, so `class func`/`class var` declare nothing. Column 0
        // only: a nested type (`CanvasClickHandler`'s `private enum ClickTarget`)
        // is unreachable from another file, so it is no helper to guard, and a
        // generic nested name must not ban that name everywhere else.
        let declaration = try NSRegularExpression(
            pattern: "^" + attributesAndModifiers
                + #"(?:struct|class|enum|actor)\s+([A-Z][A-Za-z0-9_]*)"#,
            options: [.anchorsMatchLines])
        let topLevelExtension = try NSRegularExpression(
            pattern: "^" + attributesAndModifiers + #"extension\s+([A-Za-z_][A-Za-z0-9_.]*)"#,
            options: [.anchorsMatchLines])
        let topLevelFunc = try NSRegularExpression(
            pattern: "^" + attributesAndModifiers + #"func\s"#, options: [.anchorsMatchLines])
        func captures(_ regex: NSRegularExpression, in code: String) -> [String] {
            regex.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
                Range($0.range(at: 1), in: code).map { String(code[$0]) }
            }
        }

        var offenders: [String] = []
        var homes: [String: String] = [:]   // type → the surface file declaring it
        for name in surfaceFiles {
            let url = canvasDir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw CanvasSourceCensus.SurfaceFileMissing(path: "Maugham/Canvas/\(name)")
            }
            guard name != theCanvasViewFile else { continue }
            let code = CanvasSourceCensus.commentsStripped(text)
            let declared = captures(declaration, in: code)
            for type in declared { homes[type] = name }
            for extended in Set(captures(topLevelExtension, in: code))
            where extended != "CanvasView" && !declared.contains(extended) {
                offenders.append("\(name) extends \(extended)")
            }
            if topLevelFunc.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                offenders.append("\(name) declares a top-level func")
            }
        }

        // Inside `CanvasView.swift`, a helper is named only where a computed
        // property builds it: `private var x: T { T(`. Tripwire 57's walk follows
        // such a property, so every value handed in is read where the walk looks;
        // a helper held in `@State` or made by a factory and stored would carry a
        // frozen view value past it.
        if !homes.isEmpty {
            let viewCode = CanvasSourceCensus.commentsStripped(
                try String(contentsOf: canvasDir.appendingPathComponent(theCanvasViewFile), encoding: .utf8))
            let whole = NSRange(viewCode.startIndex..., in: viewCode)
            for type in homes.keys.sorted() {
                let t = NSRegularExpression.escapedPattern(for: type)
                let builders = try NSRegularExpression(
                    pattern: #"\bprivate\s+var\s+[A-Za-z_]\w*\s*:\s*"# + t + #"\s*\{\s*"# + t + #"\("#)
                    .matches(in: viewCode, range: whole).map(\.range)
                let names = try NSRegularExpression(
                    pattern: #"(?<![A-Za-z0-9_])"# + t + #"(?![A-Za-z0-9_])"#)
                var lines: [String] = []
                for m in names.matches(in: viewCode, range: whole)
                where !builders.contains(where: { NSIntersectionRange($0, m.range).length == m.range.length }) {
                    let line = (viewCode as NSString).lineRange(for: m.range)
                    let text = (viewCode as NSString).substring(with: line)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !lines.contains(text) { lines.append(text) }
                }
                for text in lines {
                    offenders.append("\(theCanvasViewFile) names \(type) outside a building computed property: \(text)")
                }
            }
        }

        // Work a holder schedules runs after the call returns, so it would read
        // the held helper's build-time values.
        let scheduling = try NSRegularExpression(
            pattern: #"\bTask\s*\{|\bTask\.detached\b|\bDispatchQueue\b|@escaping\b"#)
        var walked = 0
        let app = base.appendingPathComponent("Maugham", isDirectory: true)
        let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            walked += 1
            let file = url.lastPathComponent
            // By path, not by name: a `CanvasView.swift` or a helper's namesake in
            // another folder is another column's file.
            func isCanvasFile(_ name: String) -> Bool {
                url.path.hasSuffix("/Maugham/Canvas/\(name)")
            }
            guard !isCanvasFile(theCanvasViewFile), !homes.isEmpty else { continue }
            let code = CanvasSourceCensus.commentsStripped(try String(contentsOf: url, encoding: .utf8))
            // Another surface file may HOLD a sibling helper the view handed it,
            // as a stored `let x: T` on a line of its own (`private`,
            // `fileprivate` or `internal` allowed: the access level changes who
            // reads the hold, not who builds it), and nothing more. The sibling
            // is still built only by the view's computed property, so the walk
            // still sees every value it carries.
            let isSurfaceFile = surfaceFiles.contains(file) && isCanvasFile(file)
            var holds = false
            for (type, home) in homes where !isCanvasFile(home) {
                let t = NSRegularExpression.escapedPattern(for: type)
                var scanned = code
                if isSurfaceFile {
                    let hold = try NSRegularExpression(
                        pattern: #"^[ \t]*(?:(?:private|fileprivate|internal)[ \t]+)?let[ \t]+[A-Za-z_]\w*[ \t]*:[ \t]*"#
                            + t + #"[ \t]*$"#,
                        options: [.anchorsMatchLines])
                    let whole = NSRange(code.startIndex..., in: code)
                    if hold.firstMatch(in: code, range: whole) != nil { holds = true }
                    scanned = hold.stringByReplacingMatches(in: code, range: whole, withTemplate: "")
                }
                let names = try NSRegularExpression(
                    pattern: #"(?<![A-Za-z0-9_])"# + t + #"(?![A-Za-z0-9_])"#)
                if names.firstMatch(in: scanned, range: NSRange(scanned.startIndex..., in: scanned)) != nil {
                    offenders.append("\(file) names \(type)")
                }
            }
            if holds {
                for m in scheduling.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                    let token = (code as NSString).substring(with: m.range)
                    let entry = "\(file) holds a sibling helper and schedules work: \(token)"
                    if !offenders.contains(entry) { offenders.append(entry) }
                }
            }
        }
        return (offenders.sorted(), walked)
    }

    /// Self-check: prove the census FIRES on a planted offender — a second
    /// column reaching the bracket with the inside verb. A census of a REQUIRED
    /// token is exactly the shape that can pass while blind, so it is measured
    /// rather than assumed.
    func test_canvasUndoBracketCensusFiresOnAPlantedInsideVerb() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-canvas-bracket-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct RegionInspector {
            let model: CanvasModel
            func commitLabel(_ new: String) { model.mutateFromInspector("Rename") { _ in } }
        }
        """.write(to: tmp.appendingPathComponent("RegionInspector.swift"),
                  atomically: true, encoding: .utf8)
        try """
        /// A doc comment naming model.mutate( must not count as a call.
        struct CanvasMenuCommands {
            let model: CanvasModel
            func tidy() {
                model.mutate("Tidy") { _ in }   // the planted offender
            }
        }
        """.write(to: tmp.appendingPathComponent("CanvasMenuCommands.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct CanvasQuickAdd {
            let model: CanvasModel
            func add() {
                // The worse offender: no bracket AT ALL, not even a nested one.
                model.withScene { $0.insert(node) }
            }
        }
        """.write(to: tmp.appendingPathComponent("CanvasQuickAdd.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct Unrelated {
            let model: CanvasModel
            func go() { TreeWalk.mutate(id: id, in: items) { _ in } }
        }
        """.write(to: tmp.appendingPathComponent("Unrelated.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct CanvasSweepCommands {
            let model: CanvasModel
            func finish() {
                // The verb the census could not see until slice 3's fix round:
                // ONLY renameGesture, so the file's verb set was empty and it
                // never entered the dictionary at all.
                model.renameGesture("Bind Region")
            }
        }
        """.write(to: tmp.appendingPathComponent("CanvasSweepCommands.swift"),
                  atomically: true, encoding: .utf8)

        // The surface is skipped by PATH: the real one (`Canvas/CanvasView.swift`)
        // is exempt, a same-named file in another folder is not. Each in a tree
        // of its own, because the census keys by basename.
        for (folder, expected) in [("Canvas", nil), ("Views", ["mutate"])] as [(String, [String]?)] {
            let tree = tmp.deletingLastPathComponent()
                .appendingPathComponent("tripwire-canvas-surface-path-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tree) }
            let dir = tree.appendingPathComponent(folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try """
            struct CanvasView {
                let model: CanvasModel
                func tidy() { model.mutate("Tidy") { _ in } }
            }
            """.write(to: dir.appendingPathComponent("CanvasView.swift"),
                      atomically: true, encoding: .utf8)
            XCTAssertEqual(try canvasBracketCensus(in: tree)["CanvasView.swift"], expected,
                "Self-check: only `Canvas/CanvasView.swift` is the surface; a "
                + "`CanvasView.swift` under \(folder)/ must \(expected == nil ? "be skipped" : "be censused").")
        }

        let census = try canvasBracketCensus(in: tmp)
        XCTAssertEqual(census["CanvasSweepCommands.swift"], ["renameGesture"],
            "Self-check: a file whose ONLY bracket verb is `renameGesture` must "
            + "enter the census. A verb missing from `canvasInsideVerbs` produces "
            + "an empty set, and an empty set is dropped rather than reported — "
            + "so the offender passes and looks exactly like a file that never "
            + "touched the bracket.")
        XCTAssertEqual(census["CanvasMenuCommands.swift"], ["mutate"],
            "Self-check: the planted inside-verb call site should be caught.")
        XCTAssertEqual(census["RegionInspector.swift"], [Self.canvasOutsideVerb],
            "Self-check: the sanctioned outside verb is still recorded.")
        XCTAssertEqual(census["CanvasQuickAdd.swift"], ["withScene"],
            "Self-check: a surface that mutates the scene with NO bracket at all "
            + "is the worst case this census exists for, and is exactly what a "
            + "census of `.mutate(` alone would record as nothing.")
        XCTAssertNil(census["Unrelated.swift"],
            "Self-check: `TreeWalk.mutate(` is a static call on another type and "
            + "must not be swept in — even though this file names CanvasModel, "
            + "which is the only pre-filter.")
    }

    // MARK: - load()'s closures read no changing view value (tripwire 57, #59)

    /// **A closure `CanvasView.load()` hands the model never reads a plain
    /// stored property of the view** — directly, or through any method or
    /// computed property of the view it calls.
    ///
    /// `CanvasView` is a struct. The closures `load()` stores on `CanvasModel`
    /// (`beforeFlush`, `onSceneChangedExternally`, `onSceneReplacedByUndo`,
    /// `onRevealRequested`, and whatever joins them) capture the view VALUE at
    /// first appear, while `ProjectWindow` goes on constructing fresh views. A
    /// `@State` read survives that (its storage is shared); a plain `let`/`var`
    /// does not — it is frozen at the value the canvas first appeared with.
    /// #57 shipped exactly that with `itemIndex`, and **it was reached
    /// transitively**: the closures called `rebuildLayouts`, and
    /// `rebuildLayouts` read the index. So this walks the call graph from each
    /// closure through the view's own members, not just the closure's text.
    ///
    /// Allowed: `@State` storage, and `canvasLoadClosureAllowedReads` — the
    /// model (a reference) and the two values that cannot change under one
    /// window. A value the closures need that DOES change goes on the model,
    /// the way `CanvasModel.itemIndex` did.
    func test_theCanvasLoadClosuresReadNoChangingViewValue() throws {
        let url = sourceDir.appendingPathComponent("Canvas/\(Self.theCanvasViewFile)")
        let census = try Self.canvasLoadClosureCensus(of: try String(contentsOf: url, encoding: .utf8),
                                                      extensions: try canvasViewExtensionSources())

        // Loud on a parse that has drifted: these are the four #57 named, and
        // the three plain properties the issue's fix shape names. A census that
        // found none of them is reading the wrong text, not proving anything.
        for callback in ["beforeFlush", "onSceneChangedExternally", "onSceneReplacedByUndo", "onRevealRequested"] {
            XCTAssertTrue(census.callbacks.contains(callback),
                "The census no longer finds `model.\(callback) = { … }` in `CanvasView.load()`. "
                + "If it moved or was renamed, update this list; if the parser stopped "
                + "seeing it, fix the parser — a blind census passes. Found: \(census.callbacks)")
        }
        for name in ["itemIndex", "subject", "pieceTitles"] {
            XCTAssertTrue(census.forbidden.contains(name),
                "The census no longer derives `\(name)` as a plain stored property of "
                + "`CanvasView`. Found: \(census.forbidden.sorted())")
        }
        // #57's path runs through `rebuildLayouts`, which now lives on
        // `CanvasLayoutPass`; the walk reaches the view member that BUILDS the
        // pass, and that property is where the pass's inputs are read.
        XCTAssertTrue(census.reachedMembers.contains("layoutPass"),
            "The walk no longer reaches `layoutPass` from the closures — #57's "
            + "path, through the property that builds `CanvasLayoutPass`. Either "
            + "the closures stopped calling it, or the walk went blind.")

        XCTAssertEqual(census.offenders, [],
            "A closure `CanvasView.load()` hands `CanvasModel` reads a plain stored "
            + "property of the view (tripwire 57). The closure captured the view "
            + "VALUE at first appear, so that read is frozen at whatever the canvas "
            + "first appeared with while `ProjectWindow` hands down newer views — "
            + "issue #57's bug, where `itemIndex` went stale through "
            + "`rebuildLayouts`. Put a copy on the model (as `CanvasModel.itemIndex` "
            + "does) and keep it current from a per-body `.onChange`, or make it "
            + "`@State`. Offending paths:\n" + census.offenders.joined(separator: "\n"))
    }

    /// Every other file under `Maugham/` that extends `CanvasView`, comments
    /// stripped before the test: a method declared in one is a member the walk
    /// must follow, and a split of the 2,000-line file is the likeliest way one
    /// appears. (`CanvasView.swift`'s own extensions are read from its text.)
    private func canvasViewExtensionSources() throws -> [String] {
        guard let walker = FileManager.default.enumerator(at: sourceDir, includingPropertiesForKeys: nil)
        else { return [] }
        var sources: [String] = []
        for case let url as URL in walker
        where url.pathExtension == "swift" && url.lastPathComponent != Self.theCanvasViewFile {
            let text = try String(contentsOf: url, encoding: .utf8)
            if Self.codeLines(of: text).contains(where: { $0.contains("extension CanvasView") }) {
                sources.append(text)
            }
        }
        return sources
    }

    /// Self-check: the census FIRES on a planted offender — directly, through a
    /// method, through a computed property, through a method in an extension
    /// (this file's or another's), through a hook assigned a method reference,
    /// as a stored closure property assigned whole, and as a value handed to a
    /// helper built in a computed property (`pass`) — and stays quiet on `@State`,
    /// a `$` projection,
    /// the `itemIndex` value copy,
    /// the allowed names, member access on something else, labels and comments.
    /// It also refuses (throws) when it cannot find `load()` or its closures.
    func test_canvasLoadClosureCensusFiresOnAPlantedOffender() throws {
        let planted = """
        @MainActor
        struct CanvasView: View {
            let model: CanvasModel
            let projectRoot: URL
            var subject: CanvasSubject = .wholeProject
            var pieceTitles: CanvasPieceTitles = .empty
            var itemIndex: CanvasItemIndex = .empty
            var selectTheProjectRow: () -> Void = {}
            @State private var camera = CanvasCamera()
            @State private var thumbnails = CanvasThumbnails()
            private var currentTitle: String { pieceTitles.first }
            var body: some View { Text("{ subject }") }
            private func load() {
                model.itemIndex = itemIndex
                model.beforeFlush = { rebuild(subject: 1) }
                model.onSceneChangedExternally = {
                    // pieceTitles named in a comment is not a read
                    camera.stop(); _ = model.subject; _ = projectRoot; _ = thumbnails
                }
                model.onRevealRequested = { target in self.selectTheProjectRow() }
                model.onSceneReplacedByUndo = { tidy() }
                model.onTick = tick
                model.onLater = self.later
                model.onHook = selectTheProjectRow
            }
            private func rebuild(subject: Int) { _ = self.itemIndex }
            private func tidy() { _ = currentTitle }
            private func later() { helper() }
        }
        extension CanvasView {
            func helper() { _ = pieceTitles }
        }
        """
        let elsewhere = """
        extension CanvasView {
            func tick() { _ = subject }
        }
        extension CanvasView.Inner {
            func unrelated() { _ = itemIndex }
        }
        """
        let census = try Self.canvasLoadClosureCensus(of: planted, extensions: [elsewhere])
        XCTAssertEqual(census.callbacks.sorted(),
                       ["beforeFlush", "onHook", "onLater", "onRevealRequested", "onSceneChangedExternally",
                        "onSceneReplacedByUndo", "onTick"],
            "Self-check: every `model.<callback> = {`, every hook assigned a view "
            + "method and every hook assigned a stored closure property is found, "
            + "and the allow-listed `model.itemIndex = itemIndex` value copy is not "
            + "a capture.")
        XCTAssertEqual(Set(census.forbidden),
                       ["subject", "pieceTitles", "itemIndex", "selectTheProjectRow"],
            "Self-check: the forbidden list is derived from the source — plain "
            + "stored properties, minus `@State`, minus the allowed names, and "
            + "never a computed property.")
        XCTAssertEqual(census.offenders.sorted(), [
            "beforeFlush → rebuild → itemIndex",
            "onHook → selectTheProjectRow",
            "onLater → later → helper → pieceTitles",
            "onRevealRequested → selectTheProjectRow",
            "onSceneReplacedByUndo → tidy → currentTitle → pieceTitles",
            "onTick → tick → subject",
        ], "Self-check: a read through `self.`, through a method (#57's shape), "
            + "through a computed property, through an extension in the same file "
            + "or another, through a method-reference hook and a stored closure "
            + "assigned whole are each caught; "
            + "`@State`, the allowed names, `model.subject`, an argument label, a "
            + "comment and a nested type's extension are not.")

        // The allow-list itself, not `@State`, is what excuses `thumbnails`:
        // declared as a plain `let` here, reading it is still no offender.
        let plainThumbnails = try Self.canvasLoadClosureCensus(of: """
            struct CanvasView: View {
                let model: CanvasModel
                let thumbnails: CanvasThumbnails
                var subject: CanvasSubject = .wholeProject
                private func load() { model.beforeFlush = { _ = thumbnails } }
            }
            """)
        XCTAssertEqual(plainThumbnails.forbidden, ["subject"],
            "Self-check: a plain `thumbnails` is excused by the allow-list.")
        XCTAssertEqual(plainThumbnails.offenders, [],
            "Self-check: reading an allow-listed plain property is no offender.")

        // #57 itself, replayed on the real file: hand the layout pass the view's
        // own index instead of the model's, and both scene callbacks must be
        // named. Measured against c64ae740^ too (then through `rebuildLayouts`,
        // a view method), which reported exactly these two paths.
        let url = sourceDir.appendingPathComponent("Canvas/\(Self.theCanvasViewFile)")
        let real = try String(contentsOf: url, encoding: .utf8)
        let fix = "itemIndex: model.itemIndex,"
        XCTAssertTrue(real.contains(fix),
            "Self-check: `CanvasView.layoutPass` no longer spells `\(fix)`; re-point "
            + "this replay at wherever the model's index is handed in now.")
        let reverted = try Self.canvasLoadClosureCensus(
            of: real.replacingOccurrences(of: fix, with: "itemIndex: itemIndex,"),
            extensions: try canvasViewExtensionSources())
        XCTAssertEqual(reverted.offenders, [
            "onSceneChangedExternally → layoutPass → itemIndex",
            "onSceneReplacedByUndo → layoutPass → itemIndex",
        ], "Self-check: undoing #57's fix in the real file must fire the census.")

        // A surface helper built in a view computed property: the walk follows
        // the property, so a changing view value handed in is read THERE and is
        // caught, while a `$layouts` projection and the argument labels are not
        // reads. `layouts` is declared plain here on purpose, so the projection
        // is skipped for being a projection and not for being `@State`.
        let helper = try Self.canvasLoadClosureCensus(of: """
            struct CanvasView: View {
                let model: CanvasModel
                var itemIndex: CanvasItemIndex = .empty
                var layouts: [CanvasNodeID: ScrapLayout] = [:]
                private var pass: P { P(index: itemIndex, layouts: $layouts) }
                private func load() { model.onSceneChangedExternally = { pass.rebuild() } }
            }
            """)
        XCTAssertEqual(Set(helper.forbidden), ["itemIndex", "layouts"],
            "Self-check: both plain properties are forbidden, so only the walk's "
            + "own rules can excuse `$layouts`.")
        XCTAssertEqual(helper.offenders, ["onSceneChangedExternally → pass → itemIndex"],
            "Self-check: a helper built with a frozen view value must fire on "
            + "`itemIndex`, and never on the `$layouts` projection.")

        XCTAssertThrowsError(try Self.canvasLoadClosureCensus(of: """
            struct CanvasView: View { let model: CanvasModel; private func appear() {} }
            """), "Self-check: no `load()` must throw, not pass.")
        XCTAssertThrowsError(try Self.canvasLoadClosureCensus(of: """
            struct CanvasView: View {
                let model: CanvasModel
                private func load() { model.attach() }
            }
            """), "Self-check: a `load()` with no closures must throw, not pass.")
        XCTAssertThrowsError(try Self.canvasLoadClosureCensus(of: "struct Other {}"),
            "Self-check: no `CanvasView` must throw, not pass.")
    }

    /// Plain stored properties of `CanvasView` a closure from `load()` MAY read:
    /// the model is a reference the stale closures still reach, and the project
    /// root and the thumbnail cache (`@State` today, named in case that
    /// changes) are the same object for the life of one window's canvas.
    private static let canvasLoadClosureAllowedReads: Set<String> = ["model", "projectRoot", "thumbnails"]

    /// Plain stored properties `load()` may assign to the model directly
    /// (`model.x = name`), because the assignment is a VALUE copy made now and
    /// kept current elsewhere — `itemIndex`, which the body's `.onChange`
    /// re-copies. Any other forbidden name assigned whole is a stored closure
    /// (or a value nobody refreshes) handed over frozen, and is an offender.
    private static let canvasLoadValueCopies: Set<String> = ["itemIndex"]

    private struct CanvasLoadClosureCensusFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// The census itself. Over comment- and string-stripped source it:
    /// 1. finds `struct CanvasView`'s body and its top-level members — stored
    ///    properties (with their attributes), functions and computed properties;
    /// 2. finds `func load()` and every `model.<name> = { … }` in it;
    /// 3. walks each closure's identifiers, following any that name a view
    ///    method or computed property into that member's body, and records
    ///    every identifier that names a plain stored property outside the
    ///    allowed set, as `callback → member → … → property`.
    /// Members come from the struct body and from every `extension CanvasView`
    /// (not `CanvasView.Nested`) in `text` and in `extensions`. A hook assigned
    /// a view method (`model.x = someMethod`) is walked like a closure, and one
    /// assigned a forbidden stored property outside `canvasLoadValueCopies` is
    /// itself an offender.
    /// It throws when it cannot find the struct, `load()` or a single closure.
    private static func canvasLoadClosureCensus(of text: String, extensions: [String] = []) throws
        -> (callbacks: [String], forbidden: [String], reachedMembers: Set<String>, offenders: [String]) {
        let fail = { (why: String) in CanvasLoadClosureCensusFailure(description: why) }
        func stripped(_ text: String) -> [Character] {
            Array(SourceScan.codeLines(of: text).map(strippingStringLiterals).joined(separator: "\n"))
        }
        func matchingBrace(_ open: Int, in chars: [Character]) -> Int? {
            var depth = 0
            for i in open..<chars.count {
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1; if depth == 0 { return i } }
            }
            return nil
        }
        func firstMatch(_ pattern: String, in s: String) -> NSTextCheckingResult? {
            (try? NSRegularExpression(pattern: pattern))?
                .firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        }
        func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
        /// The `{` offsets of every declaration of `CanvasView` matching `pattern` in `chars`.
        func openings(_ pattern: String, in chars: [Character]) throws -> [Int] {
            let code = String(chars)
            return try NSRegularExpression(pattern: pattern)
                .matches(in: code, range: NSRange(code.startIndex..., in: code))
                .compactMap { Range($0.range, in: code) }
                .map { code.distance(from: code.startIndex, to: $0.upperBound) - 1 }
        }

        // Top-level members of a body: a line that starts directly inside its braces.
        var stored: [(name: String, isState: Bool)] = []
        var memberBodies: [String: [String]] = [:]
        func collectMembers(of chars: [Character], open: Int, close: Int) {
            func memberLine(_ start: Int, _ end: Int) {
                let line = String(chars[start..<end])
                let pattern = #"^\s*((?:@\w+(?:\([^)]*\))?\s+)*)((?:(?:private|fileprivate|internal|public|nonisolated|static|lazy|weak|final|override|mutating)(?:\(set\))?\s+)*)(func|let|var)\s+([A-Za-z_]\w*)(.*)$"#
                guard let m = firstMatch(pattern, in: line),
                      let attributes = group(m, 1, in: line),
                      let modifiers = group(m, 2, in: line),
                      let keyword = group(m, 3, in: line),
                      let name = group(m, 4, in: line),
                      let rest = group(m, 5, in: line),
                      !modifiers.contains("static") else { return }
                let beforeBrace = rest.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let isComputed = keyword == "var" && rest.contains("{") && !beforeBrace.contains("=")
                if keyword == "func" || isComputed {
                    // The member's body: the first `{` at member depth after its name.
                    var i = start + (line.range(of: name).map { line.distance(from: line.startIndex, to: $0.upperBound) } ?? 0)
                    var d = 0
                    while i < close {
                        if chars[i] == "(" { d += 1 } else if chars[i] == ")" { d -= 1 }
                        if chars[i] == "{" && d == 0 { break }
                        i += 1
                    }
                    if i < close, let end = matchingBrace(i, in: chars) {
                        memberBodies[name, default: []].append(String(chars[(i + 1)..<end]))
                    }
                } else {
                    stored.append((name, attributes.contains("@State")))
                }
            }
            var depth = 0
            var lineStart = open + 1
            var lineStartDepth = 0
            for i in (open + 1)..<close {
                if chars[i] == "\n" {
                    if lineStartDepth == 0 { memberLine(lineStart, i) }
                    lineStart = i + 1
                    lineStartDepth = depth
                }
                if chars[i] == "{" { depth += 1 } else if chars[i] == "}" { depth -= 1 }
            }
            // A body closed on its last member's line has no newline before `}`.
            if lineStartDepth == 0, lineStart < close { memberLine(lineStart, close) }
        }

        let chars = stripped(text)
        guard let structOpen = try openings(#"\bstruct\s+CanvasView\b[^{]*\{"#, in: chars).first
        else { throw fail("`struct CanvasView` not found") }
        guard let structClose = matchingBrace(structOpen, in: chars)
        else { throw fail("`struct CanvasView`'s closing brace not found") }
        collectMembers(of: chars, open: structOpen, close: structClose)
        // Every `extension CanvasView` — in this file or any other handed in —
        // is more of the same struct: a method there is one more place a
        // closure's walk must be able to follow.
        for source in [chars] + extensions.map(stripped) {
            for open in try openings(#"\bextension\s+CanvasView\b(?!\.)[^{]*\{"#, in: source) {
                guard let close = matchingBrace(open, in: source)
                else { throw fail("an `extension CanvasView` never closes") }
                collectMembers(of: source, open: open, close: close)
            }
        }

        guard let loads = memberBodies["load"], loads.count == 1, let load = loads.first
        else { throw fail("`CanvasView.load()` not found exactly once (found \(memberBodies["load"]?.count ?? 0))") }

        // Every `model.<callback> = {` in load(), with its body.
        var closures: [(callback: String, body: String)] = []
        let loadChars = Array(load)
        let assignment = try NSRegularExpression(pattern: #"\bmodel\.([A-Za-z_]\w*)\s*=\s*\{"#)
        for m in assignment.matches(in: load, range: NSRange(load.startIndex..., in: load)) {
            guard let callback = group(m, 1, in: load),
                  let whole = Range(m.range, in: load) else { continue }
            let open = load.distance(from: load.startIndex, to: whole.upperBound) - 1
            var d = 0
            var close: Int?
            for i in open..<loadChars.count {
                if loadChars[i] == "{" { d += 1 }
                if loadChars[i] == "}" { d -= 1; if d == 0 { close = i; break } }
            }
            guard let close else { throw fail("`model.\(callback) = {` in `load()` never closes") }
            closures.append((callback, String(loadChars[(open + 1)..<close])))
        }
        guard !closures.isEmpty
        else { throw fail("no `model.<callback> = { … }` found in `CanvasView.load()`") }

        let forbidden = Set(stored.filter { !$0.isState }.map(\.name))
            .subtracting(canvasLoadClosureAllowedReads)

        // `model.<hook> = someViewMethod` captures the view exactly as a closure
        // does; the "body" walked is the bare name, which the walk below then
        // follows. So does `model.<hook> = someStoredClosure` — a plain stored
        // property handed over whole is frozen at first appear just as a read
        // inside a closure is — and its bare name is then itself the offender.
        // A value copy (`model.itemIndex = itemIndex`, refreshed from the body
        // on change) is made now, not captured, and is excused by name alone:
        // `canvasLoadValueCopies`.
        let reference = try NSRegularExpression(
            pattern: #"\bmodel\.([A-Za-z_]\w*)\s*=\s*(?:self\.)?([A-Za-z_]\w*)\b(?!\s*[.(\[?!])"#)
        for m in reference.matches(in: load, range: NSRange(load.startIndex..., in: load)) {
            guard let callback = group(m, 1, in: load), let target = group(m, 2, in: load),
                  memberBodies[target] != nil
                    || (forbidden.contains(target) && !canvasLoadValueCopies.contains(target))
            else { continue }
            closures.append((callback, target))
        }
        // An identifier that is not a member access (`model.subject`), not a
        // binding projection (`$camera`), and not an argument label (`subject:`).
        let identifier = try NSRegularExpression(pattern: #"(?<![.\w$])([A-Za-z_]\w*)(?![\w:])"#)
        func names(in body: String) -> [String] {
            let body = body.replacingOccurrences(of: "self.", with: "")
            return identifier.matches(in: body, range: NSRange(body.startIndex..., in: body))
                .compactMap { group($0, 1, in: body) }
        }

        var offenders: Set<String> = []
        var reached: Set<String> = []
        for (callback, body) in closures {
            var visited: Set<String> = []
            var queue: [(body: String, path: [String])] = [(body, [callback])]
            while !queue.isEmpty {
                let (current, path) = queue.removeFirst()
                for name in names(in: current) {
                    if forbidden.contains(name) {
                        offenders.insert((path + [name]).joined(separator: " → "))
                    } else if let bodies = memberBodies[name], name != "load", visited.insert(name).inserted {
                        reached.insert(name)
                        for b in bodies { queue.append((b, path + [name])) }
                    }
                }
            }
        }
        return (closures.map(\.callback), forbidden.sorted(), reached, offenders.sorted())
    }

    // MARK: - The canvas's asset well has exactly one writer (1C-d Task 2)

    /// The shared image saver. A seam that owns a `<slug>_assets/` well of its
    /// own may call it; any other caller is one more answer to "where does a
    /// dropped image live", which is the decision this seam exists to make once.
    private static let imageSaverCall = "ImagePasteHandler.saveAndReference"

    /// **Count the set, not this comment.** Each entry is a seam that owns a
    /// well of its own, and each line says which well:
    ///
    /// - `ProjectStore+Palette.swift` — a palette card's images.
    /// - `ResearchNoteEditor.swift` — an image pasted into a research note.
    /// - `ProjectStore+CanvasAssets.swift` — the canvas's ingestion pair,
    ///   `canvas_assets/`.
    /// - `ProjectStore+StatementAssets.swift` (M1A Task 12) — a statement's own
    ///   well, `visual-language_assets/` for the one statement kind that holds
    ///   pictures. It is a seam rather than a caller of one of the others
    ///   because a statement is its own file: routing its pictures into
    ///   `canvas_assets/` or a palette card's well would put them beside a
    ///   document they do not belong to, and the well's name is derived from
    ///   `Statement.path` exactly as the canvas's is from
    ///   `CanvasStore.scrapsRelativePath`.
    ///
    /// 1C-d's drop, browser-bitmap and inbox routes are all *callers* of the
    /// canvas pair; none of them is an entry here.
    private static let imageSaverCallers: Set<String> = [
        "ProjectStore+Palette.swift",
        "ResearchNoteEditor.swift",
        "ProjectStore+CanvasAssets.swift",
        "ProjectStore+StatementAssets.swift",
    ]

    /// Which production files call the shared saver, comments excluded.
    private func imageSaverCallSites(in dir: URL) throws -> Set<String> {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var callers: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard url.lastPathComponent != "ImagePasteHandler.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if Self.codeLines(of: text).contains(where: { $0.contains(Self.imageSaverCall) }) {
                callers.insert(url.lastPathComponent)
            }
        }
        return callers
    }

    /// **Census, not a ban.** An equality against a non-empty expected set is
    /// its own control: a pattern that matched nothing would fail here rather
    /// than pass quietly, which is the failure mode a bare `isEmpty` census has.
    ///
    /// The defect it exists for is the one 1C-d's remaining tasks are each one
    /// keystroke away from. Task 10 (research drag), Task 11 (Finder and
    /// browser drops) and Task 12 (inbox → canvas) all need an image on disk,
    /// and the two-line palette call above is the obvious thing to copy. Copied,
    /// it puts the photograph in a second place — and "where an ingested image
    /// lives" then has as many answers as there are routes, none of which the
    /// writer can see until a project is moved and half the cards are blank.
    func test_theSharedImageSaverIsCalledFromTheSeamsThatOwnAWell() throws {
        XCTAssertEqual(try imageSaverCallSites(in: sourceDir), Self.imageSaverCallers,
            "The set of files calling \(Self.imageSaverCall) changed. If this is a "
            + "canvas route (a drop, a browser bitmap, an inbox promotion), call "
            + "ProjectStore.ingestCanvasAsset(image:)/(fileURL:) instead — the canvas "
            + "decides where its images land in ONE place, and every route is a "
            + "caller of that pair. If it is genuinely a new seam with a well of its "
            + "own, add it to imageSaverCallers with a line saying which well.")
    }

    /// The well's name is **derived**, never spelled: `ImagePasteHandler`
    /// builds `<slug>_assets` from `canvas.md`'s own filename, so
    /// `canvas_assets/` falls out of `CanvasStore.scrapsRelativePath` with no
    /// literal anywhere in production code. A hand-built
    /// `appendingPathComponent("canvas_assets")` is the reach-around that
    /// bypasses the pair without ever naming it — and it would keep working
    /// right up until `canvas.md` moves, at which point the well and the file
    /// it belongs to part company silently.
    func test_theCanvasAssetWellIsDerivedAndNeverSpelledInCode() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["canvas_assets"],
            excludeLine: { Self.isCommentLine($0) }
        )
        XCTAssertTrue(offenders.isEmpty,
            "`canvas_assets` is spelled in production code. The well's name is derived "
            + "from CanvasStore.scrapsRelativePath by ImagePasteHandler; build a path "
            + "into it by calling ProjectStore.ingestCanvasAsset instead. Offenders:\n"
            + offenders.joined(separator: "\n"))

        // Control: the SAME grep without the comment exclusion finds the doc
        // comments that discuss the well. Without this, a typo in the pattern
        // would leave the assertion above passing on a tree it never read.
        XCTAssertFalse(try grepSwift(in: sourceDir, patterns: ["canvas_assets"]).isEmpty,
            "Control: the pattern should still match the doc comments that name the "
            + "well (CanvasItemReference, CanvasNode, CanvasRenderer). If it matches "
            + "nothing at all, the tripwire above is reading an empty tree.")
    }

    /// Self-check: both halves FIRE on planted offenders. A ban that never
    /// matches and a census that reads nothing look identical from the outside.
    func test_canvasAssetWellTripwiresFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-canvas-assets-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct CanvasDropTarget {
            /// A doc comment naming canvas_assets/ must NOT count.
            func drop(_ image: NSImage, in projectURL: URL) throws {
                let well = projectURL.appendingPathComponent("canvas_assets")
                _ = try ImagePasteHandler.saveAndReference(
                    image: image, forNoteAt: "canvas.md", in: projectURL)
                _ = well
            }
        }
        """.write(to: tmp.appendingPathComponent("CanvasDropTarget.swift"),
                  atomically: true, encoding: .utf8)

        let literalOffenders = try grepSwift(
            in: tmp, patterns: ["canvas_assets"], excludeLine: { Self.isCommentLine($0) })
        XCTAssertEqual(literalOffenders.count, 1,
            "Self-check: exactly the hand-built path should be caught — the doc "
            + "comment above it must not be. Offenders:\n"
            + literalOffenders.joined(separator: "\n"))

        XCTAssertEqual(try imageSaverCallSites(in: tmp), ["CanvasDropTarget.swift"],
            "Self-check: a planted extra caller of the shared saver should be "
            + "recorded by the census.")
    }

    // MARK: - The canvas's external drop takes the provider route (1C-d Task 11)

    /// The only route that lands a browser's image drag.
    private static let providerDropToken = ".onDrop(of: [.fileURL, .image]"

    /// The route that looks equivalent, compiles, reads correctly and **silently
    /// rejects every browser image drag** — CoreTransferable fails with error 0:
    /// nothing logged, nothing red, nothing on screen. A browser drags a
    /// *rendered bitmap* and no file URL, so `URL.self` matches nothing on the
    /// pasteboard.
    private static let forbiddenDropToken = "dropDestination(for: URL"

    /// Which files under `Maugham/Canvas/` name a token, comments excluded.
    private func canvasFilesNaming(_ token: String) throws -> Set<String> {
        try filesNaming(token, under: sourceDir.appendingPathComponent("Canvas", isDirectory: true))
    }

    private func filesNaming(_ token: String, under dir: URL) throws -> Set<String> {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var hits: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if Self.codeLines(of: text).contains(where: { $0.contains(token) }) {
                hits.insert(url.lastPathComponent)
            }
        }
        return hits
    }

    /// **Census over a required token plus a ban over a forbidden one**, because
    /// the failure is not a crash but a gesture that stops working.
    ///
    /// The external half of the canvas's drop target has to be `[.fileURL,
    /// .image]` providers routed through `DropClassification`: a browser image
    /// drag carries a rendered bitmap rather than a file URL, so a
    /// `.dropDestination(for: URL.self)` written in its place accepts the Finder
    /// drag, rejects the browser one, and reports nothing at all about it. That is
    /// this task's named failure, and no runtime test in this repo can see it —
    /// SwiftUI's drop delivery has no seam a test can post a drag session into,
    /// which is why Task 10's mount is censused too.
    ///
    /// **Count the set, not this comment.** A second canvas surface that grows a
    /// file-or-image drop belongs in the expected set with a line saying why.
    func test_theCanvasExternalDropUsesTheProviderRouteAndNeverAUrlDestination() throws {
        XCTAssertEqual(try canvasFilesNaming(Self.providerDropToken), ["CanvasView.swift"],
            "`\(Self.providerDropToken)` is the canvas's external drop target. If it "
            + "vanished, a photograph dragged from the Finder or a browser now lands "
            + "nowhere; if a second file grew one, add it here with its reason.")

        XCTAssertTrue(try canvasFilesNaming(Self.forbiddenDropToken).isEmpty,
            "`\(Self.forbiddenDropToken)` is in Maugham/Canvas/. A browser image drag "
            + "carries a rendered bitmap and no file URL, so that modifier rejects it "
            + "with CoreTransferable error 0 — nothing logged, nothing red, nothing on "
            + "screen. Route through [.fileURL, .image] providers and "
            + "DropClassification instead.")

        // Control: the scan really is reading a live tree. Task 10's internal
        // drag uses `String.self` and is expected to be there — if THIS finds
        // nothing, the two assertions above are a search over an empty directory.
        XCTAssertEqual(try canvasFilesNaming(".dropDestination(for: String.self)"),
                       ["CanvasView.swift"],
            "Control: the internal research drag's modifier should still be found. "
            + "If it is not, this census is reading nothing.")
    }

    /// Self-check: both halves fire on planted offenders, and neither counts a
    /// doc comment. A ban that never matches and a census that reads nothing look
    /// identical from the outside.
    func test_theCanvasDropRouteTripwiresFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-canvas-drop-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct PlantedCanvas: View {
            var body: some View {
                Color.clear
                    // A doc comment naming .dropDestination(for: URL.self) must NOT count.
                    .dropDestination(for: URL.self) { urls, _ in true }
            }
        }
        """.write(to: tmp.appendingPathComponent("PlantedCanvas.swift"),
                  atomically: true, encoding: .utf8)

        XCTAssertEqual(try filesNaming(Self.forbiddenDropToken, under: tmp),
                       ["PlantedCanvas.swift"],
            "Self-check: the planted URL destination should be caught.")
        XCTAssertTrue(try filesNaming(Self.providerDropToken, under: tmp).isEmpty,
            "Self-check: a tree with no provider-route drop should census as empty — "
            + "which is what the real assertion above would look like if the modifier "
            + "were deleted from CanvasView.")

        try """
        // .onDrop(of: [.fileURL, .image], isTargeted: nil) named in a comment.
        struct CommentOnly: View { var body: some View { Color.clear } }
        """.write(to: tmp.appendingPathComponent("CommentOnly.swift"),
                  atomically: true, encoding: .utf8)
        XCTAssertTrue(try filesNaming(Self.providerDropToken, under: tmp).isEmpty,
            "Self-check: a comment naming the token must not satisfy the census — "
            + "otherwise a file that only DISCUSSES the route would pass for one "
            + "that mounts it.")
    }

    // MARK: - Where both drop kinds meet, the string one goes first (1C-d Task 11)

    private static let stringDropToken = ".dropDestination(for: String.self)"

    /// Where `token` first appears in the **code** of `text`, as an index into
    /// its code lines, or nil if it never does. Comments are excluded because
    /// every file in this census discusses both tokens at length in the prose
    /// above them.
    private func firstCodeLine(of token: String, in text: String) -> Int? {
        SourceScan.codeLines(of: text).firstIndex { $0.contains(token) }
    }

    /// **Every view that mounts BOTH a `String` drop destination and a provider
    /// `.onDrop` must mount the string one FIRST.** Name the members; a count
    /// would be a prose count.
    ///
    /// - `Maugham/Canvas/CanvasView.swift` — the canvas's internal research drag
    ///   and its external photograph drop.
    /// - `Maugham/Views/ResearchRow.swift` — has always had it right, and is the
    ///   only member whose order was ever validated by use.
    /// - `Maugham/Views/BinderTreeSections.swift`, `BinderRow.swift`,
    ///   `PieceRow.swift` — the tree's own three, as of stage-2b Task 4. The
    ///   milestone deleted `ResearchView` and `CollectionResearchPane`, so the
    ///   external-drop capability moved onto the tree's targets; **the census's
    ///   guarantee had to move with it**, which is why these were listed here in
    ///   the same task that mounted them rather than after the next smoke found
    ///   the reversed order by hand. `CollectionResearchPane` was a member for
    ///   as long as it existed — it carried the pairing **twice**
    ///   (`sharedSection`, `pieceSection`), and this census only sees the first
    ///   of each token, which is why the swap had to be made in both — and left
    ///   the set when Task 7 deleted it.
    private static let bothDropKinds: Set<String> = [
        "BinderRow.swift",
        "BinderTreeSections.swift",
        "CanvasView.swift",
        "PieceRow.swift",
        "ResearchRow.swift",
    ]

    /// Which files under `dir` name **both** drop tokens in code.
    private func filesMountingBothDropKinds(under dir: URL) throws -> Set<String> {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var hits: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if firstCodeLine(of: Self.stringDropToken, in: text) != nil,
               firstCodeLine(of: Self.providerDropToken, in: text) != nil {
                hits.insert(url.lastPathComponent)
            }
        }
        return hits
    }

    /// **`.dropDestination(for: String.self)` must be mounted BEFORE
    /// `.onDrop(of: [.fileURL, .image])`, and the other way round is a shipped
    /// bug rather than a style question.**
    ///
    /// `.onDrop(of:)` claims a drag session **on hover, before any payload is
    /// examined**, so a string destination mounted after it is never offered the
    /// drop. That is not deduced — it is what two smokes found. On the canvas: a
    /// Finder photograph landed while a research drag and an inbox drag did
    /// nothing whatever, with the Inbox's "Send to Canvas" *command* working
    /// throughout, which is what identified the modifiers rather than the
    /// routers. In a Collection, one task later: *"I can't drag into the space
    /// between lines but can onto either line"* — the same defect, latent for as
    /// long as it shipped because every row carries a destination of its own
    /// nested inside the dead one.
    ///
    /// **The evidence lesson, recorded because it was got wrong in this task's
    /// own review.** When Task 11 looked for precedent, `CollectionResearchPane`
    /// was read as *supporting* the reversed order — a shipped surface with "an
    /// observed depth rule". It was a second instance of the same bug. The only
    /// validated precedent was `ResearchRow`, whose order is exercised every time
    /// anyone drags anything in the binder. **A shipped surface is not evidence
    /// that its arrangement is correct when the wrong arrangement fails
    /// silently** — and this pairing fails silently by construction.
    ///
    /// **A census rather than a per-file pin**, because the defect has now shipped
    /// twice in one codebase and been argued *for* once on false evidence. It is
    /// also the only instrument available: SwiftUI's drop delivery has no seam a
    /// test can post a session into — the reason both instances reached a smoke —
    /// so every other test in the repo is green under either order.
    ///
    /// **No general depth rule should be read off this.** `ResearchView` and
    /// `PaletteCardEditor` mount the provider `.onDrop` with no typed destination
    /// beside it at all. The *pairing* is what matters, not which kind goes
    /// outermost.
    func test_whereBothDropKindsMeetTheStringDestinationIsMountedFirst() throws {
        XCTAssertEqual(try filesMountingBothDropKinds(under: sourceDir),
                       Self.bothDropKinds,
            "The set of views mounting both drop kinds changed. A new one inherits "
            + "this ordering rule; add it here with its reason, and check the order "
            + "before you do.")

        for file in Self.bothDropKinds.sorted() {
            let url = try XCTUnwrap(
                FileManager.default.enumerator(at: sourceDir, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }
                    .first { $0.lastPathComponent == file },
                "\(file) is named in the census but is not in the tree")
            let text = try String(contentsOf: url, encoding: .utf8)
            // Both tokens must still be there — an ordering check over a token
            // that is absent is satisfied by nothing at all.
            XCTAssertNotNil(firstCodeLine(of: Self.stringDropToken, in: text),
                            "\(file) lost its string drop destination")
            XCTAssertNotNil(firstCodeLine(of: Self.providerDropToken, in: text),
                            "\(file) lost its provider drop")

            XCTAssertEqual(reversedDropPairings(in: text), [],
                "\(file) mounts `.onDrop(of:)` before a string destination in the "
                + "same chain. That modifier claims the drag session on hover, "
                + "before the payload is examined, so the destination behind it "
                + "never sees the drop — an internal drag does nothing at all, "
                + "silently, while an external one still lands. Both shipped "
                + "instances of this were found by a writer, not by a test. "
                + "Offending `.onDrop` at code line(s) "
                + "\(reversedDropPairings(in: text)).")
        }
    }

    /// Code-line indices of every provider `.onDrop` that is followed by a string
    /// destination **in the same modifier chain**.
    ///
    /// **Per chain rather than per file, and that is not fussiness.**
    /// `CollectionResearchPane` carries the pairing **twice** and also has inner
    /// destinations on its rows, its headers and its empty states — the first
    /// string destination in that file sits at the top, before any `.onDrop`, so
    /// a first-index comparison passes there no matter what the section-level
    /// chains do. Reversing only the second pairing would have been invisible to
    /// the check this replaced; caught while writing the disable experiment for
    /// it.
    ///
    /// "Same chain" is same indentation **plus a leading dot**: a modifier's own
    /// closure body is indented further, and the chain ends either when
    /// indentation drops below the modifier's own or when a line at that level
    /// starts something that is not a modifier.
    ///
    /// **Both halves of that predicate were measured, and each was wrong on its
    /// own.** With only the indentation rule the scan walks out of one chain into
    /// the next sibling view's at the same level and reports a correct chain as
    /// an offender (this test's two-chain fixture: two offences over one real
    /// one). With a leading-dot rule alone it stops at the `}` that closes the
    /// previous modifier's closure — which sits at exactly the chain's own indent
    /// — so **no multi-line modifier is ever scanned past**, and the real
    /// reversed pairing in `CollectionResearchPane` went undetected. That second
    /// one was found by running the disable experiment rather than by reading the
    /// scanner, which is the whole reason the experiment is not optional.
    private func reversedDropPairings(in text: String) -> [Int] {
        let lines = SourceScan.codeLines(of: text)
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        var offenders: [Int] = []
        for (i, line) in lines.enumerated() where line.contains(Self.providerDropToken) {
            let level = indent(line)
            var j = i + 1
            while j < lines.count, indent(lines[j]) >= level {
                if indent(lines[j]) == level {
                    let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
                    // `}` closes the previous modifier's closure and the chain
                    // continues through it; anything else at this level is a new
                    // expression and the chain is over.
                    guard trimmed.hasPrefix(".") || trimmed.hasPrefix("}") else { break }
                    if trimmed.contains(Self.stringDropToken) {
                        offenders.append(i)
                        break
                    }
                }
                j += 1
            }
        }
        return offenders
    }

    /// Self-check: the order assertion FAILS on the reversed order, and passes on
    /// the shipped one. A comparison between two indices is exactly the shape that
    /// reads as green when one of the tokens is never found at all.
    func test_theDropModifierOrderCheckFailsOnTheReversedOrder() throws {
        let good = """
        struct Good: View {
            var body: some View {
                Color.clear
                    .dropDestination(for: String.self) { _, _ in true }
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { _, _ in true }
            }
        }
        """
        let bad = """
        struct Bad: View {
            var body: some View {
                Color.clear
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { _, _ in true }
                    .dropDestination(for: String.self) { _, _ in true }
            }
        }
        """
        XCTAssertEqual(reversedDropPairings(in: good), [],
            "Self-check: the shipped order should offend nothing.")
        XCTAssertFalse(reversedDropPairings(in: bad).isEmpty,
            "Self-check: the reversed order — the one two smokes found broken — "
            + "must be reported.")

        // **The same pair with MULTI-LINE closures, which is the only shape that
        // exists in production.** The single-line fixtures above cannot see the
        // scanner's worst failure: the `}` closing a modifier's closure sits at
        // the chain's own indent, and a scanner that stops there never reaches
        // the next modifier at all. Measured — the real reversed pairing in
        // `CollectionResearchPane` was invisible until this shape was covered.
        let badMultiline = """
        struct BadMultiline: View {
            var body: some View {
                Color.clear
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                    Task { await importExternal(providers) }
                    return true
                }
                .dropDestination(for: String.self) { ids, _ in
                    guard !ids.isEmpty else { return false }
                    return true
                }
            }
        }
        """
        XCTAssertFalse(reversedDropPairings(in: badMultiline).isEmpty,
            "Self-check: the reversed pair with real multi-line closures must be "
            + "reported. A scanner that treats the closing brace of the first "
            + "modifier's closure as the end of the chain reports NOTHING here, "
            + "and is blind to every production instance.")

        XCTAssertEqual(reversedDropPairings(in: """
            struct GoodMultiline: View {
                var body: some View {
                    Color.clear
                    .dropDestination(for: String.self) { ids, _ in
                        guard !ids.isEmpty else { return false }
                        return true
                    }
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                        Task { await importExternal(providers) }
                        return true
                    }
                }
            }
            """), [],
            "Self-check: the SAME multi-line shape in the right order must offend "
            + "nothing — or the assertion above is satisfied by a scanner that "
            + "flags every pairing.")

        // **The case that motivated the per-chain scan**: two pairings in one
        // file, with an unrelated string destination above both. A first-index
        // comparison passes this happily; only the second chain is reversed.
        let twoChains = """
        struct TwoSections: View {
            var body: some View {
                VStack {
                    Text("empty state")
                        .dropDestination(for: String.self) { _, _ in true }
                }
                .dropDestination(for: String.self) { _, _ in true }
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { _ in true }
                VStack { Text("second") }
                .onDrop(of: [.fileURL, .image], isTargeted: nil) { _ in true }
                .dropDestination(for: String.self) { _, _ in true }
            }
        }
        """
        XCTAssertEqual(reversedDropPairings(in: twoChains).count, 1,
            "Self-check: exactly the SECOND chain is reversed and must be reported. "
            + "The check this replaced compared first occurrences and passed here — "
            + "which is the shape `CollectionResearchPane` actually has.")
        let firstString = try XCTUnwrap(firstCodeLine(of: Self.stringDropToken, in: twoChains))
        let firstProvider = try XCTUnwrap(firstCodeLine(of: Self.providerDropToken, in: twoChains))
        XCTAssertLessThan(firstString, firstProvider,
            "Self-check, and the point: by first occurrence this file looks correct.")

        // A file with only one of the two tokens is not this rule's business —
        // `ResearchView` and `PaletteCardEditor` mount the provider drop alone.
        XCTAssertEqual(reversedDropPairings(in: """
            struct Half: View {
                var body: some View {
                    Color.clear.onDrop(of: [.fileURL, .image], isTargeted: nil) { _, _ in true }
                }
            }
            """), [],
            "Self-check: a provider drop with no string destination after it is "
            + "not an offence — the pairing is what the rule is about.")
    }

    // MARK: - Nothing scanned may be truncated by an unclosed block (1C-d Task 11)

    /// Every `.swift` file under `dir` whose `SourceScan` run ends still inside a
    /// `/* … */` block — meaning some tail of it was invisible to every census
    /// that reads through that type.
    private func truncatedFiles(under dir: URL) throws -> Set<String> {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var hits: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if SourceScan.endsInsideABlock(try String(contentsOf: url, encoding: .utf8)) {
                hits.insert(url.lastPathComponent)
            }
        }
        return hits
    }

    /// **A file that opens a `/*` it never closes is invisible from there on, and
    /// for a FORBIDDEN-token ban that failure is silent.**
    ///
    /// The stripper cannot tell a real block comment from `/*` inside a string
    /// literal or from prose naming a path like `.maugham/sessions/*`, and files
    /// in this repo trip it today for both of those reasons — including this
    /// file's own `hasPrefix("/*")`, and including trees this guard does not
    /// assert over. **The assertions below are the count**; a figure written here
    /// would be a prose count inside a safety instrument, guarded by nothing.
    /// Teaching it to lex Swift strings is the other answer and it is worse: a
    /// half-lexer with nothing to test it against, guarding a suite of censuses.
    ///
    /// **So this is a guard rather than a cleverer stripper**, and it is aimed
    /// where the failure direction is quiet. A *required*-token census cannot be
    /// harmed silently — a hidden token reads as missing, which is red. A *ban*
    /// can: hide the offender and it passes. The only ban that reads through
    /// `SourceScan` scans `Maugham/Canvas/`, so that tree must hold at **zero**,
    /// and one `/// … /some/path/*` written above a
    /// `.dropDestination(for: URL.self)` is all it would take.
    func test_noScannedFileIsTruncatedByAnUnclosedBlockComment() throws {
        XCTAssertEqual(try truncatedFiles(under: sourceDir
                        .appendingPathComponent("Canvas", isDirectory: true)), [],
            "A file under Maugham/Canvas/ ends its scan inside an unclosed /* — so "
            + "everything after that point is invisible to "
            + "test_theCanvasExternalDropUsesTheProviderRouteAndNeverAUrlDestination, "
            + "whose BAN half would then pass while the offender sits in the hidden "
            + "tail. The usual cause is prose naming a path that ends in /*, or a "
            + "string literal containing one. Close it, or reword it.")

        // The whole tree `SourceScan`'s other readers walk. Both censuses over it
        // are equality-based, so truncation there shows up red rather than quiet
        // — this is a census with its reasons rather than a ban, and its job is
        // to make a THIRD arrival a decision somebody takes on purpose.
        XCTAssertEqual(try truncatedFiles(under: sourceDir),
                       ["MaughamSidecarPath.swift", "EPUBZipPackager.swift"],
            "The set of production files invisible past an unclosed /* changed. "
            + "Both known entries are doc comments naming a path (`.maugham/…/*`, "
            + "`OEBPS/*`) and neither contains a call any census over this tree "
            + "looks for. If a new file joins them, check what is in its hidden "
            + "tail before adding it here.")

        // **Control: the detector fires.** A guard that cannot report a positive
        // is indistinguishable from one reading an empty tree — which is the
        // shape this whole round has been about.
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-truncation-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try """
        /// A doc comment naming .maugham/sessions/* opens a block that never closes.
        struct Planted { func drop() { _ = "dropDestination(for: URL.self)" } }
        """.write(to: tmp.appendingPathComponent("Planted.swift"),
                  atomically: true, encoding: .utf8)
        XCTAssertEqual(try truncatedFiles(under: tmp), ["Planted.swift"],
            "Control: a planted unclosed /* should be reported.")
        XCTAssertTrue(try filesNaming("dropDestination(for: URL", under: tmp).isEmpty,
            "Control, and the reason this guard exists: the planted file's SECOND "
            + "line names the forbidden token in code, and the ban cannot see it "
            + "because the first line hid the rest of the file.")
    }

    // MARK: - The statement pane's mount marker has a closed set of readers (M1A Task 12)

    /// `resolvedScope` is a **proxy**, and this file has produced seven defects
    /// of one family: a value still trusted after the thing it described had
    /// moved.
    ///
    /// It says which scope finished RESOLVING. It does not say whether the host
    /// is still on screen, and for most of M1A nothing cleared it on the way out
    /// — so it went on naming a scope over a `Document` that had been closed.
    /// Two shipped defects read it as "the pane is still here": a picture ingest
    /// that finished after `⌘⌥N` wrote its ref into a husked `Document` (accepted
    /// drop, no text) or into the writer's *intent* prose, and a disappear /
    /// re-appear on the same scope left the pane mounted over a husk, eating
    /// keystrokes. Neither is guarded now; both are unreachable, because the
    /// ingest names its destination outright and reads no view state after
    /// suspending.
    ///
    /// **Construction closed the class; this keeps it closed.** Re-introduce a
    /// `resolvedScope` read inside `take`, `deliver`, `ingest` or a paste handler
    /// and nothing else in the suite goes red — which is the shape this project's
    /// own recorded lesson says to answer with a census rather than a warning.
    private static let mountMarkerToken = "resolvedScope"

    /// **Count the set, not this comment.** Every member allowed to touch the
    /// marker, and why each is legitimate:
    ///
    /// - `resolvedScope` — its own declaration.
    /// - `shouldMount` — the pure predicate; takes it as a parameter.
    /// - `showsPictureWell` — the same, for the drop well's visibility. It
    ///   carries no correctness: `take` does not consult it.
    /// - `canMount` / `body` — the mount condition, which is what the marker is
    ///   FOR.
    /// - `reconcile` — the one place it is derived.
    /// - `leave` — the one place it is retracted.
    ///
    /// An async member appearing here is the regression: anything that resumes
    /// after a suspension must name what it is acting on, not ask a marker.
    private static let mountMarkerMembers: Set<String> = [
        "resolvedScope",
        "shouldMount",
        "showsPictureWell",
        "canMount",
        "body",
        "reconcile",
        "leave",
    ]

    /// Which members of a Swift file mention `token` in CODE, keyed by the
    /// enclosing `func`/`var` declaration at member indentation.
    ///
    /// Comment lines are excluded — this file discusses the marker at length in
    /// prose, which is the point of that prose.
    private func membersMentioning(
        _ token: String, inFileNamed filename: String, under dir: URL
    ) throws -> Set<String> {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: Set<String> = []
        for case let url as URL in walker where url.lastPathComponent == filename {
            var member = "(top level)"
            for line in try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines) {
                if let declared = Self.memberName(declaredOn: line) { member = declared }
                guard !Self.isCommentLine(line), line.contains(token) else { continue }
                found.insert(member)
            }
        }
        return found
    }

    /// The name a member-level `func`/`var` declaration introduces, or nil.
    /// Member level is four-space indentation, which is this codebase's style
    /// throughout — a nested declaration is deeper and keeps its parent's name,
    /// which is what we want: a closure inside `take` is `take`.
    private static func memberName(declaredOn line: String) -> String? {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return nil }
        let words = line.dropFirst(4)
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .split(separator: " ").map(String.init)
        guard let keyword = words.firstIndex(where: { $0 == "func" || $0 == "var" }),
              words.indices.contains(keyword + 1) else { return nil }
        return words[keyword + 1]
    }

    /// **Census, not a ban.** An equality against a non-empty expected set is its
    /// own control: a scanner that read nothing would fail here rather than pass
    /// quietly.
    func test_theStatementPaneMountMarkerIsReadOnlyWhereItMeansSomething() throws {
        XCTAssertEqual(
            try membersMentioning(Self.mountMarkerToken,
                                  inFileNamed: "StatementEditorHost.swift",
                                  under: sourceDir),
            Self.mountMarkerMembers,
            "The set of members touching `\(Self.mountMarkerToken)` changed. It is a "
            + "PROXY — it names the scope that resolved, never whether the host is "
            + "still on screen — and reading it to decide where a writer's words go "
            + "has shipped two defects. If your member resumes after a suspension, "
            + "name what it is acting on instead (see `take`, which carries a "
            + "`StatementPicture`). If it is genuinely part of the mount condition, "
            + "add it to mountMarkerMembers with a line saying why.")
    }

    /// Self-check: the census FIRES on a planted offender, and its scanner
    /// really attributes a mention to the member that contains it. A census that
    /// reads nothing and a census that passes look identical from the outside.
    func test_theMountMarkerCensusFiresOnAPlantedReader() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-mount-marker-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct StatementEditorHost {
            @State private var resolvedScope: String?

            /// A doc comment naming resolvedScope must NOT count.
            private func take() async {
                let landed = await ingest()
                guard resolvedScope == scopeKey else { return }
                write(landed)
            }

            private var canMount: Bool { resolvedScope == scopeKey }
        }
        """.write(to: tmp.appendingPathComponent("StatementEditorHost.swift"),
                  atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try membersMentioning(Self.mountMarkerToken,
                                  inFileNamed: "StatementEditorHost.swift", under: tmp),
            ["resolvedScope", "take", "canMount"],
            "Self-check: the planted `take` must be caught, the declaration and "
            + "`canMount` must be attributed to themselves, and the doc comment "
            + "above `take` must not count on its own.")

        // Control: the offender is NOT in the production expectation, so the
        // census above would really have gone red for it.
        XCTAssertFalse(Self.mountMarkerMembers.contains("take"),
                       "Control: if `take` were an allowed member the planted "
                       + "offender would pass the real census too.")
    }

    // MARK: - Who takes the statement open gate (whole-branch review, I2)

    /// Every member that takes `lockStatementOpen`, `File.swift:member`.
    ///
    /// **The census exists because the prose was wrong twice.**
    /// `ProjectStore+Statements.swift` and `Maugham/Canvas/AREA.md` both said
    /// "Both openers take it", and there were three openers, one of which
    /// (`adopt`) took nothing while a fourth taker (`promotePieceToProject`)
    /// opens no `Document` at all. A number in prose about a list is a defect
    /// the moment it is written; this is the list.
    ///
    /// Each entry says what it is:
    /// - `ProjectStore+Statements.swift:lockStatementOpen` — the declaration.
    /// - `StatementEditorHost.swift:load` — the pane, which holds its `Document`
    ///   for as long as the scope is showing and releases the gate as soon as it
    ///   has registered.
    /// - `ProjectStore+Statements.swift:withStatementDocument` — the transient
    ///   writer's arm, which every out-of-band write reaches (a promotion, a
    ///   dropped picture, a ruling, a wiki-link rename). The dance was
    ///   extracted out of `appendToStatement` (origin's S2) precisely so the
    ///   rename could not ship a second copy of it; the 2026-08-09 merge folded
    ///   the second draft's throwing whole-text wrapper (`mutateStatementText`,
    ///   which `appendToStatement` and `RulingPerformer` reach) onto the same
    ///   arm, so the census moved with the `lockStatementOpen` call rather
    ///   than gaining an entry. `PromotionPerformer` is NOT a taker.
    /// - `ProjectStore+StatementAdoption.swift:adopt` — the third opener, safe
    ///   by circumstance before it took the gate and no longer relying on that.
    /// - `ProjectStore+CollectionPieces.swift:promotePieceToProject` — takes the
    ///   gate while opening nothing, because it MOVES the file the gate is over.
    /// - `ProjectStore+Statements.swift:rollbackUnusedStatement` (issue #29) —
    ///   the second taker that opens nothing, for `promotePieceToProject`'s
    ///   reason one verb further: it DELETES the file the gate is over. Its
    ///   refusal is "somebody has this open", and without the gate a pane could
    ///   bind between that check and the removal — a writer typing into a
    ///   `Document` whose file has gone.
    private static let statementOpenGateTakers: Set<String> = [
        "ProjectStore+Statements.swift:lockStatementOpen",
        "ProjectStore+Statements.swift:withStatementDocument",
        "ProjectStore+Statements.swift:rollbackUnusedStatement",
        "ProjectStore+StatementAdoption.swift:adopt",
        "ProjectStore+CollectionPieces.swift:promotePieceToProject",
        "StatementEditorHost.swift:load",
    ]

    private static let statementOpenGateToken = "lockStatementOpen("
    private static let statementOpenGateAntiToken = "unlockStatementOpen("

    /// `File.swift:member` for every CODE line matching `token` and not
    /// `antiToken`, anywhere under `dir`.
    private func membersCalling(
        _ token: String, notMatching antiToken: String, under dir: URL
    ) throws -> Set<String> {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            var member = "(top level)"
            for line in try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines) {
                if let declared = Self.memberName(declaredOn: line) { member = declared }
                guard !Self.isCommentLine(line),
                      line.contains(token),
                      !line.contains(antiToken) else { continue }
                found.insert("\(url.lastPathComponent):\(member)")
            }
        }
        return found
    }

    /// **Census, not a ban.** Equality against a non-empty set is its own
    /// control: a scanner that read nothing goes red here rather than passing.
    func test_theStatementOpenGateIsTakenByExactlyTheseMembers() throws {
        XCTAssertEqual(
            try membersCalling(Self.statementOpenGateToken,
                               notMatching: Self.statementOpenGateAntiToken,
                               under: sourceDir),
            Self.statementOpenGateTakers,
            "The set of members taking `lockStatementOpen` changed. If you added "
            + "one, add it to statementOpenGateTakers with a line saying what it "
            + "is. If you REMOVED one, say why the path it guarded can no longer "
            + "put two live `Document`s on one statement's file — that is "
            + "paragraph loss, and it is why the gate exists. And never write "
            + "the count in prose: this list is the only place it lives.")
    }

    /// Self-check: the census fires on a planted taker, attributes it to the
    /// member that contains it, ignores a comment mentioning the gate, and does
    /// not confuse `unlockStatementOpen` for a take.
    func test_theStatementOpenGateCensusFiresOnAPlantedTaker() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-statement-gate-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        extension ProjectStore {
            /// A doc comment naming lockStatementOpen( must NOT count.
            func sneakilyOpensAStatement() async throws {
                await lockStatementOpen(statement.id)
                defer { unlockStatementOpen(statement.id) }
                _ = try await Document.load(url: statementURL)
            }

            func releasesOnly() {
                unlockStatementOpen(id)
            }
        }
        """.write(to: tmp.appendingPathComponent("Planted.swift"),
                  atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try membersCalling(Self.statementOpenGateToken,
                               notMatching: Self.statementOpenGateAntiToken, under: tmp),
            ["Planted.swift:sneakilyOpensAStatement"],
            "Self-check: the planted taker must be caught and attributed to its "
            + "own member; the doc comment must not count; and `releasesOnly`, "
            + "which only unlocks, must not be read as a take.")

        // Control: the planted member is NOT in the production expectation, so
        // the real census would genuinely have gone red for it.
        XCTAssertFalse(
            Self.statementOpenGateTakers.contains(
                where: { $0.hasSuffix(":sneakilyOpensAStatement") }),
            "Control: if the planted member were already allowed, the census "
            + "above would pass for it too and prove nothing.")
    }

    // MARK: - A drop destination in the binder tree declares its Bool

    /// **Every `.dropDestination` closure in the binder tree's sections must
    /// annotate `-> Bool`** (fix round 2).
    ///
    /// The empty-section placeholder shipped as:
    ///
    /// ```swift
    /// .dropDestination(for: String.self) { ids, _ in
    ///     refuseDrop("empty section placeholder", payload: ids.first)
    /// }
    /// ```
    ///
    /// which reads exactly like a refusal and is not one. Without the annotated
    /// result type the closure bound to a **Void-returning** `dropDestination`
    /// overload, so `refuseDrop`'s `false` went nowhere and the placeholder
    /// accepted the drag and discarded it — the same accept-then-discard defect
    /// fix round 1 had just removed from the rows, one layer out. The compiler
    /// said so (`result of call to 'refuseDrop(_:payload:)' is unused`) and the
    /// warning was not read.
    ///
    /// **Why this shape of guard.** The bundle-level refusal test asks
    /// `ResearchTreeActions` and cannot see the view layer at all, and a real
    /// drag session is not synthesisable headless — so the thing to pin is the
    /// one token that forces the right overload. `-> Bool` in the closure
    /// signature is that token: with it the Void overload is not a candidate,
    /// and a value-returning closure cannot silently drop its value.
    ///
    /// **Both research surfaces, not just the new one.** The warning sweep that
    /// closed this finding found the identical defect at FOUR older sites in
    /// `CollectionResearchPane.swift` — every call of its `sectionDropHandler`,
    /// discarding the same kind of `Bool` since the day they were written, so a
    /// payload that pane's own guard rejected was accepted on screen and then
    /// ignored. They were fixed and held here too, and the file left this list
    /// when stage 2b Task 7 deleted it; a census that had covered only the file
    /// the finding arrived in would have left the older instances to be
    /// rediscovered on a surface that outlived it.
    ///
    /// **The three ROWS joined the list in stage-2a Task 7**, when their
    /// handlers stopped being a formality. Until then `BinderRow` and `PieceRow`
    /// could only ever receive a manuscript id, so accepting unconditionally was
    /// harmless; the tree now carries research rows beside them, so a note can
    /// be dragged onto a chapter that cannot take it (a screenplay's, a
    /// referenced piece's) and the refusal has to survive the same overload
    /// trap this census is about.
    func test_everyDropDestinationInTheResearchSurfacesDeclaresItsBool() throws {
        var offenders: [String] = []
        for file in ["Views/BinderTreeSections.swift",
                     "Views/BinderRow.swift",
                     "Views/PieceRow.swift",
                     "Views/ResearchRow.swift"] {
            offenders += try Self.unannotatedDropDestinations(
                in: sourceDir.appendingPathComponent(file))
        }
        XCTAssertEqual(
            offenders, [],
            "Every `.dropDestination` in the research surfaces must spell its "
            + "closure `{ ids, _ -> Bool in … }`.\n\nWithout it the closure can "
            + "bind to a Void-returning overload, and a handler that computes a "
            + "refusal has it thrown away — the drop is ACCEPTED and the "
            + "writer's drag is discarded, which is what shipped. Add the "
            + "annotation and return the value.\n\nUnannotated:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: the census must fire on the shape that shipped, and must not
    /// fire on the fixed one.
    func test_theDropDestinationBoolCensusFiresOnTheShapeThatShipped() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-drop-bool-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let offender = tmp.appendingPathComponent("Offender.swift")
        try """
        struct Placeholder: View {
            var body: some View {
                Text("No research yet.")
                    // The shape that shipped: reads like a refusal, is not one.
                    .dropDestination(for: String.self) { ids, _ in
                        refuseDrop("empty section placeholder", payload: ids.first)
                    }
            }
        }
        """.write(to: offender, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try Self.unannotatedDropDestinations(in: offender),
            [".dropDestination(for: String.self) { ids, _ in"],
            "Self-check: an unannotated drop closure must be caught, and "
            + "reported by the text of the call so the reader can find it.")

        let fixed = tmp.appendingPathComponent("Fixed.swift")
        try """
        struct Placeholder: View {
            var body: some View {
                Text("No research yet.")
                    .dropDestination(for: String.self) { ids, _ -> Bool in
                        return refuseDrop("empty", payload: ids.first)
                    }
                Text("Section")
                    // The OTHER correct shape, and the census must accept it
                    // too: no annotation, but a multi-statement body that
                    // returns explicitly cannot bind to the Void overload at
                    // all. CollectionResearchPane's section-level destinations
                    // are written this way, and an over-strict first draft of
                    // this census flagged them.
                    .dropDestination(for: String.self) { ids, _ in
                        guard !ids.isEmpty else { return false }
                        Task { await move(ids) }
                        return true
                    }
            }
        }
        """.write(to: fixed, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try Self.unannotatedDropDestinations(in: fixed), [],
            "Control: neither correct shape may be reported — the annotated "
            + "one, nor the one whose explicit returns already force the Bool "
            + "overload. A census that fires on everything says nothing.")
    }

    /// The `.dropDestination(` calls in `url` whose closure can silently discard
    /// its handler's value, reported as the text of the call.
    ///
    /// **A closure is fine if it declares `-> Bool` OR returns explicitly**, and
    /// requiring both would be a style rule rather than a guard. A
    /// multi-statement body ending in `return true` cannot bind to the
    /// Void-returning overload at all — returning a value from a Void closure is
    /// an error, so the compiler has already made the choice. The defect is
    /// specifically the *implicit-return* shape, where a single call is the
    /// whole body: that binds to Void and throws the value away with nothing
    /// but a warning. (Measured while writing this: an over-strict first draft
    /// flagged `CollectionResearchPane`'s two section-level destinations, which
    /// return explicitly and are correct.)
    ///
    /// **Text rather than a line number, deliberately:** `codeLines` drops
    /// comment-only and blank lines, so an index into it is not the file's line
    /// number — and a census that points at the wrong line is worse than one
    /// that points at none.
    private static func unannotatedDropDestinations(in url: URL) throws -> [String] {
        let lines = codeLines(of: try String(contentsOf: url, encoding: .utf8))
        var offenders: [String] = []
        for (index, line) in lines.enumerated() where line.contains(".dropDestination(") {
            let signature = line + (index + 1 < lines.count ? lines[index + 1] : "")
            if signature.contains("-> Bool") { continue }
            if Self.closureBody(startingAt: index, in: lines)
                .contains(where: { $0.contains("return ") }) { continue }
            offenders.append(line.trimmingCharacters(in: .whitespaces))
        }
        return offenders
    }

    /// The lines of the closure opening on `start`, by brace depth — good enough
    /// for a census over hand-written view code, and it needs no parser.
    private static func closureBody(startingAt start: Int, in lines: [String]) -> [String] {
        var depth = 0
        var body: [String] = []
        for line in lines[start...] {
            let opened = line.filter { $0 == "{" }.count
            let closed = line.filter { $0 == "}" }.count
            if depth > 0 { body.append(line) }
            depth += opened - closed
            if depth <= 0 && opened > 0 { break }
        }
        return body
    }

    // MARK: - The shared research row never accepts a drop on its own authority

    /// **`ResearchRow` must return its CALLER's accept/refuse, never a literal**
    /// (fix round 1).
    ///
    /// The row is shared by every research surface, and it used to answer
    /// `.dropDestination` with a bare `return true` no matter what its `onDrop`
    /// closure did. That made "accepted" a property of the row: the binder
    /// tree's handlers are stubs until stage-2a Task 7, so a note dragged onto a
    /// populated research row in the tree got the accepted-drop animation and
    /// was then silently discarded — the writer's drag gone, with the animation
    /// that says it worked.
    ///
    /// A `Bool` return through `ResearchTreeActions` fixed it, and the compiler
    /// now asks every caller. What the compiler CANNOT ask is whether the row
    /// still forwards that answer rather than shadowing it with a literal, which
    /// is exactly the shape that shipped. Hence this.
    func test_theResearchRowNeverAcceptsADropOnItsOwnAuthority() throws {
        let url = sourceDir.appendingPathComponent("Views/ResearchRow.swift")
        let code = Self.codeLines(of: try String(contentsOf: url, encoding: .utf8))

        XCTAssertTrue(
            code.contains { $0.contains("return onDrop(") },
            "ResearchRow must return its `onDrop` closure's answer. If this "
            + "moved, this census needs to know where.")
        XCTAssertTrue(
            code.contains { $0.contains("return onExternalDrop(") },
            "…and its `onExternalDrop` closure's answer.")
        XCTAssertFalse(
            code.contains { $0.trimmingCharacters(in: .whitespaces) == "return true" },
            "ResearchRow must not accept a drop on its own authority. A bare "
            + "`return true` in a drop destination discards the drag of every "
            + "caller whose handler is a stub, with the animation that says it "
            + "landed. Return the closure's Bool instead.\n\nFound:\n"
            + code.filter { $0.contains("return true") }.joined(separator: "\n"))
    }

    /// **And neither manuscript row does either** (stage-2a Task 7).
    ///
    /// `BinderRow` and `PieceRow` both answered `.dropDestination` with a bare
    /// `return true` for as long as the only thing that could land on them was
    /// another manuscript row — where the host's handler always did something,
    /// so the literal was never wrong. The tree changed the premise: a research
    /// note dropped on a chapter is now a scope change, and a chapter that
    /// cannot take one (a screenplay's, a referenced Collection piece's, a
    /// structure group) must bounce it. A literal `true` there is the
    /// accept-then-discard defect `ResearchRow` already shipped once.
    func test_neitherManuscriptRowAcceptsADropOnItsOwnAuthority() throws {
        for file in ["Views/BinderRow.swift", "Views/PieceRow.swift"] {
            let url = sourceDir.appendingPathComponent(file)
            let code = Self.codeLines(of: try String(contentsOf: url, encoding: .utf8))
            XCTAssertTrue(
                code.contains { $0.contains("return onDrop(") },
                "\(file) must return its `onDrop` closure's answer.")
            // …and its external one, since stage-2b Task 4 gave both rows a
            // Finder/browser drop. A manuscript row is the target that can
            // least afford a literal: a screenplay's script and a referenced
            // Collection piece both REFUSE files, and accepting one on the
            // row's own authority animates the writer's photograph home and
            // imports it nowhere.
            XCTAssertTrue(
                code.contains { $0.contains("return onExternalDrop(") },
                "\(file) must return its `onExternalDrop` closure's answer.")
            XCTAssertFalse(
                code.contains { $0.trimmingCharacters(in: .whitespaces) == "return true" },
                "\(file) must not accept a drop on its own authority — the row "
                + "cannot know whether the host could route it.\n\nFound:\n"
                + code.filter { $0.contains("return true") }.joined(separator: "\n"))
        }
    }

    // MARK: - Every drop target in the tree reaches the one classifier

    /// The verbs that route a drop, and the files each is reached from.
    private static let treeDropRouters = [
        "routePieceRowDrop(", "routeResearchRowDrop(", "routeSharedSectionDrop(",
        // The external half (stage-2b Task 4). One verb for every target,
        // because what a Finder file dropped on a piece row means must not be
        // decided twice — the internal side needed three verbs only because
        // three of them compute an insertion index.
        "routeExternalDrop("
    ]
    /// The file that DEFINES them, which naturally contains all three.
    private static let treeDropRouterDefiner = "BinderTreeDrops.swift"

    /// **Every drop target in the binder tree routes through
    /// `TreeDropIntent`** — and which file reaches which verb is the wiring
    /// this census holds (stage-2a Task 7).
    ///
    /// The tree has four kinds of drop target and they live in four different
    /// files: manuscript rows in the two hosts, research rows in the sections,
    /// research rows again inside a piece's fold, and the shared section itself.
    /// A target wired to anything else — its own `moveResearchItem` call, a
    /// stubbed refusal left behind, a `return true` — is invisible to every
    /// other test in the repo, because **a real drag session is not
    /// synthesisable headless**: nothing can drive the closure a
    /// `.dropDestination` installs. What CAN be checked is that the closure
    /// calls the router, and that is what this is.
    ///
    /// The sharpest case is the fold. `BinderPieceFold` re-routes
    /// `internalDrop` to pass its `documentId`, and without that one line the
    /// fold's rows read to the classifier as ordinary shared research rows —
    /// so a note dropped into chapter three's fold quietly reorders shared
    /// research and never reaches chapter three. Nothing on screen says so.
    func test_everyDropTargetInTheTreeReachesTheClassifier() throws {
        let census = try treeDropRoutingCensus(in: sourceDir)
        XCTAssertEqual(
            census,
            ["BinderView.swift": ["routeExternalDrop(", "routePieceRowDrop("],
             "CollectionPiecesPane.swift": ["routeExternalDrop(",
                                            "routePieceRowDrop("],
             "BinderTreeSections.swift": ["routeExternalDrop(",
                                          "routeResearchRowDrop(",
                                          "routeSharedSectionDrop("],
             "BinderPieceFold.swift": ["routeExternalDrop(",
                                       "routeResearchRowDrop("]],
            "Every drop target in the binder tree routes through "
            + "`TreeDropIntent`, via `BinderTreeDrops`.\n\n"
            + "If you ADDED a target: call the matching router and add the file "
            + "above. If a file has LOST its entry, its drops are no longer "
            + "classified — they either refuse everything or accept and discard, "
            + "and no mounted test can see which.\n\n"
            + "Found:\n\(census)")
    }

    /// Self-check: a census of a REQUIRED token passes happily while blind, so
    /// prove it sees a host that stopped routing.
    func test_theDropRoutingCensusFiresOnAHostThatStoppedRouting() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-drop-routing-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct Wired: View {
            var body: some View {
                Row(onDrop: { id, position in
                    verbs.routePieceRowDrop(draggedId: id, documentId: item.id) {}
                })
            }
        }
        """.write(to: tmp.appendingPathComponent("Wired.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct Unwired: View {
            var body: some View {
                // A doc comment naming routePieceRowDrop( must not count, and
                // neither may a host that only reorders.
                Row(onDrop: { id, position in
                    Task { await handleDrop(draggedId: id, position: position) }
                    return true
                })
            }
        }
        """.write(to: tmp.appendingPathComponent("Unwired.swift"),
                  atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try treeDropRoutingCensus(in: tmp),
            ["Wired.swift": ["routePieceRowDrop("]],
            "Self-check: the census must name the wired host and say nothing "
            + "about the one that routes nothing.")
    }

    private func treeDropRoutingCensus(in dir: URL) throws -> [String: [String]] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var census: [String: [String]] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name != Self.treeDropRouterDefiner else { continue }
            let code = Self.codeLines(of: try String(contentsOf: url, encoding: .utf8))
            var found: Set<String> = []
            for line in code {
                for router in Self.treeDropRouters where line.contains(router) {
                    found.insert(router)
                }
            }
            if !found.isEmpty { census[name] = found.sorted() }
        }
        return census
    }

    // MARK: - The binder tree's sections mount in two halves

    /// The file that DEFINES both halves, which naturally contains both tokens
    /// and is not a host.
    private static let binderTreeSectionsDefiner = "BinderTreeSections.swift"
    /// The rows, mounted inside a host's `List`.
    private static let binderTreeSectionsRows = "BinderTreeSections("
    /// The presentations, attached outside it.
    private static let binderTreeSectionsPresentations = ".binderTreeSections("

    /// **A host that mounts the tree's sections must attach their presentations
    /// too**, and the failure of the pair is silent in exactly one direction.
    ///
    /// `BinderTreeSections` puts its rows inside the host's `List` and its
    /// presentations — the Add Link sheet, the error alert, the palette-card
    /// load, the deferred rename commit — OUTSIDE it, because a sheet attached
    /// to a row inside a lazy list is presented from a view the list may
    /// unmount. That split is deliberate and it is also a trap: a host with the
    /// rows and no modifier draws a perfectly convincing tree in which Add Link
    /// does nothing, every store failure is swallowed, the palette section is
    /// permanently empty and a new note never enters rename mode. **No row count
    /// and no selection test can see any of it** — which is what a census is
    /// for.
    func test_everyBinderTreeMountsBothHalvesOfTheSections() throws {
        let census = try binderTreeSectionsCensus(in: sourceDir)
        XCTAssertEqual(
            census,
            ["BinderView.swift": ["presentations", "rows"],
             "CollectionPiecesPane.swift": ["presentations", "rows"],
             "SceneNavigatorPane.swift": ["presentations", "rows"]],
            "Every binder tree host mounts BOTH halves of the sections.\n\n"
            + "If you have ADDED a tree host (a fifth project type, a new left "
            + "column): mount `BinderTreeSections(store:state:selectedSubject:)` "
            + "inside its `List`, attach "
            + "`.binderTreeSections(store:state:)` outside it, and add it "
            + "above.\n\n"
            + "If a host here shows only \"rows\": its sheet, alert, "
            + "palette-card load and deferred rename are all missing and "
            + "NOTHING else fails — Add Link opens nothing, store errors "
            + "vanish, the Palette section is empty forever.\n\n"
            + "If a host shows only \"presentations\": it carries the state and "
            + "the modifiers and draws no section at all.\n\n"
            + "Found:\n\(census)")
    }

    /// Self-check: prove the census FIRES on a host with one half. A census of
    /// a REQUIRED token is exactly the shape that can pass while blind.
    func test_binderTreeSectionsCensusFiresOnAHostMissingItsPresentations() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-tree-sections-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct WholeHost: View {
            var body: some View {
                List(selection: $subject) {
                    BinderTreeSections(store: store, state: state,
                                       selectedSubject: $subject)
                }
                .binderTreeSections(store: store, state: state)
            }
        }
        """.write(to: tmp.appendingPathComponent("WholeHost.swift"),
                  atomically: true, encoding: .utf8)
        try """
        /// A doc comment naming .binderTreeSections( must not count as a call.
        struct HalfHost: View {
            var body: some View {
                List(selection: $subject) {
                    BinderTreeSections(store: store, state: state,
                                       selectedSubject: $subject)
                }
            }
        }
        """.write(to: tmp.appendingPathComponent("HalfHost.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct StrandedHost: View {
            var body: some View {
                List(selection: $subject) { projectRow }
                    .binderTreeSections(store: store, state: state)
            }
        }
        """.write(to: tmp.appendingPathComponent("StrandedHost.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct Unrelated: View {
            var body: some View { Text("nothing to do with the tree") }
        }
        """.write(to: tmp.appendingPathComponent("Unrelated.swift"),
                  atomically: true, encoding: .utf8)

        let census = try binderTreeSectionsCensus(in: tmp)
        XCTAssertEqual(
            census,
            ["WholeHost.swift": ["presentations", "rows"],
             "HalfHost.swift": ["rows"],
             "StrandedHost.swift": ["presentations"]],
            "Self-check: a host with only the rows must enter the census with "
            + "only \"rows\" (the silent half — its doc comment naming the "
            + "modifier must NOT count as attaching it), a host with only the "
            + "modifier with only \"presentations\", and a file naming neither "
            + "must not appear at all.")
    }

    // MARK: - Every tree host consumes the scroll request (stage-3b Task 8)

    /// **All three hosts consume** — a scroll request queued on
    /// `BinderTreeSectionsState.scrollRequest` while a DIFFERENT tree host was
    /// mounted (the writer switched project type mid-session is not a real
    /// case, but the find overlay swapping the column for `ProjectSearchView`
    /// and back IS) needs picking up by whichever tree remounts, and that is
    /// production's responsibility to wire at every host — not something a
    /// shared helper can enforce by itself, since a host that never calls it
    /// simply never scrolls, silently.
    func test_everyBinderTreeHostConsumesTheScrollRequest() throws {
        let census = try consumingScrollRequestsCensus(in: sourceDir)
        XCTAssertEqual(
            census,
            ["BinderView.swift", "CollectionPiecesPane.swift",
             "SceneNavigatorPane.swift"],
            "Every binder tree host must call "
            + "`.consumingTreeScrollRequests(_:state:)` on its `List` (inside "
            + "the `ScrollViewReader` that hands back the proxy) — a host that "
            + "does not is a tree ⌘⌥R/⌘⌥P and a find match scroll silently do "
            + "nothing in.\n\nFound: \(census)")
    }

    /// Self-check: the census fires on a host missing the call, and a doc
    /// comment naming it must not count.
    func test_consumingScrollRequestsCensusFiresOnAHostMissingTheCall() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-scroll-consumption-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct WiredHost: View {
            var body: some View {
                ScrollViewReader { proxy in
                    List(selection: $subject) { rows }
                        .consumingTreeScrollRequests(proxy, state: treeState)
                }
            }
        }
        """.write(to: tmp.appendingPathComponent("WiredHost.swift"),
                  atomically: true, encoding: .utf8)
        try """
        /// A doc comment naming .consumingTreeScrollRequests( must not count.
        struct UnwiredHost: View {
            var body: some View {
                ScrollViewReader { proxy in
                    List(selection: $subject) { rows }
                }
            }
        }
        """.write(to: tmp.appendingPathComponent("UnwiredHost.swift"),
                  atomically: true, encoding: .utf8)

        let census = try consumingScrollRequestsCensus(in: tmp)
        XCTAssertEqual(census, ["WiredHost.swift"],
                       "Self-check: only the file that actually calls the "
                       + "consumer must enter the census — a doc comment "
                       + "naming it must not count.")
    }

    /// Which files call `.consumingTreeScrollRequests(`, comments stripped so
    /// a definer's or a host's own prose cannot stand in for the call.
    private func consumingScrollRequestsCensus(in dir: URL) throws -> [String] {
        let offenders = try grepSwift(
            in: dir, patterns: [".consumingTreeScrollRequests("],
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("///")
                || $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        return offenders.compactMap { $0.split(separator: ":").first.map(String.init) }
            .reduce(into: [String]()) { acc, name in
                if !acc.contains(name) { acc.append(name) }
            }
            .sorted()
    }

    /// The whole-tree census: which halves of `BinderTreeSections` each file
    /// carries. Comments are stripped, so the definer's own prose and a host's
    /// explanatory comments cannot stand in for a call.
    private func binderTreeSectionsCensus(in dir: URL) throws -> [String: [String]] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var census: [String: [String]] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name != Self.binderTreeSectionsDefiner else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            var found: Set<String> = []
            for line in Self.codeLines(of: text) {
                if line.contains(Self.binderTreeSectionsPresentations) {
                    found.insert("presentations")
                }
                // The modifier's spelling contains the rows' spelling only if
                // case is ignored, so the rows test is safe as written — but
                // check anyway rather than rely on it staying that way.
                if line.replacingOccurrences(
                    of: Self.binderTreeSectionsPresentations, with: "")
                    .contains(Self.binderTreeSectionsRows) {
                    found.insert("rows")
                }
            }
            if !found.isEmpty { census[name] = found.sorted() }
        }
        return census
    }

    /// A whole-line comment, in either spelling. Shared by the canvas-asset
    /// tripwires, which both guard tokens their own documentation names.
    private static func isCommentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*")
    }

    // MARK: - No spelling of the killed binder strip survives (stage 2b Task 8)

    /// **The five names the strip died with, censused rather than merely
    /// believed dead.** `BinderSegment` itself (Task 7); `Persona`'s
    /// `binderSegments(for:)` registry (Task 7, this class's own two-file
    /// helper of the same shape); `binderHome(for:)` (Task 7 — CLAUDE.md's
    /// Views row named it as where a dying transient segment used to return
    /// to); `findActive` (`treeFindActive`'s dead predecessor — its own doc
    /// comment at the property that replaced it says "zero true-writers");
    /// and `selectedResearchId` (the old research pane's private selection,
    /// half of the 2a Critical `ResearchSubjectRoutingTests` and
    /// `ProjectSubjectReachabilityTests` now guard the successor of).
    ///
    /// All five are still named in prose across this repo — `Views/AREA.md`,
    /// `docs/history/canvas.md`, CLAUDE.md, three task reports in this milestone's own
    /// `.superpowers/sdd/` directory, and the doc comment two paragraphs up
    /// this file — which is exactly why `SourceScan` and not a raw `contains`
    /// is the reader: it strips comments first, so a citation cannot trip a
    /// census built to catch the name coming back as real code.
    private static let deadStripSpellings = [
        "BinderSegment", "binderSegments(", "binderHome(", "findActive",
        "selectedResearchId",
    ]

    func test_noProductionSpellingOfTheDeadStripSurvives() throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(sourceDir)"); return
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = SourceScan.codeLines(of: text)
            for name in Self.deadStripSpellings {
                for line in lines where line.contains(name) {
                    offenders.append(
                        "\(url.lastPathComponent): \(name) — "
                        + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "A name from the binder strip killed in stage 2b Task 7 survives "
            + "outside comments. BinderSegment, binderSegments(for:), "
            + "binderHome(for:), findActive and selectedResearchId are all "
            + "dead — see ManuscriptForceCensusTests, TreePaneTests and "
            + "PersonaMemoryTests for their successors. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check, both directions in one plant: a doc comment naming all five
    /// spellings must NOT fire — that is the whole reason this census reads
    /// through `SourceScan` rather than a raw `contains` — and real code
    /// reintroducing each of them, right below that same comment, must.
    func test_deadStripCensusFiresOnPlantedOffendersAndIgnoresComments() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-deadstrip-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        /// Prose naming every dead spelling, which must not fire the census:
        /// BinderSegment, binderSegments(for:), binderHome(for:), findActive,
        /// selectedResearchId.
        struct Reviving {
            var findActive = false
            var selectedResearchId: String?
            let segment: BinderSegment? = nil
            func binderSegments(for persona: Int) -> [Int] { [] }
            func binderHome(for type: Int) -> Int { 0 }
        }
        """.write(to: tmp.appendingPathComponent("Reviving.swift"),
                  atomically: true, encoding: .utf8)

        var offenders: Set<String> = []
        let walker = try XCTUnwrap(
            fm.enumerator(at: tmp, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = SourceScan.codeLines(of: text)
            for name in Self.deadStripSpellings
            where lines.contains(where: { $0.contains(name) }) {
                offenders.insert(name)
            }
        }
        XCTAssertEqual(offenders, Set(Self.deadStripSpellings),
            "self-check: every planted offender must fire and the doc comment "
            + "naming all five must not suppress any of them — got \(offenders)")
    }

    // MARK: - Who decides the persona (stage 2b Task 8, T7 report §6)

    /// **T7's report closed with a named open question rather than a built
    /// census**: "does any site write `selectedSubject` without going through
    /// the rule that decides the persona with it." Building that census
    /// literally is the wrong shape, and the reason is worth recording rather
    /// than silently doing something else.
    ///
    /// `grep -rn "selectedSubject = " Maugham/` finds roughly twenty sites —
    /// `BinderTreeSections`, `CorkboardGrid`, `SceneNavigatorPane`,
    /// `OutlineTable`, `BinderView`, and a dozen more inside `ProjectWindow`
    /// itself — and asking each "did you call `ManuscriptNavigation.go` first"
    /// would fail on nearly all of them, because nearly all of them are
    /// correct as written: a click in whatever tree the writer is already
    /// looking at needs no persona decision to go with it. Which document or
    /// research item the centre column HOLDS is answered by
    /// `Persona.centresTheCanvas`/`showsManuscriptDocuments`
    /// (`ManuscriptNavigationTests`), never by `selectedSubject`'s write
    /// history — so a census demanding every subject write route through the
    /// persona rule would be a forbidden-pattern census whose "forbidden"
    /// pattern is the normal case. That is what "vacuous" means for this
    /// class of test (task 8 brief, item 1's own escape hatch), and the three
    /// notification receivers that DO need the rule — `.maughamNavigateToDocument`,
    /// `.maughamNavigateToParagraph`, `.maughamNavigateToScene` — already have
    /// their own census: `ManuscriptForceCensusTests
    /// .test_everyNavigationReceiverStillRoutesThroughTheNavigation`.
    ///
    /// **The stronger fact underneath both of those, asserted here.** If
    /// `selectedSubject`'s write history is irrelevant to which persona is
    /// showing, the only way the two could ever disagree is a site deciding to
    /// move the PERSONA on its own — reinventing `ManuscriptNavigation`'s rule
    /// one level up, which is exactly this file's own doc comment's warning
    /// ("a route added and nothing goes red") about a different value. So the
    /// census asks of `persona` what T7's question asked of `selectedSubject`:
    /// every production site that WRITES the window's `persona` is one of a
    /// small, named, closed set — nowhere else invents its own persona-moving
    /// logic. `ManuscriptNavigation.go` is the one sanctioned cross-context
    /// arrival; `PersonaModifier`'s `.maughamSetPersona` handler is the one
    /// sanctioned direct choice (⌘1–4 and the picker); `CanvasClaudeArrivalModifier`
    /// is Claude's own arrival (1C-c3), reviewed separately; `TreeTravel.swift`'s
    /// `TreeTravelModifier` is the tree's own double-click arrival (shell-finish
    /// stage 3b) — through `PersonaModifier.applyPersonaChange` directly rather
    /// than `ManuscriptNavigation.go`, because the travel rule's question ("is
    /// there a persona to travel TO") is not `ManuscriptNavigation`'s ("does the
    /// CURRENT persona already show a document"), and routing one through the
    /// other would let a rule answer a premise it was never asked about;
    /// `UIState.swift` is the model's own init/decode, not a live decision; and
    /// the two `self.persona = persona` lines in `AssistantColumn.swift` and
    /// `DetailPaneToggle.swift` are init-parameter captures for a subview
    /// reading the persona it was handed, not a place that moves anything.
    func test_theWindowsPersonaIsWrittenOnlyFromTheClosedSetOfDecisionSites() throws {
        let (bySite, unresolved, offendersByFile) = try personaDecisionSites(in: sourceDir)
        XCTAssertTrue(unresolved.isEmpty, "persona decision sites: \(unresolved)")
        XCTAssertEqual(
            Set(bySite.keys), Self.personaDecisionSites,
            "a new file writes the window's persona directly — either route it "
            + "through ManuscriptNavigation.go / PersonaModifier, or if it is a "
            + "genuinely new sanctioned decision site, add it here by name "
            + "rather than widening the census silently. Found:\n"
            + offendersByFile.map { "\($0.key): \($0.value.joined(separator: " / "))" }
                .sorted().joined(separator: "\n"))
    }

    /// The closed set. A type key claims its type's DECLARATIONS: a write in a
    /// child view sharing a file with `extension ProjectWindow` answers under
    /// that file's own name, and fails the census. `PersonaModifier` (the
    /// `.maughamSetPersona` handler, the one sanctioned direct choice) lives in
    /// `ProjectWindow.swift` beside the window, so it is named by its own type.
    static let personaDecisionSites: Set<String> = [
        "ManuscriptNavigation.swift", "CanvasClaudeArrivalModifier.swift",
        "type:ProjectWindow", "type:PersonaModifier", "TreeTravel.swift",
    ]

    /// Every persona write under `dir`, folded into `personaDecisionSites`'
    /// keys (`bySite`), plus each file's raw writes for the failure message.
    private func personaDecisionSites(in dir: URL) throws
        -> (bySite: [String: [String]], unresolved: [String], offendersByFile: [String: [String]]) {
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var offendersByFile: [String: [String]] = [:]
        var hits: [(hit: SourceTree.Hit, value: [String])] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            if name == "UIState.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in SourceScan.numberedCodeLines(of: text) {
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                guard Self.isPersonaStateWrite(trimmed) else { continue }
                if trimmed == "self.persona = persona" { continue }   // init capture
                offendersByFile[name, default: []].append(trimmed)
                hits.append((SourceTree.Hit(file: name, line: line.number), [trimmed]))
            }
        }
        let (bySite, unresolved) = SourceTree.foldingIntoTypeKeys(
            hits, keyedLike: Self.personaDecisionSites, in: [dir], combine: +)
        return (bySite, unresolved, offendersByFile)
    }

    /// **The type key claims the window's declarations, not its files**
    /// (plan 2 final review, I1). A persona write inside `extension
    /// ProjectWindow` answers as `type:ProjectWindow`; one in a child view
    /// that shares the file answers under the FILE, which is not a site.
    func test_personaDecisionCensusCatchesAWriteInAChildViewSharingTheWindowsFile() throws {
        let dir = try SourceTree.plantedTree([
            "Views/ProjectWindow.swift": "struct ProjectWindow {\n    func a() { persona = .plan }\n}\n",
            "Views/ProjectWindow+Columns.swift": """
            extension ProjectWindow {
                func b() { persona = .author }
            }

            struct ChildInspector {
                func c() { persona = .review }
            }
            """,
        ]).appendingPathComponent("Views")
        let inside = try personaDecisionSites(in: dir)
        XCTAssertEqual(Set(inside.bySite["type:ProjectWindow"] ?? []),
                       ["func a() { persona = .plan }", "func b() { persona = .author }"],
                       "both writes inside the window's declarations fold into the key")
        XCTAssertEqual(inside.bySite["ProjectWindow+Columns.swift"], ["func c() { persona = .review }"],
                       "the child view's write is the file's own, not the window's")
        XCTAssertFalse(Set(inside.bySite.keys).isSubset(of: Self.personaDecisionSites),
                       "so the census fails on it")
    }

    /// A line writes the persona state if it assigns through one of the three
    /// shapes production actually uses — a plain `persona =`, a `Binding`'s
    /// `.wrappedValue`, or the keyed `UIState` mutation closure's `$0.persona`.
    /// The trailing space in each pattern is load-bearing: `persona == .plan`
    /// does NOT contain `"persona = "` (the second `=` sits where the pattern
    /// wants a space), so a bare comparison never matches and needs no special
    /// exclusion — verified rather than assumed, because the same-line guard
    /// shape (`if persona == .plan { persona = .author }`) would have made an
    /// exclusion on the substring `"persona =="` blind the whole line to the
    /// real write sharing it.
    private static func isPersonaStateWrite(_ trimmed: String) -> Bool {
        trimmed.contains("persona = ")
            || trimmed.contains("persona.wrappedValue = ")
            || trimmed.contains("$0.persona = ")
    }

    /// Self-check: a planted direct write in a file outside the closed set
    /// must fire, and the same census run over just the three sanctioned files
    /// (stood up as a fixture, so the test does not depend on the real tree's
    /// line numbers) must not.
    func test_personaDecisionCensusFiresOnAPlantedDirectWrite() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-persona-decision-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct ManuscriptNavigation {
            static func go() { persona.wrappedValue = .author }
        }
        """.write(to: tmp.appendingPathComponent("ManuscriptNavigation.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct AssistantColumn {
            init(persona: Persona) {
                self.persona = persona
            }
        }
        """.write(to: tmp.appendingPathComponent("AssistantColumn.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct RogueRow {
            // The guard on its own must not fire the census — only the write
            // below it, which shares the same comparison a blind exclusion on
            // "persona ==" would have hidden.
            func tap() {
                if persona == .plan {
                    persona = .author
                }
            }
        }
        """.write(to: tmp.appendingPathComponent("RogueRow.swift"),
                  atomically: true, encoding: .utf8)

        var offendersByFile: [String: [String]] = [:]
        let walker = try XCTUnwrap(
            fm.enumerator(at: tmp, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            if name == "UIState.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in SourceScan.codeLines(of: text) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard Self.isPersonaStateWrite(trimmed) else { continue }
                if trimmed == "self.persona = persona" { continue }
                offendersByFile[name, default: []].append(trimmed)
            }
        }
        XCTAssertEqual(offendersByFile["RogueRow.swift"], ["persona = .author"],
            "the planted direct write must fire, and only the comparison-free "
            + "assignment inside it — the guard's own `persona == .plan` must "
            + "not")
        XCTAssertNil(offendersByFile["AssistantColumn.swift"],
            "the init-parameter capture must not fire — it is not a decision")
        XCTAssertEqual(offendersByFile["ManuscriptNavigation.swift"],
            ["static func go() { persona.wrappedValue = .author }"],
            "the sanctioned file still reports its own write — the closed-set "
            + "test is what allows it, not this census")
    }

    // MARK: - A view asks a persona predicate, never a persona name (foundations plan 4 Task 6)

    /// One allowance: a FILE and the exact SPELLING that may compare a persona
    /// there, with the reason it is not a gate a predicate should answer.
    struct PersonaComparisonAllowance {
        let file: String
        let spelling: String
        let reason: String
    }

    /// **File plus spelling, an array with a reason each — count the array,
    /// never a prose number about it.** Every other persona comparison in
    /// `Maugham/Views` is a gate, and a gate asks a named `Persona` predicate
    /// (`centresTheCanvas`, `showsPaletteWall`, `showsIntentStrip`,
    /// `showsExports`, …), because a name compared at four sites reads the same
    /// at all four and drifts at the fifth.
    static let personaComparisonAllowed: [PersonaComparisonAllowance] = [
        PersonaComparisonAllowance(
            file: "AssistantColumn.swift",
            spelling: "old.persona == new.persona",
            reason: "compares two SNAPSHOTS of the window's persona to tell a "
                + "pane change from a persona switch (`paneChangeEndsTheStudy`); "
                + "it names no persona, so there is no predicate it could ask"),
    ]

    /// `persona ==`, `persona != .x` / `persona != Persona.x`, and the same two
    /// through a binding (`persona.wrappedValue ==` / `!=`) — the shapes a
    /// name-gate takes. `persona != nil` is not a gate and is not matched.
    /// **Known limits**: `candidate == persona` (the picker's own selection
    /// test) and a persona compared from the other side (`.plan == persona`)
    /// are not matched, nor are `switch persona` / `case .plan` and
    /// `[…].contains(persona)` — a gate spelled any of those escapes.
    static let personaComparisonPattern = try! NSRegularExpression(
        pattern: #"\bpersona\s*==|\bpersona\s*!=\s*(\.|Persona\.)|\bpersona\.wrappedValue\s*(==|!=)"#)

    /// Every persona comparison under `root`'s `Maugham/Views` that no
    /// allowance admits, as `"<path>: <line>"`, plus every allowance that
    /// admitted nothing (a stale entry is a hole someone can walk through).
    /// Read through the source mask, so a comment or a string naming
    /// `persona == .plan` is not a hit.
    static func personaComparisonOffenders(
        base: URL = SourceTree.repoRoot,
        allowed: [PersonaComparisonAllowance] = personaComparisonAllowed
    ) throws -> (offenders: [String], unused: [String]) {
        var used = Set<Int>()
        var offenders: [String] = []
        for file in try SourceTree.maskedSources(under: "Maugham/Views", base: base) {
            let name = (file.path as NSString).lastPathComponent
            let masked = String(decoding: file.masked, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
            let raw = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            for index in masked.indices {
                let line = String(masked[index])
                let range = NSRange(line.startIndex..., in: line)
                guard personaComparisonPattern.firstMatch(in: line, range: range) != nil
                else { continue }
                let rawLine = raw[index].trimmingCharacters(in: .whitespaces)
                if let hit = allowed.indices.first(where: {
                    allowed[$0].file == name && rawLine.contains(allowed[$0].spelling)
                }) {
                    used.insert(hit)
                    continue
                }
                offenders.append("\(file.path): \(rawLine)")
            }
        }
        let unused = allowed.indices.filter { !used.contains($0) }
            .map { "\(allowed[$0].file): \(allowed[$0].spelling)" }
        return (offenders, unused)
    }

    /// **No view gates on a persona's NAME.** Before this census the window
    /// asked `persona != .plan` for the palette wall, `IntentStrip` asked
    /// `persona == .author` twice and both binder toggles asked `persona !=
    /// .plan` for the Exports footer; each is a named predicate now
    /// (`Persona.showsPaletteWall`, `.showsIntentStrip`, `.showsExports`).
    func test_noViewComparesAPersonaByName() throws {
        let result = try Self.personaComparisonOffenders()
        XCTAssertTrue(result.offenders.isEmpty,
            "A view compares the persona by name. Ask a named `Persona` predicate "
            + "(an exhaustive switch in `Persona.swift`) instead, or — if the "
            + "comparison is not a gate — add a FILE plus SPELLING allowance "
            + "with its reason. Offenders:\n" + result.offenders.joined(separator: "\n"))
        XCTAssertTrue(result.unused.isEmpty,
            "An allowance admits nothing any more — remove it: \(result.unused)")
        for allowance in Self.personaComparisonAllowed {
            XCTAssertFalse(allowance.reason.isEmpty, "\(allowance.file) carries no reason")
        }
    }

    /// The control: planted name-gates of both shapes fire; a comment, a
    /// string, the picker's `candidate == persona` and a predicate do not; the
    /// allowed spelling passes in its own FILE and fires under any other name;
    /// and an allowance whose spelling is gone is reported as unused.
    func test_thePersonaComparisonCensusFiresOnPlantedOffenders() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/RogueStrip.swift": """
            struct RogueStrip {
                // persona == .author would be the old gate, in prose.
                let label = "persona != .plan"
                func a(persona: Persona) -> Bool { persona == .author }
                func b(persona: Persona) -> Bool { persona != .plan }
                func c(box: Box) -> Bool { box.persona==.review }
                func d(candidate: Persona, persona: Persona) -> Bool { candidate == persona }
                func e(persona: Persona) -> Bool { persona.showsExports }
                func g(persona: Persona) -> Bool { persona != Persona.review }
                func h(persona: Binding<Persona>) -> Bool { persona.wrappedValue == .plan }
                func i(persona: Binding<Persona>) -> Bool { persona.wrappedValue != .plan }
                func j(persona: Persona?) -> Bool { persona != nil }
            }
            """,
            "Maugham/Views/AssistantColumn.swift": """
            struct AssistantColumn {
                static func f(old: S, new: S) -> Bool { old.persona == new.persona }
            }
            """,
            "Maugham/Views/Elsewhere/NotTheAssistant.swift": """
            struct NotTheAssistant {
                static func f(old: S, new: S) -> Bool { old.persona == new.persona }
            }
            """,
        ])
        let planted = try Self.personaComparisonOffenders(base: base)
        XCTAssertEqual(planted.offenders.sorted(), [
            "Maugham/Views/Elsewhere/NotTheAssistant.swift: static func f(old: S, new: S) -> Bool { old.persona == new.persona }",
            "Maugham/Views/RogueStrip.swift: func a(persona: Persona) -> Bool { persona == .author }",
            "Maugham/Views/RogueStrip.swift: func b(persona: Persona) -> Bool { persona != .plan }",
            "Maugham/Views/RogueStrip.swift: func c(box: Box) -> Bool { box.persona==.review }",
            "Maugham/Views/RogueStrip.swift: func g(persona: Persona) -> Bool { persona != Persona.review }",
            "Maugham/Views/RogueStrip.swift: func h(persona: Binding<Persona>) -> Bool { persona.wrappedValue == .plan }",
            "Maugham/Views/RogueStrip.swift: func i(persona: Binding<Persona>) -> Bool { persona.wrappedValue != .plan }",
        ].sorted(), "every shape fires, nothing else does, and the allowance is by FILE")
        XCTAssertEqual(planted.unused, [], "the planted AssistantColumn used its allowance")

        let stale = try Self.personaComparisonOffenders(
            base: base,
            allowed: Self.personaComparisonAllowed + [PersonaComparisonAllowance(
                file: "RogueStrip.swift", spelling: "persona == .gone", reason: "planted")])
        XCTAssertEqual(stale.unused, ["RogueStrip.swift: persona == .gone"],
                       "an allowance that admits nothing is reported")
    }

    // MARK: - Canvas zoom rendering guard (tripwire 25, ADR 0026)

    /// The forbidden zoom-rendering call shapes. `.scaleEffect(` blurs text,
    /// reports unscaled geometry to SwiftUI, and breaks `NSCursor` tracking;
    /// `NSScrollView.magnification` puts the canvas's zoom outside SwiftUI's
    /// coordinate space entirely — the same `.global` frame is reported at
    /// every zoom level, so at 2x and above a translated click point falls
    /// outside the view and clicks stop registering (measured 2026-07-25,
    /// macOS 26.5). Both failure modes are SILENT: no crash, no assertion
    /// elsewhere fires — which is why tripwire 25 had zero grep-level
    /// recurrence protection until this test. The camera's zoom is a manual
    /// CTM (`CanvasCamera`); nothing in `Maugham/Canvas/` should assign to
    /// `.magnification` or call `.scaleEffect(`.
    static let tw25ScaleEffectPattern = ".scaleEffect("
    static let tw25MagnificationPatterns = [
        ".magnification(", "magnification =", "setMagnification(", "allowsMagnification",
    ]

    /// Recurrence-tripper: scoped to PRODUCTION `.swift` under
    /// `Maugham/Canvas/`, plus `Views/CanvasClaudeArrivalModifier.swift` by
    /// name — canvas view code that lives outside `Maugham/Canvas/` proper
    /// (it's an animation-shaped `ViewModifier` for arriving Claude-written
    /// scraps, exactly the kind of file where a stray `.scaleEffect(` would
    /// naturally be reached for). Named explicitly rather than widening the
    /// scan to all of `Views/`, which would pull in unrelated UI code. Test
    /// files under `MaughamTests/Canvas/` legitimately name these tokens in
    /// prose/assertions (e.g. `CanvasViewMountingSurfaceTests.swift` discusses
    /// the `.scaleEffect` alternative it deliberately does NOT use) and are
    /// excluded by scanning `sourceDir` (which is `Maugham/`, not
    /// `MaughamTests/`) rather than by an allowlist. As of this writing there
    /// are zero legitimate production uses to exclude — the guard is a flat
    /// ban.
    func test_noCanvasZoomViaScaleEffectOrMagnification() throws {
        let canvasDir = sourceDir.appendingPathComponent("Canvas", isDirectory: true)
        let viewsDir = sourceDir.appendingPathComponent("Views", isDirectory: true)
        var offenders = try grepSwift(
            in: canvasDir,
            patterns: [Self.tw25ScaleEffectPattern] + Self.tw25MagnificationPatterns,
            excludeLine: { Self.isCommentLine($0) }
        )
        offenders += try grepSwift(
            in: viewsDir,
            files: ["CanvasClaudeArrivalModifier.swift"],
            patterns: [Self.tw25ScaleEffectPattern] + Self.tw25MagnificationPatterns,
            excludeLine: { Self.isCommentLine($0) }
        )
        XCTAssertTrue(offenders.isEmpty,
            "`.scaleEffect(` or a `.magnification` assignment found in "
            + "Maugham/Canvas/ production code. Canvas zoom MUST go through the "
            + "manual camera transform (CTM) — SwiftUI's coordinate space is "
            + "unaware of NSScrollView.magnification (clicks stop registering at "
            + "2x and above) and .scaleEffect blurs text, reports unscaled "
            + "geometry, and breaks NSCursor tracking. Both failures are SILENT "
            + "(tripwire 25; ADR 0026; "
            + "docs/superpowers/notes/2026-07-25-canvas-rendering-spike.md). "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the tripwire FIRES on a planted `.scaleEffect(` call.
    /// A ban that never matches and a scan that reads nothing look identical
    /// from the outside.
    func test_tw25TripwireFiresOnPlantedScaleEffectOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-tw25-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct BadCanvasZoom: View {
            let camera: CanvasCamera
            var content: some View { EmptyView() }
            var body: some View {
                // A doc comment naming .scaleEffect( must not count.
                content.scaleEffect(camera.zoom)
            }
        }
        """.write(to: tmp.appendingPathComponent("BadCanvasZoom.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: [Self.tw25ScaleEffectPattern] + Self.tw25MagnificationPatterns,
            excludeLine: { Self.isCommentLine($0) }
        )
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the planted content.scaleEffect(camera.zoom) "
            + "call to fire (and the doc comment above it to be excluded). Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("content.scaleEffect(camera.zoom)") == true,
            "Self-check: the planted scaleEffect call should be the one caught.")
    }

    /// Self-check: prove the tripwire FIRES on a planted `.magnification`
    /// assignment (the other forbidden shape — a raw `NSScrollView` zoom
    /// rather than `.scaleEffect`).
    func test_tw25TripwireFiresOnPlantedMagnificationOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-tw25-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        final class BadScrollZoom: NSScrollView {
            /// A doc comment naming magnification = must not count.
            func zoomTo(_ level: CGFloat) {
                magnification = level
            }
        }
        """.write(to: tmp.appendingPathComponent("BadScrollZoom.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: [Self.tw25ScaleEffectPattern] + Self.tw25MagnificationPatterns,
            excludeLine: { Self.isCommentLine($0) }
        )
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the planted `magnification = level` "
            + "assignment to fire (and the doc comment above it to be excluded). Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("magnification = level") == true,
            "Self-check: the planted magnification assignment should be the one caught.")
    }

    /// Self-check: prove the tripwire FIRES on a planted `setMagnification(`
    /// call — AppKit's setter-method spelling of the same forbidden zoom,
    /// distinct from both the property assignment above and `.scaleEffect(`.
    func test_tw25TripwireFiresOnPlantedSetMagnificationOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-tw25-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        final class BadScrollZoom: NSScrollView {
            /// A doc comment naming setMagnification( must not count.
            func zoomTo(_ level: CGFloat) {
                setMagnification(level, centeredAt: .zero)
            }
        }
        """.write(to: tmp.appendingPathComponent("BadScrollZoom.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: [Self.tw25ScaleEffectPattern] + Self.tw25MagnificationPatterns,
            excludeLine: { Self.isCommentLine($0) }
        )
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the planted `setMagnification(level, "
            + "centeredAt: .zero)` call to fire (and the doc comment above it to "
            + "be excluded). Got:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("setMagnification(level, centeredAt: .zero)") == true,
            "Self-check: the planted setMagnification( call should be the one caught.")
    }

    // MARK: - "Quarantine" never reaches the writer (recovery fix round, M5)

    /// **The internal term stays internal.** Plan B's verb is `quarantine`;
    /// what the writer is told is that part of their history was *set aside*.
    /// That rule lived in three doc comments and one reviewer's memory — and it
    /// had already been broken once, in the crash-recovery notice's "a record
    /// was kept in the project's quarantine folder", which shipped on main and
    /// which no test could see. Copy rules that are only written down decay;
    /// this is the census that makes this one durable.
    ///
    /// **What is scanned:** the contents of single-line string literals in
    /// every `.swift` file under `Maugham/Views/` plus
    /// `Maugham/Editor/EditorSurface.swift` — the two places writer-visible
    /// copy is composed. Selected negatively (every literal, minus the named
    /// exemptions) rather than by listing `Text(`/`Label(`/`Button(`/
    /// `postNotice(` call shapes: writer-visible copy also arrives through
    /// `.help`, `accessibilityHint`, `NSAlert.informativeText`, a `static let`
    /// two hundred lines from its own view, and whatever the next surface
    /// invents, and a ban that only knows four spellings misses all of them.
    ///
    /// **What is exempt, and why:** whole comments and comment tails (through
    /// `SourceScan`, so a doc comment explaining this very rule cannot trip
    /// it); a diagnostic channel's own declaration (`Logger(`/`subsystem:`/
    /// `category:` — `"HistoryPaneQuarantine"` is a log category, not a
    /// sentence); and `os.Logger` call lines, which are written for whoever
    /// debugs this and SHOULD name the verb (`Log.error(`, `Log.notice(`, …,
    /// and `privacy:`, which is meaningless outside a Logger interpolation).
    ///
    /// **What it cannot see:** multi-line (`"""`) literals — a line carrying
    /// one is skipped whole rather than guessed at, and the two in this tree
    /// today are an iCloud alert and a JSON snippet. A censused ban with a
    /// blind spot is worth saying out loud (`SourceScan`'s own doc comment
    /// makes the same admission about unclosed blocks); this one is narrow and
    /// the self-check below plants the shapes that matter.
    private static let writerVisibleBannedTerm = "quarantine"

    /// Lines whose literals are diagnostics rather than copy.
    private static let diagnosticLineMarkers = [
        "Logger(", "subsystem:", "category:", "privacy:",
        "Log.error(", "Log.notice(", "Log.debug(", "Log.info(",
        "Log.warning(", "Log.fault(", "Log.critical(", "Log.trace(",
    ]

    /// The contents of the single-line string literals on `line`, honouring
    /// backslash escapes. A line carrying a `"""` delimiter is skipped whole —
    /// this reader does not model multi-line literals and will not pretend to.
    private static func stringLiterals(in line: String) -> [String] {
        guard !line.contains("\"\"\"") else { return [] }
        var literals: [String] = []
        var current = ""
        var inLiteral = false
        var escaped = false
        for ch in line {
            if escaped { if inLiteral { current.append(ch) }; escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" {
                if inLiteral { literals.append(current); current = "" }
                inLiteral.toggle()
                continue
            }
            if inLiteral { current.append(ch) }
        }
        return literals
    }

    /// Every writer-visible literal under `dir` (plus `extraFiles`) whose text
    /// names the banned term, as "file:line: literal".
    private func bannedTermInWriterCopy(
        in dir: URL, extraFiles: [URL] = []
    ) throws -> [String] {
        let fm = FileManager.default
        var urls = extraFiles
        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                urls.append(url)
            }
        }
        var offenders: [String] = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            // A file whose scan ends inside an unclosed `/*` hides its tail
            // from this BAN — the quiet failure direction (see
            // `test_noScannedFileIsTruncatedByAnUnclosedBlockComment`).
            XCTAssertFalse(SourceScan.endsInsideABlock(text),
                "\(url.lastPathComponent) ends its scan inside an unclosed /* — "
                + "everything after that point is invisible to this ban")
            for (i, line) in SourceScan.codeLines(of: text).enumerated() {
                if Self.diagnosticLineMarkers.contains(where: { line.contains($0) }) { continue }
                for literal in Self.stringLiterals(in: line)
                where literal.localizedCaseInsensitiveContains(Self.writerVisibleBannedTerm) {
                    offenders.append("\(url.lastPathComponent) (code line \(i + 1)): \(literal)")
                }
            }
        }
        return offenders
    }

    func test_noWriterVisibleCopyNamesTheQuarantineVerb() throws {
        let offenders = try bannedTermInWriterCopy(
            in: sourceDir.appendingPathComponent("Views", isDirectory: true),
            extraFiles: [sourceDir.appendingPathComponent("Editor/EditorSurface.swift")])
        XCTAssertTrue(offenders.isEmpty,
            "Writer-facing copy names the internal verb. What the writer is told "
            + "is that history was SET ASIDE — see HistoryPane.quarantineNotice "
            + "and EditorHost's set-aside notices for the voice. If the string is "
            + "really a diagnostic, it belongs in an os.Logger call, which this "
            + "census exempts. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check, both directions in one plant: three writer-visible spellings
    /// must fire — including one on a CONTINUATION line of a multi-line
    /// `postNotice`, which is how the real notices are written — and the three
    /// legitimate uses beside them (a doc comment explaining the rule, a log
    /// category, an `os.Logger` call naming the verb) must not.
    func test_theWriterCopyBanFiresOnPlantedOffendersAndSparesDiagnostics() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-writercopy-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try #"""
        /// Prose naming quarantine — the rule's own explanation must not fire.
        struct Offenders: View {
            private let log = Logger(subsystem: "x", category: "PaneQuarantine")
            static let standing = "Part of this history is in quarantine."
            var body: some View {
                Text("This history was quarantined")
                Label("Quarantine folder", systemImage: "tray")
                Button("Retry", action: retryQuarantine)   // the CODE may say it
            }
            func report(_ name: String) {
                log.error("retryQuarantine: \(name, privacy: .public) still held")
                MaughamEvent.postNotice(
                    "Maugham put it in the Quarantine folder.",
                    projectURL: url)
            }
        }
        """#.write(to: tmp.appendingPathComponent("Offenders.swift"),
                   atomically: true, encoding: .utf8)

        let offenders = try bannedTermInWriterCopy(in: tmp)
        let caught = offenders.map { String($0.split(separator: ": ", maxSplits: 1).last ?? "") }.sorted()
        XCTAssertEqual(caught, [
            "Maugham put it in the Quarantine folder.",
            "Part of this history is in quarantine.",
            "Quarantine folder",
            "This history was quarantined",
        ], "Self-check: every writer-visible spelling fires — the standing "
         + "`static let` far from its view, the two SwiftUI labels, and the "
         + "continuation line of a multi-line postNotice — while the doc "
         + "comment, the log category and the Logger call do not. Got:\n"
         + offenders.joined(separator: "\n"))
    }

    // MARK: - No second statusColor switch (M3 P1 Task 3)

    /// Recurrence-tripper: `OutlineTable`, `BinderRow`, `CorkboardGrid` and
    /// `PieceRow` each carried their own `statusColor` switch over the legacy
    /// free-string `status` — and had already drifted from each other
    /// (`PieceRow` alone painted `.gray` for `"draft"`) before they converged
    /// on `StatusSwatch.color(for: ReviewStatus)`, the ONE switch. A future
    /// edit reaching for a quick local `statusColor` (the path of least
    /// resistance when a view just wants "a color for this status") reopens
    /// exactly the drift this task closed. `StatusSwatch.swift` itself names
    /// its function `color(for:)`, never `statusColor`, so it never
    /// self-matches.
    func test_noPrivateStatusColorSwitchInViews() throws {
        let offenders = try grepSwift(in: sourceDir, patterns: ["statusColor"])
        XCTAssertTrue(offenders.isEmpty,
            "A view file has its own statusColor switch again. Route through "
            + "StatusSwatch.color(for: ReviewStatus.derived(...)) instead — the one "
            + "place a ReviewStatus becomes a Color. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the statusColor tripwire FIRES on a planted private
    /// switch, so the empty result above is read absence, not a pattern typo.
    func test_theStatusColorTripwireFiresOnAPlantedSwitch() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-statuscolor-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct SomeNewRow: View {
            let item: StructureItem
            var body: some View {
                Circle().fill(statusColor(item.status))
            }
            private func statusColor(_ status: String?) -> Color {
                switch status {
                case "revising": return .orange
                case "final":    return .green
                default:         return .secondary
                }
            }
        }
        """.write(to: tmp.appendingPathComponent("SomeNewRow.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(in: tmp, patterns: ["statusColor"])
        XCTAssertEqual(offenders.count, 2,
            "Self-check: both the call site and the private func declaration should "
            + "fire. Got:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - Fingerprint join-spelling census (seam (a), M4 P2 Task 7)

    /// Matches any hex spelling of U+001F (Unit Separator) inside a Swift
    /// string-literal escape — `\u{1f}`, `\u{1F}`, `\u{001f}`, `\u{001F}`, and
    /// so on (one to three leading zeros, either case for the hex digit).
    /// A CENSUS, not an allow/deny grep: the character itself is not
    /// forbidden, only a SECOND site that joins fields with it is.
    private static func isUnitSeparatorJoinSpelling(_ line: String) -> Bool {
        line.range(of: #"\\u\{0{0,2}1[fF]\}"#, options: .regularExpression) != nil
    }

    /// Recurrence-tripper: `RoundFingerprint.stringValue` (RoundHistory.swift)
    /// is **the one identity spelling** for "the same finding across a round"
    /// (CompilerNote.swift's own doc comment) — kind, clause quote, paragraph
    /// id and category, joined by U+001F. A second production site that joins
    /// fingerprint-shaped fields with the same separator is a second identity
    /// spelling, and two spellings is how the dedupe silently forks: two
    /// readers of "the same finding" that can disagree about whether a
    /// re-raised question is the one already open in front of the writer —
    /// exactly the failure `stringValue`'s doc comment describes minting as a
    /// duplicate. Unlike the other tripwires here this is a CENSUS: the one
    /// legitimate join must be present exactly once, in RoundHistory.swift,
    /// and a second site elsewhere is the defect even though the escape
    /// itself is not a forbidden token in isolation.
    func test_onlyOneProductionSiteJoinsFingerprintFieldsWithTheUnitSeparator() throws {
        let coreDir = repoRoot
            .appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true)
        var joinSites = try grepSwift(
            in: sourceDir,
            patterns: [],
            extraOffender: Self.isUnitSeparatorJoinSpelling
        )
        joinSites += try grepSwift(
            in: coreDir,
            patterns: [],
            extraOffender: Self.isUnitSeparatorJoinSpelling
        )
        XCTAssertEqual(joinSites.count, 1,
            "Expected exactly ONE production site joining fields with U+001F — "
            + "RoundFingerprint.stringValue in RoundHistory.swift, the sanctioned "
            + "identity spelling for \"the same finding across a round\". A second "
            + "join site is a second identity spelling, which is how the dedupe "
            + "silently forks (CompilerNote.swift's fingerprint doc comment). Found:\n"
            + joinSites.joined(separator: "\n"))
        XCTAssertTrue(joinSites.first?.contains("RoundHistory.swift") == true,
            "The one join site should be in RoundHistory.swift. Got:\n"
            + joinSites.joined(separator: "\n"))
    }

    /// Self-check: prove the census FIRES when a second join site is planted
    /// — the real defect this test guards against — an allow/deny grep for a
    /// forbidden token wouldn't catch a second occurrence of a REQUIRED one).
    func test_theFingerprintJoinCensusFiresOnAPlantedSecondSite() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-fingerprintjoin-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct RoundFingerprint {
            var stringValue: String {
                [kind, clauseQuote ?? "", paragraphId ?? "", category ?? ""]
                    .joined(separator: "\\u{1f}")
            }
        }
        """.write(to: tmp.appendingPathComponent("RoundHistory.swift"),
                  atomically: true, encoding: .utf8)
        try """
        struct SomeNewDedupe {
            // A second, forbidden join site — planted offender. A different
            // hex spelling of the same separator still fires.
            var key: String {
                [sectionKind, quote, anchor].joined(separator: "\\u{001F}")
            }
        }
        """.write(to: tmp.appendingPathComponent("SomeNewDedupe.swift"),
                  atomically: true, encoding: .utf8)

        let joinSites = try grepSwift(
            in: tmp,
            patterns: [],
            extraOffender: Self.isUnitSeparatorJoinSpelling
        )
        XCTAssertEqual(joinSites.count, 2,
            "Self-check expected two join sites (RoundHistory + planted "
            + "SomeNewDedupe) — including the uppercase-and-zero-padded spelling. "
            + "Got:\n" + joinSites.joined(separator: "\n"))
        XCTAssertTrue(joinSites.contains { $0.contains("SomeNewDedupe.swift") },
            "Self-check: the planted second join site in SomeNewDedupe.swift "
            + "should fire.")
    }

    // MARK: - Translation write-batch census (publish department P2, Task 1)

    /// Every production site that appends a batch of `TranslationRecord`s.
    /// Comment lines are skipped: this counts CALL sites, and the pipeline
    /// names the batch append in the prose right above it.
    private func translationBatchAppendSites() throws -> [String] {
        try grepSwift(
            in: sourceDir,
            patterns: ["TranslationStore.appendBatch("],
            excludeLine: Self.isCommentLine)
    }

    /// Recurrence-tripper: **one translation write pipeline.** Everything that
    /// makes a batch of translated paragraphs safe — exactly one of
    /// text/verbatim/delete per entry, no intra-batch duplicate ids, the
    /// unknown-id all-or-nothing rule that `delete` is exempt from, the
    /// server-stamped `TranslationHash.hash(source)` no caller may supply, and
    /// the single coordinated `appendBatch` that makes "nothing is written"
    /// hold for an I/O failure too — lives in `TranslationWritePipeline`. A
    /// second production site that builds records and appends them is a second
    /// pipeline, and two pipelines drift: the MCP tool and the coming ingest
    /// path would disagree about which batches are legal and which hashes are
    /// trustworthy, silently, with the writer's translation as the evidence.
    ///
    /// This is a CENSUS, not an allow/deny grep: `appendBatch` is a REQUIRED
    /// call, so what is guarded is the number and identity of its callers.
    ///
    /// Two sanctioned sites, and the second is a deliberate exception:
    /// `TranslationReviewPaneLogic.purgeOrphans` appends TOMBSTONES ONLY. It
    /// builds no translated text, stamps no source hash against live text (an
    /// orphan's paragraph is gone, so it hashes `""`), and validates nothing
    /// the pipeline validates, because a purge has no `text` entry to check.
    /// It is the Mac side's own removal path (spec §2.2 — orphans never leave
    /// through MCP), not a way in for new translations.
    func test_theTranslationWritePipelineIsTheOnlyPlaceAWriteBatchIsAppended() throws {
        let sites = try translationBatchAppendSites()

        XCTAssertEqual(sites.count, 2,
            "Expected exactly TWO production appendBatch sites: "
            + "TranslationWritePipeline.swift (the one write pipeline) and "
            + "TranslationReviewPane.swift (the tombstone-only orphan purge). "
            + "A new site is a second write pipeline — route it through "
            + "TranslationWritePipeline.perform instead, so the MCP tool and "
            + "the ingest path cannot disagree about validation or the "
            + "server-stamped source hash. Found:\n"
            + sites.joined(separator: "\n"))
        XCTAssertEqual(sites.filter { $0.hasPrefix("TranslationWritePipeline.swift:") }.count, 1,
            "The one write pipeline should append exactly once. Found:\n"
            + sites.joined(separator: "\n"))
        XCTAssertEqual(sites.filter { $0.hasPrefix("TranslationReviewPane.swift:") }.count, 1,
            "The orphan purge should append exactly once. Found:\n"
            + sites.joined(separator: "\n"))
        XCTAssertTrue(sites.allSatisfy {
            $0.hasPrefix("TranslationWritePipeline.swift:")
                || $0.hasPrefix("TranslationReviewPane.swift:")
        }, "Unsanctioned appendBatch site. Found:\n" + sites.joined(separator: "\n"))

        // Carried over from the retired WriteTranslationToolTests census: a
        // per-record `append` inside a loop leaves a partial write when the
        // I/O fails midway, which is exactly what the single batch removed.
        let perRecord = try grepSwift(
            in: sourceDir,
            patterns: ["TranslationStore.append("],
            excludeLine: Self.isCommentLine)
        XCTAssertTrue(perRecord.isEmpty,
            "A per-record TranslationStore.append inside a loop makes a "
            + "mid-batch I/O failure leave a partial write. Build every record "
            + "first and persist the batch in one call. Found:\n"
            + perRecord.joined(separator: "\n"))
    }

    /// Self-check: prove the census FIRES on a planted third site — the real
    /// defect it guards. An allow/deny grep for a forbidden token could not
    /// catch a third occurrence of a REQUIRED one.
    func test_theTranslationBatchCensusFiresOnAPlantedThirdSite() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-translationbatch-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        enum TranslationWritePipeline {
            static func perform() throws {
                try TranslationStore.appendBatch(
                    records, forDocId: docId, language: language,
                    deviceSlug: slug, in: url)
            }
        }
        """.write(to: tmp.appendingPathComponent("TranslationWritePipeline.swift"),
                  atomically: true, encoding: .utf8)
        try """
        enum TranslationIngest {
            // A second write pipeline — planted offender. The comment below
            // mentions TranslationStore.appendBatch( and must NOT be counted.
            static func ingest() throws {
                try TranslationStore.appendBatch(
                    records, forDocId: docId, language: language,
                    deviceSlug: slug, in: url)
            }
        }
        """.write(to: tmp.appendingPathComponent("TranslationIngest.swift"),
                  atomically: true, encoding: .utf8)

        let sites = try grepSwift(
            in: tmp,
            patterns: ["TranslationStore.appendBatch("],
            excludeLine: Self.isCommentLine)
        XCTAssertEqual(sites.count, 2,
            "Self-check expected two call sites (the pipeline plus the planted "
            + "ingest), with the prose mention skipped. Got:\n"
            + sites.joined(separator: "\n"))
        XCTAssertTrue(sites.contains { $0.hasPrefix("TranslationIngest.swift:") },
            "Self-check: the planted second pipeline should fire.")
        XCTAssertFalse(sites.contains { $0.contains("must NOT be counted") },
            "Self-check: a prose mention in a comment is not a call site.")
    }

    // MARK: - Imprint identity resolves once, at the door (imprints P1 Task 8)

    /// Files where imprint identity legitimately lives: the config/model
    /// that holds it (`PublishConfig.swift`), the one resolver
    /// (`PublishConfig+Imprints.swift`'s `resolved(imprint:pieceIDs:)`), the
    /// publication record and mint-gate key that carry it forward
    /// (`Publication.swift`, `PublishMintGate.swift`), the two callers that
    /// resolve it (`CompileOrchestrator.swift`, `Republisher.swift`), the
    /// preview compiler that resolves for its own subset render
    /// (`PreviewCompiler.swift`), the validator that walks `config.imprints`
    /// (`PublishConfigValidator.swift`), and the three MCP tool files whose
    /// wire params carry `imprint` as a request field (`CompileTools.swift`,
    /// `PublicationTools.swift`, `PublishConfigTools.swift`). Every other
    /// production file reads the RESOLVED config (`config.imprint`,
    /// `config.template`) instead of taking imprint as an argument of its
    /// own — `PDFCompiler.swift` and `OutputFilenameBuilder.swift` do exactly
    /// that, and are the census's live proof it does not fire on a read.
    private static let filesAllowedToDeclareImprint: Set<String> = [
        "PublishConfig.swift", "PublishConfig+Imprints.swift", "Publication.swift",
        "PublishMintGate.swift", "Republisher.swift", "CompileOrchestrator.swift",
        "PreviewCompiler.swift", "PublishConfigValidator.swift", "CompileTools.swift",
        "PublicationTools.swift", "PublishConfigTools.swift",
    ]

    /// Matches BOTH Swift parameter-label shapes for `imprint`, each followed
    /// by an explicit type annotation: the same-name shape
    /// (`imprint: String`, a stored property or a plain-labeled parameter)
    /// and the label-plus-internal-name shape
    /// (`imprint name: String?`, exactly how `PublishConfig+Imprints.swift`'s
    /// own `resolved(imprint name: String?, pieceIDs:)` reads — the shape
    /// the substring check this replaced could not see, since no `:`
    /// immediately follows `imprint` there). The negative lookbehind refuses
    /// `.imprint` (member access) and a word character immediately before
    /// (so `reimprint:`, were such a thing to exist, does not match); the
    /// trailing `(String|Imprint)` is what distinguishes a DECLARATION from
    /// a call site, which passes a VALUE instead
    /// (`imprint: config.imprint`, `imprint: nil`, `imprint: imprint`,
    /// `imprint: requestedImprint`) and never a bare type name — so this does
    /// not fire on `loaded.resolved(imprint: imprint, pieceIDs: pieceIDs)`.
    /// A local read with no type annotation (`let imprint = config.imprint`,
    /// as `OutputFilenameBuilder.swift` does) also does not match: there is
    /// no `:` immediately after `imprint` there, only `=`.
    private static let imprintParameterRegex = try! NSRegularExpression(
        pattern: #"(?<![\w.])imprint(\s+[A-Za-z_]\w*)?\s*:\s*(String|Imprint)\b"#)

    /// True when `line` declares `imprint` as a stored property or a
    /// function/init parameter — see `imprintParameterRegex`'s doc comment
    /// for the two shapes matched and why a call site or an untyped local
    /// read is not one of them.
    private static func declaresImprintParameter(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return imprintParameterRegex.firstMatch(in: line, range: range) != nil
    }

    /// Census (a): no function/init signature or stored property outside the
    /// resolution door declares `imprint` as its own parameter or field.
    /// Constraint 1 ("resolved(imprint:pieceIDs:) is the one door") is a
    /// design intention until something greps it; this makes it enforceable
    /// — a new compiler, emitter, gate or snapshot that takes `imprint` as
    /// its own argument (rather than reading it off the resolved config) is
    /// the same shape of hazard as a defaulted `mintGate:` parameter
    /// (`PublishMintGateTests`' census): it compiles, and it quietly forgets
    /// to go through resolution.
    func test_noImprintDeclarationOutsideTheResolutionDoor() throws {
        let publishDir = sourceDir.appendingPathComponent("Publish", isDirectory: true)
        let mcpToolsDir = sourceDir
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)

        var offenders: [String] = []
        for dir in [publishDir, mcpToolsDir] {
            offenders += try grepSwift(
                in: dir,
                patterns: [],
                allowed: Self.filesAllowedToDeclareImprint,
                excludeLine: { Self.isCommentLine($0) },
                extraOffender: Self.declaresImprintParameter)
        }
        XCTAssertTrue(offenders.isEmpty,
            "A file outside the resolution door declares `imprint` as its own "
            + "parameter or stored property. Imprint identity resolves ONCE, "
            + "at PublishConfig.resolved(imprint:pieceIDs:) — every compiler, "
            + "emitter, gate and snapshot downstream reads it off the resolved "
            + "config (config.imprint / config.template) instead of taking it "
            + "as an argument of its own. If this file genuinely belongs at "
            + "the door, add it to filesAllowedToDeclareImprint. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: the census fires on both planted parameter-declaration
    /// shapes — same-name (`imprint: String?`) and label-plus-internal-name
    /// (`imprint name: String?`, `PublishConfig+Imprints.swift`'s own
    /// `resolved(imprint name:)` shape) — and lets a same-shaped call site
    /// through, in a file outside the allowed set.
    func test_imprintDeclarationCensusFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-imprint-declaration-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct RogueEmitter {
            // A call site is allowed — it passes a VALUE, not a type:
            func resolveFirst(_ config: PublishConfig, requestedImprint: String?) throws {
                let resolved = try config.resolved(imprint: requestedImprint, pieceIDs: [])
                emit(imprint: resolved.imprint, to: "x")
            }

            // A same-name parameter declaration — forbidden:
            func emit(imprint: String?, to path: String) {}

            // A label-plus-internal-name parameter declaration — forbidden,
            // and the shape a bare `imprint:` substring check cannot see:
            func relay(imprint name: String?) {}
        }
        """.write(to: tmp.appendingPathComponent("RogueEmitter.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: [],
            excludeLine: { Self.isCommentLine($0) },
            extraOffender: Self.declaresImprintParameter)
        XCTAssertEqual(offenders.count, 2,
            "Self-check expected exactly the two planted parameter "
            + "declarations, with the call site and the `resolved.imprint` "
            + "read left alone. Got:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("func emit(imprint: String?") },
            "Self-check: the same-name declaration should be caught. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("func relay(imprint name: String?") },
            "Self-check: the label-plus-internal-name declaration should be "
            + "caught. Got:\n" + offenders.joined(separator: "\n"))
    }

    /// The line containing `index`, by scanning back to the nearest `\n`
    /// (or the start of `text`) and forward to the next `\n` (or the end).
    private func line(containing index: String.Index, in text: String) -> Substring {
        let lineStart = text[..<index].lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
        let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
        return text[lineStart..<lineEnd]
    }

    /// Walks every `Publication(` construction in `dir` to its own closing
    /// paren (never the first `)`, since several arguments are themselves
    /// parenthesized calls — `Date()`, `relativePath(outputPath, from:)`),
    /// skips one whose OWN line is a comment (so a doc-comment example
    /// showing `Publication(...)` usage can't register as a phantom site),
    /// and reports which real sites omit `imprint:`.
    private func publicationConstructionOffenders(in dir: URL) throws -> (sites: Int, offenders: [String]) {
        let files = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        var offenders: [String] = []
        var sites = 0
        let constructor = "Publication("
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: constructor, range: search) {
                search = found.upperBound..<text.endIndex
                guard !Self.isCommentLine(String(line(containing: found.lowerBound, in: text))) else {
                    continue
                }
                var depth = 1
                var args = ""
                for ch in text[found.upperBound...] {
                    if ch == "(" { depth += 1 }
                    if ch == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    args.append(ch)
                }
                sites += 1
                if !args.contains("imprint:") {
                    offenders.append("\(file.lastPathComponent): Publication( without imprint:")
                }
            }
        }
        return (sites, offenders)
    }

    /// Census (b): every production `Publication(` construction passes
    /// `imprint:` — the "reach every sink" lesson (memory/feedback_census_
    /// over_warning.md). `imprint` is the mint key's fourth component (Task
    /// 5) and a `Publication.swift` model field (Task 3) defaulted to `nil`
    /// in its initializer, so a construction site that forgets `imprint:`
    /// still compiles and silently mints as book-level — the same hazard
    /// shape `PublishMintGateTests`' `mintGate:` census guards for the two
    /// compiler-construction sites.
    func test_everyProductionPublicationConstructionCarriesItsImprint() throws {
        let (sites, offenders) = try publicationConstructionOffenders(in: sourceDir)
        XCTAssertEqual(sites, 2,
            "expected exactly the two production construction sites "
            + "(CompileOrchestrator, Republisher); found \(sites)")
        XCTAssertTrue(offenders.isEmpty,
            "every production Publication(...) construction must carry "
            + "imprint: (the mint key's fourth component). Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: the census fires on a planted `Publication(` construction
    /// missing `imprint:`.
    func test_publicationConstructionCensusFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-publication-imprint-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct RoguePublisher {
            func finish() throws {
                let pub = Publication(
                    publicationID: "pub-1",
                    version: "0.1",
                    label: nil,
                    format: .pdf,
                    outputPath: relativePath(outputPath, from: projectURL),
                    snapshotID: "s",
                    checkpointID: "",
                    republishedFrom: nil,
                    compiledAt: Date(),
                    maughamVersion: "1",
                    tectonicVersion: "1",
                    language: nil,
                    allowStale: false)
            }
        }
        """.write(to: tmp.appendingPathComponent("RoguePublisher.swift"),
                  atomically: true, encoding: .utf8)

        let (sites, offenders) = try publicationConstructionOffenders(in: tmp)
        XCTAssertEqual(sites, 1, "Self-check expected exactly the one planted construction site.")
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected the planted construction, missing imprint:, "
            + "to fire. Got:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - The compiler's depth choices have one drawn menu (editorial letter P1)

    /// **Tripwire: `CompilerModelChoice.allCases` is iterated in exactly ONE
    /// production view — the shared `CompilerModelMenu`.**
    ///
    /// The gear menu now mounts in two homes, Author's Diagnostics pane and
    /// Review's round cockpit (Task 8), and the whole point of factoring it
    /// out was that neither one draws its own list of choices. A second
    /// `ForEach(CompilerModelChoice.allCases` is a second menu that can offer
    /// a different set, or tick the wrong one, while this one keeps compiling
    /// and passing.
    func test_compilerModelChoiceAllCasesIsIteratedInExactlyOneProductionView() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["ForEach(CompilerModelChoice.allCases"],
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        XCTAssertEqual(
            offenders.compactMap { $0.split(separator: ":").first.map(String.init) },
            ["CompilerModelMenu.swift"],
            "the depth picker's choices are drawn in exactly one place \u{2014} "
            + "the shared `CompilerModelMenu` \u{2014} and both of its mount "
            + "sites (`DiagnosticsPane`, `ReviewRoundCockpit`) construct that "
            + "view rather than building their own list. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: a planted second `ForEach` over the same
    /// `allCases` is caught.
    func test_compilerModelChoiceCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-compiler-model-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        struct RogueModelPicker: View {
            let choice: CompilerModelChoice
            var body: some View {
                Menu {
                    ForEach(CompilerModelChoice.allCases, id: \\.self) { candidate in
                        Text(candidate.displayName)
                    }
                }
            }
        }
        """.write(to: tmp.appendingPathComponent("RogueModelPicker.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: ["ForEach(CompilerModelChoice.allCases"])
        XCTAssertEqual(offenders.count, 1,
            "Self-check: the planted second menu should be the one caught. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders[0].hasPrefix("RogueModelPicker.swift:"), offenders[0])
    }

    // MARK: - The reveal's two window-side facts (translation pipeline P4 Task 5)

    /// **A departure or disagreement row is a way back into the manuscript, and
    /// both ends of that live where no headless test can reach.**
    ///
    /// `TranslationReveal` itself is pure and pinned by `TranslationRevealTests`
    /// — the plan, the payload, the two posts. The wiring is not: the poster is
    /// a closure inside a ViewBuilder arm of `ProjectWindow.body`, and the
    /// receiver is an `.onKeyWindowCommand` inside a `ViewModifier` that needs a
    /// key window to deliver anything at all. Delete either and every
    /// `TranslationReveal` test stays green while the row does nothing when
    /// clicked — which is exactly the state Task 3 shipped on purpose
    /// (`onReveal: { _ in }`) and this task ends.
    ///
    /// Two checks, each scoped to the region that must carry it, so the token
    /// appearing anywhere else in a 5,000-line file cannot satisfy either.
    /// Comments are stripped first (`SourceScan.codeLines`), so a doc comment
    /// naming the call is not the call.
    func test_theTranslationRevealIsPostedByTheReportArmAndHandledByTheWindow() throws {
        // By type and by symbol (foundations plan 2): the arm is read from
        // every file declaring `ProjectWindow`, and the modifier — a struct of
        // its own beside the window — from its one declaration, wherever a
        // split puts it. Both lookups throw when they find nothing.
        // The arm is scoped file by file, so its case-to-case slice never
        // runs from one window file into the next.
        let sources = try SourceTree.windowSources()
        let modifier = try SourceTree.declaration(
            named: "struct TranslationReviewModifier", under: "Maugham")

        XCTAssertTrue(sources.contains(where: Self.reportArmPostsTheReveal(in:)),
            "the round report's `onReveal` must call TranslationReveal.post — "
            + "without it the report's reveal rows are the Task 3 stub "
            + "(`onReveal: { _ in }`) and a click does nothing at all. It "
            + "belongs in the `case .translationRound(let round):` arm of "
            + "publishCentre's switch in ProjectWindow.body.")

        // **The publish problems arm reveals through the same post** (report
        // foundations plan 2, Task 8, R-S11): a source reveal is a
        // `TranslationReveal` with no language, so the window keeps ONE
        // select-wait-scroll path. A second hand-rolled wait in this arm, or a
        // stubbed `onReveal`, fails here.
        XCTAssertTrue(sources.contains(where: Self.problemsArmPostsTheReveal(in:)),
            "the publish problems arm's `onReveal` must call TranslationReveal.post "
            + "— it is the window's one source-paragraph reveal. It belongs in the "
            + "`case .publishProblems(let problems):` arm of the centre's switch.")

        XCTAssertTrue(Self.translationReviewModifierHandlesTheReveal(in: modifier),
            "TranslationReviewModifier must handle .maughamRevealTranslation — "
            + "it is the only thing in the window that knows which chapter is "
            + "open, so it is where the reveal's plan (.now vs .afterSelecting) "
            + "is made. Without the receiver the post reaches nobody and the "
            + "row is silently inert.")
    }

    /// Self-check: prove both halves fire on the pre-task shape — the Task 3
    /// stub closure, and a `TranslationReviewModifier` with no reveal receiver —
    /// and that a comment naming either call suppresses neither. A grep pin that
    /// cannot fail is a comment.
    func test_theTranslationRevealPinsFireOnThePlantedStub() throws {
        let planted = """
        struct ProjectWindow: View {
            var body: some View {
                switch Self.publishCentre(persona: persona, subject: selectedSubject) {
                case .translationRound(let round):
                    // A comment naming TranslationReveal.post( is not the call.
                    TranslationRoundReportHost(
                        round: round, store: store,
                        onClose: { publishCentre.clearRound() },
                        onReveal: { _ in })
                case .designProposal(let proposal):
                    DesignGateView(proposal: proposal, onReveal: {
                        TranslationReveal.post(somethingElse)
                    })
                }
            }
        }

        private struct TranslationReviewModifier: ViewModifier {
            // A comment naming .onKeyWindowCommand(.maughamRevealTranslation is
            // not a receiver.
            func body(content: Content) -> some View {
                content
                    .onKeyWindowCommand(.maughamEnterTranslationReview, window: window) { _ in }
            }
        }

        struct SomeOtherModifier: ViewModifier {
            func body(content: Content) -> some View {
                content
                    .onKeyWindowCommand(.maughamRevealTranslation, window: window) { _ in }
            }
        }
        """

        let plantedProblems = """
        switch route {
        case .publishProblems(let problems):
            // A comment naming TranslationReveal.post( is not the call.
            PublishProblemsView(rows: rows, onClose: {}, onReveal: { _ in })
        case .translationRound(let round):
            TranslationRoundReportHost(onReveal: { TranslationReveal.post(x) })
        }
        """
        XCTAssertFalse(Self.problemsArmPostsTheReveal(in: plantedProblems),
            "self-check: a stubbed problems `onReveal` must fire the pin — neither "
            + "a comment naming the call nor the call in the NEXT arm may satisfy it")
        XCTAssertTrue(Self.problemsArmPostsTheReveal(in: plantedProblems
            .replacingOccurrences(of: "onReveal: { _ in }",
                                  with: "onReveal: { TranslationReveal.post(r) }")),
            "control: the wired arm passes")

        XCTAssertFalse(Self.reportArmPostsTheReveal(in: planted),
            "self-check: the Task 3 stub `onReveal: { _ in }` must fire the "
            + "poster pin — neither a comment naming the call nor the same call "
            + "in the NEXT switch arm may satisfy it")
        XCTAssertFalse(Self.translationReviewModifierHandlesTheReveal(in: planted),
            "self-check: a TranslationReviewModifier with no reveal receiver "
            + "must fire the handler pin — neither a comment naming the "
            + "receiver nor the receiver in ANOTHER modifier, which would have "
            + "no activeDocId to plan against, may satisfy it")
    }

    /// The round report's arm of `publishCentre`'s switch posts the reveal.
    /// Scoped from that arm's `case` to the next one, because `onReveal:` is a
    /// parameter name the file carries in more than one place.
    private static func reportArmPostsTheReveal(in source: String) -> Bool {
        let lines = SourceScan.codeLines(of: source)
        guard let start = lines.firstIndex(where: {
            $0.contains("case .translationRound(let round):")
        }) else { return false }
        let after = lines[(start + 1)...]
        let end = after.firstIndex(where: { $0.contains("case .designProposal(") })
            ?? lines.endIndex
        return lines[start..<end].contains { $0.contains("TranslationReveal.post(") }
    }

    /// The publish problems arm posts the reveal. Scoped from that arm's `case`
    /// to the round report's, which follows it and posts one of its own.
    private static func problemsArmPostsTheReveal(in source: String) -> Bool {
        let lines = SourceScan.codeLines(of: source)
        guard let start = lines.firstIndex(where: {
            $0.contains("case .publishProblems(let problems):")
        }) else { return false }
        let after = lines[(start + 1)...]
        let end = after.firstIndex(where: { $0.contains("case .translationRound(") })
            ?? lines.endIndex
        return lines[start..<end].contains { $0.contains("TranslationReveal.post(") }
    }

    /// `TranslationReviewModifier` receives `.maughamRevealTranslation`. Scoped
    /// to that one declaration, so the receiver landing in some other modifier —
    /// which would not have `activeDocId` to plan against — does not pass.
    private static func translationReviewModifierHandlesTheReveal(in source: String) -> Bool {
        guard let body = topLevelDeclaration(
            named: "struct TranslationReviewModifier", in: source) else { return false }
        return body.contains {
            $0.contains(".onKeyWindowCommand(.maughamRevealTranslation")
        }
    }

    /// The code lines of the top-level declaration whose line contains
    /// `declaration`, ending at the next line that starts in column 0 with
    /// something other than a closing brace — i.e. at the next top-level
    /// declaration, whatever keyword or attribute introduces it.
    private static func topLevelDeclaration(
        named declaration: String, in source: String
    ) -> [String]? {
        let lines = SourceScan.codeLines(of: source)
        guard let start = lines.firstIndex(where: { $0.contains(declaration) })
        else { return nil }
        let after = lines[(start + 1)...]
        let end = after.firstIndex(where: { line in
            guard let first = line.first else { return false }
            return !first.isWhitespace && first != "}"
        }) ?? lines.endIndex
        return Array(lines[start..<end])
    }

    // MARK: - No software private key in production (signed op log, spec §4.1)

    /// A device key must not be a SOFTWARE key. A software P256 (or
    /// Curve25519) private key lives in process memory and copies off the
    /// machine with whatever file holds it, so a signature made with one
    /// proves nothing about which device wrote the op — which is the entire
    /// job of the signature. The only production signer is the enclave's,
    /// `SecureEnclave.P256.Signing.PrivateKey`, whose `dataRepresentation` is
    /// useless on any other machine; that is why the app can persist it as a
    /// plain file and needs no keychain item and no entitlement.
    ///
    /// The test-only software signer lives in one file of its own,
    /// `DeviceIdentity+Testing.swift` (an `internal` extension reachable only
    /// through `@testable import MaughamCore`), and that file is this census's
    /// ONE allow-list entry, by name.
    ///
    /// SHARED between the production check and its planted-offender self-check
    /// — one place to widen the shape.
    static func isSoftwarePrivateKeyLine(_ line: String) -> Bool {
        if line.contains("Curve25519") { return true }
        // The enclave spelling contains the software one as a substring, so the
        // qualifier is what separates the sanctioned key from the forbidden one.
        return line.contains("P256.Signing.PrivateKey(")
            && !line.contains("SecureEnclave.P256.Signing.PrivateKey(")
    }

    /// The census's allow-list, BY FILE NAME — two entries, each for a reason:
    ///
    /// - `DeviceIdentity+Testing.swift` — the test-only software signers,
    ///   `internal` and reachable only through `@testable import`.
    /// - `PersonKey.swift` (your devices are you, plan 1 Task 2) — the person
    ///   key, the ONE production software key. A device key is the enclave's
    ///   because it proves which MACHINE wrote a line; the person key proves the
    ///   opposite — that several machines are one person — so it has to leave
    ///   the machine through iCloud Keychain, and a key that leaves the machine
    ///   is a software key. It never signs manuscript lines, only a claim that a
    ///   device belongs to a person. Allowed by NAME, so a software key in any
    ///   other file (a `PersonClaim.swift`, a second keychain helper) still fires
    ///   — `test_theSoftwarePrivateKeyCensusFiresOnPlantedOffenders` proves it.
    static let softwarePrivateKeyAllowed: Set<String> = [
        "DeviceIdentity+Testing.swift",
        "PersonKey.swift",
    ]

    /// Prose may name a software key; code may not construct one.
    static func softwarePrivateKeyExcludeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
    }

    func test_noSoftwarePrivateKeyInProduction() throws {
        let roots = [
            sourceDir,
            repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true),
            repoRoot.appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true),
        ]
        var offenders: [String] = []
        for root in roots {
            offenders += try grepSwift(
                in: root,
                patterns: [],
                allowed: Self.softwarePrivateKeyAllowed,
                excludeLine: Self.softwarePrivateKeyExcludeLine,
                extraOffender: Self.isSoftwarePrivateKeyLine)
        }
        XCTAssertTrue(offenders.isEmpty,
            "A production file constructs a software signing key. The device key "
            + "is the enclave's — `SecureEnclave.P256.Signing.PrivateKey` — because "
            + "a software key copies off the machine with the file that holds it, "
            + "and a signature that proves nothing about the device is not a "
            + "signature. Test signers belong in DeviceIdentity+Testing.swift. "
            + "Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: the SAME predicate, over a planted file,
    /// catches the bare software key and the Curve25519 key, and lets the
    /// sanctioned enclave construction and a comment naming the software key
    /// through.
    func test_theSoftwarePrivateKeyCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-softkey-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name P256.Signing.PrivateKey() and Curve25519 — allowed.
        let sanctioned = try SecureEnclave.P256.Signing.PrivateKey()
        let reloaded = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        let forbidden = P256.Signing.PrivateKey()
        let alsoForbidden = Curve25519.Signing.PrivateKey()
        """.write(to: tmp.appendingPathComponent("BadDeviceKey.swift"),
                  atomically: true, encoding: .utf8)

        // Under the PRODUCTION allow-list: a file not named in it is caught
        // whatever else the list admits.
        let offenders = try grepSwift(
            in: tmp,
            patterns: [],
            allowed: Self.softwarePrivateKeyAllowed,
            excludeLine: Self.softwarePrivateKeyExcludeLine,
            extraOffender: Self.isSoftwarePrivateKeyLine)

        XCTAssertEqual(offenders.count, 2,
            "Self-check: the two planted software keys should be the ones caught, "
            + "and neither the enclave constructions nor the comment. Caught:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let forbidden") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let alsoForbidden") }))

        // And the allow-list entry is honoured by name.
        try fm.moveItem(at: tmp.appendingPathComponent("BadDeviceKey.swift"),
                        to: tmp.appendingPathComponent("DeviceIdentity+Testing.swift"))
        let allowed = try grepSwift(
            in: tmp,
            patterns: [],
            allowed: ["DeviceIdentity+Testing.swift"],
            excludeLine: Self.softwarePrivateKeyExcludeLine,
            extraOffender: Self.isSoftwarePrivateKeyLine)
        XCTAssertTrue(allowed.isEmpty,
            "Self-check: the allow-listed file must be skipped whole. Caught:\n"
            + allowed.joined(separator: "\n"))

        // The person key's entry is honoured by name too — and only by name:
        // the same planted keys in a file whose name merely CONTAINS it fire.
        try fm.moveItem(at: tmp.appendingPathComponent("DeviceIdentity+Testing.swift"),
                        to: tmp.appendingPathComponent("PersonKey.swift"))
        let personKey = try grepSwift(
            in: tmp,
            patterns: [],
            allowed: Self.softwarePrivateKeyAllowed,
            excludeLine: Self.softwarePrivateKeyExcludeLine,
            extraOffender: Self.isSoftwarePrivateKeyLine)
        XCTAssertTrue(personKey.isEmpty,
            "Self-check: PersonKey.swift is allow-listed by name. Caught:\n"
            + personKey.joined(separator: "\n"))

        try fm.moveItem(at: tmp.appendingPathComponent("PersonKey.swift"),
                        to: tmp.appendingPathComponent("PersonKeyHelpers.swift"))
        let lookalike = try grepSwift(
            in: tmp,
            patterns: [],
            allowed: Self.softwarePrivateKeyAllowed,
            excludeLine: Self.softwarePrivateKeyExcludeLine,
            extraOffender: Self.isSoftwarePrivateKeyLine)
        XCTAssertEqual(lookalike.count, 2,
            "Self-check: a file whose name only resembles PersonKey.swift must "
            + "still be caught. Caught:\n" + lookalike.joined(separator: "\n"))
    }

    // MARK: - One reader of iCloud's saved-by name (your devices are you, plan 2 Task 3)

    /// The spelling the census looks for: the key's name and the value's
    /// property share it, so one substring finds a request, a read and prose.
    static let savedByKeySpelling = "MostRecentEditorNameComponents"

    /// **Is this line in this file a use of the saved-by key the census
    /// refuses?** `SavedByReader.swift` is the one reader and is allowed
    /// whole. `FileURLShareMetadataReader.swift` REQUESTS the key for the share
    /// pill and never reads it, so there every occurrence must be the key's
    /// own name — `…NameComponentsKey` — and a read of the value there fires
    /// too. Everything else fires on any mention, prose included: a comment
    /// elsewhere can say `SavedByReader`.
    static func isForeignSavedByKeyUse(_ line: String, file: String) -> Bool {
        guard line.contains(savedByKeySpelling) else { return false }
        switch file {
        case "SavedByReader.swift":
            return false
        case "FileURLShareMetadataReader.swift":
            return line.components(separatedBy: savedByKeySpelling).dropFirst()
                .contains { !$0.hasPrefix("Key") }
        default:
            return true
        }
    }

    private func savedByKeyOffenders(in roots: [URL]) throws -> [String] {
        var offenders: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (i, line) in text.split(
                    separator: "\n", omittingEmptySubsequences: false).enumerated()
                where Self.isForeignSavedByKeyUse(String(line), file: url.lastPathComponent) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): "
                        + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return offenders
    }

    /// **`SavedByReader` is the one reader of iCloud's saved-by name.** A
    /// second reader is a second opinion about what nil means — and nil is
    /// the owner's own save, so a reader that filled it in would put the
    /// root's own save in somebody else's name (Review Focus 3).
    func test_theSavedByKeyIsReadBySavedByReaderOnly() throws {
        let offenders = try savedByKeyOffenders(in: [
            sourceDir,
            repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true),
            repoRoot.appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true),
        ])
        XCTAssertTrue(offenders.isEmpty,
            "iCloud's most-recent-editor name is read in SavedByReader.swift only "
            + "(FileURLShareMetadataReader.swift may request the key, never read "
            + "it). Ask SavedByReader. Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// CONTROL: the census fires on a planted reader, on a read of the value
    /// inside `FileURLShareMetadataReader.swift`, and on a file whose name
    /// only resembles the allowed one — and lets the allowed request through.
    func test_theSavedByKeyCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-savedby-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let request = "    .ubiquitousSharedItemMostRecentEditorNameComponentsKey,\n"
        let read = "let who = values.ubiquitousSharedItemMostRecentEditorNameComponents\n"

        try (request + read).write(to: tmp.appendingPathComponent("SecondReader.swift"),
                                   atomically: true, encoding: .utf8)
        XCTAssertEqual(try savedByKeyOffenders(in: [tmp]).count, 2,
                       "Self-check: any file but the two named fires on both lines")

        try fm.moveItem(at: tmp.appendingPathComponent("SecondReader.swift"),
                        to: tmp.appendingPathComponent("FileURLShareMetadataReader.swift"))
        let inShare = try savedByKeyOffenders(in: [tmp])
        XCTAssertEqual(inShare.count, 1,
            "Self-check: the share reader may request the key and not read it. Caught:\n"
            + inShare.joined(separator: "\n"))
        XCTAssertTrue(inShare.first?.contains("let who") == true)

        try fm.moveItem(at: tmp.appendingPathComponent("FileURLShareMetadataReader.swift"),
                        to: tmp.appendingPathComponent("SavedByReader.swift"))
        XCTAssertEqual(try savedByKeyOffenders(in: [tmp]), [],
                       "Self-check: SavedByReader.swift is allowed whole")

        try fm.moveItem(at: tmp.appendingPathComponent("SavedByReader.swift"),
                        to: tmp.appendingPathComponent("SavedByReaderHelpers.swift"))
        XCTAssertEqual(try savedByKeyOffenders(in: [tmp]).count, 2,
                       "Self-check: allowed by exact name, not by resemblance")
    }

    // MARK: - The device string is the key (signed op log, spec §4.8)

    /// The three production roots the device-identity censuses scan. The
    /// shared substrate is in the list because a hand-built id there would
    /// reach BOTH surfaces at once.
    private var deviceIdentityRoots: [URL] {
        [sourceDir,
         repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true),
         repoRoot.appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true)]
    }

    /// Prose may name a host name or a legacy id spelling; code may not use
    /// one. SHARED by the two censuses below and their planted-offender
    /// self-checks — one place to widen the shape.
    static func deviceIdentityExcludeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
    }

    /// `ProcessInfo.processInfo.hostName` was the Mac's device id until the
    /// signed op log; every other spelling of a host name is the same mistake.
    static let hostnameIdentityPatterns = [".hostName"]

    /// The two hand-built id spellings this milestone retired: the phone's
    /// `"phone:<uuid>"` convention and the Mac's empty-hostname fallback.
    static let handBuiltDeviceIdPatterns = ["\"phone:", "\"unknown-host\""]

    /// A device's identity is its KEY's fingerprint, never its host name.
    /// Two Macs named alike — the shipped default twice over, or a machine
    /// restored from another's backup — answered the same `hostName`, so their
    /// per-device op-log files collided; tripwire 17 is the record of what a
    /// collision on that file costs (a silently dropped conflict twin the
    /// loader never opens). `DeviceIdentity.author.deviceId` (MaughamCore) is
    /// the one answer on both surfaces, and it is derived from key material
    /// that cannot repeat across machines.
    func test_noHostnameIdentity() throws {
        var offenders: [String] = []
        for root in deviceIdentityRoots {
            offenders += try grepSwift(
                in: root,
                patterns: Self.hostnameIdentityPatterns,
                excludeLine: Self.deviceIdentityExcludeLine)
        }
        XCTAssertTrue(offenders.isEmpty,
            "A production file derives an identity from the host name. The "
            + "device id is `DeviceIdentity.author.deviceId` — the prefix of "
            + "this device's key fingerprint — because two Macs can share a "
            + "name and then share a per-device op-log file, which is how a "
            + "writer's lines go missing (tripwire 17). Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// No production file hand-builds a device id. The phone minted
    /// `"phone:<uuid>"` into `UserDefaults` and the Mac fell back to
    /// `"unknown-host"`; both are gone, and a second source of device strings
    /// is a second answer to which file this device appends to.
    func test_noHandBuiltDeviceIdOutsideDeviceIdentity() throws {
        var offenders: [String] = []
        for root in deviceIdentityRoots {
            offenders += try grepSwift(
                in: root,
                patterns: Self.handBuiltDeviceIdPatterns,
                excludeLine: Self.deviceIdentityExcludeLine)
        }
        XCTAssertTrue(offenders.isEmpty,
            "A production file hand-builds a device id. `DeviceIdentity` is "
            + "the only place a device string is decided, on the Mac and the "
            + "phone alike; a literal here is a device that partitions its "
            + "writes somewhere else. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the two censuses above: the SAME patterns and the SAME
    /// exclusion, over a planted file, catch the host-name read and both
    /// hand-built id spellings, and let the comments that merely NAME them
    /// through.
    func test_theDeviceIdentityCensusesFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-deviceid-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may say ProcessInfo.processInfo.hostName — allowed.
        /// And may name the old "phone:<uuid>" and "unknown-host" spellings.
        let sanctioned = DeviceIdentity.author.deviceId
        let host = ProcessInfo.processInfo.hostName
        let minted = "phone:\\(UUID().uuidString)"
        let fallback = name.isEmpty ? "unknown-host" : name
        """.write(to: tmp.appendingPathComponent("BadDeviceIdentity.swift"),
                  atomically: true, encoding: .utf8)

        let hostOffenders = try grepSwift(
            in: tmp,
            patterns: Self.hostnameIdentityPatterns,
            excludeLine: Self.deviceIdentityExcludeLine)
        XCTAssertEqual(hostOffenders.count, 1,
            "Self-check: the planted host-name READ should be the only catch, "
            + "not the comment naming it. Caught:\n"
            + hostOffenders.joined(separator: "\n"))
        XCTAssertTrue(hostOffenders.first?.contains("let host") == true)

        let idOffenders = try grepSwift(
            in: tmp,
            patterns: Self.handBuiltDeviceIdPatterns,
            excludeLine: Self.deviceIdentityExcludeLine)
        XCTAssertEqual(idOffenders.count, 2,
            "Self-check: both planted id literals should be caught, and neither "
            + "comment. Caught:\n" + idOffenders.joined(separator: "\n"))
        XCTAssertTrue(idOffenders.contains(where: { $0.contains("let minted") }))
        XCTAssertTrue(idOffenders.contains(where: { $0.contains("let fallback") }))
    }

    // MARK: - A seal line is recognised in OpLogChain only (tripwire 37)

    /// The seal line's one top-level key, in both spellings a Swift source can
    /// carry it: escaped inside a string literal (`{\"seal\":`, which is how
    /// `OpLogChain.sealPrefix` is written) and bare (`"seal":`, a raw string or
    /// a JSON fixture). SHARED by the census and its planted-offender
    /// self-check — one place to widen the shape.
    static func isSealKeyLine(_ line: String) -> Bool {
        line.contains(#"\"seal\":"#) || line.contains(#""seal":"#)
    }

    /// Prose may name the seal's wire key; code may not recognise one.
    static func sealKeyExcludeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
    }

    /// Tripwire 37, as a census rather than a warning. `OpLogChain.isSealLine`
    /// is the one door onto the `{"seal":` prefix and `JSONLAppendStore.parse`
    /// is its one caller, so a SECOND recogniser anywhere is a second opinion
    /// about what a seal is — and it fails in the worst direction, silently: a
    /// reader that hands a seal line to an element decoder reports a healthy
    /// file as damaged. The claim was true when the milestone landed, which is
    /// exactly when a census is cheap.
    /// The one recogniser's home, by type: it follows `OpLogChain` into any
    /// file the type is split across.
    static let sealLineAllowed: Set<String> = ["type:OpLogChain"]

    func test_sealLinesAreRecognisedInOpLogChainOnly() throws {
        let offenders = try grepSwift(
            in: deviceIdentityRoots,
            patterns: [],
            allowed: Self.sealLineAllowed,
            excludeLine: Self.sealKeyExcludeLine,
            extraOffender: Self.isSealKeyLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside OpLogChain.swift spells the seal line's "
            + "wire key. `OpLogChain.isSealLine` is the ONE recogniser and "
            + "`JSONLAppendStore.parse` its one caller — every reader (live "
            + "tails, decompressed segments, the inbox) goes through that "
            + "parser, so a seal can never reach an element decoder and be "
            + "reported as damage. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: the SAME predicate, over a planted file,
    /// catches both spellings and lets a comment naming the key through — and
    /// the allow-list entry is honoured by name.
    func test_theSealLineCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-seal-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try #"""
        // A comment may name the {"seal": prefix — allowed.
        let escaped = data.starts(with: Data("{\"seal\":".utf8))
        let raw = line.hasPrefix(#"{"seal":"#)
        let innocent = OpLogChain.isSealLine(data)
        """#.write(to: tmp.appendingPathComponent("SecondSealReader.swift"),
                   atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: [],
            excludeLine: Self.sealKeyExcludeLine,
            extraOffender: Self.isSealKeyLine)
        XCTAssertEqual(offenders.count, 2,
            "Self-check: both planted spellings should be caught, and neither "
            + "the comment nor the sanctioned call. Caught:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let escaped") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let raw") }))

        // The allowance is the TYPE's: the planted file must declare it.
        try fm.moveItem(at: tmp.appendingPathComponent("SecondSealReader.swift"),
                        to: tmp.appendingPathComponent("OpLogChain.swift"))
        try Self.declare("OpLogChain", in: tmp.appendingPathComponent("OpLogChain.swift"))
        let allowed = try grepSwift(
            in: [tmp],
            patterns: [],
            allowed: Self.sealLineAllowed,
            excludeLine: Self.sealKeyExcludeLine,
            extraOffender: Self.isSealKeyLine)
        XCTAssertTrue(allowed.isEmpty,
            "Self-check: the allow-listed file must be skipped whole. Caught:\n"
            + allowed.joined(separator: "\n"))
    }

    // MARK: - No hand-built device string at a production `Document.load`
    //         (signed op log P1b, plan constraint 5)

    /// Every `device:` argument found inside a `Document.load(` call
    /// expression in `text`, by line number.
    ///
    /// **Figures too** (report plan 6a Task 8): the needle is matched as a
    /// SUFFIX, so `FigureDocument.load(` — a figure's one load door, which
    /// must keep `Document.load`'s guarantees — is parsed by the same walk,
    /// and so is any later `…Document.load(` host. Do not anchor the needle.
    ///
    /// The scan is CALL-SHAPED rather than line-shaped because every
    /// production call site spans four or five lines: it walks the source with
    /// a paren counter, remembers the depth at which each `Document.load(`
    /// opened, and records a `device:` label seen while any such call is still
    /// open. Line comments are stripped first (with their newlines kept, so
    /// line numbers survive), because prose about this rule must be able to
    /// name the argument it forbids.
    ///
    /// **The stripper does not know about string literals** (the whole-branch
    /// review's M3): a `//` inside one — a URL, say — takes the rest of that
    /// line with it, so an unmatched `(` before it inflates the depth counter
    /// for the remainder of the file. Nothing in the three roots does that
    /// today, and the failure direction is a false POSITIVE, which is a red
    /// test somebody reads rather than a rule that quietly stopped holding. If
    /// one ever appears, teach the stripper about quotes rather than loosening
    /// the census.
    static func deviceArgumentsAtDocumentLoad(in text: String) -> [Int] {
        let stripped = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
        let chars = Array(stripped)
        let needle = Array("Document.load(")
        let label = Array("device:")
        var offenders: [Int] = []
        var line = 1
        var depth = 0
        var openCalls: [Int] = []   // paren depths at which a load call opened
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "\n":
                line += 1
            case "(":
                depth += 1
                if i + 1 >= needle.count,
                   Array(chars[(i + 1 - needle.count)...i]) == needle {
                    openCalls.append(depth)
                }
            case ")":
                if openCalls.last == depth { openCalls.removeLast() }
                depth -= 1
            default:
                if !openCalls.isEmpty, chars[i] == "d",
                   i + label.count <= chars.count,
                   Array(chars[i..<(i + label.count)]) == label {
                    // A LABEL, not the tail of `deviceId:` or `.device:` —
                    // the character before must not be identifier-ish.
                    let prev: Character = i > 0 ? chars[i - 1] : " "
                    if !(prev.isLetter || prev.isNumber || prev == "_" || prev == ".") {
                        offenders.append(line)
                    }
                }
            }
            i += 1
        }
        return offenders
    }

    /// **A production `Document.load` names an ACTOR, never a device string.**
    ///
    /// Before P1b, four production call sites passed a literal — `"wiki-rename"`,
    /// `"find-replace"` and `"mcp"` twice — and a literal names no key, so
    /// `OpLogStore.append` took the plain unchained path: everything Claude
    /// wrote through MCP, and both automations of the writer's hand, were lines
    /// nothing on the device could vouch for. The `device: String` overloads
    /// survive as `internal` for the test call sites that predate the actors;
    /// production says which of the four writers is acting and lets
    /// `LocalIdentities` answer with the id.
    func test_noDeviceStringAtAProductionDocumentLoad() throws {
        let roots = [
            sourceDir,
            repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true),
        ]
        var offenders: [String] = []
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in Self.deviceArgumentsAtDocumentLoad(in: text) {
                    offenders.append("\(url.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "A production `Document.load` passes a `device:` string. A device is "
            + "four writers (`DeviceActor`), and the one acting must be named as "
            + "an actor — `.author` for the writer's own acts and the automations "
            + "of their hand, `.assistant` for anything arriving through MCP, "
            + "`.translator` for the translation pipeline, `.maugham` for the app "
            + "acting on nobody's instruction. A hand-built string names no key, "
            + "so the op appends unchained and unsigned. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: over a planted file, the multi-line call
    /// and the single-line call are both caught, while the actor call, a
    /// `device:` argument to something that is not `Document.load`, a
    /// `deviceId:` label, and a comment naming the forbidden argument all go
    /// through.
    func test_theDocumentLoadActorCensusFiresOnAPlantedOffender() throws {
        let planted = """
        // A comment may say Document.load(url: x, device: "mcp", session: s).
        let fine = try await Document.load(
            url: docURL, actor: .assistant,
            session: "s", presenter: nil)
        let alsoFine = Op(docId: id, device: deviceId, session: s)
        let stillFine = PendingBuffer(projectURL: p, docId: id, device: d)
        let andFine = Document.load(url: u, deviceId: x, session: s)
        let bad = try await Document.load(
            url: docURL,
            device: "find-replace",
            session: "s", presenter: nil)
        let alsoBad = try await Document.load(url: u, device: "mcp", session: s, presenter: nil)
        """
        let offenders = Self.deviceArgumentsAtDocumentLoad(in: planted)
        XCTAssertEqual(offenders, [10, 12],
            "Self-check: the two planted `device:` arguments should be the ones "
            + "caught, and neither the actor call, the other constructors, the "
            + "`deviceId:` label, nor the comment. Caught lines: \(offenders)")
    }

    /// **The census reaches a figure's load** (report plan 6a Task 8):
    /// `FigureDocument.load(` with a `device:` label is caught, on one line or
    /// across several; the production call (an actor) and a comment naming
    /// the forbidden argument are not. Taken away, the planted file is clean.
    func test_theDocumentLoadActorCensusFiresOnAPlantedFigureLoad() throws {
        let control = """
        // A comment may say FigureDocument.load(figureId: f, device: "mcp").
        let figure = try await FigureDocument.load(
            figureId: figureId, projectURL: projectURL, actor: .author,
            session: session, presenter: presenter, documentStore: self)
        """
        XCTAssertEqual(Self.deviceArgumentsAtDocumentLoad(in: control), [],
            "Self-check: the actor call and the comment go through")

        let planted = control + """

        let bad = try await FigureDocument.load(
            figureId: figureId, projectURL: projectURL,
            device: "figure-import",
            session: session, presenter: nil, documentStore: nil)
        let alsoBad = try await FigureDocument.load(figureId: f, projectURL: p, device: d, session: s, presenter: nil, documentStore: nil)
        """
        XCTAssertEqual(Self.deviceArgumentsAtDocumentLoad(in: planted), [7, 9],
            "Self-check: both planted `device:` arguments to FigureDocument.load "
            + "are caught. Caught lines: \(Self.deviceArgumentsAtDocumentLoad(in: planted))")
    }

    // MARK: - The spawned session is the reader's own (spec 2026-09-09 §3)

    /// A line that spells the old flag inside prose rather than as an argument.
    private static func appendSystemPromptCommentLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// `--append-system-prompt` keeps Claude Code's coding-agent prompt in
    /// front of whatever Maugham says; `--system-prompt` replaces it. No
    /// production spawn may use the former.
    func test_noProductionSpawnAppendsToTheCodingAgentPrompt() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["\"--append-system-prompt\""],
            excludeLine: Self.appendSystemPromptCommentLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production spawn appends to the coding-agent system prompt. Use "
            + "--system-prompt so the preamble IS the prompt (spec 2026-09-09 §3). "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// Every production file that builds a `claude` argv (it names
    /// `--output-format`) must also pass `--setting-sources`, or the writer's
    /// hooks, plugins and global effort ride into the session.
    func test_everyProductionSpawnIgnoresTheWritersSettingsFiles() throws {
        // Hoisted rather than called inside the assertion: `XCTAssertTrue`'s
        // autoclosure is non-throwing, and one scan answers both halves.
        let offenders = try spawnSitesMissingSettingSources(in: sourceDir)
        XCTAssertTrue(offenders.isEmpty,
            "A production `claude` spawn does not pass --setting-sources \"\". "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// Files under `dir` whose text builds a claude argv (`--output-format`)
    /// without `--setting-sources`.
    private func spawnSitesMissingSettingSources(in dir: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let spawns = text.contains("\"--output-format\"")
            let ignores = text.contains("\"--setting-sources\"")
            if spawns && !ignores { offenders.append(url.lastPathComponent) }
        }
        return offenders
    }

    /// CONTROL: both censuses fire on planted offenders and pass a clean file.
    func test_theSpawnCensusesFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-spawn-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name "--append-system-prompt" — allowed.
        let bad = ["-p", "--output-format", "json", "--append-system-prompt", preamble]
        """.write(to: tmp.appendingPathComponent("BadSpawn.swift"), atomically: true, encoding: .utf8)
        try """
        let good = ["-p", "--output-format", "json", "--setting-sources", "", "--system-prompt", preamble]
        """.write(to: tmp.appendingPathComponent("GoodSpawn.swift"), atomically: true, encoding: .utf8)

        let appended = try grepSwift(
            in: tmp, patterns: ["\"--append-system-prompt\""],
            excludeLine: Self.appendSystemPromptCommentLine)
        XCTAssertEqual(appended.count, 1, "Self-check: one planted append. Caught:\n"
            + appended.joined(separator: "\n"))
        XCTAssertTrue(appended[0].hasPrefix("BadSpawn.swift"))

        let missing = try spawnSitesMissingSettingSources(in: tmp)
        XCTAssertEqual(missing, ["BadSpawn.swift"],
            "Self-check: the spawn without --setting-sources is the one caught")
    }

    // MARK: - Trust closures are built from the TrustTable only (tripwire 39)

    /// The three roots the P2a censuses scan. The shared substrate is in the
    /// list because a hand-built trust decision there would reach BOTH
    /// surfaces at once.
    private var admissionRoots: [URL] {
        [sourceDir,
         repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true),
         repoRoot.appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true)]
    }

    /// Prose may name a trust closure or the field this milestone retired;
    /// code may not build one. SHARED by the census and its self-check.
    static func admissionExcludeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
    }

    /// The shapes a trust decision took before `TrustTable` existed.
    ///
    /// `trusted: {` is the Bool overload of the walk — it can say *mine* or
    /// *nobody* and nothing in between, so a caller that builds one has
    /// decided, off its own bat, that an admitted device's sealed span is
    /// either this device's own hand or unsigned history. `trustedFingerprints`
    /// was `ChainPolicy`'s set-of-my-keys, removed in P2a;
    /// `identities.fingerprints` / `.fingerprints.contains` are the membership
    /// test that set was for.
    static let trustClosurePatterns = [
        "trusted: {", "trustedFingerprints",
        "identities.fingerprints", ".fingerprints.contains",
    ]

    /// The KEYLESS sites, by file and by spelling. Each holds no key to judge
    /// by, or must not widen past this device's own hand:
    ///
    /// - `type:OpLogClassifier` (today `OpLogClassifier.swift`) — `trusted: { _ in false }`
    ///   once: `OpLogClassifier.walk`'s no-table arm, the ONE verify walk
    ///   (foundations plan 6, Task 4). Three callers reach it: the keyless
    ///   reader of a live tail (`ProjectIntegrity.check`, which passes no
    ///   table), the fallback walk of an unsettled segment's inner seals, and
    ///   `StreamPositions.verificationForPositions` — the mark sweep's walk of
    ///   a translation sidecar or inbox manifest when no table is held. All
    ///   judge nobody, which is what P1 did for every caller.
    /// - `JSONLAppendStore.swift` — `trusted: { chain.trust($0) == .mine }`:
    ///   the chained WRITE, whose rewrite assumes a prefix. ADR 0012 gives the
    ///   file one writer, so a stranger's line in MY file is a quarantine and
    ///   never a hold, and the write path must not widen past `.mine`.
    ///
    /// A spelling rather than a bare filename, so a NEW `trusted:` closure in
    /// any allow-listed file fires. A reflow that splits one of these across two lines
    /// fires too — which is the moment to re-read the rule, not route around it.
    static let trustClosureAllowedSpellings: [String: Set<String>] = [
        "type:OpLogClassifier": ["trusted: { _ in false }"],
        "JSONLAppendStore.swift": ["trusted: { chain.trust($0) == .mine }"],
    ]

    /// Walk `roots`, recording every line matching `patterns` except where the
    /// file's entry in `allowedSpellings` names a substring the line carries.
    /// File-and-spelling rather than file alone: the allow-listed files hold
    /// the sanctioned closures AND the sanctioned table-built ones, so allowing
    /// a whole file would let a fourth keyless site in beside them.
    ///
    /// `onlyFiles`, where given, narrows the walk to those file names — for a
    /// census whose whole subject is ONE file's discipline
    /// (`test_theSilentAdmissionNarrowsNobody`, P3b Task 10), where the
    /// patterns are ordinary Swift that every other file uses legitimately.
    /// A name in `onlyFiles` that no root holds is itself an offender
    /// (`missingScope`).
    ///
    /// A key of `allowedSpellings` may be `type:<TypeName>` — every file
    /// declaring that type, resolved across all of `roots` before the walk
    /// (`SourceTree.expandingTypeKeys`); one that resolves to no file is an
    /// offender.
    private func grepSwift(
        in roots: [URL],
        patterns: [String],
        allowedSpellings: [String: Set<String>],
        excludeLine: @escaping (String) -> Bool,
        onlyFiles: Set<String>? = nil
    ) throws -> [String] {
        let (allowance, unresolved) = SourceTree.expandingTypeKeys(allowedSpellings, in: roots)
        var offenders = unresolved
        var seen: Set<String> = []
        for root in roots {
            if let onlyFiles {
                if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                    for case let url as URL in walker
                    where url.pathExtension == "swift" && onlyFiles.contains(url.lastPathComponent) {
                        seen.insert(url.lastPathComponent)
                    }
                }
            }
            offenders += try grepSwift(
                in: root,
                patterns: [],
                excludeLine: excludeLine,
                extraOffender: nil,
                perFile: { name, number, line in
                    if let onlyFiles, !onlyFiles.contains(name) { return false }
                    guard patterns.contains(where: { line.contains($0) }) else { return false }
                    let allowed = allowance.spellings(file: name, line: number)
                    return !allowed.contains(where: { line.contains($0) })
                })
        }
        if let onlyFiles { offenders += Self.missingScope(onlyFiles, seen: seen) }
        return offenders
    }

    /// `grepSwift` with a predicate that sees the FILE NAME and the 1-based
    /// LINE NUMBER as well as the line. The existing overloads cannot: their allow-list is whole-file and
    /// their `extraOffender` sees a line with no idea where it came from.
    private func grepSwift(
        in dir: URL,
        patterns: [String],
        excludeLine: ((String) -> Bool)?,
        extraOffender: ((String) -> Bool)?,
        perFile: (String, Int, String) -> Bool
    ) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                if let exclude = excludeLine, exclude(lineStr) { continue }
                var hit = patterns.contains { lineStr.contains($0) }
                if !hit, let extra = extraOffender { hit = extra(lineStr) }
                if !hit { hit = perFile(name, i + 1, lineStr) }
                if hit {
                    offenders.append("\(name):\(i + 1): "
                        + lineStr.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return offenders
    }

    /// Tripwire 39. Who a seal's key is to this device is `TrustTable`'s one
    /// answer, in six words (`.mine`, `.admitted`, `.stranger`, `.revoked`,
    /// `.otherRoot`, `.noChain`), and a walk takes the verdict. A closure built
    /// anywhere else can only say *mine* or *nobody*, and the middle of that
    /// range is the whole of P2a: an admitted device's sealed span applied as
    /// this device's own, a stranger's applied as unsigned history rather than
    /// HELD. Both failures are silent — the words land in the manuscript and
    /// nothing goes red.
    func test_everyTrustClosureIsBuiltFromTheTrustTable() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.trustClosurePatterns,
            allowedSpellings: Self.trustClosureAllowedSpellings,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file decides trust without a `TrustTable`. The walk "
            + "takes a `TrustVerdict`; the Bool `trusted:` overload is P1's "
            + "shape and survives only at the keyless sites named in "
            + "`trustClosureAllowedSpellings` with the reason (counted by "
            + "`typeAllowanceBounds`). "
            + "`ChainPolicy.trustedFingerprints` is gone. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - Registry records are written through RegistryWriter only
    //         (tripwire 40)

    /// The FOUR registry directories, as a Swift source can spell them, plus
    /// the two acts that make a file in one of them a RECORD: the canonical
    /// digest a signature is made over, and the per-record URL.
    ///
    /// **`events` joined in P3a** — `.maugham/people/events`, the permit
    /// history. Its literal is already caught by the `.maugham/people` prefix;
    /// what needed its own spelling is the component-at-a-time compose
    /// (`…("people").appendingPathComponent("events")`), which is exactly how
    /// `RegistryWriter` builds it and so exactly how a second writer would.
    ///
    /// **Three spellings of each directory, not one** (whole-branch review,
    /// Minor 2). The literal with its leading dot is the obvious one; a writer
    /// composing the path a component at a time —
    /// `.appendingPathComponent(".maugham").appendingPathComponent("devices")`
    /// — walks straight past it, and so does a bare `"maugham/devices"` under
    /// some other prefix. The last two patterns are what close those, and the
    /// planted-offender control carries one of each shape.
    static let registryPathPatterns = [
        "\".maugham/devices", "\".maugham/people", "\".maugham/claims",
        "maugham/devices", "maugham/people", "maugham/claims", "maugham/events",
        "PathComponent(\"devices", "PathComponent(\"people", "PathComponent(\"claims",
        "PathComponent(\"events",
        "digestHex(ofRecord:", "RegistryWriter.url(",
    ]

    /// The three files that may spell a registry path or sign a record.
    /// `RegistryWriter.swift` builds the paths and makes the signature;
    /// `RegistryWriter+Restore.swift` puts already-signed bytes back for the
    /// cache; `RegistryReader.swift` re-derives the digest to verify one.
    /// Everything else asks `RegistryWriter.directoryURL` — a read, and the
    /// door those three are behind.
    static let registryWriterAllowed: Set<String> = [
        "RegistryWriter.swift", "RegistryWriter+Restore.swift", "RegistryReader.swift",
    ]

    /// Tripwire 40. Every record is signed, and a record written any other way
    /// is one no reader can vouch for — the reader's honest answer to it is
    /// *malformed*, which is a device silently un-admitted and its whole
    /// history left pending. One writer is what makes the signer check
    /// (`RegistryWriteError.wrongSigner`) a door rather than call-site
    /// discipline, and one place spelling `.maugham/devices` / `.maugham/people`
    /// / `.maugham/people/claims` is what stops a second opinion about where a
    /// record lives.
    func test_registryRecordsAreWrittenThroughRegistryWriterOnly() throws {
        var offenders: [String] = []
        for root in admissionRoots {
            offenders += try grepSwift(
                in: root,
                patterns: Self.registryPathPatterns,
                allowed: Self.registryWriterAllowed,
                excludeLine: Self.admissionExcludeLine)
        }
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside RegistryWriter.swift, "
            + "RegistryWriter+Restore.swift and RegistryReader.swift spells a "
            + "registry path or signs a record. `RegistryWriter.write` is the "
            + "one door (it refuses an identity that is not the one the record "
            + "names); `RegistryWriter.directoryURL` is what a reader asks. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - The registry's writers are a census (P2b Task 10)

    /// The four verbs that put bytes into the registry folder.
    ///
    /// `write` signs a record and refuses an identity that is not the one the
    /// record names; `writeUnchecked` skips that check; `restore` puts already
    /// signed bytes back; `resign` re-signs a record from the FILE object so a
    /// later build's unknown fields survive. Each is a way to change what a
    /// reader will believe about who may write in this book.
    static let registryWriterVerbs = [
        "RegistryWriter.write(", "RegistryWriter.writeUnchecked(",
        "RegistryWriter.restore(", "RegistryWriter.resign(",
    ]

    /// The THREE production files that may call one, and what each is for.
    ///
    /// - `RegistryPresence.swift` — a device announcing itself, and the silent
    ///   admission of a device the writer has already named elsewhere.
    /// - `RegistryAdmission.swift` — the writer's own admit / revoke / retire /
    ///   re-admit, each with its authority check in front of it.
    /// - `RegistryCache.swift` — `restore` alone, in both of its senses:
    ///   `reconcile` putting back a record this device verified and the folder
    ///   has LOST, and (P2 smoke find 1) `RegistryCache.restore(_:in:)` putting
    ///   one back over a record the folder still holds and will not verify,
    ///   which is a press in People & Devices rather than anything an open
    ///   decides.
    ///
    /// `RegistryWriter.swift` and `RegistryWriter+Restore.swift` are the verbs'
    /// own files and are not callers.
    static let registryWriterCallers: Set<String> = [
        "RegistryPresence.swift", "type:RegistryAdmission", "RegistryCache.swift",
        "RegistryWriter.swift", "RegistryWriter+Restore.swift",
    ]

    /// **A fourth caller is a fourth opinion about who may write in this book.**
    ///
    /// Tripwire 40 already says every record goes through `RegistryWriter`;
    /// this is the other half, and it is the half that matters for admission.
    /// The writer's authority is not checked inside `write` for every case —
    /// `RegistryAdmission` is where *only the root that admitted them may
    /// revoke them* lives, and `RegistryPresence` is where *a device signs its
    /// own record* lives. A call from anywhere else reaches the signing without
    /// reaching the rule, and what it produces is a perfectly valid record
    /// nobody was entitled to write.
    func test_theRegistrysWritersAreThreeFiles() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.registryWriterVerbs,
            allowed: Self.registryWriterCallers,
            excludeLine: Self.admissionExcludeLine,
            extraOffender: nil)
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside RegistryPresence.swift, "
            + "RegistryAdmission.swift and RegistryCache.swift writes a "
            + "registry record. The authority rules live in the first two "
            + "(who may revoke, who may sign a device record); a call that "
            + "skips them reaches the signature without reaching the rule. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// **No not-yet flag is left standing in production.**
    ///
    /// P2a drew several controls it could not yet wire and gated each on a
    /// constant — `admitIsAvailable` was the pattern. P2b wired them, and a
    /// gate that is now a constant `true` is worse than no gate: it draws as
    /// conditionally live, cannot be anything but live, and the next writer of
    /// the file has to prove it is dead before touching it. One left at
    /// `false` is worse still — a control the writer can see and never press,
    /// with no sentence saying why.
    func test_noAvailabilityFlagIsLeftStandingInProduction() throws {
        var offenders: [String] = []
        for root in admissionRoots {
            offenders += try grepSwift(
                in: root,
                patterns: [],
                excludeLine: Self.admissionExcludeLine,
                extraOffender: Self.isAvailabilityFlagDeclaration)
        }
        XCTAssertTrue(offenders.isEmpty,
            "A production file declares a static `…IsAvailable` constant. "
            + "A milestone's not-yet flag is deleted when the wiring lands, "
            + "along with the `.disabled(!…)` it fed — a control is live or it "
            + "is not drawn. Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// A `static let|var <name>IsAvailable = true|false` declaration, which is
    /// the shape a milestone's not-yet flag takes. A `.isAvailable` READ of a
    /// system API (`SecureEnclave.isAvailable`, a speech recogniser's) is not
    /// this and must pass: it is a fact about the machine, asked at the moment
    /// it matters.
    static func isAvailabilityFlagDeclaration(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("static let ") || trimmed.hasPrefix("static var ")
        else { return false }
        guard trimmed.contains("IsAvailable") else { return false }
        return trimmed.contains("= true") || trimmed.contains("= false")
    }

    /// CONTROL for both P2a censuses: the SAME patterns and the SAME
    /// exclusions, over planted files, catch every offender, let the three
    /// sanctioned trust spellings and the sanctioned `directoryURL` call
    /// through, and honour the allow-lists by name.
    func test_theAdmissionCensusesFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-admission-selfcheck-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name trusted: { _ in true } and trustedFingerprints.
        let bad = chain.verify(bytes: data, trusted: { _ in true })
        let stale = policy.trustedFingerprints
        let member = identities.fingerprints
        let test = mine.fingerprints.contains(key)
        let good = chain.verify(bytes: data, trust: { table.verdict(forSealKey: $0) })
        """.write(to: tmp.appendingPathComponent("SecondTrustOpinion.swift"),
                  atomically: true, encoding: .utf8)

        // No planted file declares `OpLogClassifier` yet, so its type key is
        // (correctly) unresolved here; the control is about the four decisions.
        let trust = Self.dropping(unplanted: ["type:OpLogClassifier"], from: try grepSwift(
            in: [tmp],
            patterns: Self.trustClosurePatterns,
            allowedSpellings: Self.trustClosureAllowedSpellings,
            excludeLine: Self.admissionExcludeLine))
        XCTAssertEqual(trust.count, 4,
            "Self-check: the four planted decisions should be caught, and "
            + "neither the comment nor the table-built walk. Caught:\n"
            + trust.joined(separator: "\n"))
        XCTAssertTrue(trust.contains(where: { $0.contains("let bad") }))
        XCTAssertTrue(trust.contains(where: { $0.contains("let stale") }))
        XCTAssertTrue(trust.contains(where: { $0.contains("let member") }))
        XCTAssertTrue(trust.contains(where: { $0.contains("let test") }))

        // The allow-list is a TYPE plus a SPELLING: the keyless walk passes
        // inside the keyed type's declaration, a new closure there does not,
        // and a LOOKALIKE-named type is not the keyed one — its keyless line
        // fires, because the key claims `OpLogClassifier`'s declarations and
        // nothing whose name merely starts the same way.
        try """
        let keyless = chain.verify(bytes: data, trusted: { _ in false })
        let widened = chain.verify(bytes: data, trusted: { _ in true })
        """.write(to: tmp.appendingPathComponent("OpLogClassifier.swift"),
                  atomically: true, encoding: .utf8)
        try Self.declare("OpLogClassifier", in: tmp.appendingPathComponent("OpLogClassifier.swift"))
        try """
        let lookalike = chain.verify(bytes: data, trusted: { _ in false })
        """.write(to: tmp.appendingPathComponent("OpLogClassifierShadow.swift"),
                  atomically: true, encoding: .utf8)
        try Self.declare("OpLogClassifierShadow", in: tmp.appendingPathComponent("OpLogClassifierShadow.swift"))
        try """
        let write = chain.verify(bytes: data, trusted: { chain.trust($0) == .mine })
        """.write(to: tmp.appendingPathComponent("JSONLAppendStore.swift"),
                  atomically: true, encoding: .utf8)

        let allowed = try grepSwift(
            in: [tmp],
            patterns: Self.trustClosurePatterns,
            allowedSpellings: Self.trustClosureAllowedSpellings,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(allowed.filter { $0.hasPrefix("OpLogClassifier.swift") }.count, 1,
            "Self-check: the keyless spelling passes and a NEW closure in the "
            + "same type does not. Caught:\n" + allowed.joined(separator: "\n"))
        XCTAssertTrue(allowed.contains(where: { $0.contains("let widened") }))
        XCTAssertFalse(allowed.contains(where: { $0.contains("let keyless") }))
        XCTAssertTrue(allowed.contains(where: { $0.contains("let lookalike") }),
            "Self-check: a lookalike-named type's keyless line is NOT allowed. "
            + "Caught:\n" + allowed.joined(separator: "\n"))
        XCTAssertFalse(allowed.contains(where: { $0.contains("let write") }))

        // The registry census, over its own planted file.
        let registryTmp = tmp.appendingPathComponent("registry")
        try fm.createDirectory(at: registryTmp, withIntermediateDirectories: true)
        try """
        // A comment may name .maugham/devices and digestHex(ofRecord:).
        let dir = projectURL.appendingPathComponent(".maugham/devices", isDirectory: true)
        let people = projectURL.appendingPathComponent(".maugham/people")
        let digest = try RegistryCanonical.digestHex(ofRecord: record)
        let file = RegistryWriter.url(.devices, fingerprint: fp, in: projectURL)
        let composed = base.appendingPathComponent(".maugham").appendingPathComponent("devices")
        let bare = support.appendingPathComponent("maugham/claims")
        let composedEvents = people.appendingPathComponent("events", isDirectory: true)
        let bareEvents = support.appendingPathComponent("maugham/events")
        let sanctioned = RegistryWriter.directoryURL(.people, in: projectURL)
        """.write(to: registryTmp.appendingPathComponent("SecondRegistryWriter.swift"),
                  atomically: true, encoding: .utf8)

        let registry = try grepSwift(
            in: registryTmp,
            patterns: Self.registryPathPatterns,
            allowed: Self.registryWriterAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(registry.count, 8,
            "Self-check: the two path literals, the digest, the record URL, the "
            + "component-at-a-time compose, the bare relative path and the two "
            + "events spellings should be caught, and neither the comment nor "
            + "the sanctioned `directoryURL` read. Caught:\n"
            + registry.joined(separator: "\n"))
        XCTAssertTrue(registry.contains(where: { $0.contains("let composedEvents") }),
            "the events directory is composed from its parent, which is exactly "
            + "how RegistryWriter builds it and how a second writer would")
        XCTAssertTrue(registry.contains(where: { $0.contains("let bareEvents") }))
        XCTAssertTrue(registry.contains(where: { $0.contains("let composed") }),
            "a path composed one component at a time is still a registry path")
        XCTAssertTrue(registry.contains(where: { $0.contains("let bare") }),
            "and so is one written without the leading dot")
        XCTAssertFalse(registry.contains(where: { $0.contains("let sanctioned") }))

        try fm.moveItem(at: registryTmp.appendingPathComponent("SecondRegistryWriter.swift"),
                        to: registryTmp.appendingPathComponent("RegistryWriter.swift"))
        let allowedRegistry = try grepSwift(
            in: registryTmp,
            patterns: Self.registryPathPatterns,
            allowed: Self.registryWriterAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(allowedRegistry.isEmpty,
            "Self-check: an allow-listed file is skipped whole. Caught:\n"
            + allowedRegistry.joined(separator: "\n"))
    }

    /// CONTROL for the two P2b Task 10 censuses: the same patterns and the same
    /// exclusions, over planted files, catch every offender and honour the
    /// allow-list by name.
    func test_theRegistryWriterAndAvailabilityCensusesFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-writers-selfcheck-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name RegistryWriter.write( and RegistryWriter.resign(.
        try RegistryWriter.write(record, signedBy: identity, in: projectURL)
        try RegistryWriter.writeUnchecked(record, signedBy: identity, in: projectURL)
        _ = try RegistryWriter.restore(rawBytes: bytes, to: .people, fingerprint: fp)
        try RegistryWriter.resign(file, signedBy: identity, in: projectURL)
        let read = RegistryWriter.directoryURL(.people, in: projectURL)
        """.write(to: tmp.appendingPathComponent("FourthRegistryWriter.swift"),
                  atomically: true, encoding: .utf8)

        // Nothing planted declares `RegistryAdmission` yet: its type key is
        // (correctly) unresolved, and the control is about the four verbs.
        let writers = Self.dropping(unplanted: ["type:RegistryAdmission"], from: try grepSwift(
            in: [tmp],
            patterns: Self.registryWriterVerbs,
            allowed: Self.registryWriterCallers,
            excludeLine: Self.admissionExcludeLine,
            extraOffender: nil))
        XCTAssertEqual(writers.count, 4,
            "Self-check: all four write verbs should be caught, and neither the "
            + "comment nor the `directoryURL` read. Caught:\n"
            + writers.joined(separator: "\n"))
        XCTAssertFalse(writers.contains(where: { $0.contains("let read") }),
            "reading where a record lives is not writing one")

        try fm.moveItem(at: tmp.appendingPathComponent("FourthRegistryWriter.swift"),
                        to: tmp.appendingPathComponent("RegistryAdmission.swift"))
        try Self.declare("RegistryAdmission",
                         in: tmp.appendingPathComponent("RegistryAdmission.swift"))
        let allowedWriters = try grepSwift(
            in: [tmp],
            patterns: Self.registryWriterVerbs,
            allowed: Self.registryWriterCallers,
            excludeLine: Self.admissionExcludeLine,
            extraOffender: nil)
        XCTAssertTrue(allowedWriters.isEmpty,
            "Self-check: an allow-listed caller is skipped whole. Caught:\n"
            + allowedWriters.joined(separator: "\n"))

        // The availability-flag census, over its own planted file. A system
        // API's `isAvailable` is a fact about the machine and must pass.
        let flags = tmp.appendingPathComponent("flags")
        try fm.createDirectory(at: flags, withIntermediateDirectories: true)
        try """
        // A comment may say static let admitIsAvailable = false.
        static let admitIsAvailable = true
        static var mergeIsAvailable = false
        guard SecureEnclave.isAvailable else { return nil }
        if recognizer.isAvailable { start() }
        static let admitTitle = "Admit…"
        """.write(to: flags.appendingPathComponent("StillGated.swift"),
                  atomically: true, encoding: .utf8)

        let stale = try grepSwift(
            in: flags,
            patterns: [],
            excludeLine: Self.admissionExcludeLine,
            extraOffender: Self.isAvailabilityFlagDeclaration)
        XCTAssertEqual(stale.count, 2,
            "Self-check: both declared flags should be caught — the `true` as "
            + "well as the `false`, since a constant `true` gate is the shape "
            + "P2b's wiring leaves behind — and neither the comment, the two "
            + "system-API reads, nor the unrelated constant. Caught:\n"
            + stale.joined(separator: "\n"))
        XCTAssertTrue(stale.contains(where: { $0.contains("admitIsAvailable") }))
        XCTAssertTrue(stale.contains(where: { $0.contains("mergeIsAvailable") }))
        XCTAssertFalse(stale.contains(where: { $0.contains("SecureEnclave") }),
            "asking the machine whether it has an enclave is not a not-yet flag")
        XCTAssertFalse(stale.contains(where: { $0.contains("recognizer") }))
        XCTAssertFalse(stale.contains(where: { $0.contains("admitTitle") }))
    }

    // MARK: - The role check reads the timeline (P3a Task 10, spec §3.4)

    /// A read of a registry record's PERMIT FIELDS, as a Swift source can spell
    /// one: `role`, `scope` and `pieces` on a receiver that reads like a
    /// registry record or a permit event.
    ///
    /// **The receiver is part of the pattern because the three field names are
    /// ordinary English**, and each is a property of unrelated types all over
    /// this app — `ResearchItem.role`, `ProductionRole.role`,
    /// `Collaborator.role`, `Statement.scope`, `TaskFilter.scope`,
    /// `CanvasSubject.pieces`. A bare `.role` census would be hundreds of lines
    /// of noise, which is a census nobody reads.
    ///
    /// **Its known limit**, stated rather than hidden: a receiver named
    /// something else — `existing`, `theirs`, `subject` — escapes it. Those
    /// words are all bound to OTHER types in this tree today (`existing` is a
    /// `ResearchItem` in `ProjectStore+Palette`, `subject` a `CanvasSubject`),
    /// so widening the receiver list would buy offenders it cannot tell apart
    /// and allow-list entries that teach the wrong rule.
    static let permitFieldPatterns: [String] = {
        var out: [String] = []
        for receiver in ["record", "person", "standing", "event"] {
            for field in ["role", "scope", "pieces"] {
                out.append("\(receiver).\(field)")
                out.append("\(receiver)?.\(field)")
            }
        }
        return out
    }()

    /// Where a permit field may be read, by file AND by spelling.
    ///
    /// - `RegistryAdmission.swift` — the WRITER. It carries a standing
    ///   person's permit forward when a rename re-signs their record
    ///   (`standing.role`), reads a subject's own permit onto the event a
    ///   retirement writes (`person?.role`), and compares the record's parsed
    ///   permit against the timeline to answer *is there anything to do*
    ///   (`record.role`, `recordBehindEvents`). All three are write-side.
    /// - `Permit.swift` — the one PARSE, off a `PermitEvent`'s three strings.
    /// - `RegistryReader.swift` — the malformed reason for an event that would
    ///   demote a root, which names the role and scope the event ASKED FOR so
    ///   the writer can see what was refused. It reads an event, not a person.
    /// - `PeopleAndDevicesModel.swift` — DISPLAY, and display only: the word
    ///   goes into the person row's `detail` line and decides nothing.
    ///
    /// `PermitTimeline.swift` has no entry and needs none: it reads an event
    /// through `Permit(event:)` and never a field of its own. The same is true
    /// of every reader in the trust layer — `TrustTable.timeline(forPerson:)`
    /// is built from `Registry.events`, never from `PersonRecord.role`.
    static let permitFieldAllowedFiles: [String: Set<String>] = [
        "type:RegistryAdmission": ["standing.role", "standing.scope",
                                   "standing.pieces", "record.role",
                                   "record.scope", "record.pieces",
                                   "person?.role", "person?.scope",
                                   "person?.pieces"],
        // The one PARSE reads an EVENT's three strings — and, since P3b Task
        // 5, a person RECORD's, which is `Permit.permit(recordedIn:)`: the
        // current-state convenience, spelled here so a surface drawing a row
        // does not assemble `Permit.parse(role:…)` for itself (tripwire 44).
        // It is still not the check — what judges a line is `PermitTimeline`,
        // and this file's own doc comment says so.
        "Permit.swift": ["event.role", "event.scope", "event.pieces",
                         "record.role", "record.scope", "record.pieces"],
        "RegistryReader.swift": ["record.role", "record.scope"],
        "PeopleAndDevicesModel.swift": ["record.role"],
    ]

    /// **The role check reads the TIMELINE, never the record's `role` field**
    /// (P3 spec §3.4).
    ///
    /// `PersonRecord.role` is a CONVENIENCE — the permit as it stands today,
    /// written so a reader can show it without replaying anything. What judges
    /// a LINE is `PermitTimeline`, because a line is judged by the permit its
    /// signer held WHEN THEY WROTE IT: a person demoted to reviewer on Tuesday
    /// wrote her chapters on Monday as an author, and a check that read the
    /// field would set every one of them aside. The same mistake in the other
    /// direction is worse — a promotion would pardon text the book had already
    /// refused.
    ///
    /// Both failures are silent. Nothing goes red; the words simply leave, or
    /// arrive.
    func test_theRoleCheckReadsTheTimelineAndNotTheRecordsField() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.permitFieldPatterns,
            allowedSpellings: Self.permitFieldAllowedFiles,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file reads a registry record's `role` / `scope` / "
            + "`pieces` outside the writer, the parse, the malformed reason and "
            + "the People & Devices row. The field says what somebody may write "
            + "TODAY; what judges a line is `PermitTimeline`, which says what "
            + "they could write when they wrote it. Deciding from the field "
            + "makes a demotion reach back through the book and a promotion "
            + "pardon what was already refused — both silently. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - One table (P3a Task 10, spec §2, §4.2)

    /// The one classifier that says which ops become words.
    static let manuscriptClassifierPattern = "Deriver.appliesToManuscript("

    /// Its callers, named. `Deriver.swift` is its own file and folds the ops;
    /// `Permit.swift` asks it rather than restating the list (a second copy
    /// would drift, and the drift would wave a manuscript-moving kind through
    /// on the reviewer row); `ProcessSignals.swift` finds the writer's frontier
    /// by it; `DeltaBuilder.swift` builds a run's delta by it;
    /// `OpLogQuarantine.swift` decides by it which SET-ASIDE lines took words
    /// out of the draft, and so which of them spec §7.4's Send to Inbox can
    /// hand back (P3b Task 8) — a second list there would refuse a writer
    /// their own paragraph, or offer to re-file a disposition as prose.
    static let manuscriptClassifierCallers: Set<String> = [
        "Deriver.swift", "Permit.swift", "ProcessSignals.swift", "DeltaBuilder.swift",
        "OpLogQuarantine.swift",
    ]

    /// **Which ops become words is asked, never restated** — and the list of
    /// askers is the array, not a number in prose.
    func test_theManuscriptClassifierHasOneNamedSetOfCallers() throws {
        var callers: Set<String> = []
        for root in admissionRoots {
            let hits = try grepSwift(
                in: root,
                patterns: [Self.manuscriptClassifierPattern],
                allowed: [],
                excludeLine: Self.admissionExcludeLine)
            for hit in hits {
                callers.insert(String(hit.prefix(while: { $0 != ":" })))
            }
        }
        XCTAssertEqual(callers, Self.manuscriptClassifierCallers,
            "The set of files asking `Deriver.appliesToManuscript` moved. A NEW "
            + "one is a new opinion about which ops move the prose unless it is "
            + "asking rather than deciding; a MISSING one has stopped asking "
            + "and is very likely restating. Add it to "
            + "`manuscriptClassifierCallers` with its reason, or take the "
            + "second opinion out. Found: \(callers.sorted())")
    }

    /// **A figure op is never words** (report plan 6a, ruling D-c): figure
    /// kinds are `.manuscriptText` in `Permit.group`'s own switch, while
    /// `Deriver.appliesToManuscript` answers false for them, so the figure
    /// deriver has no business asking it — the census's named set already
    /// keeps it out; this pins it by name. A planted `FigureDeriver.swift`
    /// that asks is seen and fails the named set; taken away, the planted
    /// tree has no asker.
    func test_theFigureDeriverNeverAsksTheManuscriptClassifier() throws {
        let fm = FileManager.default
        let figureDeriver = repoRoot.appendingPathComponent(
            "Packages/MaughamCore/Sources/MaughamCore/Table/FigureDeriver.swift")
        let text = try String(contentsOf: figureDeriver, encoding: .utf8)
        let asks = text.split(separator: "\n").map(String.init)
            .filter { !Self.admissionExcludeLine($0) && $0.contains(Self.manuscriptClassifierPattern) }
        XCTAssertEqual(asks, [], "FigureDeriver.swift asks Deriver.appliesToManuscript")
        XCTAssertFalse(Self.manuscriptClassifierCallers.contains("FigureDeriver.swift"))

        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-figure-classifier-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        func callers() throws -> Set<String> {
            Set(try grepSwift(
                in: tmp, patterns: [Self.manuscriptClassifierPattern],
                allowed: [], excludeLine: Self.admissionExcludeLine
            ).map { String($0.prefix(while: { $0 != ":" })) })
        }
        let clean = """
        // A comment may name Deriver.appliesToManuscript(kind) without asking it.
        public static func fold(_ op: Op, into state: inout FigureState) {}
        """
        try (clean + "\nguard !Deriver.appliesToManuscript(op.kind) else { return }\n")
            .write(to: tmp.appendingPathComponent("FigureDeriver.swift"),
                   atomically: true, encoding: .utf8)
        let planted = try callers()
        XCTAssertEqual(planted, ["FigureDeriver.swift"],
            "Self-check: a FigureDeriver that asks is seen by name")
        XCTAssertFalse(planted.isSubset(of: Self.manuscriptClassifierCallers),
            "and fails the named set")

        try clean.write(to: tmp.appendingPathComponent("FigureDeriver.swift"),
                        atomically: true, encoding: .utf8)
        XCTAssertEqual(try callers(), [], "and taken away, nothing asks")
    }

    /// The spellings that would restate the permission table somewhere else.
    ///
    /// `WrittenGroup` is the table's left-hand column; `-> Allowed` is its
    /// answer type; `Permit.parse(` turns the wire strings into a permit;
    /// `Permit(event:` does the same off an event. Each is a way to decide, or
    /// to decide what was decided, and a second one fails in the direction that
    /// costs words.
    static let permitTablePatterns = [
        "WrittenGroup", "-> Allowed", "Permit.parse(", "Permit(event:",
    ]

    /// File AND spelling. `Permit.swift` is the table and holds all four.
    /// `LocalWritePermit.swift` FORWARDS to it — two wrappers that take the
    /// hardest class where none is known — so it may name the answer type and
    /// nothing else. `RegistryAdmission.swift` parses on the WRITE side (what a
    /// verb is about to write, and whether it differs from what is on disk).
    /// `PermitTimeline.swift` and `TrustEvents.swift` turn an event into the
    /// permit it installs — the timeline to judge by, the events file to
    /// narrate.
    static let permitTableAllowed: [String: Set<String>] = [
        "Permit.swift": ["WrittenGroup", "-> Allowed", "Permit.parse(", "Permit(event:"],
        "LocalWritePermit.swift": ["-> Allowed"],
        "type:RegistryAdmission": ["Permit.parse(", "Permit(event:"],
        "PermitTimeline.swift": ["Permit(event:"],
        "TrustEvents.swift": ["Permit(event:"],
    ]

    /// **`Permit.allows` is the one table** (spec §2's ladder).
    ///
    /// Its switch over `OpKind` has no `default:` on purpose: a kind added by a
    /// later build of this app fails to compile there until somebody decides
    /// who may sign it. A second switch somewhere else takes that gate away —
    /// it keeps compiling, and the new kind is waved through or refused by
    /// whichever copy the reader happened to reach.
    func test_thePermissionTableIsSpelledInThePermitLayerOnly() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.permitTablePatterns,
            allowedSpellings: Self.permitTableAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside the permit layer names the permission "
            + "table's own vocabulary. `Permit.allows` — with `Permit.group` in "
            + "front of it and `Permit.parse` behind it — is the one answer to "
            + "*may this person have signed this*. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - The partition's call sites are a named list (P3a Task 10)

    /// **Every production call of `PermitPartition.partition`, by file and by
    /// count** — the array, never a number in prose (memory: *prose counts are
    /// unmaintainable*).
    ///
    /// - `type:OpLogClassifier` × 1, summed over the type's files (in
    ///   `OpLogClassifier.swift` today): `partitioningByPermit`, the ops door,
    ///   itself reached from three sites (the live tail, a settled segment, the
    ///   fallback walk).
    /// - `type:StreamPositions` × 1 — `verificationForPositions`, the SWEEP that
    ///   computes a mark, which has to judge a file exactly as the load judges
    ///   it or the two would cut it in different places.
    /// - `TranslationStore.swift` × 1 — `loadMerged`, every translation
    ///   reader's one door.
    /// - `JSONLAppendStore.swift` × 1 — `loadVerifiedStrict`, which is how the
    ///   inbox manifest and the annotation log reach it.
    ///
    /// A MISSING site is a read path that applies another person's lines
    /// without asking what they were allowed to write. A NEW one is a second
    /// opinion about where the permit is judged, and the two would disagree the
    /// first time one of them was changed.
    static let partitionCallSites: [String: Int] = [
        "type:OpLogClassifier": 1,
        "type:StreamPositions": 1,
        "TranslationStore.swift": 1,
        "JSONLAppendStore.swift": 1,
    ]

    /// Every `PermitPartition.partition(` under `roots`, comments excluded,
    /// one per line, for `SourceTree.foldingIntoTypeKeys`.
    private func partitionCallCounts(in roots: [URL]) throws -> [(hit: SourceTree.Hit, value: Int)] {
        var counts: [(hit: SourceTree.Hit, value: Int)] = []
        for root in roots {
            let hits = try grepSwift(
                in: root,
                patterns: ["PermitPartition.partition("],
                allowed: [],
                excludeLine: Self.admissionExcludeLine)
            for hit in hits {
                counts.append((try XCTUnwrap(SourceTree.Hit(offender: hit)), 1))
            }
        }
        return counts
    }

    func test_thePartitionsCallSitesAreExactlyTheNamedList() throws {
        let (found, unresolved) = SourceTree.foldingIntoTypeKeys(
            try partitionCallCounts(in: admissionRoots),
            keyedLike: Self.partitionCallSites.keys, in: admissionRoots, combine: +)
        XCTAssertTrue(unresolved.isEmpty, "partitionCallSites: \(unresolved)")
        XCTAssertEqual(found, Self.partitionCallSites,
            "The places a line is judged by permit moved. Every read path that "
            + "applies somebody else's lines runs the partition before the "
            + "parse; a site that disappeared is a path applying unjudged text, "
            + "and a site that appeared is a second opinion about where the "
            + "judging happens. Update `partitionCallSites` with the reason in "
            + "the same commit, or put the call back. Found: \(found.sorted(by: { $0.key < $1.key }))")
    }

    // MARK: - The unsigned holder is spelled once (P3b Task 2)

    /// **The one file that may spell the unsigned holder, and the one that may
    /// classify a held line's holder.**
    ///
    /// A held line now has three reasons and one storage state, and which of
    /// the three it is turns entirely on the STRING the walk held it under.
    /// The unsigned holder is `unsigned:<stream>` — a shape no fingerprint and
    /// no device id can be — and the whole classification is total only while
    /// that literal exists in one place: a second spelling is a holder one
    /// surface recognises and another calls a stranger, which is an Admit…
    /// sheet offered about a Mac that has no key to admit.
    ///
    /// `HeldLines.holder(of:registry:)` is the one classifier for the same
    /// reason. `Registry.isStrangerDevice` and `TrustTable.isStrangerDevice`
    /// ASK it (they name `isUnsignedHolder`, which is the allowed spelling
    /// outside the file), so every admission-worded count narrows in one
    /// place; a `hasPrefix("unsigned:")` anywhere else is a filter per surface.
    static let unsignedHolderSpellings = ["\"unsigned:\"", "unsigned:\\("]

    static let heldLinesClassifierFiles: Set<String> = ["HeldLines.swift"]

    private func unsignedHolderOffenders() throws -> [String] {
        var offenders: [String] = []
        for root in admissionRoots {
            offenders.append(contentsOf: try grepSwift(
                in: root,
                patterns: Self.unsignedHolderSpellings,
                allowed: Self.heldLinesClassifierFiles,
                excludeLine: Self.admissionExcludeLine))
        }
        return offenders
    }

    func test_theUnsignedHolderIsSpelledInHeldLinesOnly() throws {
        let offenders = try unsignedHolderOffenders()
        XCTAssertTrue(offenders.isEmpty,
            "The unsigned holder’s own spelling escaped `HeldLines`. It is the "
            + "only thing that tells an unsigned stream from a stranger's key, "
            + "and a second literal fails silently in the direction that offers "
            + "an Admit… sheet about a Mac with no key. Ask "
            + "`HeldLines.isUnsignedHolder`/`unsignedHolder(for:)` instead. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    func test_theUnsignedHolderCensusFiresOnAPlantedOffender() throws {
        let planted = """
            // A comment naming "unsigned:" must not fire.
            func holdIt(_ stream: String) -> String { "unsigned:\\(stream)" }
            func isIt(_ device: String) -> Bool { device.hasPrefix("unsigned:") }
            """
        let dir = TestTemp.root
            .appendingPathComponent("held-lines-census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try planted.write(
            to: dir.appendingPathComponent("Offender.swift"),
            atomically: true, encoding: .utf8)

        let hits = try grepSwift(
            in: dir,
            patterns: Self.unsignedHolderSpellings,
            allowed: Self.heldLinesClassifierFiles,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(hits.count, 2,
            "the census must catch both spellings and let the comment through")
    }

    // MARK: - The write-side question has one function (P3a Task 8)

    /// The one "may this device's actor write here" answer, and the type it
    /// comes in. Fabricating a `LocalWritePermit` anywhere else is answering
    /// that question by hand — and the shape it takes is
    /// `LocalWritePermit(permit: .bookAuthor, …)`, which never refuses.
    ///
    /// The builder's two entries are counted too (foundations plan 6): they
    /// take the table as an ARGUMENT, so a Core caller passing `table: nil`
    /// gets `.bookAuthor` without `registerTable`'s remembered fallback — a
    /// second route to a permit round the door.
    static let localWritePermitPatterns = [
        "LocalWritePermit(", "func localWritePermit(",
        "LocalWritePermitBuilder.permit(", "LocalWritePermitBuilder.annotationAmendments(",
    ]

    /// `OpLogStore` declares the one function (the door, never throwing and
    /// never suspending); `LocalWritePermitBuilder` mints the value behind it
    /// and declares no door of its own (foundations plan 6 moved the
    /// construction out of the store, so the store is no longer allowed to
    /// spell one); `LocalWritePermit.swift` is its own file and holds the
    /// `.unrestricted` value every keyless reader and every P1/P2-era test
    /// path gets. Only the store's forwarders call the builder, each passing
    /// `registerTable()`.
    static let localWritePermitAllowed: [String: Set<String>] = [
        "type:OpLogStore": [
            "func localWritePermit(",
            "LocalWritePermitBuilder.permit(", "LocalWritePermitBuilder.annotationAmendments(",
        ],
        "type:LocalWritePermitBuilder": ["LocalWritePermit("],
        "LocalWritePermit.swift": ["LocalWritePermit("],
    ]

    func test_theWriteSidePermitQuestionHasOneFunction() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.localWritePermitPatterns,
            allowedSpellings: Self.localWritePermitAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file builds a write permit of its own. "
            + "`OpLogStore.localWritePermit(as:documentClass:)` is the one "
            + "answer to whether this device's actor may write here — it never "
            + "throws and never suspends, and it falls back to this Mac's "
            + "remembered register rather than forgetting it is a reviewer. A "
            + "hand-built one is `.unrestricted` by another name. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// **The whole-type allowances (over `OpLogClassifier`,
    /// `LocalWritePermitBuilder` and the door on `OpLogStore`), bounded by
    /// count.**
    ///
    /// `trustClosureAllowedSpellings` and `localWritePermitAllowed` key the
    /// classifier and the permit builder by TYPE, so the allowance reaches
    /// every file declaring it — an `extension LocalWritePermitBuilder` in a
    /// testing seam compiled into production Core would be the natural home
    /// for a "testing" hand-built `LocalWritePermit(`. The allow-list cannot tell a
    /// sanctioned site moved within the type from a NEW one; the count can. A
    /// site added anywhere in the type fails here, and only a move passes.
    ///
    /// - `trusted: { _ in false }` — in `OpLogClassifier`, once:
    ///   `OpLogClassifier.walk`'s no-table arm, the one verify walk the live
    ///   tail, the unsettled segment and `verificationForPositions` share
    ///   (tripwire 39's doc on the allow-list).
    /// - `LocalWritePermit(` — the five construction sites of
    ///   `LocalWritePermitBuilder.permit`, the body behind
    ///   `OpLogStore.localWritePermit(as:documentClass:)` (foundations plan 6
    ///   moved all five out of the store), plus `LocalWritePermit.swift`'s own
    ///   `.unrestricted` value.
    /// - `func localWritePermit(` — the door's two overloads on `OpLogStore`
    ///   (`as:placement:` and `as:documentClass:startedBy:`). A third is a
    ///   second door.
    /// - `LocalWritePermitBuilder.permit(` — those two forwarders, each
    ///   passing `registerTable()`; the builder's own placement overload calls
    ///   `permit(` unqualified and is not counted.
    /// - `LocalWritePermitBuilder.annotationAmendments(` — the store's one
    ///   `annotationAmendments` forwarder.
    static let typeAllowanceBounds: [String: [String: Int]] = [
        "trusted: { _ in false }": ["type:OpLogClassifier": 1],
        "LocalWritePermit(": ["type:LocalWritePermitBuilder": 5, "LocalWritePermit.swift": 1],
        "func localWritePermit(": ["type:OpLogStore": 2],
        "LocalWritePermitBuilder.permit(": ["type:OpLogStore": 2],
        "LocalWritePermitBuilder.annotationAmendments(": ["type:OpLogStore": 1],
    ]

    func test_theTypeKeyedOpLogStoreAllowancesAreBoundedByCount() throws {
        for (pattern, expected) in Self.typeAllowanceBounds {
            let (found, unresolved) = try countedListFound(
                of: pattern, keyedLike: expected, in: admissionRoots)
            XCTAssertTrue(unresolved.isEmpty, "typeAllowanceBounds[\(pattern)]: \(unresolved)")
            XCTAssertEqual(found, expected,
                "The sites spelling “\(pattern)” moved. The type-keyed allow-list "
                + "lets the spelling anywhere in the keyed type's files; this count is "
                + "what keeps that to the sites already reviewed. A new one is a new "
                + "keyless decision or a hand-built permit — gate it, or update "
                + "`typeAllowanceBounds` with its reason. Found: "
                + "\(found.sorted(by: { $0.key < $1.key }))")
        }
    }

    // MARK: - The verify walk's callers are a named list (tripwire 39's decisions)

    /// **Every production call of `OpLogClassifier.walk`, by type and by
    /// count.** Tripwire 39 counts the keyless SPELLING, and since foundations
    /// plan 6 that spelling lives once, inside `walk`'s no-table arm — so the
    /// keyless DECISIONS are the walk's callers. **Each caller is a keyless
    /// decision wherever it can pass a nil table**, and a new one would take
    /// the keyless arm without tripwire 39 seeing it.
    ///
    /// Counted by the spelling `walk(bytes:`, which every caller writes on one
    /// line; the declaration breaks it across lines, so it is not counted.
    ///
    /// - `type:OpLogClassifier` × 2 — `classifyTail` (the live tail; keyless
    ///   for `ProjectIntegrity.check`, which passes no table) and
    ///   `classifySegment`'s fallback walk of an unsettled segment.
    /// - `type:StreamPositions` × 1 — `verificationForPositions`, the mark
    ///   sweep's walk of a translation sidecar or inbox manifest.
    ///
    /// A MISSING caller is a reader that walks its own way. A NEW one is a
    /// keyless decision nobody reviewed: name it here with its reason.
    static let walkCallSites: [String: Int] = [
        "type:OpLogClassifier": 2,
        "type:StreamPositions": 1,
    ]

    static let walkCallPattern = "walk(bytes:"

    func test_theVerifyWalksCallersAreExactlyTheNamedList() throws {
        let (found, unresolved) = try countedListFound(
            of: Self.walkCallPattern, keyedLike: Self.walkCallSites, in: admissionRoots)
        XCTAssertTrue(unresolved.isEmpty, "walkCallSites: \(unresolved)")
        XCTAssertEqual(found, Self.walkCallSites,
            "The callers of `OpLogClassifier.walk` moved. Each one is a keyless "
            + "decision wherever it can pass a nil table — tripwire 39 counts the "
            + "keyless spelling inside `walk`, so this list is where its callers "
            + "are reviewed. Update `walkCallSites` with the reason in the same "
            + "commit, or route the read through an existing caller. Found: "
            + "\(found.sorted(by: { $0.key < $1.key }))")
    }

    /// CONTROL: an extra call in a listed type, and a call in an unlisted
    /// type, each move the count; the declaration and a comment do not.
    func test_theVerifyWalkCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-walk-selfcheck-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name walk(bytes: freely.
        static func walk(
            bytes: Data, trust: TrustTable?, rememberedHead: String?, url: URL
        ) -> Verification { fatalError() }
        func tail() { _ = walk(bytes: b, trust: t, rememberedHead: h, url: u) }
        func segment() { _ = walk(bytes: b, trust: t, rememberedHead: nil, url: u) }
        """.write(to: tmp.appendingPathComponent("OpLogClassifier.swift"),
                  atomically: true, encoding: .utf8)
        try Self.declare("OpLogClassifier", in: tmp.appendingPathComponent("OpLogClassifier.swift"))
        try """
        func sweep() { _ = OpLogClassifier.walk(bytes: b, trust: t, rememberedHead: nil, url: u) }
        """.write(to: tmp.appendingPathComponent("StreamPositions.swift"),
                  atomically: true, encoding: .utf8)
        try Self.declare("StreamPositions", in: tmp.appendingPathComponent("StreamPositions.swift"))

        let (clean, unresolved) = try countedListFound(
            of: Self.walkCallPattern, keyedLike: Self.walkCallSites, in: [tmp])
        XCTAssertTrue(unresolved.isEmpty, "\(unresolved)")
        XCTAssertEqual(clean, Self.walkCallSites,
            "Self-check: the named callers match, and neither the declaration "
            + "nor the comment is counted. Found: \(clean)")

        // An unlisted type's call is a new keyless decision.
        try """
        func stranger() { _ = OpLogClassifier.walk(bytes: b, trust: nil, rememberedHead: nil, url: u) }
        """.write(to: tmp.appendingPathComponent("Stranger.swift"),
                  atomically: true, encoding: .utf8)
        try Self.declare("Stranger", in: tmp.appendingPathComponent("Stranger.swift"))
        let (withStranger, _) = try countedListFound(
            of: Self.walkCallPattern, keyedLike: Self.walkCallSites, in: [tmp])
        XCTAssertEqual(withStranger["Stranger.swift"], 1, "\(withStranger)")
        XCTAssertNotEqual(withStranger, Self.walkCallSites)
        try fm.removeItem(at: tmp.appendingPathComponent("Stranger.swift"))

        // An extra call inside a listed type moves that type's count.
        try """
        func third() { _ = walk(bytes: b, trust: nil, rememberedHead: nil, url: u) }
        """.write(to: tmp.appendingPathComponent("OpLogClassifier+Extra.swift"),
                  atomically: true, encoding: .utf8)
        try Self.declare("OpLogClassifier", in: tmp.appendingPathComponent("OpLogClassifier+Extra.swift"))
        let (withExtra, _) = try countedListFound(
            of: Self.walkCallPattern, keyedLike: Self.walkCallSites, in: [tmp])
        XCTAssertEqual(withExtra["type:OpLogClassifier"], 3, "\(withExtra)")
        XCTAssertNotEqual(withExtra, Self.walkCallSites)
    }

    /// A permit compared to a literal rung. Unlike a bare `.reviewer` — also
    /// `Posture.Reason.reviewer` and `PostureStandingLine`'s own kind, the
    /// display values surfaces are MEANT to switch on — these three spellings
    /// can only be this milestone's `Permit`.
    static let permitLiteralPatterns = [
        "Permit.bookAuthor", ".author(.book)", "Permit.reviewer",
    ]

    /// The permit layer, by file and spelling. `Permit.swift` DEFINES the
    /// rungs and may name any of them; `PermitPartition.swift` asks the book
    /// author's own row for the fast path that skips a per-line decode;
    /// `OpLogPermitContext.swift` orders permits for a memo key;
    /// `TrustEventSentence.swift` puts the rung into an English sentence for
    /// History.
    static let permitLiteralAllowed: [String: Set<String>] = [
        "Permit.swift": ["Permit.bookAuthor", ".author(.book)", "Permit.reviewer"],
        "PermitPartition.swift": ["Permit.bookAuthor", ".author(.book)"],
        "OpLogPermitContext.swift": [".author(.book)"],
        "TrustEventSentence.swift": [".author(.book)"],
    ]

    /// **A rung is compared only where the permit layer compares it.**
    ///
    /// The failure this guards is the one P3c's Posture is for and P3a
    /// deliberately does not have: a surface that decides *this is a reviewer,
    /// so grey the editor out* by testing the permit against a literal, instead
    /// of asking the table what may be written. The two answers drift the first
    /// time a rung is added, and the surface is the copy that does not compile
    /// -error when it does.
    func test_aPermitRungIsComparedOnlyInThePermitLayer() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.permitLiteralPatterns,
            allowedSpellings: Self.permitLiteralAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside the permit layer tests a permit against "
            + "a literal rung. Ask `Permit.allows` what may be written; the "
            + "rungs are not a vocabulary for anything else. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - The load-emission rule is one answer (final fix wave, W3(a))

    /// The two spellings of *this line is one the load path emitted on its own
    /// account*, which is a released-build grandfather and therefore permanent.
    static let loadEmissionPatterns = ["isALoadEmission", "actorJudging("]

    /// File AND spelling. `Permit.swift` DECIDES which kinds they are and
    /// answers which actor judges; `PermitPartition.swift` is the one reader
    /// that can meet a load emission under a narrowed actor, so it ASKS and
    /// never restates — `LocalWritePermit` asks as `.author`, the ownership
    /// rule asks about a disposition, and `answersWholeFile` asks about a
    /// translation record or an inbox row, so none of the three can reach one.
    static let loadEmissionAllowed: [String: Set<String>] = [
        "Permit.swift": ["isALoadEmission", "actorJudging("],
        "PermitPartition.swift": ["actorJudging("],
    ]

    /// **What the load wrote is decided in one place** (final fix wave, W3(a);
    /// whole-branch review F3).
    ///
    /// v0.37–v0.40 signed `bootstrap` and the anchor `taskCreate` with
    /// whichever actor opened the document, so the partition waives the actor
    /// narrowing for exactly those two kinds and judges them under the
    /// person's own permit. A SECOND list of which kinds those are fails
    /// silently in the direction that costs the writer a document's opening
    /// op — and the list is a `default:`-less switch over `OpKind` precisely so
    /// that a later kind the load starts emitting has to be decided rather
    /// than inherited. A second copy takes that gate away.
    func test_theLoadEmissionRuleIsSpelledInThePermitLayerOnly() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.loadEmissionPatterns,
            allowedSpellings: Self.loadEmissionAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside the permit layer decides which lines the "
            + "LOAD emitted, or which actor judges one. `Permit.isALoadEmission` "
            + "is the list and `Permit.actorJudging` is the answer; the "
            + "partition asks them. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - MCP emits no task op (P3b Task 3, Census A)

    /// Every production emitter of a task op, and the wire kind they all carry.
    ///
    /// The seven names are `Document+Tasks.swift`'s five and
    /// `ProjectStore+Tasks.swift`'s two; `kind: .task` is the prefix every task
    /// `OpKind` shares, so a new emitter that spells its own `Op(...)` rather
    /// than calling one of them is caught too.
    static let taskOpEmitterPatterns = [
        "appendTaskOpInternal",
        "createPaneTask(",
        "setTaskStatus(",
        "setTaskPriority(",
        "archiveTask(",
        "createProjectPaneTask(",
        "appendProjectTaskOp(",
        "kind: .task",
    ]

    /// **Nothing under `Maugham/MCP` emits a task op** (P3b Task 3, Census A).
    ///
    /// `Permit.isALoadEmission` names `taskCreate` a load emission **by KIND
    /// alone**, and judges it under the person's own permit whichever actor
    /// signed it. That is right today because the one `taskCreate` a non-author
    /// actor can reach is the anchor breadcrumb `Document.rebuildTasksCache`
    /// writes — the other two emitters are the writer's own pane acts, reached
    /// only from editor surfaces — so *signed by the assistant* and *emitted by
    /// the load* are the same set.
    ///
    /// Give MCP a tool that creates a task and they stop being the same set,
    /// silently: Claude's own `taskCreate` would then be waved through the
    /// actor row on the strength of a rule written for the load's housekeeping,
    /// in a book where a reviewer is meant to sign no task anywhere. Nothing
    /// goes red; the row simply stops meaning what it says.
    ///
    /// The census is the gate. A tool that genuinely should write a task is a
    /// decision about `isALoadEmission`, made here first.
    func test_nothingUnderMCPEmitsATaskOp() throws {
        let mcp = sourceDir.appendingPathComponent("MCP", isDirectory: true)
        let offenders = try grepSwift(
            in: mcp,
            patterns: Self.taskOpEmitterPatterns,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A file under Maugham/MCP emits a task op. `Permit.isALoadEmission` "
            + "waives the actor narrowing for `taskCreate` by KIND, which is "
            + "safe only while the load path is the one non-author emitter of "
            + "one. Decide that rule before adding the tool. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL for the census above: it is not passing because the patterns
    /// match nothing. A planted emitter is caught by its verb AND by the wire
    /// kind; a comment naming either is not.
    func test_theTaskOpEmitterCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-mcp-taskop-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may say appendTaskOpInternal and kind: .taskCreate freely.
        struct CreateTaskTool: MCPTool {
            func run() async throws {
                doc.createPaneTask(body: body, kind: .checkbox)
                let op = Op(opId: id, docId: docId, at: Date(), device: d,
                            session: s, kind: .taskCreate, changes: [])
                doc.appendTaskOpInternal(op)
            }
        }
        """.write(to: tmp.appendingPathComponent("CreateTaskTool.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwift(
            in: tmp,
            patterns: Self.taskOpEmitterPatterns,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(offenders.count, 3,
            "Self-check: the pane verb, the hand-built kind and the internal "
            + "append should each be caught, and not the comment. Caught:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(
            offenders.allSatisfy { $0.hasPrefix("CreateTaskTool.swift:") },
            offenders.joined(separator: "\n"))
    }

    // MARK: - CONTROL for the five P3a censuses

    /// The same patterns and the same exclusions, over planted files: every
    /// offender is caught, the comment naming one is not, and each allow-list
    /// is honoured by FILE AND SPELLING — a file allowed one spelling is still
    /// caught reaching for another.
    func test_thePermitCensusesFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-permit-selfcheck-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // -- 1. The role check reads the timeline.
        let fields = tmp.appendingPathComponent("fields")
        try fm.createDirectory(at: fields, withIntermediateDirectories: true)
        try """
        // A comment may say record.role and person?.scope all it likes.
        let rung = record.role == Permit.reviewerRole ? "held" : "applied"
        if person?.pieces?.contains(docId) == true { apply(line) }
        let asked = standing.scope
        let carried = existingItem.role
        """.write(to: fields.appendingPathComponent("SecondRoleCheck.swift"),
                  atomically: true, encoding: .utf8)

        // Each planted tree holds only part of an allow-list's scope, so the
        // `type:` keys it declares nothing for are (correctly) unresolved —
        // these controls are about the spellings, and drop exactly those lines.
        let fieldHits = Self.dropping(unplanted: ["type:RegistryAdmission"], from: try grepSwift(
            in: [fields],
            patterns: Self.permitFieldPatterns,
            allowedSpellings: Self.permitFieldAllowedFiles,
            excludeLine: Self.admissionExcludeLine))
        XCTAssertEqual(fieldHits.count, 3,
            "Self-check: the three field reads should be caught and neither the "
            + "comment nor the unrelated `existingItem.role`. Caught:\n"
            + fieldHits.joined(separator: "\n"))
        XCTAssertFalse(fieldHits.contains(where: { $0.contains("let carried") }),
            "a receiver this census cannot tell from a ResearchItem is left "
            + "alone on purpose — the limit is stated, not papered over")

        try fm.moveItem(at: fields.appendingPathComponent("SecondRoleCheck.swift"),
                        to: fields.appendingPathComponent("RegistryReader.swift"))
        let partlyAllowed = Self.dropping(unplanted: ["type:RegistryAdmission"], from: try grepSwift(
            in: [fields],
            patterns: Self.permitFieldPatterns,
            allowedSpellings: Self.permitFieldAllowedFiles,
            excludeLine: Self.admissionExcludeLine))
        XCTAssertEqual(partlyAllowed.count, 2,
            "Self-check: the allow-list is FILE PLUS SPELLING — "
            + "RegistryReader.swift may read `record.role` and is still caught "
            + "reading `person?.pieces` and `standing.scope`. Caught:\n"
            + partlyAllowed.joined(separator: "\n"))

        // -- 1b. The load-emission rule (final fix wave, W3(a)).
        let emission = tmp.appendingPathComponent("emission")
        try fm.createDirectory(at: emission, withIntermediateDirectories: true)
        try """
        // A comment may say isALoadEmission and actorJudging( all it likes.
        func isALoadEmission(_ what: Written) -> Bool { what == .op(.bootstrap) }
        let who = Permit.actorJudging(what, signedBy: actor)
        """.write(to: emission.appendingPathComponent("SecondEmissionList.swift"),
                  atomically: true, encoding: .utf8)

        let emissionHits = try grepSwift(
            in: [emission],
            patterns: Self.loadEmissionPatterns,
            allowedSpellings: Self.loadEmissionAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(emissionHits.count, 2,
            "Self-check: both spellings should be caught and not the comment. "
            + "Caught:\n" + emissionHits.joined(separator: "\n"))

        try fm.moveItem(
            at: emission.appendingPathComponent("SecondEmissionList.swift"),
            to: emission.appendingPathComponent("PermitPartition.swift"))
        let emissionPartlyAllowed = try grepSwift(
            in: [emission],
            patterns: Self.loadEmissionPatterns,
            allowedSpellings: Self.loadEmissionAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(emissionPartlyAllowed.count, 1,
            "Self-check: the allow-list is FILE PLUS SPELLING — the partition "
            + "may ASK `actorJudging(` and is still caught declaring a second "
            + "list of which kinds are load emissions. Caught:\n"
            + emissionPartlyAllowed.joined(separator: "\n"))

        // -- 2. One table.
        let table = tmp.appendingPathComponent("table")
        try fm.createDirectory(at: table, withIntermediateDirectories: true)
        try """
        // A comment may name WrittenGroup and Permit.parse( freely.
        func group(of kind: OpKind) -> WrittenGroup { .manuscriptText }
        private func row(_ g: Int) -> Allowed { .yes }
        let mine = Permit.parse(role: role, scope: scope, pieces: pieces)
        let installed = Permit(event: event)
        if Deriver.appliesToManuscript(op.kind) { fold(op) }
        """.write(to: table.appendingPathComponent("SecondTable.swift"),
                  atomically: true, encoding: .utf8)

        let tableHits = Self.dropping(unplanted: ["type:RegistryAdmission"], from: try grepSwift(
            in: [table],
            patterns: Self.permitTablePatterns,
            allowedSpellings: Self.permitTableAllowed,
            excludeLine: Self.admissionExcludeLine))
        XCTAssertEqual(tableHits.count, 4,
            "Self-check: all four restatement spellings should be caught and "
            + "not the comment. Caught:\n" + tableHits.joined(separator: "\n"))

        try fm.moveItem(at: table.appendingPathComponent("SecondTable.swift"),
                        to: table.appendingPathComponent("PermitTimeline.swift"))
        let timelineAllowed = Self.dropping(unplanted: ["type:RegistryAdmission"], from: try grepSwift(
            in: [table],
            patterns: Self.permitTablePatterns,
            allowedSpellings: Self.permitTableAllowed,
            excludeLine: Self.admissionExcludeLine))
        XCTAssertEqual(timelineAllowed.count, 3,
            "Self-check: PermitTimeline.swift may say `Permit(event:` and is "
            + "still caught declaring a group, an answer or a parse. Caught:\n"
            + timelineAllowed.joined(separator: "\n"))

        // The manuscript classifier's caller census, over the same planted file
        // now named something that is not in the list.
        try fm.moveItem(at: table.appendingPathComponent("PermitTimeline.swift"),
                        to: table.appendingPathComponent("SomeNewFolder.swift"))
        var plantedCallers: Set<String> = []
        for hit in try grepSwift(
            in: table, patterns: [Self.manuscriptClassifierPattern],
            allowed: [], excludeLine: Self.admissionExcludeLine
        ) {
            plantedCallers.insert(String(hit.prefix(while: { $0 != ":" })))
        }
        XCTAssertEqual(plantedCallers, ["SomeNewFolder.swift"],
            "Self-check: a new asker of the manuscript classifier is seen by "
            + "name. Caught: \(plantedCallers.sorted())")
        XCTAssertNotEqual(plantedCallers, Self.manuscriptClassifierCallers,
            "and so would fail the census it feeds")

        // -- 3. The partition's call sites.
        let sites = tmp.appendingPathComponent("sites")
        try fm.createDirectory(at: sites, withIntermediateDirectories: true)
        try """
        // A comment may name PermitPartition.partition( without being one.
        let a = PermitPartition.partition(of: v, file: url, judging: judge)
        let b = PermitPartition.partition(of: w, file: url, judging: judge)
        let c = PermitPartition.couldJudge(aFileNamedBy: slug, trust: table)
        """.write(to: sites.appendingPathComponent("AFifthPartitionSite.swift"),
                  atomically: true, encoding: .utf8)

        let plantedSites = Self.byFile(try partitionCallCounts(in: [sites]), combine: +)
        XCTAssertEqual(plantedSites, ["AFifthPartitionSite.swift": 2],
            "Self-check: both partition calls are counted, the comment is not, "
            + "and `couldJudge` — which judges nothing — is not. Counted: "
            + "\(plantedSites.sorted(by: { $0.key < $1.key }))")
        XCTAssertNotEqual(plantedSites, Self.partitionCallSites,
            "and a file that is not on the list fails the census it feeds")

        // -- 4. The write-side question, and the rung comparison.
        let write = tmp.appendingPathComponent("write")
        try fm.createDirectory(at: write, withIntermediateDirectories: true)
        try """
        // A comment may name LocalWritePermit( and Permit.bookAuthor.
        let permit = LocalWritePermit(permit: .bookAuthor, actor: .author, documentClass: nil)
        if resolved == Permit.bookAuthor { enableEditing() }
        if case .author(.book) = resolved { enableEditing() }
        if resolved == Permit.reviewer { greyTheEditorOut() }
        let fine = store.localWritePermit { manifestClass(of: docId) }
        """.write(to: write.appendingPathComponent("AHandBuiltPermit.swift"),
                  atomically: true, encoding: .utf8)

        let writeHits = Self.dropping(
            unplanted: ["type:OpLogStore", "type:LocalWritePermitBuilder"],
            from: try grepSwift(
                in: [write],
                patterns: Self.localWritePermitPatterns,
                allowedSpellings: Self.localWritePermitAllowed,
                excludeLine: Self.admissionExcludeLine))
        XCTAssertEqual(writeHits.count, 1,
            "Self-check: the fabricated permit is caught and the ASK of the one "
            + "function is not. Caught:\n" + writeHits.joined(separator: "\n"))
        XCTAssertTrue(writeHits.contains(where: { $0.contains("let permit") }))

        // -- 4b. The type keys are per declaration and per spelling
        // (foundations plan 6): the builder may mint and may not open a second
        // door; the store may declare the door and may no longer mint; a
        // lookalike type is admitted nothing.
        let keyed = tmp.appendingPathComponent("write-keyed")
        try fm.createDirectory(at: keyed, withIntermediateDirectories: true)
        let builderFile = keyed.appendingPathComponent("LocalWritePermitBuilder.swift")
        try """
        static func permit() -> LocalWritePermit { LocalWritePermit(permit: p, actor: a, documentClass: nil) }
        public func localWritePermit(as actor: DeviceActor) -> LocalWritePermit { fatalError() }
        """.write(to: builderFile, atomically: true, encoding: .utf8)
        try Self.declare("LocalWritePermitBuilder", in: builderFile)
        let storeFile = keyed.appendingPathComponent("OpLogStore.swift")
        try """
        public func localWritePermit(as actor: DeviceActor) -> LocalWritePermit { door() }
        func minted() -> LocalWritePermit { LocalWritePermit(permit: p, actor: a, documentClass: nil) }
        """.write(to: storeFile, atomically: true, encoding: .utf8)
        try Self.declare("OpLogStore", in: storeFile)
        // A Core file that reaches the builder round the door, either entry.
        let roundTheDoor = keyed.appendingPathComponent("PostureDoor.swift")
        try """
        let p = LocalWritePermitBuilder.permit(as: .author, documentClass: { c }, startedBy: nil, table: nil, in: url)
        let a = LocalWritePermitBuilder.annotationAmendments(table: nil, from: nil, documentClass: { c })
        """.write(to: roundTheDoor, atomically: true, encoding: .utf8)
        let shadowFile = keyed.appendingPathComponent("LocalWritePermitBuilderShadow.swift")
        try """
        func shadow() -> LocalWritePermit { LocalWritePermit(permit: p, actor: a, documentClass: nil) }
        """.write(to: shadowFile, atomically: true, encoding: .utf8)
        try Self.declare("LocalWritePermitBuilderShadow", in: shadowFile)
        let keyedHits = try grepSwift(
            in: [keyed],
            patterns: Self.localWritePermitPatterns,
            allowedSpellings: Self.localWritePermitAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(keyedHits.count, 5,
            "Self-check: the builder's second door, the store's own mint, the "
            + "lookalike's mint and both calls round the door are caught; the "
            + "builder's mint and the store's door are not. Caught:\n"
            + keyedHits.joined(separator: "\n"))
        XCTAssertTrue(keyedHits.contains(where: {
            $0.contains("PostureDoor.swift") && $0.contains("LocalWritePermitBuilder.permit(") }))
        XCTAssertTrue(keyedHits.contains(where: {
            $0.contains("PostureDoor.swift")
                && $0.contains("LocalWritePermitBuilder.annotationAmendments(") }))
        XCTAssertTrue(keyedHits.contains(where: {
            $0.contains("LocalWritePermitBuilder.swift") && $0.contains("func localWritePermit(") }))
        XCTAssertTrue(keyedHits.contains(where: {
            $0.contains("OpLogStore.swift") && $0.contains("func minted") }))
        XCTAssertTrue(keyedHits.contains(where: {
            $0.contains("LocalWritePermitBuilderShadow.swift") }))

        // -- 4c. The door and the builder's entries are bounded by count: the
        // sanctioned shape matches `typeAllowanceBounds`, and a third overload
        // or a third call round the forwarders moves the count.
        let bounded = tmp.appendingPathComponent("write-bounded")
        try fm.createDirectory(at: bounded, withIntermediateDirectories: true)
        let boundedStore = bounded.appendingPathComponent("OpLogStore.swift")
        let sanctioned = """
        // A comment may name func localWritePermit( and LocalWritePermitBuilder.permit(.
        public func localWritePermit(as a: DeviceActor, placement: ManifestPlacement) -> LocalWritePermit {
            LocalWritePermitBuilder.permit(as: a, placement: placement, table: registerTable(), in: url) }
        public func localWritePermit(as a: DeviceActor, documentClass: () -> DocumentClass) -> LocalWritePermit {
            LocalWritePermitBuilder.permit(as: a, documentClass: documentClass, startedBy: nil, table: registerTable(), in: url) }
        public func annotationAmendments() -> AnnotationAmendments {
            LocalWritePermitBuilder.annotationAmendments(table: registerTable(), from: nil, documentClass: { c }) }
        """
        try sanctioned.write(to: boundedStore, atomically: true, encoding: .utf8)
        try Self.declare("OpLogStore", in: boundedStore)
        let doorBounds = ["func localWritePermit(", "LocalWritePermitBuilder.permit(",
                          "LocalWritePermitBuilder.annotationAmendments("]
        for pattern in doorBounds {
            let expected = try XCTUnwrap(Self.typeAllowanceBounds[pattern])
            let (found, unresolved) = try countedListFound(
                of: pattern, keyedLike: expected, in: [bounded])
            XCTAssertTrue(unresolved.isEmpty, "\(unresolved)")
            XCTAssertEqual(found, expected,
                "Self-check: the sanctioned shape matches the bound for “\(pattern)”")
        }
        try (sanctioned + """

        public func localWritePermit(as a: DeviceActor) -> LocalWritePermit {
            LocalWritePermitBuilder.permit(as: a, documentClass: { c }, startedBy: nil, table: nil, in: url) }
        """).write(to: boundedStore, atomically: true, encoding: .utf8)
        try Self.declare("OpLogStore", in: boundedStore)
        for pattern in ["func localWritePermit(", "LocalWritePermitBuilder.permit("] {
            let expected = try XCTUnwrap(Self.typeAllowanceBounds[pattern])
            let (found, _) = try countedListFound(of: pattern, keyedLike: expected, in: [bounded])
            XCTAssertEqual(found["type:OpLogStore"], 3,
                "Self-check: a third overload / call round the door moves “\(pattern)”: \(found)")
            XCTAssertNotEqual(found, expected)
        }

        let rungHits = try grepSwift(
            in: [write],
            patterns: Self.permitLiteralPatterns,
            allowedSpellings: Self.permitLiteralAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(rungHits.count, 3,
            "Self-check: all three hand comparisons against a rung are caught "
            + "and not the comment. Caught:\n" + rungHits.joined(separator: "\n"))

        try fm.moveItem(at: write.appendingPathComponent("AHandBuiltPermit.swift"),
                        to: write.appendingPathComponent("PermitPartition.swift"))
        let partitionAllowed = try grepSwift(
            in: [write],
            patterns: Self.permitLiteralPatterns,
            allowedSpellings: Self.permitLiteralAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertEqual(partitionAllowed.count, 1,
            "Self-check: PermitPartition.swift may name the book author's rung "
            + "and is still caught naming the reviewer's. Caught:\n"
            + partitionAllowed.joined(separator: "\n"))
        XCTAssertTrue(partitionAllowed.contains(where: { $0.contains("greyTheEditorOut") }))
    }

    // MARK: - One macOS floor, spelled four times

    /// Every macOS floor `project.yml` declares, in file order, as
    /// `(line, key, value)`. Pure over the file's text so the census can run it
    /// on the real file and the control on a planted one.
    ///
    /// Deliberately keyless about WHICH declaration is which: the rule is that
    /// they agree, so collecting them all and counting the distinct values says
    /// it without this test having to know the shape of the YAML around them.
    /// `platform: macOS` cannot match — the value must be numeric.
    static func declaredMacOSFloors(in projectYML: String) -> [(line: Int, key: String, value: String)] {
        let pattern = #"^\s*(macOS|MACOSX_DEPLOYMENT_TARGET|LSMinimumSystemVersion):\s*"?([0-9]+(?:\.[0-9]+)*)"?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [(Int, String, String)] = []
        for (index, line) in projectYML.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = regex.firstMatch(in: line, range: range),
                  let keyRange = Range(m.range(at: 1), in: line),
                  let valueRange = Range(m.range(at: 2), in: line) else { continue }
            found.append((index + 1, String(line[keyRange]), String(line[valueRange])))
        }
        return found
    }

    /// **Tripwire: the app's macOS floor is one number, however many times
    /// `project.yml` says it.** Four declarations: `deploymentTarget.macOS`,
    /// `settings.base`'s `MACOSX_DEPLOYMENT_TARGET`, `maugham-mcp`'s (it ships
    /// inside the bundle and can never run anywhere the app cannot), and the
    /// app's `LSMinimumSystemVersion`.
    ///
    /// The last one is why this is a test and not a comment. `release.yml`
    /// publishes the BUILT app's `LSMinimumSystemVersion` into every release
    /// body, and `MinimumSystemVersion` reads it back to decide whether to
    /// offer an update at all — so that value is a promise made to other
    /// people's Macs. It sat at `14.0` from before the target was ever raised,
    /// through two floor moves, because prose linking it to the deployment
    /// target is not a link. See `Maugham/Updates/AREA.md` for what the BUILD
    /// does when they disagree, which is the reason a stale-LOW value was never
    /// able to publish a lie — and the reason a stale-HIGH one could.
    func test_everyMacOSFloorInProjectYmlIsTheSameNumber() throws {
        let yml = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"),
                             encoding: .utf8)
        let floors = Self.declaredMacOSFloors(in: yml)

        XCTAssertEqual(floors.count, 4,
            "project.yml should declare the macOS floor exactly four times "
            + "(deploymentTarget.macOS, two MACOSX_DEPLOYMENT_TARGETs, "
            + "LSMinimumSystemVersion). A fifth is fine — add it here — but a "
            + "count that DROPPED means a declaration was renamed or removed "
            + "and this census silently stopped guarding it. Found:\n"
            + floors.map { "\($0.line): \($0.key) = \($0.value)" }.joined(separator: "\n"))

        let distinct = Set(floors.map(\.value))
        XCTAssertEqual(distinct.count, 1,
            "Every macOS floor in project.yml must be the same number. "
            + "LSMinimumSystemVersion is the one macOS enforces at launch AND "
            + "the one release.yml publishes for the updater to read, so a "
            + "drift here is a promise to other people's Macs. Found:\n"
            + floors.map { "\($0.line): \($0.key) = \($0.value)" }.joined(separator: "\n"))
    }

    /// CONTROL for the census above: it is not passing because the pattern
    /// matches nothing. A planted `project.yml` with one floor out of step is
    /// caught, and `platform: macOS` is not mistaken for a version.
    func test_theMacOSFloorCensusFiresOnAPlantedOffender() throws {
        let planted = """
        options:
          deploymentTarget:
            macOS: "27.0"
            iOS: "17.0"
        settings:
          base:
            MACOSX_DEPLOYMENT_TARGET: "27.0"
        targets:
          Maugham:
            platform: macOS
            info:
              properties:
                LSMinimumSystemVersion: "14.0"
          maugham-mcp:
            settings:
              base:
                MACOSX_DEPLOYMENT_TARGET: "27.0"
        """
        let floors = Self.declaredMacOSFloors(in: planted)

        XCTAssertEqual(floors.count, 4,
            "the four numeric floors are found and `platform: macOS` is not "
            + "one of them (nor is iOS). Found:\n"
            + floors.map { "\($0.line): \($0.key) = \($0.value)" }.joined(separator: "\n"))
        XCTAssertFalse(floors.contains { $0.key == "macOS" && $0.value == "17.0" },
            "the iOS floor must not be read as the macOS one")
        XCTAssertEqual(Set(floors.map(\.value)), ["27.0", "14.0"],
            "the planted stale LSMinimumSystemVersion is seen — this is exactly "
            + "the state project.yml shipped in until 2026-09-19")

        // And the converse: the same parser over an agreeing file is silent.
        let agreeing = planted.replacingOccurrences(
            of: #"LSMinimumSystemVersion: "14.0""#,
            with: #"LSMinimumSystemVersion: "27.0""#)
        XCTAssertEqual(Set(Self.declaredMacOSFloors(in: agreeing).map(\.value)), ["27.0"])
    }

    // MARK: - P3b Task 10: the eight censuses this branch owes

    /// **The narrowing predicate and the photograph are spelled in the permit
    /// layer only.**
    ///
    /// Two spellings, one rule. `PermitTimeline.narrows(_:)` is *does this
    /// event give somebody less than the whole book* — the question the
    /// governing snapshot is chosen by and the question the schema gate turns
    /// on — and a second answer to it decides, in one place, that a book is
    /// narrowed while another goes on reading it as P1. `UnsignedSnapshot` is
    /// the photograph itself; naming the type outside the layer is how a
    /// surface comes to hold an opinion about which side of it a line falls
    /// on, which is `PermitMark.judge`'s and nobody else's.
    ///
    /// **File AND spelling, and the spellings matter here more than usual**:
    /// four identifiers CONTAIN the type's name without being it —
    /// `insideTheUnsignedSnapshot`, `recordInsideTheUnsignedSnapshot`,
    /// `resolvedInsideTheUnsignedSnapshot` and `sweptUnsignedSnapshot` — and
    /// each is allowed by name in the file that owns it. A line in one of
    /// those files that said `UnsignedSnapshot.governing(` carries none of
    /// them and is an offender.
    ///
    /// `Permit.narrows` (the plain property on a permit a caller already
    /// holds) is NOT censused: it is a read of a value, not a decision about
    /// an event, and it is read by every surface that has to say what a
    /// narrowing would cost.
    static let narrowingPatterns = ["PermitTimeline.narrows(", "UnsignedSnapshot"]

    static let narrowingAllowed: [String: Set<String>] = [
        // The photograph, and the one derivation of which one governs.
        "UnsignedSnapshot.swift": ["UnsignedSnapshot", "PermitTimeline.narrows("],
        // The one resolution: the table carries the governing snapshot.
        "TrustTable.swift": ["UnsignedSnapshot"],
        // The write side: only a NARROWING event carries a photograph.
        "type:RegistryAdmission": ["PermitTimeline.narrows("],
        // The carrier and its readers name the per-LINE fact, never the type.
        "AnnotationOwnership.swift": ["insideTheUnsignedSnapshot"],
        // The permit builder reads the carrier's resolved set
        // (`LocalWritePermitBuilder.annotationAmendments`, moved out of the
        // store by foundations plan 6)…
        "type:LocalWritePermitBuilder": [
            "insideTheUnsignedSnapshot", "InsideTheUnsignedSnapshot",
        ],
        // …and the carrier itself, `AmendmentPermits`, records and resolves
        // it. It shares `OpLogPermitContext.swift` with an `extension
        // OpLogStore`, and a type key claims DECLARATIONS, so it is named.
        "type:AmendmentPermits": [
            "insideTheUnsignedSnapshot", "InsideTheUnsignedSnapshot",
        ],
        "PermitPartition.swift": ["InsideTheUnsignedSnapshot"],
        "ProjectStore+Annotations.swift": [
            "insideTheUnsignedSnapshot", "InsideTheUnsignedSnapshot",
        ],
        // The Mac's two doors name the SWEEP that takes one, not the type.
        "type:DocumentStore": ["sweptUnsignedSnapshot"],
    ]

    func test_theNarrowingPredicateAndTheSnapshotAreInThePermitLayerOnly() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.narrowingPatterns,
            allowedSpellings: Self.narrowingAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside the permit layer names the narrowing "
            + "predicate or the unsigned photograph. Whether a book is narrowed "
            + "is `PermitTimeline.narrows`/`TrustTable.hasNarrowingPermits`, and "
            + "which side of the photograph a line falls on is "
            + "`PermitMark.judge`. A second answer to either decides, silently, "
            + "that a line is held here and applied there. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// **Whether a file is attributable at all is computed in `OpLogChain`.**
    ///
    /// `Verification.unattributable` is *this register can name no key for the
    /// bytes in this file* — the whole input to the unsigned door. It is read
    /// in three other places and that is right; what may not happen twice is
    /// somebody DECIDING it, which the argument label is the shape of. A
    /// second opinion fails in the worse direction: a file wrongly called
    /// attributable never reaches the photograph, so everything an unsigned
    /// Mac wrote after the first narrowing is applied on a Mac that should
    /// have held it.
    static let unattributableDecisionPattern = "unattributable:"

    func test_whetherAFileIsUnattributableIsDecidedInOpLogChainOnly() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: [Self.unattributableDecisionPattern],
            allowedSpellings: ["type:OpLogChain": [Self.unattributableDecisionPattern]],
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside `OpLogChain` decides whether a file is "
            + "unattributable. The walk is the one place that has both the "
            + "seals and the table; reading the answer is free, making one is "
            + "a second opinion about which files the photograph is even "
            + "about. Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// **`HeldLines.holder` is the one holder classifier**, and the census is
    /// over the three arms' CONSTRUCTION.
    ///
    /// The holder string is censused already
    /// (`test_theUnsignedHolderIsSpelledInHeldLinesOnly`); this is its other
    /// half. Matching on the classifier's answer is the whole point of it and
    /// is not censused — `LoadQuestions` does exactly that. What must not
    /// happen is a surface MAKING one of the three, which is deciding for
    /// itself whether a waiting writer is a stranger (admittable), a person
    /// already in the book (not) or a stream with no key at all (never).
    static let holderArmPatterns = [
        ".stranger(fingerprint:", ".permitPending(person:", ".unsigned(stream:",
    ]

    func test_theThreeHoldersAreBuiltInHeldLinesOnly() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: Self.holderArmPatterns,
            allowedSpellings: ["HeldLines.swift": Set(Self.holderArmPatterns)],
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file builds a `HeldLines.Holder` of its own. Ask "
            + "`HeldLines.holder(of:registry:)` — a filter per surface is how "
            + "one of them comes to offer an Admit… sheet about a Mac that has "
            + "no key. Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// **The holder-standing classifier is one enum in one file** (P3b Task 4's
    /// carry). `AdmissionDecision.HeldKeyStanding` answers *why is this held
    /// key not offered* — waiting for its device record, contested, or a
    /// stranger who is — and People & Devices READS it
    /// (`AdmissionDecision.standing(ofHolder:…)`) rather than re-deriving
    /// either fact. A second derivation is how the sheet and the pane come to
    /// disagree about one waiting key on one afternoon.
    func test_theHolderStandingClassifierIsOneFile() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: ["HeldKeyStanding"],
            allowedSpellings: ["AdmissionDecision.swift": ["HeldKeyStanding"]],
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file outside `AdmissionDecision` names the "
            + "held-key standing. Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// **A surface builds a permit in one place** (P3b Task 4's carry).
    ///
    /// `Permit.permit(offering:pieces:)` is the permit layer's own door for a
    /// control — three rungs in, a `Permit` out — and `PermitControl` is the
    /// one thing that walks through it. Every other surface asks
    /// `PermitControl.permit(for:pieces:)`. The failure it guards is tripwire
    /// 47's from the other side: a view assembling a permit out of wire words
    /// is a second ladder, in the copy that does not compile-error when a rung
    /// is added. (Task 4's first draft did exactly that and two censuses
    /// caught it.)
    func test_aSurfaceBuildsAPermitInOnePlace() throws {
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: ["Permit.permit(offering:"],
            allowedSpellings: [
                "Permit.swift": ["Permit.permit(offering:"],
                "PermitControl.swift": ["Permit.permit(offering:"],
            ],
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production file other than `PermitControl` turns a display "
            + "choice into a `Permit`. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// **The silent admission installs no permit** (P3b Task 4's carry).
    ///
    /// `RegistryPresence.admitRemembered` is decision B2: a device this Mac
    /// has already granted a label to somewhere else is let in with no sheet.
    /// It must therefore install the permit an unasked admission can only
    /// mean — author of the whole book — and it does that by passing no rung
    /// at all. A `role:`/`scope:`/`pieces:` reaching that file would be this
    /// app narrowing somebody the writer was never asked about, and it is
    /// outside the schema gate besides (Task 3's carry), which is safe only
    /// while it narrows nobody.
    ///
    /// The two `role: "author"` literals in the file are the PERSON RECORD's
    /// convenience field on a book author, which is what an unasked admission
    /// writes; they are allowed by spelling, so `role: "reviewer"` — or any
    /// `scope:` or `pieces:` — fires.
    ///
    /// The scope is every file DECLARING `RegistryPresence` (foundations plan
    /// 2, Task 2), not a file name: split the type into an extension file and
    /// the census reads the new file too, with the same allowed spelling,
    /// rather than going quietly blind to it.
    func test_theSilentAdmissionNarrowsNobody() throws {
        let scope = try Self.silentAdmissionScope(
            under: SourceTree.productionRoots, base: SourceTree.repoRoot)
        let offenders = try grepSwift(
            in: admissionRoots,
            patterns: ["role:", "scope:", "pieces:"],
            allowedSpellings: scope.allowed,
            excludeLine: Self.admissionExcludeLine,
            onlyFiles: scope.files)
        XCTAssertTrue(offenders.isEmpty,
            "`RegistryPresence` names a rung. The silent admission is the one "
            + "that shows no sheet, so the only permit it may install is the "
            + "whole book — anything else narrows somebody nobody asked about, "
            + "through a door that is outside the schema gate. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// The one spelling the silent admission may carry, in EVERY file that
    /// declares `RegistryPresence`: the person record's convenience field on
    /// a book author.
    static let silentAdmissionAllowedSpellings: Set<String> = [#"role: "author""#]

    /// The silent-admission census's scope: the basenames of every file under
    /// `roots` declaring `RegistryPresence` (throws if none does), each
    /// allowed `silentAdmissionAllowedSpellings`.
    static func silentAdmissionScope(
        under roots: [String], base: URL
    ) throws -> (files: Set<String>, allowed: [String: Set<String>]) {
        let names = try SourceTree.filesDeclaring("RegistryPresence", under: roots, base: base)
            .map { ($0 as NSString).lastPathComponent }
        let files = Set(names)
        return (files, Dictionary(uniqueKeysWithValues: files.map {
            ($0, silentAdmissionAllowedSpellings)
        }))
    }

    /// **The counted lists.** Each is an ARRAY with a count per file, never a
    /// number in prose (memory: *prose counts are unmaintainable*), and each
    /// names what a missing entry and an extra entry would mean.
    ///
    /// - `expectedStreams` — the ONE escape-aware answer to *which streams
    ///   must this sweep find* (P3b Task 6). `OpLogDeviceState` defines it;
    ///   `DocumentStore+Registry` holds both builders and the sites that pass
    ///   them. A builder somewhere else is a sweep that does not take the
    ///   acknowledgement, so a loss the writer has already put down refuses a
    ///   marking verb for ever.
    /// - `acknowledgedLosses` — the memory that escape is kept in.
    ///   `OpLogDeviceState` owns it and clears it; `StreamCensus.lostHistory`
    ///   and the pane's count read it. A fourth reader is a second opinion
    ///   about what the writer has been shown.
    /// - `absentStreams` — the *remembered but no file at all* half of the
    ///   loss drawer, which is the commonest thing a marking verb refuses
    ///   over. One caller, `StreamCensus.lostHistory`, plus its own
    ///   definition.
    /// - `gateOldBuildsOut` — the schema gate (P3b Task 3). One function,
    ///   reached from every narrowing verb: `changePermit`, the label-wide
    ///   `changePermit(everyRecordOf:)` and the sheet's `admit`. A verb that
    ///   stopped calling it lets a v0.40 Mac into a narrowed book, where it
    ///   re-asserts a reviewer's refused text under its own book-author key.
    /// - `narrowingSchemaVersion` ASSIGNMENT — the narrowing gate's two
    ///   raises (the manifest it writes, and the live store it syncs), both in
    ///   `gateOldBuildsOut` (ruling R5: the permit layer's schema, never
    ///   `currentSchemaVersion`). `currentSchemaVersion` ASSIGNMENT — none:
    ///   `StatementAdoption`'s `< 4` migration stamps the statements schema
    ///   (4), and a new book takes the init default. Anything else is a
    ///   number written without the raise-only rule.
    /// - `sendHeldWordsToInbox` — §7.4's held-line door. One production
    ///   caller: History's held row, where the sentence and the control sit
    ///   together.
    static let countedLists: [String: [String: Int]] = [
        "expectedStreams(": [
            "type:DocumentStore": 5, "OpLogDeviceState.swift": 1,
        ],
        "acknowledgedLosses": [
            "OpLogDeviceState.swift": 12, "type:StreamCensus": 1,
            "type:DocumentStore": 1,
        ],
        "absentStreams": ["type:StreamCensus": 2],
        "gateOldBuildsOut": [
            "type:DocumentStore": 4,
        ],
        "schemaVersion = ProjectManifest.currentSchemaVersion": [:],
        "schemaVersion = ProjectManifest.narrowingSchemaVersion": [
            "type:DocumentStore": 2,
        ],
        "documentStore.sendHeldWordsToInbox(": ["HistoryPane.swift": 1],
    ]

    /// Every line naming `pattern` under `roots`, comments excluded.
    private func occurrences(
        of pattern: String, in roots: [URL]
    ) throws -> [(hit: SourceTree.Hit, value: Int)] {
        var counts: [(hit: SourceTree.Hit, value: Int)] = []
        for root in roots {
            for hit in try grepSwift(
                in: root, patterns: [pattern], allowed: [],
                excludeLine: Self.admissionExcludeLine) {
                counts.append((try XCTUnwrap(SourceTree.Hit(offender: hit)), 1))
            }
        }
        return counts
    }

    /// Occurrences of `pattern` under `roots`, keyed the way `expected` is:
    /// a file a `type:` key claims is counted under that key, so the key's
    /// count is the sum over its files. `offenders` holds every type key that
    /// resolved to no file.
    private func countedListFound(
        of pattern: String, keyedLike expected: [String: Int], in roots: [URL]
    ) throws -> (found: [String: Int], offenders: [String]) {
        let (folded, offenders) = SourceTree.foldingIntoTypeKeys(
            try occurrences(of: pattern, in: roots), keyedLike: expected.keys,
            in: roots, combine: +)
        return (folded, offenders)
    }

    func test_theP3bCountedListsAreExactlyTheNamedArrays() throws {
        for (pattern, expected) in Self.countedLists {
            let (found, unresolved) = try countedListFound(
                of: pattern, keyedLike: expected, in: admissionRoots)
            XCTAssertTrue(unresolved.isEmpty, "countedLists[\(pattern)]: \(unresolved)")
            XCTAssertEqual(found, expected,
                "The production sites naming “\(pattern)” moved. Update "
                + "`countedLists` with the reason in the same commit, or put "
                + "the call back — see the doc comment for what a missing and "
                + "an extra one each mean. Found: "
                + "\(found.sorted(by: { $0.key < $1.key }))")
        }
    }

    // MARK: - …and the planted offenders that prove they fire

    func test_theP3bCensusesFireOnPlantedOffenders() throws {
        let planted = """
            // A comment naming UnsignedSnapshot and PermitTimeline.narrows( is fine.
            func governing() -> UnsignedSnapshot? { UnsignedSnapshot.governing(events: []) }
            func isNarrowing(_ e: PermitEvent) -> Bool { PermitTimeline.narrows(e) }
            func verify() -> Verification { Verification(unattributable: true) }
            func whose(_ id: String) -> HeldLines.Holder { .stranger(fingerprint: id) }
            func why() -> HeldKeyStanding { .contested }
            func rung() -> Permit { Permit.permit(offering: .reviewer, pieces: []) }
            """
        let dir = TestTemp.root
            .appendingPathComponent("p3b-census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Named for one of the ALLOW-LISTED files, so the allow-list's
        // file-plus-spelling shape is proved as well: an offender wearing
        // `TrustTable.swift`'s name still fires on every spelling that file is
        // not allowed.
        try planted.write(
            to: dir.appendingPathComponent("TrustTable.swift"),
            atomically: true, encoding: .utf8)

        // The planted tree declares none of the allow-list's `type:` keys, so
        // they are (correctly) unresolved; this control is about the spellings.
        XCTAssertEqual(
            Self.dropping(unplanted: ["type:RegistryAdmission", "type:LocalWritePermitBuilder", "type:AmendmentPermits", "type:DocumentStore"], from: try grepSwift(
                in: [dir], patterns: Self.narrowingPatterns,
                allowedSpellings: Self.narrowingAllowed,
                excludeLine: Self.admissionExcludeLine)).count, 1,
            "the narrowing predicate fires even in a file allowed the snapshot, "
            + "and the comment is let through")
        XCTAssertEqual(
            try grepSwift(
                in: [dir], patterns: [Self.unattributableDecisionPattern],
                allowedSpellings: [:],
                excludeLine: Self.admissionExcludeLine).count, 1)
        XCTAssertEqual(
            try grepSwift(
                in: [dir], patterns: Self.holderArmPatterns,
                allowedSpellings: [:],
                excludeLine: Self.admissionExcludeLine).count, 1)
        XCTAssertEqual(
            try grepSwift(
                in: [dir], patterns: ["HeldKeyStanding"],
                allowedSpellings: [:],
                excludeLine: Self.admissionExcludeLine).count, 1)
        XCTAssertEqual(
            try grepSwift(
                in: [dir], patterns: ["Permit.permit(offering:"],
                allowedSpellings: [:],
                excludeLine: Self.admissionExcludeLine).count, 1)

        // The silent-admission census, scoped by TYPE: the type's own file
        // and an extension of it in a second file, each with the one allowed
        // spelling beside a banned one. A scope by file name would read the
        // first and never the second.
        let presence = """
            public enum RegistryPresence {
                let record = PersonRecord(person: p, role: "author")
                let narrowed = PersonRecord(person: p, role: "reviewer", scope: "pieces")
            }
            """
        try presence.write(
            to: dir.appendingPathComponent("RegistryPresence.swift"),
            atomically: true, encoding: .utf8)
        let split = """
            extension RegistryPresence {
                let record = PersonRecord(person: p, role: "author")
                let narrowed = PersonRecord(person: p, role: "reviewer")
            }
            """
        try split.write(
            to: dir.appendingPathComponent("RegistryPresence+Silent.swift"),
            atomically: true, encoding: .utf8)
        let scope = try Self.silentAdmissionScope(
            under: [dir.lastPathComponent], base: dir.deletingLastPathComponent())
        XCTAssertEqual(scope.files, ["RegistryPresence.swift", "RegistryPresence+Silent.swift"],
            "the scope is every file declaring the type, and only those")
        let rungs = try grepSwift(
            in: [dir], patterns: ["role:", "scope:", "pieces:"],
            allowedSpellings: scope.allowed,
            excludeLine: Self.admissionExcludeLine,
            onlyFiles: scope.files)
        XCTAssertEqual(rungs.count, 2,
            "the book author's own field is allowed by SPELLING and the "
            + "narrowed one is not, in the extension file as in the type's own: \(rungs)")
        XCTAssertTrue(rungs.contains { $0.hasPrefix("RegistryPresence+Silent.swift:") },
            "the extension's `role: \"reviewer\"` is caught: \(rungs)")

        // And the counted lists: a planted extra call really does move a count.
        let extra = "let more = state.expectedStreams(inRoot: url, writtenBy: nil)"
        try extra.write(
            to: dir.appendingPathComponent("OpLogDeviceState.swift"),
            atomically: true, encoding: .utf8)
        XCTAssertEqual(
            Self.byFile(try occurrences(of: "expectedStreams(", in: [dir]), combine: +),
            ["OpLogDeviceState.swift": 1],
            "the counter sees the planted call")
    }

    // MARK: - Posture is asked of the permit in one place (P3c Task 1; tripwire 51)

    /// The spellings of asking the permit table a question directly. A surface
    /// asks `posture.allows(.someVerb)` instead; `Posture(` is construction,
    /// which is MaughamCore's `PostureDoor` alone (P3c plan 2 Task 1 — Core is
    /// not scanned), reached on the Mac through `DocumentStore+Posture.swift`.
    ///
    /// Task 2 tightened it by three: the table asked by its qualified name
    /// (`Permit.allows(`), the inbox row asked of a permit (`.allows(.inboxRow`),
    /// and `Posture.author` — a fallback that walks round the door by
    /// answering *the whole book* without asking anyone. Fix round 1 adds
    /// `Posture.settling`, the door's own not-yet answer, for the same reason
    /// from the other side: a surface that spelled it would be deciding when
    /// the door has not answered.
    static let postureAskPatterns = [
        "LocalWritePermit", "localWritePermit", ".allows(.op(",
        ".allows(.translationRecord", "Posture(",
        "Permit.allows(", ".allows(.inboxRow", "Posture.author",
        "Posture.settling",
    ]

    /// File AND spelling. The door names every ask spelling; the `Document`
    /// files are P3a's load-seam and membrane sites and keep exactly the spellings
    /// they already have. `Document+Load.swift` asks through a local
    /// `writePermit`, so it carries `.allows(.op(` as well; every other line
    /// there is admitted by `localWritePermit` on the same line.
    static let postureAskAllowed: [String: Set<String>] = [
        // file-scoped: the posture door is THIS file, not the DocumentStore
        // type. Keyed by type it would admit every spelling in every
        // `extension DocumentStore` — `RulingPerformer.swift`'s among them,
        // which below is admitted none.
        "DocumentStore+Posture.swift": Set(postureAskPatterns),
        "Document.swift": ["localWritePermit"],
        "Document+Load.swift": ["localWritePermit", ".allows(.op("],
        "Document+Waiting.swift": ["localWritePermit"],
        "Document+Tasks.swift": ["localWritePermit"],
        "Document+Annotations.swift": ["localWritePermit"],
        // P3c whole-branch fix wave (C1): the restore door,
        // `requireRestorePermitted`, asks the stamp like its siblings.
        "Document+Rewind.swift": ["localWritePermit"],
        // P3c plan 2 Task 1: `RulingPerformer.swift` (the ruling door's
        // windowless fallback) and `TranslationWritePipeline.swift` (the
        // translator's refusal) were admitted builders here; both now ask
        // MaughamCore's `PostureDoor`, which this census does not scan, so
        // neither is admitted any spelling. A `Posture(` built in either again
        // is caught.
        // P3c plan 2 Task 6: the phone's one door. It asks Core's
        // `PostureDoor` (unscanned) and holds the door's not-yet answer as its
        // unanswered state — that spelling and nothing else.
        "PhonePosture.swift": ["Posture.settling"],
    ]

    /// **The door's own acting accessor is an ASK, not a second table** (P3c
    /// Task 3). `settledPosture(forDocId:as:)` is what every door that ACTS
    /// calls (controller ruling I), and its name ends in `Posture(` — which the
    /// substring match reads as building one. A line is admitted only where
    /// removing every `settledPosture(` leaves no ask spelling behind, so a
    /// real offender on the same line is still caught.
    static func postureAskExcludeLine(_ line: String) -> Bool {
        if admissionExcludeLine(line) { return true }
        guard line.contains("settledPosture(") else { return false }
        let rest = line.replacingOccurrences(of: "settledPosture(", with: "")
        return !postureAskPatterns.contains(where: { rest.contains($0) })
    }

    /// Component A — the sharing-role posture P3c retires. Allowed nowhere.
    static let componentAPatterns = [
        "CollaborationRole", "ReviewPosturePolicy", "ShareIdentityMapper", "effectivePosture",
    ]

    private var postureAskRoots: [URL] {
        [sourceDir, repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)]
    }

    /// **Every Mac surface asks `Posture`; nothing else asks the permit.**
    ///
    /// The distinction most likely to be re-spelled per surface: a queue that
    /// decides whether to draw Accept by asking `localWritePermit` itself, or
    /// by building a `Posture` of its own from some other permit, is a second
    /// answer that drifts from the door's the first time either changes.
    func test_postureIsAskedOfThePermitInOnePlace() throws {
        let askers = try grepSwift(
            in: postureAskRoots,
            patterns: Self.postureAskPatterns,
            allowedSpellings: Self.postureAskAllowed,
            excludeLine: Self.postureAskExcludeLine)
        XCTAssertTrue(askers.isEmpty,
            "A file outside the posture door asks the permit table directly or "
            + "builds a Posture of its own. Ask `posture.allows(.someVerb)` of "
            + "`DocumentStore.posture(forDocId:)`. Offenders:\n"
            + askers.joined(separator: "\n"))

        let componentA = try grepSwift(
            in: admissionRoots,
            patterns: Self.componentAPatterns,
            allowedSpellings: [:],
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(componentA.isEmpty,
            "The sharing-role posture survives. A role is the permit's, "
            + "asked through `Posture`. Offenders:\n"
            + componentA.joined(separator: "\n"))
    }

    /// The census's control: it fires on a planted file carrying one of each
    /// spelling, lets the comment through, and — moved to an allow-listed
    /// NAME — admits only that name's own spellings.
    func test_thePostureCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-posture-selfcheck-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name LocalWritePermit, Posture( and CollaborationRole.
        let built = LocalWritePermit.unrestricted
        let asked = store.localWritePermit { cls }
        let text = permit.allows(.op(.typingBurst)) == .yes
        let rendering = permit.allows(.translationRecord) == .yes
        let mine = Posture(permit)
        let direct = Permit.allows(written, in: cls, actor: actor)
        let row = permit.allows(.inboxRow) == .yes
        let fallback = Posture.author
        let undecided = Posture.settling
        let role: CollaborationRole = .reviewer
        let policy = ReviewPosturePolicy.resolve(role)
        let mapped = ShareIdentityMapper.map(share)
        let effective = effectivePosture.isReviewMode
        let fine = posture.allows(.writeText)
        let acted = await store.settledPosture(forDocId: id)
        let smuggled = await store.settledPosture(forDocId: id) ?? Posture(permit)
        """.write(to: tmp.appendingPathComponent("ASecondPostureTable.swift"),
                  atomically: true, encoding: .utf8)

        func hits() throws -> (ask: [String], componentA: [String]) {
            (try grepSwift(in: [tmp], patterns: Self.postureAskPatterns,
                           allowedSpellings: Self.postureAskAllowed,
                           excludeLine: Self.postureAskExcludeLine),
             try grepSwift(in: [tmp], patterns: Self.componentAPatterns,
                           allowedSpellings: [:],
                           excludeLine: Self.admissionExcludeLine))
        }

        let planted = try hits()
        XCTAssertEqual(planted.ask.count, 10,
            "Self-check: each of the nine ask spellings is caught, plus a real "
            + "one beside the door's acting accessor, and neither the comment, "
            + "the posture's own `allows` nor `settledPosture(` alone. Caught:\n"
            + planted.ask.joined(separator: "\n"))
        XCTAssertFalse(planted.ask.contains(where: { $0.contains("let fine") }))
        XCTAssertFalse(planted.ask.contains(where: { $0.contains("let acted") }),
            "the acting door is an ask (P3c Task 3)")
        XCTAssertTrue(planted.ask.contains(where: { $0.contains("let smuggled") }),
            "a Posture( built beside it is still caught")
        XCTAssertEqual(planted.componentA.count, 4,
            "Self-check: each Component A spelling is caught. Caught:\n"
            + planted.componentA.joined(separator: "\n"))

        // A P3a site may keep `localWritePermit` and nothing else.
        try fm.moveItem(at: tmp.appendingPathComponent("ASecondPostureTable.swift"),
                        to: tmp.appendingPathComponent("Document+Waiting.swift"))
        let asASite = try hits()
        XCTAssertEqual(asASite.ask.count, 9,
            "Self-check: Document+Waiting.swift is admitted `localWritePermit` "
            + "alone. Caught:\n" + asASite.ask.joined(separator: "\n"))
        XCTAssertFalse(asASite.ask.contains(where: { $0.contains("let asked") }))
        XCTAssertEqual(asASite.componentA.count, 4)

        // The translation pipeline asks Core's `PostureDoor` since P3c plan 2
        // Task 1, so it is admitted NOTHING: every spelling there is caught.
        try fm.moveItem(at: tmp.appendingPathComponent("Document+Waiting.swift"),
                        to: tmp.appendingPathComponent("TranslationWritePipeline.swift"))
        let asThePipeline = try hits()
        XCTAssertEqual(asThePipeline.ask.count, 10,
            "Self-check: TranslationWritePipeline.swift is admitted no spelling. "
            + "Caught:\n" + asThePipeline.ask.joined(separator: "\n"))
        XCTAssertTrue(asThePipeline.ask.contains(where: { $0.contains("let mine") }),
            "a bare Posture( in the pipeline is caught")
        XCTAssertTrue(asThePipeline.ask.contains(where: { $0.contains("let asked") }),
            "and so is the builder asked there directly")

        // The ruling performer likewise.
        try fm.moveItem(at: tmp.appendingPathComponent("TranslationWritePipeline.swift"),
                        to: tmp.appendingPathComponent("RulingPerformer.swift"))
        let asThePerformer = try hits()
        XCTAssertEqual(asThePerformer.ask.count, 10,
            "Self-check: RulingPerformer.swift is admitted no spelling. Caught:\n"
            + asThePerformer.ask.joined(separator: "\n"))

        // The phone's door is admitted its not-yet answer and nothing else
        // (P3c plan 2 Task 6): a builder, a `Posture(` or a fallback there is
        // still caught.
        try fm.moveItem(at: tmp.appendingPathComponent("RulingPerformer.swift"),
                        to: tmp.appendingPathComponent("PhonePosture.swift"))
        let asThePhone = try hits()
        XCTAssertEqual(asThePhone.ask.count, 9,
            "Self-check: PhonePosture.swift is admitted `Posture.settling` "
            + "alone. Caught:\n" + asThePhone.ask.joined(separator: "\n"))
        XCTAssertFalse(asThePhone.ask.contains(where: { $0.contains("let undecided") }))
        XCTAssertTrue(asThePhone.ask.contains(where: { $0.contains("let mine") }),
            "a Posture( built in the phone's door is caught")
        try fm.moveItem(at: tmp.appendingPathComponent("PhonePosture.swift"),
                        to: tmp.appendingPathComponent("RulingPerformer.swift"))

        // The door may ask every spelling, and is still caught naming Component A.
        try fm.moveItem(at: tmp.appendingPathComponent("RulingPerformer.swift"),
                        to: tmp.appendingPathComponent("DocumentStore+Posture.swift"))
        let asTheDoor = try hits()
        XCTAssertTrue(asTheDoor.ask.isEmpty,
            "Self-check: the door is admitted every ask spelling. Caught:\n"
            + asTheDoor.ask.joined(separator: "\n"))
        XCTAssertEqual(asTheDoor.componentA.count, 4)
    }

    // MARK: - Every manuscript writer outside the editor asks first (P3c whole-branch fix wave, C1)

    /// **The spellings that write a document's TEXT from outside the editor's
    /// membrane.** A burst's emission (`setFullText`) is deliberately not
    /// permit-guarded — the editor's `shouldChangeTextIn` is in front of the
    /// keystroke — so every OTHER caller must ask the posture (or the
    /// Document's stamp) before it reaches one of these, or it signs text in
    /// the writer's name that every read then sets aside. A restore
    /// (`applyRestore`/`restoreToOp`/`restoreToOpUndoable`/
    /// `Restore.buildRestoreOp`) rewrites every paragraph that differs; the
    /// replace verbs reach `setFullText` for a whole book. The whole-branch
    /// review found two such doors with neither a surface gate nor a storage
    /// door — the third time in P3 a "which paths write X" list was enumerated
    /// from the plan rather than from the code — so the population is a grep.
    ///
    /// **The re-review grew it** by the paragraph primitives — `setParagraph(`,
    /// `insertParagraph(`, `deleteParagraph(` and `Document.reorder(sequence:` —
    /// which write a burst exactly as `setFullText` does and which the first
    /// list missed (History's recovered-orphans Append and the inline
    /// checkbox's ⌘Z). So the list is no longer trusted on its own:
    /// `test_everyGuardedDocumentMutatorIsClassified` derives the population
    /// from `Document`'s own `rejectMutationIfNotWritable`/`requireWritable`
    /// sites and fails on a new one nobody classified.
    ///
    /// **A figure's content is manuscript content** (report plan 6a, ruling
    /// D-c: figure kinds are `.manuscriptText` in `Permit.group`), so its
    /// writers join this census: `FigureDocument`'s guarded mutators
    /// (`figureMutatorSpellings`), `createFigure(` and `createImageFigure(` (a figure's birth, behind
    /// its own posture question), and `figureOpMintSpelling` — every `Op(`
    /// built with a `figure:` argument, which is where a figure op is born,
    /// so a writer that appends one without a mutator (an inverse, a payload
    /// copied off another op) is still a named site.
    static let manuscriptWriterPatterns = [
        "setFullText(", "applyRestore(", "restoreToOp(", "restoreToOpUndoable(",
        "buildRestoreOp(", "replaceAll(", "replaceMatch(", "replaceInManuscript(",
        "setParagraph(", "insertParagraph(", "deleteParagraph(", "reorder(sequence:",
        "setCell(", "insertRow(", "insertColumn(", "deleteRow(", "deleteColumn(",
        "reviveRow(", "reviveColumn(",
        "moveRow(", "moveColumn(", "setHeaderRows(", "setTotalRow(", "setColumnWidth(",
        "setImage(", "createFigure(", "createImageFigure(", figureOpMintSpelling,
    ]

    /// The key a figure op's minting is counted under: an `Op(`/`Op.init(`
    /// (or an `opId:`-carrying bare `.init(`) with a `figure:` argument at its
    /// own depth, however many lines it spans (`figureOpMintLines`). Not a
    /// substring — the call is walked.
    static let figureOpMintSpelling = "Op(…figure:"

    /// **`FigureDocument`'s mutator spellings, counted only as an AWAITED
    /// call.** The names are generic — plan 5's `FigureTable.setCell(`/
    /// `insertRow(`/`moveRow(` in Core, `FigureStructureChange.insertRow(`,
    /// the grid editor's `model.setCell(` — and every one of those is
    /// synchronous, while `FigureDocument`'s are `async throws` and so are
    /// always reached as `await <receiver>.setCell(` (or `await setCell(`
    /// from inside). A spelling here counts only in that shape
    /// (`awaitedCallLines`), so the census names the figure host's callers and
    /// not every table helper in the codebase.
    static let figureMutatorSpellings: Set<String> = [
        "setCell(", "insertRow(", "insertColumn(", "deleteRow(", "deleteColumn(",
        "reviveRow(", "reviveColumn(",
        "moveRow(", "moveColumn(", "setHeaderRows(", "setTotalRow(", "setColumnWidth(",
        "setImage(",
    ]

    /// `text` with every comment and string literal blanked to spaces, its
    /// newlines kept, so line numbers survive and nothing inside a literal —
    /// a `"a//b"`, a `"(("`, a `figure:` in prose — can cut a line, skew a
    /// paren depth or pose as a label. Lexes `//` and nested `/* */`
    /// comments, `"…"` with escapes and `\(…)` interpolations (themselves
    /// holding strings), multi-line `"""…"""`, and raw `#"…"#` of any number
    /// of `#`s. SHARED by the figure scanners and their controls.
    static func blankingCommentsAndStrings(_ text: String) -> String {
        let c = Array(text)
        var out = c
        var i = 0
        func blank(_ k: Int) { if c[k] != "\n" { out[k] = " " } }
        func at(_ k: Int, _ s: String) -> Bool {
            var n = k
            for ch in s {
                guard n < c.count, c[n] == ch else { return false }
                n += 1
            }
            return true
        }
        // Blanks a string body from `k` (just past its opening delimiter)
        // through its closing delimiter; answers the index after it.
        func string(from k: Int, hashes: Int, multiline: Bool) -> Int {
            var k = k
            let close = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            while k < c.count {
                if !multiline, c[k] == "\n" { return k }
                if at(k, escape) {
                    let past = k + escape.count
                    for j in k..<min(past, c.count) { blank(j) }
                    if past < c.count, c[past] == "(" {
                        // An interpolation: code (and strings) to its `)`.
                        var depth = 0, j = past
                        while j < c.count {
                            if c[j] == "\"" {
                                blank(j); j = string(from: j + 1, hashes: 0, multiline: false); continue
                            }
                            if c[j] == "(" { depth += 1 }
                            if c[j] == ")" { depth -= 1 }
                            blank(j); j += 1
                            if depth == 0 { break }
                        }
                        k = j
                    } else {
                        if past < c.count { blank(past) }
                        k = past + 1
                    }
                    continue
                }
                if at(k, close) {
                    for j in k..<(k + close.count) { blank(j) }
                    return k + close.count
                }
                blank(k); k += 1
            }
            return k
        }
        while i < c.count {
            if c[i] != "/" && c[i] != "\"" && c[i] != "#" {
                i += 1
            } else if at(i, "//") {
                while i < c.count, c[i] != "\n" { blank(i); i += 1 }
            } else if at(i, "/*") {
                var depth = 0
                while i < c.count {
                    if at(i, "/*") { depth += 1; blank(i); blank(i + 1); i += 2; continue }
                    if at(i, "*/") { depth -= 1; blank(i); blank(i + 1); i += 2; if depth == 0 { break }; continue }
                    blank(i); i += 1
                }
            } else if c[i] == "#" || c[i] == "\"" {
                var hashes = 0
                while i + hashes < c.count, c[i + hashes] == "#" { hashes += 1 }
                let q = i + hashes
                guard q < c.count, c[q] == "\"" else { i += max(hashes, 1); continue }
                let multiline = at(q, "\"\"\"")
                let open = q + (multiline ? 3 : 1)
                for j in i..<open { blank(j) }
                i = string(from: open, hashes: hashes, multiline: multiline)
            } else {
                i += 1
            }
        }
        return String(out)
    }

    /// The 1-based line of every AWAITED call of `spelling` in `text`. Over
    /// the blanked text (`blankingCommentsAndStrings`), an occurrence of the
    /// name counts when it is
    /// - a CALL: a member call, whose receiver ends in a name, `)`, `]`, `?`
    ///   or `!` before the dot (whitespace and newlines allowed between —
    ///   `d.setCell(`, `$0.setCell(`, `(await x).setCell(`,
    ///   `store.openFigure(figureId: f).setCell(`, `figure` then `.setCell(`
    ///   on the next line), or a bare call (`setCell(` from inside); not an
    ///   implicit member like `structure: .insertRow(` or `case .insertRow(`,
    ///   and not a `func`/`case` declaration; and
    /// - AWAITED: its statement, read backwards to a `{`, `}` or `;` outside
    ///   any parentheses, or to a line break that does not continue (the next
    ///   line starts with `.`, or this one ends in `=`, `(`, `,`, `try` or
    ///   `await`), says `await` or `async let` before it.
    /// So one `await` covering several calls counts each. The line is the
    /// NAME's line. Every sync table helper has no `await` in its statement;
    /// a sync call sharing a statement with an `await` is counted — the safe
    /// direction.
    static func awaitedCallLines(of spelling: String, in text: String) -> [Int] {
        awaitedCallLines(of: spelling, inBlanked: Array(blankingCommentsAndStrings(text)))
    }

    /// `awaitedCallLines` over text already blanked, so a file is lexed once.
    static func awaitedCallLines(of spelling: String, inBlanked c: [Character]) -> [Int] {
        let name = Array(spelling)
        func isIdent(_ x: Character) -> Bool { x.isLetter || x.isNumber || x == "_" || x == "$" }
        func lineText(endingAt k: Int) -> String {   // the line whose "\n" is at k
            var j = k - 1
            while j >= 0, c[j] != "\n" { j -= 1 }
            return String(c[(j + 1)..<k])
        }
        func lineText(startingAfter k: Int) -> String {
            var j = k + 1
            while j < c.count, c[j] != "\n" { j += 1 }
            return String(c[(k + 1)..<j])
        }
        func continues(at newline: Int) -> Bool {
            let next = lineText(startingAfter: newline).trimmingCharacters(in: .whitespaces)
            if next.hasPrefix(".") { return true }
            let prev = lineText(endingAt: newline).trimmingCharacters(in: .whitespaces)
            if prev.hasSuffix("=") || prev.hasSuffix("(") || prev.hasSuffix(",") { return true }
            let last = prev.split(separator: " ").last.map(String.init) ?? ""
            return ["try", "try?", "try!", "await"].contains(last)
        }
        let awaitRegex = try? NSRegularExpression(pattern: #"\bawait\b|\basync\s+let\b"#)
        var lines: [Int] = []
        var line = 1
        var i = 0
        while i < c.count {
            if c[i] == "\n" { line += 1; i += 1; continue }
            guard c[i] == name[0], i + name.count <= c.count,
                  c[i..<(i + name.count)].elementsEqual(name),
                  i == 0 || !isIdent(c[i - 1]) else { i += 1; continue }
            // A member call, a bare call, or neither.
            var j = i - 1
            while j >= 0, c[j] == " " || c[j] == "\t" { j -= 1 }
            var start = i
            if j >= 0, c[j] == "." {
                // Glued to its receiver, or leading its own line after one;
                // a dot after a space mid-line is an implicit member.
                var r = j - 1
                if r >= 0, c[r] == " " || c[r] == "\t" {
                    while r >= 0, c[r] == " " || c[r] == "\t" { r -= 1 }
                    guard r >= 0, c[r] == "\n" else { i += 1; continue }
                    while r >= 0, c[r].isWhitespace { r -= 1 }
                } else if r >= 0, c[r] == "\n" {
                    while r >= 0, c[r].isWhitespace { r -= 1 }
                }
                guard r >= 0, isIdent(c[r]) || ")]?!".contains(c[r]) else { i += 1; continue }
                start = j
            } else {
                let before = String(c[max(0, i - 6)..<i])
                if before.hasSuffix("func ") || before.hasSuffix("case ") { i += 1; continue }
            }
            // The statement, read backwards from the call.
            var k = start - 1, depth = 0
            while k >= 0 {
                let x = c[k]
                if x == ")" { depth += 1 } else if x == "(" { depth -= 1 }
                if depth <= 0, x == "{" || x == "}" || x == ";" { break }
                if depth == 0, x == "\n", !continues(at: k) { break }
                k -= 1
            }
            let prefix = String(c[(k + 1)..<start])
            if let awaitRegex,
               awaitRegex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil {
                lines.append(line)
            }
            i += name.count
        }
        return lines
    }

    /// The 1-based line of every `figure:` argument that mints an `Op` in
    /// `text` — a CALL-SHAPED walk over the blanked text, since an op spans
    /// several lines. The calls are `Op(`, `Op.init(` (neither the tail of a
    /// longer name — `FigureOp(` is not one), and a bare `.init(` whose own
    /// argument list also carries `opId:` (`Op.init`'s first, required label —
    /// which keeps `ElementWords`' `.init(figure: "Figura", …)` out). The label
    /// must sit at the call's own depth (a nested `Thing(figure:` is not the
    /// op's) and not be the tail of a longer label. `Op.figure` is a `let`,
    /// so an op's payload is set only at its construction.
    static func figureOpMintLines(in text: String) -> [Int] {
        figureOpMintLines(inBlanked: Array(blankingCommentsAndStrings(text)))
    }

    /// `figureOpMintLines` over text already blanked, so a file is lexed once.
    static func figureOpMintLines(inBlanked c: [Character]) -> [Int] {
        func isIdent(_ x: Character) -> Bool { x.isLetter || x.isNumber || x == "_" }
        func ends(at k: Int, with s: String) -> Bool {
            let a = Array(s)
            let start = k + 1 - a.count
            guard start >= 0, Array(c[start...k]) == a else { return false }
            return start == 0 || !isIdent(c[start - 1])
        }
        func label(_ s: String, at k: Int) -> Bool {
            let a = Array(s)
            guard k + a.count <= c.count, Array(c[k..<(k + a.count)]) == a else { return false }
            let prev: Character = k > 0 ? c[k - 1] : " "
            return !(isIdent(prev) || prev == ".")
        }
        struct Open { let depth: Int; let needsOpId: Bool; var sawOpId = false; var figureLines: [Int] = [] }
        var lines: [Int] = []
        var line = 1, depth = 0
        var open: [Open] = []
        for k in c.indices {
            switch c[k] {
            case "\n":
                line += 1
            case "(":
                depth += 1
                if ends(at: k, with: "Op(") || ends(at: k, with: "Op.init(") {
                    open.append(Open(depth: depth, needsOpId: false))
                } else if k >= 5, String(c[(k - 5)...k]) == ".init(",
                          k == 5 || !(isIdent(c[k - 6]) || c[k - 6] == ".") {
                    open.append(Open(depth: depth, needsOpId: true))
                }
            case ")":
                if let last = open.last, last.depth == depth {
                    open.removeLast()
                    if !last.needsOpId || last.sawOpId { lines += last.figureLines }
                }
                depth -= 1
            default:
                guard var last = open.last, last.depth == depth else { break }
                if label("figure:", at: k) { last.figureLines.append(line) }
                if label("opId:", at: k) { last.sawOpId = true }
                open[open.count - 1] = last
            }
        }
        return lines.sorted()
    }

    /// Every writer spelling in one file's `text`, per line: the substring
    /// spellings line by line (`manuscriptWriterExcludeLine` skipping comments
    /// and declarations), a figure mutator only as an awaited call, a figure
    /// op only as an `Op(` with `figure:`. SHARED by the census and its
    /// controls.
    static func manuscriptWriterHits(
        file: String, text: String
    ) -> [(hit: SourceTree.Hit, value: [String: Int])] {
        var out: [(hit: SourceTree.Hit, value: [String: Int])] = []
        let plain = manuscriptWriterPatterns.filter {
            !figureMutatorSpellings.contains($0) && $0 != figureOpMintSpelling
        }
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineStr = String(line)
            if manuscriptWriterExcludeLine(lineStr) { continue }
            var spellings: [String: Int] = [:]
            for spelling in plain where lineStr.contains(spelling) { spellings[spelling, default: 0] += 1 }
            if !spellings.isEmpty { out.append((SourceTree.Hit(file: file, line: i + 1), spellings)) }
        }
        // The figure scanners lex the file once, and only a file that could
        // hold a figure writer at all.
        let mutators = figureMutatorSpellings.sorted().filter { text.contains($0) }
        let mayMint = text.contains("figure:")
        guard !mutators.isEmpty || mayMint else { return out }
        let blanked = Array(blankingCommentsAndStrings(text))
        for spelling in mutators {
            for line in awaitedCallLines(of: spelling, inBlanked: blanked) {
                out.append((SourceTree.Hit(file: file, line: line), [spelling: 1]))
            }
        }
        if mayMint {
            for line in figureOpMintLines(inBlanked: blanked) {
                out.append((SourceTree.Hit(file: file, line: line), [figureOpMintSpelling: 1]))
            }
        }
        return out
    }

    /// **Every production call site, by file and by count** — count the array,
    /// never a number in prose. Each entry says where its posture question is
    /// asked, or why it need not be:
    ///
    /// - `EditorHost.swift` × 1 — the editor's binding. Its gate is the
    ///   membrane (`EditorEditPolicy` via `shouldChangeTextIn`), fed by the
    ///   drawing posture; the one entry whose door is in front of the keystroke.
    /// - `StatementEditorHost.swift` × 2 — the statement editor's binding and
    ///   its merge; the same membrane, locked by `statementPosture`.
    /// - `ProjectStore+Statements.swift` × 1 — `mutateStatementText`, every
    ///   statement writer's one door: it refuses where the statement Document's
    ///   stamp refuses its text (`StatementWriteRefused`), before the write.
    /// - `ProjectStore+Structure.swift` × 2 — the rename's wiki-link sweep,
    ///   pieces and statements: `sweepMayWrite` (the settled posture) before any
    ///   load and the Document's stamp before the write; skipped and NAMED
    ///   (ruling AH).
    /// - `ProjectStore+Search.swift` × 3 — `replaceMatch`/`replaceAll` →
    ///   `replaceInManuscript` → `setFullText`: the settled posture before any
    ///   load and the Document's stamp before the write; Replace All skips and
    ///   names (ruling AI).
    /// - `ProjectSearchView.swift` × 2 — the two presses; per-match Replace and
    ///   Replace All are drawn only where the match's own document allows
    ///   `.writeText` (`ProjectSearchView.mayReplace`).
    /// - `Document+Rewind.swift` × 2 — `restoreToOp`'s `applyRestore`, and
    ///   `applyRestore`'s `buildRestoreOp`; each function refuses first
    ///   (`requireRestorePermitted`).
    /// - `Document+RewindUndo.swift` × 4 — the undoable wrapper (its own door
    ///   before the stack clear) and its undo/redo; each reaches the doored
    ///   `restoreToOp`, and a refusal there is said (`declineUndo(.notPermitted)`).
    /// - `Document+Tasks.swift` × 3 — the inline-archive undo's
    ///   `applyRestore`, doored, its refusal said the same way; and
    ///   `archiveTask`'s own splice (`deleteParagraph`/`setParagraph`), behind
    ///   the task door that refuses the archive whole where the splice is
    ///   refused.
    /// - `OpUndoRegistrar.swift` × 2 — `InlineToggleUndo`'s checkbox flip and
    ///   its undo/redo: each asks `mayWriteItsText` AND the host's `mayWrite`
    ///   (the yield-aware posture's `.writeText`, #74) first, and a refusal is
    ///   said (`declineUndo(.taskNotPermitted)`); the press is hidden by
    ///   `TaskRowVerbs` on the drawing posture, and refused by the editor's
    ///   membrane while it is locked.
    /// - `RecoveredHistorySheet.swift` × 1 — *Append to End* / *Append All*:
    ///   drawn only where `.writeText` is allowed (`mayAppend`), the door
    ///   `RecoveredHistorySheet.mayAppend(to:posture:)` asking the stamp AND
    ///   the yield-aware posture at the press (#74), a refusal said in the
    ///   sheet.
    ///
    /// And beneath all four paragraph primitives, whatever the caller:
    /// `Document.rejectTextWriteIfNotPermitted` refuses inside
    /// `setParagraph`/`insertParagraph`/`deleteParagraph`/`reorder`, so a future
    /// caller that forgets to ask writes nothing (silently — which is why each
    /// listed caller asks first and says it).
    /// - `ProjectWindow.swift` × 1 — *Restore here…*'s receiver; the button is
    ///   drawn only where `.writeText` is allowed (`RewindWindow.offersRestore`)
    ///   and a refusal from the door is SAID in the restore toast.
    /// - `PartialRestorePicker.swift` × 1 — *Revert here…*'s checkpoint
    ///   restore, which appends through its own store: the settled posture per
    ///   document before the build; the rows and the History button are drawn
    ///   only for documents this Mac may write, and what the door left alone is
    ///   named in the sheet.
    /// - `TestEditTool.swift` × 1 — `test_apply_edit`, compiled only into the
    ///   dev build (`MAUGHAM_DEV_BUILD`): the smoke rig's typing surrogate,
    ///   deliberately NOT gated, because it stands in for a keystroke and is
    ///   how a rig drives a burst the read side must then set aside.
    /// - `FigureDocument.swift` — a figure's host (report plan 6a). Its one
    ///   `Op(…, figure:)` is `commit`, reached only from a mutator after
    ///   `requireWritable("…")` — which asks posture (the figure's own,
    ///   `.editFigure`, through the window's door) and throws
    ///   `FigureEditRefused` before any op — or from `registerFigureUndo`'s
    ///   undo after `mayEditHere`. Its awaited mutator calls are the redo
    ///   closures, each re-entering that doored mutator, a refusal said
    ///   (`decline(.notPermitted)`).
    /// - `ProjectStore+Figures.swift` × 1 — `figureOpMinter`, which mints
    ///   `createFigure`'s `figureCreate` and row and column inserts and
    ///   `createImageFigure`'s `figureCreate` and `figureImageSet`: each asks
    ///   posture (`.editFigure` of the class the new figure will have,
    ///   `requireNewFigurePermitted`) before it mints a line, and throws
    ///   `FigureEditRefused`.
    /// - `FigureIngest.swift` × 1 — `importImage`'s `createImageFigure(`, the
    ///   editor's Insert Figure…, image drop and image paste (report plan 6a
    ///   Task 9): reached only once the editor's membrane allows writing, and
    ///   `createImageFigure` asks the figure's own posture before it copies
    ///   or mints anything.
    /// - `Op.swift` × 1 — Core's `withReplacedOpId`, a RE-ID of an op already
    ///   built (and judged) by one of the above, never a new figure write.
    ///
    /// `createFigure(` has no production caller yet: plan 7's surfaces add
    /// theirs here, each drawn and pressed only where the posture allows
    /// `.editFigure`.
    ///
    /// **Counted per SPELLING per file** (P3c plan 2 Task 9), not per file: a
    /// file that swapped one writer for another — a Replace that began
    /// reaching `setFullText(` directly instead of `replaceInManuscript(` —
    /// kept a per-file count and passed, though the door it stood behind had
    /// moved.
    static let manuscriptWriterCallSites: [String: [String: Int]] = [
        "EditorHost.swift": ["setFullText(": 1],
        "StatementEditorHost.swift": ["setFullText(": 2],
        "ProjectStore+Statements.swift": ["setFullText(": 1],
        "ProjectStore+Structure.swift": ["setFullText(": 2],
        "ProjectStore+Search.swift": ["replaceInManuscript(": 2, "setFullText(": 1],
        "ProjectSearchView.swift": ["replaceMatch(": 1, "replaceAll(": 1],
        "Document+Rewind.swift": ["applyRestore(": 1, "buildRestoreOp(": 1],
        "Document+RewindUndo.swift": ["restoreToOp(": 3, "restoreToOpUndoable(": 1],
        "Document+Tasks.swift": ["applyRestore(": 1, "deleteParagraph(": 1, "setParagraph(": 1],
        "OpUndoRegistrar.swift": ["setParagraph(": 2],
        "RecoveredHistorySheet.swift": ["insertParagraph(": 1],
        // History's undoable Rewind, inside the window's `RewindModifier`.
        "type:RewindModifier": ["restoreToOpUndoable(": 1],
        "PartialRestorePicker.swift": ["buildRestoreOp(": 1],
        "TestEditTool.swift": ["setFullText(": 1],
        // Figures (report plan 6a): each asks posture before it writes.
        "FigureDocument.swift": [
            figureOpMintSpelling: 1,
            "setCell(": 1, "moveRow(": 1, "moveColumn(": 1,
            "setHeaderRows(": 1, "setTotalRow(": 1, "setColumnWidth(": 1,
            "setImage(": 1,
            // A delete's redo; an undone insert's redo and a revive's own
            // redo (report plan 6b Task 4).
            "deleteRow(": 1, "deleteColumn(": 1, "reviveRow(": 2, "reviveColumn(": 2,
        ],
        "ProjectStore+Figures.swift": [figureOpMintSpelling: 1],
        "FigureIngest.swift": ["createImageFigure(": 1],
        "Op.swift": [figureOpMintSpelling: 1],
    ]

    /// A comment, or a declaration of one of the verbs, is not a call site.
    static func manuscriptWriterExcludeLine(_ line: String) -> Bool {
        admissionExcludeLine(line) || line.contains("func ")
    }

    /// Call sites under `roots`, per file and per SPELLING
    /// (`manuscriptWriterHits` over each file).
    private func manuscriptWriterCallCounts(
        in roots: [URL]
    ) throws -> [(hit: SourceTree.Hit, value: [String: Int])] {
        var counts: [(hit: SourceTree.Hit, value: [String: Int])] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                counts += Self.manuscriptWriterHits(file: url.lastPathComponent, text: text)
            }
        }
        return counts
    }

    func test_everyManuscriptWriterOutsideTheEditorIsANamedSite() throws {
        let (found, unresolved) = SourceTree.foldingIntoTypeKeys(
            try manuscriptWriterCallCounts(in: admissionRoots),
            keyedLike: Self.manuscriptWriterCallSites.keys, in: admissionRoots,
            combine: { $0.merging($1, uniquingKeysWith: +) })
        XCTAssertTrue(unresolved.isEmpty, "manuscriptWriterCallSites: \(unresolved)")
        XCTAssertEqual(found, Self.manuscriptWriterCallSites,
            "A path that writes a document's text from outside the editor moved. "
            + "Every such site asks the posture (or the Document's stamp) before "
            + "it writes, or is listed with why it need not. A NEW site is a verb "
            + "that can sign text every read then sets aside — gate it and add it "
            + "to `manuscriptWriterCallSites` with its reason in the same commit. "
            + "Found: \(found.sorted(by: { $0.key < $1.key }))")
    }

    /// **Every guarded `Document` mutator, classified** — the population the
    /// spelling list is checked against, DERIVED from the code (the re-review's
    /// ask: the first list was enumerated and missed two primitives). Each name
    /// that `Maugham/` guards with `rejectMutationIfNotWritable("…")` or
    /// `requireWritable("…")` is here, as a TEXT WRITER (its spelling must be
    /// in `manuscriptWriterPatterns`) or with why it is not one.
    static let guardedDocumentMutators: [String: String] = [
        // Text writers — each spelled in `manuscriptWriterPatterns`.
        "setFullText": "text", "setParagraph": "text", "insertParagraph": "text",
        "deleteParagraph": "text", "reorder": "text", "applyRestore": "text",
        "restoreToOp": "text",
        // Not text writers, and where their own door is.
        "appendMirrored": "⌘S's checkpoint op — CheckpointCapture's door",
        "performAutosave": "writes the DERIVED .md of ops already judged",
        "flushBurstNow": "emits what setFullText/the primitives already wrote",
        "handleExternalDiskChange": "a read — another device's lines, judged by the partition",
        "handleExternalLogChange": "a read — another device's lines, judged by the partition",
        "acceptAnnotation": "a disposition — requireDispositionPermitted, and a suggestion's text asks the host's yield-aware mayWrite (#79)",
        "revertAcceptedAnnotation": "a disposition — requireDispositionPermitted, and a suggestion's text asks the host's yield-aware mayWrite (#79)",
        "reopenAnnotation": "undoing an archive, rejection or stet is a disposition — requireDispositionPermitted; undoing a withdrawal is the ownership rule's — requireRestoreHonoured (ruling P)",
        "reopenAcceptedTextlessAnnotation": "a disposition — requireDispositionPermitted",
        "appendTaskOpInternal": "a task op — the task door",
        "appendTaskRewindCloser": "reached only after the doored restoreToOp",
        "applyMintedAnchors": "the load's own emission, the author's (tripwire 38), gated on mayAnchor",
        // Figure writers (report plan 6a) — a figure's content is manuscript
        // content (ruling D-c). Each is `FigureDocument`'s, opening with
        // `requireWritable("…")`, which asks the FIGURE's posture
        // (`.editFigure`) and throws `FigureEditRefused` before any op; each
        // is spelled in `manuscriptWriterPatterns` AND in
        // `figureMutatorSpellings` (counted only as an awaited call).
        "setCell": "figure", "insertRow": "figure", "insertColumn": "figure",
        "deleteRow": "figure", "deleteColumn": "figure", "moveRow": "figure",
        "reviveRow": "figure", "reviveColumn": "figure",
        "moveColumn": "figure", "setHeaderRows": "figure", "setTotalRow": "figure",
        "setColumnWidth": "figure", "setImage": "figure",
    ]

    /// The names `root` guards with `rejectMutationIfNotWritable("…")` or
    /// `requireWritable("…")`, a comment excluded — SHARED by the census and
    /// its planted-offender control.
    private func guardedDocumentMutatorNames(in root: URL) throws -> Set<String> {
        let hits = try grepSwift(
            in: root,
            patterns: ["rejectMutationIfNotWritable(\"", "requireWritable(\""],
            allowed: [],
            excludeLine: Self.admissionExcludeLine)
        var names: Set<String> = []
        let regex = try NSRegularExpression(
            pattern: #"(?:rejectMutationIfNotWritable|requireWritable)\("([A-Za-z]+)"\)"#)
        for hit in hits {
            let range = NSRange(hit.startIndex..., in: hit)
            regex.enumerateMatches(in: hit, range: range) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: hit) { names.insert(String(hit[r])) }
            }
        }
        return names
    }

    /// What is wrong with `classified` against the guarded `names` found —
    /// empty when every name is classified, every classification is still
    /// found, every TEXT or FIGURE writer's spelling is in
    /// `manuscriptWriterPatterns`, and every FIGURE writer's is also in
    /// `figureMutatorSpellings` (so it is counted in its awaited shape).
    /// SHARED by the census and its planted-offender controls.
    static func guardedMutatorProblems(
        names: Set<String>, classified: [String: String]
    ) -> [String] {
        var problems: [String] = []
        for name in names.subtracting(classified.keys).sorted() {
            problems.append("\(name): guarded but unclassified")
        }
        for name in Set(classified.keys).subtracting(names).sorted() {
            problems.append("\(name): classified but no longer guarded")
        }
        for (name, kind) in classified.sorted(by: { $0.key < $1.key })
        where kind == "text" || kind == "figure" {
            if !manuscriptWriterPatterns.contains(where: { $0.hasPrefix(name + "(") }) {
                problems.append("\(name): a \(kind) writer not in manuscriptWriterPatterns")
            }
            if kind == "figure", !figureMutatorSpellings.contains(name + "(") {
                problems.append("\(name): a figure writer not in figureMutatorSpellings")
            }
        }
        return problems
    }

    func test_everyGuardedDocumentMutatorIsClassified() throws {
        let names = try guardedDocumentMutatorNames(in: sourceDir)
        XCTAssertFalse(names.isEmpty, "precondition: the guarded mutators were found")
        XCTAssertTrue(
            ["setCell", "setColumnWidth"].allSatisfy(names.contains),
            "precondition: FigureDocument's guarded mutators are in the population")
        let problems = Self.guardedMutatorProblems(
            names: names, classified: Self.guardedDocumentMutators)
        XCTAssertTrue(problems.isEmpty,
            "A guarded Document or FigureDocument mutator appeared, disappeared "
            + "or lost its spelling. Classify it in `guardedDocumentMutators`: a "
            + "TEXT or FIGURE writer's spelling joins `manuscriptWriterPatterns` "
            + "(a figure's also `figureMutatorSpellings`) and its callers "
            + "`manuscriptWriterCallSites`. Problems:\n" + problems.joined(separator: "\n"))
    }

    /// **The classification census's control** (P3c plan 2 Task 9): a planted
    /// guard under a name nobody classified is found — both spellings of the
    /// guard, and not the comment that names one — and the set it produces
    /// fails the census it feeds.
    func test_theGuardedMutatorCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-guarded-selfcheck-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name rejectMutationIfNotWritable("commentedAway") without being one.
        func rewriteEverything() {
            if rejectMutationIfNotWritable("rewriteEverything") { return }
        }
        func appendSomewhereNew() throws {
            try requireWritable("appendSomewhereNew")
        }
        """.write(to: tmp.appendingPathComponent("AFifthDocumentMutator.swift"),
                  atomically: true, encoding: .utf8)

        let planted = try guardedDocumentMutatorNames(in: tmp)
        XCTAssertEqual(planted, ["rewriteEverything", "appendSomewhereNew"],
            "Self-check: both guard spellings are read, the comment is not")
        let production = try guardedDocumentMutatorNames(in: sourceDir)
        XCTAssertNotEqual(production.union(planted), Set(Self.guardedDocumentMutators.keys),
            "and a guarded mutator nobody classified fails the census")
        XCTAssertEqual(
            Self.guardedMutatorProblems(
                names: production.union(planted), classified: Self.guardedDocumentMutators),
            ["appendSomewhereNew: guarded but unclassified",
             "rewriteEverything: guarded but unclassified"],
            "and the census's own check names each one")
    }

    /// **A figure mutator nobody classified fails the census** (report plan 6a
    /// Task 8): a planted `FigureDocument`-shaped mutator behind
    /// `requireWritable("…")` joins the derived population and is refused
    /// until classified; classified as a figure writer but left out of the
    /// spelling lists, it is refused again. Without the planted mutator, the
    /// production population passes as it stands.
    func test_theGuardedMutatorCensusFiresOnAPlantedFigureMutator() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-figure-mutator-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        extension FigureDocument {
            public func setCellFormat(_ format: CellFormat, at key: CellKey) async throws {
                try await requireWritable("setCellFormat")
                try await commit(.figureCellSet, FigureOpPayload(cell: key, next: nil, prior: nil))
            }
        }
        """.write(to: tmp.appendingPathComponent("FigureDocument+Format.swift"),
                  atomically: true, encoding: .utf8)

        let production = try guardedDocumentMutatorNames(in: sourceDir)
        let planted = try guardedDocumentMutatorNames(in: tmp)
        XCTAssertEqual(planted, ["setCellFormat"], "Self-check: the planted guard is read")
        let withPlanted = production.union(planted)

        XCTAssertEqual(
            Self.guardedMutatorProblems(names: withPlanted, classified: Self.guardedDocumentMutators),
            ["setCellFormat: guarded but unclassified"],
            "an unclassified figure mutator fails the census")

        var classified = Self.guardedDocumentMutators
        classified["setCellFormat"] = "figure"
        XCTAssertEqual(
            Self.guardedMutatorProblems(names: withPlanted, classified: classified),
            ["setCellFormat: a figure writer not in manuscriptWriterPatterns",
             "setCellFormat: a figure writer not in figureMutatorSpellings"],
            "classified as a figure writer, it still fails until its spelling is listed")

        XCTAssertTrue(
            Self.guardedMutatorProblems(names: production, classified: Self.guardedDocumentMutators)
                .isEmpty,
            "and with the planted mutator taken away the census passes")
    }

    /// The census's control: it counts a planted call of each spelling, not the
    /// comment and not the declaration, and a file off the list fails it.
    func test_theManuscriptWriterCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-writers-selfcheck-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name setFullText( and restoreToOp( without being one.
        public func setFullText(_ text: String) {}
        doc.setFullText(rewritten)
        _ = try await doc.applyRestore(target: t, sourceCheckpoint: c, synthesisSource: .rewind)
        _ = try await doc.restoreToOp(opId: id)
        _ = try await doc.restoreToOpUndoable(opId: id, undoManager: um)
        let op = Restore.buildRestoreOp(current: a, target: b, scope: .document,
        try await store.replaceAll(in: results, with: text)
        try await store.replaceMatch(match, with: text)
        try await replaceInManuscript(path: p, title: t, query: q,
        doc.setParagraph(id: pid, text: flipped)
        _ = doc.insertParagraph(after: last, text: orphan)
        doc.deleteParagraph(id: pid)
        doc.reorder(sequence: ids)
        try await figure.setCell(cell, at: key)
        _ = try await figure.insertRow(after: nil)
        _ = try await self.figure?.insertColumn(after: nil)
        try await figures[i].deleteRow(row)
        try await figure.deleteColumn(column)
        try await d.reviveRow(id, removed: slice, actionName: name, undoManager: undoManager)
        try await d.reviveColumn(id, removed: slice, actionName: name, undoManager: undoManager)
        await d.redoing { try await d.moveRow(id, after: after, undoManager: undoManager) }
        try await figure.moveColumn(column, after: nil)
        try await setHeaderRows(1)
        try await figure.setTotalRow(true)
        try await figure.setColumnWidth(column, 120)
        try await figure.setImage(fromURL: picture)
        let record = try await store.createFigure(kind: .table, name: "Prices", piece: p)
        let image = try await store.createImageFigure(fromURL: picture, piece: p)
        let op = Op(opId: ULID.generate(), docId: figureId, at: Date(), device: device,
                    session: session, kind: kind, changes: [], figure: payload)
        """.write(to: tmp.appendingPathComponent("ASixthWayToWriteText.swift"),
                  atomically: true, encoding: .utf8)

        let planted = Self.byFile(try manuscriptWriterCallCounts(in: [tmp]))
        XCTAssertEqual(planted, ["ASixthWayToWriteText.swift": Dictionary(
                uniqueKeysWithValues: Self.manuscriptWriterPatterns.map { ($0, 1) })],
            "Self-check: each spelling is counted once, under its own name, the "
            + "comment and the declaration are not. Counted: \(planted)")
        XCTAssertNotEqual(planted, Self.manuscriptWriterCallSites,
            "and a file that is not on the list fails the census it feeds")
    }

    /// **A figure mutator's generic name counts only on FigureDocument's
    /// receiver shape** (report plan 6a Task 8). Plan 5's `FigureTable`
    /// mutators in Core, `FigureStructureChange`'s cases and the grid
    /// editor's model share the names `setCell(`/`insertRow(`/`moveRow(`, and
    /// all are synchronous: none is counted, so Core's `FigureDeriver.swift`
    /// and `TableCSV.swift` are not writer sites. The awaited
    /// `FigureDocument` call on the same file is, and taken away the file
    /// leaves the census. The production census's own result is checked the
    /// same way: no file that only holds a table helper is in it.
    func test_theFigureWriterSpellingsCountOnlyTheFigureHostsCalls() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-figure-writers-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let helpers = """
        // A comment may say try await figure.setCell(cell, at: key).
        state.table.setCell(p.next, at: key)
        table.setCell(Cell(content: content, format: format), at: CellKey(row: r, column: c))
        state.table.insertRow(id, after: after)
        state.table.moveRow(id, after: after)
        case let .insertRow(id, after):
        Button("Move Up") { model.moveRow(at.row, by: -1) }
        set: { model.setCell(row, column, to: $0) })
        let op = try await commit(.figureStructure, structure: .insertRow(id, after: after))
        try await commit(.figureStructure, FigureOpPayload(structure: .insertRow(id, after: after)))
        public func setCell(_ cell: Cell?, at key: CellKey) async throws {
        let payload = FigureOpPayload(cell: key, next: nil, prior: nil)
        let words = ElementWords(figure: "Figure", table: "Table")
        let wrapped = FigureOp(figure: payload)
        let nested = Op(kind: k, provenance: Provenance(figure: p))
        public init(opId: String, figure: FigureOpPayload? = nil) {}
        """
        try helpers.write(to: tmp.appendingPathComponent("FigureDeriver.swift"),
                          atomically: true, encoding: .utf8)
        XCTAssertEqual(Self.byFile(try manuscriptWriterCallCounts(in: [tmp])), [:],
            "Self-check: no table helper, structure case, grid-model call, "
            + "declaration, comment, bare payload or other `figure:` label is "
            + "counted as a figure writer")

        // Each awaited shape a caller may take counts once: a receiver that
        // ends in a call, and a call split across lines.
        try (helpers + """

        try await documentStore.openFigure(figureId: f).setCell(cell, at: key)
        _ = try await figure
            .insertRow(after: nil)
        """).write(to: tmp.appendingPathComponent("FigureDeriver.swift"),
                   atomically: true, encoding: .utf8)
        let shapes = try manuscriptWriterCallCounts(in: [tmp])
        XCTAssertEqual(Self.byFile(shapes), ["FigureDeriver.swift": ["setCell(": 1, "insertRow(": 1]],
            "Self-check: the chained and the split awaited calls each count")
        XCTAssertEqual(Set(shapes.map(\.hit.line)), [17, 19],
            "and each is counted on the line holding the mutator's name")

        try (helpers + "\ntry await figure.setCell(cell, at: key)\n")
            .write(to: tmp.appendingPathComponent("FigureDeriver.swift"),
                   atomically: true, encoding: .utf8)
        let planted = Self.byFile(try manuscriptWriterCallCounts(in: [tmp]))
        XCTAssertEqual(planted, ["FigureDeriver.swift": ["setCell(": 1]],
            "the planted FigureDocument call is counted, and only it")
        XCTAssertNotEqual(planted, Self.manuscriptWriterCallSites,
            "and a file off the list fails the census it feeds")

        let production = Self.byFile(try manuscriptWriterCallCounts(in: admissionRoots))
        for helperFile in ["FigureDeriver.swift", "TableCSV.swift", "FigureOp.swift",
                           "FigureTable.swift", "TableGridEditor.swift"] {
            XCTAssertNil(production[helperFile],
                "\(helperFile) holds table helpers, not figure writers")
        }
    }

    /// **A figure op is counted where the OP is born, not the payload**
    /// (report plan 6a Task 8 fix round 1): a writer that appends an `Op(`
    /// reusing another op's payload (`figure: someOp.figure`) — a restore, a
    /// replay — builds no `FigureOpPayload(` and calls no mutator, and is
    /// still caught, on the label's line, across a multi-line call. Taken
    /// away, the planted file leaves the census.
    func test_theFigureOpMintCensusFiresOnAReusedPayload() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-figure-mint-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("FigureCheckpointRestore.swift")

        let clean = """
        // A restore may say Op(…, figure: someOp.figure) in a comment.
        let ops = try await store.loadDiagnosed(docId: figureId).ops
        """
        try (clean + """

        for someOp in ops {
            try await opStore.append(Op(
                opId: ULID.generate(), docId: figureId, at: Date(), device: device,
                session: session, kind: someOp.kind, changes: [], figure: someOp.figure))
        }
        """).write(to: file, atomically: true, encoding: .utf8)
        let planted = try manuscriptWriterCallCounts(in: [tmp])
        XCTAssertEqual(Self.byFile(planted),
                       ["FigureCheckpointRestore.swift": [Self.figureOpMintSpelling: 1]],
            "Self-check: the reused payload's op is counted once")
        XCTAssertEqual(planted.map(\.hit.line), [6], "on the line holding `figure:`")
        XCTAssertNotEqual(Self.byFile(planted), Self.manuscriptWriterCallSites,
            "and a file off the list fails the census it feeds")

        try clean.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Self.byFile(try manuscriptWriterCallCounts(in: [tmp])), [:],
            "and taken away, nothing is counted")
    }

    /// **The figure scanners read every call shape, and through strings**
    /// (report plan 6a Task 8 fix round 2). Each planted shape below is
    /// counted on its own line, and taken away the file leaves the census:
    /// - awaited mutators: `async let`, a `$0.` receiver, `(await x).`, and
    ///   one `await` covering two calls (each counted);
    /// - op mints: `Op.init(`, a bare `.init(` carrying `opId:`, and an `Op(`
    ///   whose earlier string arguments hold `//` and `((`;
    /// - and NOT: a mutator or an `Op(…figure:` spelled inside a string
    ///   (single-line, interpolated or multi-line), a bare `.init(figure:`
    ///   without `opId:` (`ElementWords`' shape), or a `/* */` comment.
    func test_theFigureScannersReadThroughStringsAndEveryCallShape() throws {
        let quiet = #"""
        let words: [String: ElementWords] = ["es": .init(figure: "Figura", table: "Tabla")]
        let prose = "try await figure.setCell(x) and Op(opId: i, figure: p)"
        let mixed = "\(name) says try await figure.setRow( \("Op(figure: q)") ("
        let note = """
            try await figure.setCell(cell, at: key)
            Op(opId: a, figure: b)
            """
        /* try await figure.setCell(c, at: k); Op(opId: z, figure: y) */
        """#
        XCTAssertEqual(Self.manuscriptWriterHits(file: "Quiet.swift", text: quiet).count, 0,
            "Self-check: nothing in a string, an ElementWords .init or a comment counts")

        let loud = quiet + #"""

        async let r = figure.setCell(cell, at: key)
        try await cells.forEachAsync { try await $0.setHeaderRows(1) }
        try await (await store.openFigure(figureId: f)).setTotalRow(true)
        _ = try await (figure.moveRow(a, after: nil), other.moveRow(b, after: nil))
        let one = Op.init(opId: i, docId: d, at: t, device: v, session: s,
                          kind: k, changes: [], figure: p)
        let two: Op = .init(opId: i, docId: d, at: t, device: v, session: s, kind: k, changes: [], figure: p)
        let three = Op(opId: i, docId: d, at: t, device: "a//b", session: "((",
                       kind: k, changes: [], figure: p)
        let four = Op(opId: i, docId: d, at: t, device: v, session: s, kind: k, changes: [], figure: p)
        """#
        let hits = Self.manuscriptWriterHits(file: "Loud.swift", text: loud)
        func linesOf(_ spelling: String) -> [Int] {
            hits.filter { $0.value[spelling] != nil }.map(\.hit.line).sorted()
        }
        XCTAssertEqual(linesOf("setCell("), [9], "async let")
        XCTAssertEqual(linesOf("setHeaderRows("), [10], "a $0. receiver")
        XCTAssertEqual(linesOf("setTotalRow("), [11], "(await x).")
        XCTAssertEqual(linesOf("moveRow("), [12, 12], "one await, two calls, each counted")
        XCTAssertEqual(linesOf(Self.figureOpMintSpelling), [14, 15, 17, 18],
            "Op.init(, a bare .init( with opId:, an Op( past \"a//b\" and \"((\", "
            + "and the Op( after it — the depth is not skewed")
        XCTAssertEqual(hits.count, 9, "and nothing else: \(hits)")
    }

    /// **A swap inside a listed file fails the census** (Task 9): the same
    /// number of calls, one spelling traded for another, is a door that moved.
    func test_theManuscriptWriterCensusCountsEachSpellingNotEachFile() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-writers-swap-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // `ProjectSearchView.swift`'s two presses, as listed…
        try """
        try await store.replaceMatch(match, with: replacement)
        let outcome = try await store.replaceAll(in: r, with: replacement)
        """.write(to: tmp.appendingPathComponent("ProjectSearchView.swift"),
                  atomically: true, encoding: .utf8)
        let listed = Self.byFile(try manuscriptWriterCallCounts(in: [tmp]))
        XCTAssertEqual(listed["ProjectSearchView.swift"],
                       Self.manuscriptWriterCallSites["ProjectSearchView.swift"],
                       "precondition: the listed shape reads as listed")

        // …and the same file with one press reaching the text directly: two
        // calls still, so a per-file count would pass it.
        try """
        try await store.replaceMatch(match, with: replacement)
        doc.setFullText(rewritten)
        """.write(to: tmp.appendingPathComponent("ProjectSearchView.swift"),
                  atomically: true, encoding: .utf8)
        let swapped = Self.byFile(try manuscriptWriterCallCounts(in: [tmp]))
        XCTAssertEqual(swapped["ProjectSearchView.swift"]?.values.reduce(0, +), 2,
                       "precondition: the same number of calls")
        XCTAssertNotEqual(swapped["ProjectSearchView.swift"],
                          Self.manuscriptWriterCallSites["ProjectSearchView.swift"],
                          "a spelling traded for another inside a listed file fails")
    }

    // MARK: - The project stream's task door (P3c plan 2 Task 8)

    /// **Every project-stream task op passes one door, and its callers are a
    /// counted list.** `ProjectStore.appendProjectTaskOp` asks
    /// `projectTaskRefusal()` (the drawing posture of `__project__`) before it
    /// appends; every production call of it — the create, its ⌘Z inverse, the
    /// pane's archive and its inverse — is named here with a count per file.
    /// A NEW caller is a new way to write a project task and must be decided
    /// here; a caller that vanished is a verb that moved. Count the array,
    /// never a prose number.
    static let projectTaskOpAppendSites: [String: Int] = [
        // `createProjectPaneTask`'s append, and its ⌘Z inverse's.
        "ProjectStore+Tasks.swift": 2,
        // `archiveProjectTask`'s append (whose ⌘Z is registered only when it
        // landed), and its inverse's.
        "TasksPane.swift": 2,
    ]

    static func projectTaskOpAppendExcludeLine(_ line: String) -> Bool {
        admissionExcludeLine(line) || line.contains("func appendProjectTaskOp(")
    }

    private func projectTaskOpAppendCounts(in roots: [URL]) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for root in roots {
            for hit in try grepSwift(
                in: root, patterns: ["appendProjectTaskOp("],
                excludeLine: Self.projectTaskOpAppendExcludeLine) {
                counts[String(hit.prefix(while: { $0 != ":" })), default: 0] += 1
            }
        }
        return counts
    }

    func test_everyProjectTaskOpPassesTheProjectStreamsDoor() throws {
        XCTAssertEqual(try projectTaskOpAppendCounts(in: admissionRoots),
                       Self.projectTaskOpAppendSites,
            "A project-stream task op is appended from a site this census does "
            + "not name, or a named site moved. Add it to "
            + "`projectTaskOpAppendSites` with its reason in the same commit.")

        // The door is INSIDE the one append, before anything is written.
        let file = sourceDir.appendingPathComponent("Stores/ProjectStore+Tasks.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let body = try XCTUnwrap(
            text.components(separatedBy: "func appendProjectTaskOp(").dropFirst().first)
        let door = try XCTUnwrap(body.range(of: "projectTaskRefusal()"),
            "appendProjectTaskOp must ask the project stream's door")
        let write = try XCTUnwrap(body.range(of: "_projectOpLogMirror.append("))
        XCTAssertLessThan(door.lowerBound, write.lowerBound,
            "the door is asked before the mirror is written")
    }

    /// The census's control: a planted caller is counted, the declaration and
    /// a comment are not, and a file off the list fails the census.
    func test_theProjectTaskOpAppendCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-projecttask-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try """
        // A comment may say appendProjectTaskOp( freely.
        public func appendProjectTaskOp(_ op: Op) -> Bool { true }
        store.appendProjectTaskOp(op)
        """.write(to: tmp.appendingPathComponent("ASecondProjectTaskWriter.swift"),
                  atomically: true, encoding: .utf8)
        let planted = try projectTaskOpAppendCounts(in: [tmp])
        XCTAssertEqual(planted, ["ASecondProjectTaskWriter.swift": 1],
            "Self-check: the call is counted, the declaration and the comment "
            + "are not. Counted: \(planted)")
        XCTAssertNotEqual(planted, Self.projectTaskOpAppendSites)
    }

    // MARK: - author_collaborator_id is decoded and never written (P3c Task 4)

    /// The argument label that WRITES the retired field into an op. Reading it
    /// (`prov?.authorCollaboratorId`, `AnnotationDeriver`) carries no colon.
    static let collaboratorIdWritePatterns = ["authorCollaboratorId:"]

    /// `Op.swift` declares the field, its init parameter and its decode — old
    /// logs carry it — and nothing else may name the label.
    static let collaboratorIdWriteAllowed: [String: Set<String>] = [
        "Op.swift": ["authorCollaboratorId:"],
    ]

    /// **`author_collaborator_id` is decoded and never written** (signed op
    /// log P3 spec §8, Denver's ruling 2026-09-19 — attribution is the signing
    /// device through the registry; claim M5-AN-012). The WF1 share-role
    /// system stamped a collaborator id on reviewer annotations; a second
    /// writer would be a second attribution beside the signature, one nothing
    /// verifies.
    func test_theCollaboratorIdIsDecodedAndNeverWritten() throws {
        let writers = try grepSwift(
            in: admissionRoots,
            patterns: Self.collaboratorIdWritePatterns,
            allowedSpellings: Self.collaboratorIdWriteAllowed,
            excludeLine: Self.admissionExcludeLine)
        XCTAssertTrue(writers.isEmpty,
            "A file writes `authorCollaboratorId` into an op. It is decoded "
            + "from old logs and never written — attribution is the signing "
            + "device. Offenders:\n" + writers.joined(separator: "\n"))
    }

    /// The control: a planted writer is caught, the comment and a read are
    /// not, and the same file named `Op.swift` is admitted.
    func test_theCollaboratorIdCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-collabid-selfcheck-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try """
        // A comment may name authorCollaboratorId: freely.
        let read = AnnotationAuthor(sourceKind: .human, displayName: "", collaboratorId: prov?.authorCollaboratorId)
        let prov = Op.Provenance(authorDisplayName: name, authorCollaboratorId: id)
        """.write(to: tmp.appendingPathComponent("SecondAttribution.swift"),
                  atomically: true, encoding: .utf8)
        func hits() throws -> [String] {
            try grepSwift(in: [tmp], patterns: Self.collaboratorIdWritePatterns,
                          allowedSpellings: Self.collaboratorIdWriteAllowed,
                          excludeLine: Self.admissionExcludeLine)
        }
        let planted = try hits()
        XCTAssertEqual(planted.count, 1, "Self-check: the one writer is caught. Caught:\n"
                       + planted.joined(separator: "\n"))
        XCTAssertTrue(planted.first?.contains("let prov") == true)

        try fm.moveItem(at: tmp.appendingPathComponent("SecondAttribution.swift"),
                        to: tmp.appendingPathComponent("Op.swift"))
        XCTAssertTrue(try hits().isEmpty, "Self-check: Op.swift is admitted")
    }
}

// MARK: - Option A: every piece a creation makes records its starter

/// **Every production `StructureItem(` construction records `startedBy:`, or
/// says why not** (P3c plan 2 Task 4 fix round 1, M3; Ruling OA-1).
///
/// A construction that forgets the field does not fail: its piece silently
/// falls back to today's rule, so the Mac that made it no longer mints its
/// opening first and a collaborator's words can land behind somebody else's.
/// The population is DERIVED — every `StructureItem(` in `Maugham/`,
/// `MaughamPhone/` and MaughamCore's sources — and each file's count is a
/// named entry, so a new construction anywhere is judged here.
///
/// **Its known limit**: a structure item made by COPYING another (`var copy =
/// source`, `duplicatedItemTree`) constructs nothing and is not seen; the
/// duplicate re-stamps `copy.startedBy` itself and is pinned by
/// `AdmissionPermitTests.test_everyCreationRecordsThisMacAndARenameOrMoveNeverRewritesIt`.
extension TripwireGrepTests {

    /// File → how many `StructureItem(` constructions it holds, and what each
    /// records. Count the array, never a prose number.
    static let structureItemConstructions: [String: (count: Int, records: String)] = [
        "ProjectStore+Structure.swift":
            (1, "addStructureItem — this Mac, on a document; nil on a group"),
        "ProjectStore+CollectionPieces.swift":
            (3, "addLoosePiece, addProjectReference — this Mac; "
                + "writePromotedManifest — carries the piece's own (a move)"),
        "ProjectFactory.swift":
            (2, "a new book's first piece — this Mac"),
    ]

    /// Constructions allowed to leave `startedBy:` out, by `"<file>#<n>"`
    /// (the n-th construction in that file, from 1), each with its reason.
    /// Empty today: every construction records a starter.
    static let structureItemConstructionsWithoutAStarter: [String: String] = [:]

    /// Every `StructureItem(` construction in `text`: its argument list, found
    /// by balancing parentheses. A name that merely ENDS in `StructureItem(`
    /// (`restoreStructureItem(`) is not one, and neither is a comment line.
    static func structureItemConstructions(in text: String) -> [String] {
        let chars = Array(text)
        let needle = Array("StructureItem(")
        var found: [String] = []
        var i = 0
        while i + needle.count <= chars.count {
            guard Array(chars[i..<(i + needle.count)]) == needle else { i += 1; continue }
            let before: Character? = i > 0 ? chars[i - 1] : nil
            if let before, before.isLetter || before.isNumber || before == "_" {
                i += needle.count; continue
            }
            // The line this sits on, to skip a comment.
            var lineStart = i
            while lineStart > 0, chars[lineStart - 1] != "\n" { lineStart -= 1 }
            let linePrefix = String(chars[lineStart..<i])
                .trimmingCharacters(in: .whitespaces)
            if linePrefix.hasPrefix("//") || linePrefix.hasPrefix("*") {
                i += needle.count; continue
            }
            var depth = 1
            var j = i + needle.count
            while j < chars.count, depth > 0 {
                if chars[j] == "(" { depth += 1 }
                if chars[j] == ")" { depth -= 1 }
                j += 1
            }
            found.append(String(chars[(i + needle.count)..<max(i + needle.count, j - 1)]))
            i = j
        }
        return found
    }

    /// Does a construction's argument list record a starter? It must NAME
    /// `startedBy:`, and its value must not be a bare `nil` (2026-10-11 sweep,
    /// SW3 — the label alone passed a construction that records nobody). A
    /// conditional that can yield nil (`isDocument ? starter : nil`) passes:
    /// that is the census's stated limit, and `addStructureItem`'s group arm
    /// is the one such site today.
    static func recordsAStarter(_ args: String) -> Bool {
        guard let label = args.range(of: "startedBy:") else { return false }
        let value = args[label.upperBound...].drop(while: { $0.isWhitespace })
        guard value.hasPrefix("nil") else { return true }
        let after = value.dropFirst(3).first
        return after.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
    }

    /// The census over a set of `(file name, source)` pairs: the per-file
    /// counts, and every construction missing `startedBy:` (or recording a
    /// bare `nil`) that is not allowed.
    static func structureItemCensus(
        _ files: [(name: String, text: String)]
    ) -> (counts: [String: Int], missing: [String]) {
        var counts: [String: Int] = [:]
        var missing: [String] = []
        for file in files {
            let calls = structureItemConstructions(in: file.text)
            guard !calls.isEmpty else { continue }
            counts[file.name, default: 0] += calls.count
            for (index, args) in calls.enumerated()
            where !recordsAStarter(args)
                && structureItemConstructionsWithoutAStarter["\(file.name)#\(index + 1)"] == nil {
                missing.append("\(file.name)#\(index + 1)")
            }
        }
        return (counts, missing)
    }

    private func productionSources(under roots: [String]) -> [(name: String, text: String)] {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var files: [(name: String, text: String)] = []
        for root in roots {
            let dir = here.appendingPathComponent(root, isDirectory: true)
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                files.append((url.lastPathComponent, text))
            }
        }
        return files
    }

    func test_everyStructureItemAProductionFileConstructsRecordsItsStarter() {
        let census = Self.structureItemCensus(productionSources(
            under: ["Maugham", "MaughamPhone", "Packages/MaughamCore/Sources"]))
        XCTAssertEqual(
            census.counts, Self.structureItemConstructions.mapValues(\.count),
            "a StructureItem construction appeared or went: name it in "
            + "structureItemConstructions with what it records as its starter")
        XCTAssertEqual(census.missing, [],
                       "these constructions record no startedBy and give no reason")
        XCTAssertFalse(census.counts.isEmpty,
                       "the control: no construction found means the scan reads nothing")
    }

    /// The planted offender: a construction without `startedBy:`, or with a
    /// bare `startedBy: nil`, is caught; a name ending in `StructureItem(` and
    /// a comment are not, and a nested
    /// call inside the argument list does not end it early.
    func test_theStarterCensusFiresOnAPlantedOffender() {
        let planted = """
        // StructureItem(id: "in a comment", title: "t", type: .document)
        let a = restoreStructureItem(item)
        let b = StructureItem(id: newId(prefix: "doc"), title: t, type: .document)
        let c = StructureItem(
            id: newId(prefix: "doc"), title: t, type: .document,
            startedBy: Self.thisMacAsAStarter)
        let d = StructureItem(id: newId(prefix: "doc"), title: t, type: .document,
                              startedBy: nil)
        let e = StructureItem(id: i, title: t, type: .document, startedBy:nil)
        let f = StructureItem(id: i, title: t, type: .document, startedBy: nilStarter)
        let g = StructureItem(id: i, title: t, type: k, startedBy: isDoc ? me : nil)
        """
        let census = Self.structureItemCensus([("Planted.swift", planted)])
        XCTAssertEqual(census.counts, ["Planted.swift": 6])
        XCTAssertEqual(census.missing, ["Planted.swift#1", "Planted.swift#3", "Planted.swift#4"],
                       "a missing label and a bare nil are named (SW3); an identifier "
                       + "beginning with nil and a conditional are not")
    }

    // MARK: - The editor's checkbox click asks the membrane first (#74)

    /// Names what is wrong with a `mouseDown` body, or returns nil. The rule:
    /// the first `checkboxToggleHandler` in the body is preceded by an
    /// `allowsCheckboxToggle` — the clause that stops a click in a locked or
    /// yielding editor from writing text (and silently claiming a piece).
    static func checkboxGateProblem(inMouseDownBody body: String) -> String? {
        guard let use = body.range(of: "checkboxToggleHandler") else { return nil }
        guard let gate = body.range(of: "allowsCheckboxToggle"), gate.lowerBound < use.lowerBound else {
            return "checkboxToggleHandler is reached without allowsCheckboxToggle before it"
        }
        return nil
    }

    /// The text of `override func mouseDown(with event: NSEvent) { … }`, brace-matched.
    static func mouseDownBody(in source: String) -> String? {
        guard let sig = source.range(of: "override func mouseDown(with event: NSEvent)"),
              let open = source[sig.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 }
            if source[i] == "}" { depth -= 1; if depth == 0 { return String(source[open...i]) } }
            i = source.index(after: i)
        }
        return nil
    }

    func test_theEditorsCheckboxClickAsksTheMembraneFirst() throws {
        let editorDir = sourceDir.appendingPathComponent("Editor")
        let surface = try String(contentsOf: editorDir.appendingPathComponent("EditorSurface.swift"),
                                 encoding: .utf8)
        let body = try XCTUnwrap(Self.mouseDownBody(in: surface), "mouseDown not found")
        XCTAssertTrue(body.contains("checkboxToggleHandler"), "the click still reaches the handler")
        XCTAssertNil(Self.checkboxGateProblem(inMouseDownBody: body))

        // Nowhere else INVOKES the handler: a use is `checkboxToggleHandler` followed
        // by `{`/`(`-free reads only in wiring (`= …checkboxToggleHandler`, a label,
        // a declaration) — so flag any other file where it is read into a `let`
        // binding or called, and any second use in EditorSurface outside mouseDown.
        let fm = FileManager.default
        var offenders: [String] = []
        for dir in [editorDir, sourceDir.appendingPathComponent("Views")] {
            for case let url as URL in fm.enumerator(at: dir, includingPropertiesForKeys: nil)!
            where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.contains("checkboxToggleHandler"), !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                    let wiring = t.contains("var checkboxToggleHandler")
                        || t.contains("checkboxToggleHandler = ")
                        || t.hasPrefix("checkboxToggleHandler:")
                        || t.contains("let toggle = coordinator?.checkboxToggleHandler")
                    if !wiring { offenders.append("\(url.lastPathComponent): \(t)") }
                }
            }
        }
        XCTAssertEqual(offenders, [], "checkboxToggleHandler is read only by mouseDown, behind the gate")
        XCTAssertEqual(surface.components(separatedBy: "coordinator?.checkboxToggleHandler").count - 1, 1,
                       "EditorSurface reads the handler off the coordinator in exactly one place")
    }

    func test_theCheckboxGateCensusFiresOnAPlantedOffender() {
        let ungated = """
        { let hit = coordinator?.checkboxHitTest(atCharacterIndex: i)
          if let toggle = coordinator?.checkboxToggleHandler { toggle(a, b, c); return } }
        """
        XCTAssertNotNil(Self.checkboxGateProblem(inMouseDownBody: ungated))
        let reordered = "{ if let t = coordinator?.checkboxToggleHandler, coordinator?.allowsCheckboxToggle == true {} }"
        XCTAssertNotNil(Self.checkboxGateProblem(inMouseDownBody: reordered))
        let gated = "{ if coordinator?.allowsCheckboxToggle == true, let t = coordinator?.checkboxToggleHandler {} }"
        XCTAssertNil(Self.checkboxGateProblem(inMouseDownBody: gated))
        XCTAssertEqual(Self.mouseDownBody(in: "override func mouseDown(with event: NSEvent) { if x { y } } z"),
                       "{ if x { y } }")
    }

    // MARK: - The table grid opens on a double-click of the delimiter row only (plan 3b Task 5)

    /// Names what is wrong with a `mouseDown` body's table double-click, or
    /// returns nil. R-3b-3: a double-click on a table's delimiter row opens
    /// the grid; inside a cell it stays AppKit's word selection. So the
    /// coordinator's `editTableOnDelimiterRow` (which says no off the
    /// delimiter row, `TableGridCommandTests`) is asked in ONE `if`, whose
    /// clause first requires `event.clickCount == 2` — a single click would
    /// otherwise open the sheet — and before `super.mouseDown`, which would
    /// already have selected the word.
    ///
    /// And `mouseDown` never calls `editTable(` itself (fix round 1, M4):
    /// that opens the grid wherever the caret's table is, with no
    /// delimiter-row question asked.
    static func tableDoubleClickProblem(inMouseDownBody body: String) -> String? {
        if body.contains("editTable(") {
            return "mouseDown calls editTable( directly, skipping the delimiter-row question"
        }
        let ask = "editTableOnDelimiterRow"
        let uses = body.components(separatedBy: ask).count - 1
        guard uses == 1, let use = body.range(of: ask) else {
            return "mouseDown asks editTableOnDelimiterRow \(uses) times, not once"
        }
        guard let clause = body[..<use.lowerBound].range(of: "if ", options: .backwards),
              body[clause.upperBound..<use.lowerBound].contains("event.clickCount == 2,")
        else {
            return "editTableOnDelimiterRow is asked without event.clickCount == 2 first in its if"
        }
        // The call, not a comment naming it — spelled in two halves so the
        // click census does not read this helper as one that builds a click.
        if let superCall = body.range(of: "super.mouseDown" + "(with:"),
           superCall.lowerBound < use.lowerBound {
            return "editTableOnDelimiterRow is asked after super.mouseDown has selected the word"
        }
        return nil
    }

    func test_theTableDoubleClickIsADoubleClickOnTheDelimiterRow() throws {
        let editorDir = sourceDir.appendingPathComponent("Editor")
        let surface = try String(contentsOf: editorDir.appendingPathComponent("EditorSurface.swift"),
                                 encoding: .utf8)
        let body = try XCTUnwrap(Self.mouseDownBody(in: surface), "mouseDown not found")
        XCTAssertNil(Self.tableDoubleClickProblem(inMouseDownBody: body))
        // The double-click route is defined in the coordinator and called by
        // mouseDown alone: any other caller is a way in no ruling covers.
        var callers: [String] = []
        for dir in [editorDir, sourceDir.appendingPathComponent("Views")] {
            for case let url as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
            where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("editTableOnDelimiterRow(") { callers.append(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(callers.sorted(), ["EditorCoordinator+Tables.swift", "EditorSurface.swift"],
                       "the double-click route is defined in the coordinator and called by mouseDown alone")
    }

    /// The planted bodies live in multi-line literals, which the click census
    /// (tripwire 33's click arm) does not read as code.
    func test_theTableDoubleClickCensusFiresOnAPlantedOffender() {
        let anyClick = """
            { if coordinator?.editTableOnDelimiterRow(atCharacterIndex: i) == true { return }
              super.mouseDown(with: event) }
            """
        XCTAssertNotNil(Self.tableDoubleClickProblem(inMouseDownBody: anyClick), "a single click opens it")
        let afterSuper = """
            { super.mouseDown(with: event)
              if event.clickCount == 2, coordinator?.editTableOnDelimiterRow(atCharacterIndex: i) == true { return } }
            """
        XCTAssertNotNil(Self.tableDoubleClickProblem(inMouseDownBody: afterSuper), "the word is already selected")
        let otherIf = """
            { if event.clickCount == 2, x { }
              if coordinator?.editTableOnDelimiterRow(atCharacterIndex: i) == true { return }
              super.mouseDown(with: event) }
            """
        XCTAssertNotNil(Self.tableDoubleClickProblem(inMouseDownBody: otherIf), "the count is another if's")
        let gone = """
            { super.mouseDown(with: event) }
            """
        XCTAssertNotNil(Self.tableDoubleClickProblem(inMouseDownBody: gone), "the route is gone")
        let direct = """
            { if event.clickCount == 2,
                 coordinator?.editTableOnDelimiterRow(atCharacterIndex: i) == true { return }
              if event.clickCount == 2 { coordinator?.editTable(at: i); return }
              super.mouseDown(with: event) }
            """
        XCTAssertNotNil(Self.tableDoubleClickProblem(inMouseDownBody: direct),
                        "editTable( called straight from mouseDown")
        let wired = """
            { // falls through to `super.mouseDown` below
              if event.clickCount == 2,
                 coordinator?.editTableOnDelimiterRow(atCharacterIndex: i) == true { return }
              super.mouseDown(with: event) }
            """
        XCTAssertNil(Self.tableDoubleClickProblem(inMouseDownBody: wired),
                     "a comment naming super.mouseDown is not the call")
    }
}

// MARK: - One temp root for every test (signed op log P3 plan 3, Task 1)

/// **Every test builds under `TestTemp`, and nothing else names the machine's
/// temp directory.**
///
/// `$TMPDIR` reached 208,937 entries and its link-count cap, almost all of them
/// this project's own fixtures: every test named the temp directory itself, so
/// a fixture that forgot its `removeItem` — or whose `removeItem` raced an
/// async write — lived for ever, and at 543,002 entries a launch-time listing
/// of it hung whole gates. `TestTemp.root` is removed when its test finishes
/// whatever the test did; this census is what keeps a new test from reaching
/// past it.
///
/// Over `MaughamTests/` and `Packages/MaughamCore/Tests/` (the phone's twin is
/// `TripwirePhoneGrepTest.test_noTestNamesTheTempDirectoryButTestTemp`). The
/// three `TestTemp.swift` files are the one home. The allow-list is FILE plus
/// SPELLING, and each entry says why a test must name a PRODUCTION temp path.
extension TripwireGrepTests {

    /// Spelled in halves so this file does not match itself.
    static let tempDirectoryNeedles = ["temporary" + "Directory", "NSTemporary" + "Directory("]

    struct TempDirectoryAllowance {
        let file: String
        let spelling: String
        let reason: String
    }

    static let tempDirectoryAllowed: [TempDirectoryAllowance] = [
        TempDirectoryAllowance(
            file: "TestHostSocketPathTests.swift",
            spelling: "temporary" + "Directory: temp)",
            reason: "the argument LABEL of production's TestHost.mcpSocketPath, over a fixture path"),
        TempDirectoryAllowance(
            file: "TestHostSocketPathTests.swift",
            spelling: "temporary" + "Directory: FileManager.default.temporary" + "Directory)",
            reason: "sun_path's 104 bytes are checked against the REAL temp root production binds under; "
                + "a TestTemp root is ~60 bytes longer and would fail for the wrong reason"),
    ]

    /// Every line under `dirs` naming the temp directory, minus comments, the
    /// `TestTemp.swift` files, and allow-listed file-plus-spelling pairs.
    /// Also returns which allowances matched nothing, so a stale entry is loud.
    static func rawTempDirectorySites(
        under dirs: [URL],
        allowed: [TempDirectoryAllowance] = tempDirectoryAllowed
    ) throws -> (offenders: [String], unusedAllowances: [String]) {
        var offenders: [String] = []
        var used = Set<Int>()
        for dir in dirs {
            guard let walker = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let name = url.lastPathComponent
                if name == "TestTemp.swift" { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    guard tempDirectoryNeedles.contains(where: { trimmed.contains($0) }) else {
                        continue
                    }
                    if let hit = allowed.indices.first(where: {
                        allowed[$0].file == name && trimmed.contains(allowed[$0].spelling)
                    }) {
                        used.insert(hit)
                        continue
                    }
                    offenders.append("\(name):\(i + 1): \(trimmed)")
                }
            }
        }
        let unused = allowed.indices.filter { !used.contains($0) }
            .map { "\(allowed[$0].file) — \(allowed[$0].spelling)" }
        return (offenders, unused)
    }

    func test_noTestNamesTheTempDirectoryButTestTemp() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let census = try Self.rawTempDirectorySites(under: [
            repoRoot.appendingPathComponent("MaughamTests", isDirectory: true),
            repoRoot.appendingPathComponent("Packages/MaughamCore/Tests", isDirectory: true),
        ])
        XCTAssertTrue(census.offenders.isEmpty,
            "\(census.offenders.count) test lines name the machine's temp directory — "
            + "build under TestTemp.root (or TestTemp.workerRoot for a class fixture):\n"
            + census.offenders.joined(separator: "\n"))
        XCTAssertTrue(census.unusedAllowances.isEmpty,
            "allow-list entries that match nothing any more — remove them:\n"
            + census.unusedAllowances.joined(separator: "\n"))
    }

    /// The control: every spelling is caught — the `FileManager.default` one,
    /// a local `fm` alias, a bare `NSTemporaryDirectory()` — a comment is not,
    /// and the allow-list is file PLUS spelling: the allowed spelling passes in
    /// its file, and a different spelling in that same file is still caught.
    func test_theTempDirectoryCensusFiresOnPlantedOffenders() throws {
        let tmp = TestTemp.root.appendingPathComponent("tripwire-temp-selfcheck")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let td = "temporary" + "Directory"
        let ns = "NSTemporary" + "Directory"
        try """
        // FileManager.default.\(td) in a comment is fine
        let a = FileManager.default.\(td).appendingPathComponent("x")
        let fm = FileManager.default
        let b = fm.\(td)
        let c = URL(fileURLWithPath: \(ns)())
        let d = \(ns)() + "/y"
        """.write(to: tmp.appendingPathComponent("PlantedTests.swift"),
                  atomically: true, encoding: .utf8)
        try """
        let p = TestHost.mcpSocketPath(pid: 1, \(td): temp)
        let q = FileManager.default.\(td).path
        """.write(to: tmp.appendingPathComponent("TestHostSocketPathTests.swift"),
                  atomically: true, encoding: .utf8)
        try "let r = FileManager.default.\(td)".write(
            to: tmp.appendingPathComponent("TestTemp.swift"), atomically: true, encoding: .utf8)

        let census = try Self.rawTempDirectorySites(under: [tmp])
        let byFile = Dictionary(grouping: census.offenders) { String($0.prefix { $0 != ":" }) }
        XCTAssertEqual(byFile["PlantedTests.swift"]?.count, 4,
            "all four spellings, and not the comment:\n" + census.offenders.joined(separator: "\n"))
        XCTAssertEqual(byFile["TestHostSocketPathTests.swift"]?.count, 1,
            "the allowed spelling passes in its file; any other spelling there is caught:\n"
            + census.offenders.joined(separator: "\n"))
        XCTAssertTrue(byFile["TestHostSocketPathTests.swift"]?.first?.contains(".path") == true)
        XCTAssertNil(byFile["TestTemp.swift"], "TestTemp.swift is the one home")
        XCTAssertEqual(census.unusedAllowances.count, 1,
            "the planted tree uses one of the two allowances; the other is reported unused")
    }

    /// The three `TestTemp.swift` copies (and their tests) are one file in three
    /// places — a test bundle cannot import another's sources — so a fix made in
    /// one and not the others is a drift this catches.
    func test_theThreeTestTempFilesAreIdentical() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["TestTemp.swift", "TestTempTests.swift"] {
            let copies = try [
                "MaughamTests/TestSupport/", "MaughamPhoneTests/",
                "Packages/MaughamCore/Tests/MaughamCoreTests/",
            ].map { try String(contentsOf: repoRoot.appendingPathComponent($0 + name), encoding: .utf8) }
            XCTAssertEqual(Set(copies).count, 1, "the three \(name) copies have drifted")
        }
    }

    // MARK: - The fountain literal has one home (foundations plan 7, Task 7)

    /// The quoted spellings of the Fountain format: the bare extension, any
    /// literal ENDING in the extension (so `"\(slug).fountain"` is caught as
    /// well as `".fountain"`), and any literal STARTING `fountain-` (the help
    /// resource, and whatever `"fountain-syntax-v2"` follows it). None matches
    /// `"fountain_boneyard"`, a persisted task-kind raw value.
    static let fountainLiteralPatterns = [#""fountain""#, #".fountain""#, #""fountain-"#]

    /// Where a fountain literal may be spelled, and why.
    static let fountainLiteralAllowed: [String: String] = [
        "type:DocumentFormat": "the one home: extension, help resource and every format decision",
        "type:ReadDocumentTool": "`read_document.mode`'s MCP wire value, pinned by DocumentToolsTests",
    ]

    private func fountainLiteralOffenders(in roots: [URL], allowed: Set<String>) throws -> [String] {
        try grepSwift(
            in: roots, patterns: Self.fountainLiteralPatterns, allowed: allowed,
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") },
            extraOffender: nil)
    }

    /// **The Fountain extension is spelled in `DocumentFormat` only.** A site
    /// that compares an extension or a suffix to `"fountain"` itself is a second
    /// answer to "is this Fountain?" — and five such sites had drifted to
    /// case-sensitive while the op log read `X.FOUNTAIN` as Fountain. Mac,
    /// phone and Core are all scanned.
    func test_theFountainExtensionIsSpelledInDocumentFormatOnly() throws {
        let offenders = try fountainLiteralOffenders(
            in: SourceTree.productionRootURLs, allowed: Set(Self.fountainLiteralAllowed.keys))
        XCTAssertEqual(offenders, [],
            "a fountain literal outside DocumentFormat — ask `DocumentFormat` "
            + "(`ofManuscript(path:)`, `fileExtension`, `helpResourceName`) instead:\n"
            + offenders.joined(separator: "\n"))
    }

    /// The control: each code spelling is caught — the bare extension, a
    /// suffix, an interpolated filename, the help resource — while a comment
    /// and `"fountain_boneyard"` are not; inside `DocumentFormat` they pass,
    /// and a lookalike (a file NAMED `DocumentFormat.swift` declaring another
    /// type) is still caught.
    func test_theFountainLiteralCensusFiresOnPlantedOffenders() throws {
        let dir = TestTemp.root
            .appendingPathComponent("fountain-literal-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let planted = dir.appendingPathComponent("Planted.swift")
        try #"""
        let a = url.pathExtension.lowercased() == "fountain"
        let b = path.hasSuffix(".fountain")
        let c = Bundle.main.url(forResource: "fountain-syntax", withExtension: "md")
        let d = "\(slug).fountain"
        // "fountain"
        case fountainBoneyard = "fountain_boneyard"
        let g = Bundle.main.url(forResource: "fountain-syntax-v2", withExtension: "md")
        """#.write(to: planted, atomically: true, encoding: .utf8)
        try #"struct DocumentFormatter { let e = "fountain" }"#
            .write(to: dir.appendingPathComponent("DocumentFormat.swift"), atomically: true, encoding: .utf8)

        let bare = try fountainLiteralOffenders(in: [dir], allowed: [])
        let byFile = Dictionary(grouping: bare) { String($0.prefix { $0 != ":" }) }
        XCTAssertEqual(byFile["Planted.swift"]?.map { SourceTree.Hit(offender: $0)?.line },
                       [1, 2, 3, 4, 7],
                       "the five code spellings, not the comment or the boneyard:\n"
                       + bare.joined(separator: "\n"))
        XCTAssertEqual(byFile["DocumentFormat.swift"]?.count, 1, bare.joined(separator: "\n"))

        try Self.declare("DocumentFormat", in: planted)
        let allowed = Self.dropping(unplanted: ["type:ReadDocumentTool"], from: try fountainLiteralOffenders(
            in: [dir], allowed: Set(Self.fountainLiteralAllowed.keys)))
        XCTAssertEqual(allowed.count, 1, "only the lookalike is caught:\n" + allowed.joined(separator: "\n"))
        XCTAssertTrue(allowed.first?.hasPrefix("DocumentFormat.swift:1:") == true,
                      "a file NAMED DocumentFormat.swift earns nothing: \(allowed)")
    }

    // MARK: - Word bookmark names have one home (report plan 4, Task 3)

    /// The quoted beginnings of a Word bookmark name: Maugham's paragraph
    /// (`p_`) and label (`l_`) prefixes, and Word's own hidden ones (`_Ref`,
    /// `_Toc`, `_GoBack`). A name built anywhere else is a second mapping the
    /// round trip (milestone 3) would not read back.
    static let bookmarkNamePatterns = [#""p_"#, #""l_"#, #""_Ref"#, #""_Toc"#, #""_GoBack"#]

    static let bookmarkNameAllowed: [String: String] = [
        "type:DOCXNames": "the one home: R-4-3's paragraph and label mapping, its truncation and counter",
    ]

    private func bookmarkNameOffenders(in roots: [URL], allowed: Set<String>) throws -> [String] {
        try grepSwift(
            in: roots, patterns: Self.bookmarkNamePatterns, allowed: allowed,
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") },
            extraOffender: nil)
    }

    /// **Every Word bookmark name is spelled in `DOCXNames`** (R-4-3): the
    /// emitter asks it for every `w:name` and every `REF` target, so a
    /// returned file's bookmarks map back through one function.
    func test_bookmarkNamesAreSpelledInDOCXNamesOnly() throws {
        let offenders = try bookmarkNameOffenders(
            in: SourceTree.productionRootURLs, allowed: Set(Self.bookmarkNameAllowed.keys))
        XCTAssertEqual(offenders, [],
            "a bookmark name spelled outside DOCXNames — ask `DOCXNames.paragraphBookmark` "
            + "or `labelBookmark` instead:\n" + offenders.joined(separator: "\n"))
    }

    /// The control: each spelling is caught — a paragraph prefix, an
    /// interpolated label name, Word's hidden prefixes — while a comment and
    /// an unrelated `"map_"` are not; declared inside `DOCXNames` they pass.
    func test_theBookmarkNameCensusFiresOnPlantedOffenders() throws {
        let dir = TestTemp.root
            .appendingPathComponent("bookmark-name-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let planted = dir.appendingPathComponent("Planted.swift")
        try #"""
        let a = "p_" + id
        let b = "l_\(label.kind.rawValue)_\(label.name)"
        // "p_k3wq"
        let c = "map_" + id
        let d = "_Ref123456"
        let e = "_Toc1"
        let f = "_GoBack"
        """#.write(to: planted, atomically: true, encoding: .utf8)

        let bare = try bookmarkNameOffenders(in: [dir], allowed: [])
        XCTAssertEqual(bare.compactMap { SourceTree.Hit(offender: $0)?.line }, [1, 2, 5, 6, 7],
                       "the five spellings, not the comment or map_:\n" + bare.joined(separator: "\n"))

        try Self.declare("DOCXNames", in: planted)
        let allowed = try bookmarkNameOffenders(in: [dir], allowed: Set(Self.bookmarkNameAllowed.keys))
        XCTAssertEqual(allowed, [], "inside DOCXNames every spelling passes:\n" + allowed.joined(separator: "\n"))
    }

    // MARK: - Kind and format are asked by capability (foundations plan 7, Task 8)

    /// Equality (or a `case … =` match) against a `ProjectType` or
    /// `DocumentFormat` case name, in each spelling a second answer takes:
    /// leading-dot or qualified (`ProjectType.screenplay`), on either side of
    /// the operator, an optional pattern (`case .collection? =`), an extension
    /// compared to a format's `fileExtension` (the case-sensitive re-derivation
    /// `DocumentFormat(fileExtension:)` exists to replace), and a kind's raw
    /// value compared to its string. Word-bounded, so `.fountainBoneyard` and
    /// `.collectionPiece` are not caught; and NOT a bare `.fileExtension ==`,
    /// which is `DocumentFormat`'s own lookup and every `OpLogSegment` filename.
    static let kindEqualityPattern: NSRegularExpression = {
        let cases = "(screenplay|collection|novel|shortStory|fountain|markdown)"
        let qualifier = "(?:ProjectType|DocumentFormat)?"
        return try! NSRegularExpression(pattern: [
            #"(==|!=)\s*"# + qualifier + #"\."# + cases + #"\b"#,
            qualifier + #"\."# + cases + #"\s*(==|!=)"#,
            #"case\s+"# + qualifier + #"\."# + cases + #"\??\s*="#,
            #"(==|!=)\s*(?:DocumentFormat)?\.(fountain|markdown)\.fileExtension\b"#,
            #"DocumentFormat\.(fountain|markdown)\.fileExtension\s*(==|!=)"#,
            #"rawValue\s*(==|!=)\s*"(screenplay|collection|novel|short_story)""#,
        ].joined(separator: "|"))
    }()

    /// Where equality on kind or format is allowed, and why. Empty. A key is
    /// `type:<Type>` only, and it exempts that type's whole declaration — so a
    /// real exception should prefer an exhaustive `switch`, which needs no key.
    static let kindEqualityAllowed: [String: String] = [:]

    private func kindEqualityOffenders(in roots: [URL], allowed: Set<String>) throws -> [String] {
        try grepSwift(
            in: roots, patterns: [], allowed: allowed,
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") },
            extraOffender: { line in
                Self.kindEqualityPattern.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)) != nil
            })
    }

    /// **A project's kind and a document's format are asked by capability,
    /// never by equality.** `type == .collection` is `holdsPieces`;
    /// `type == .screenplay` is `primaryFormat.isScreenplay`; a format decision
    /// is an exhaustive `switch` or a `DocumentFormat` property. An equality is
    /// a second answer that a new case (`.unknown` today, a new kind tomorrow)
    /// silently falls through. Mac, phone and Core are all scanned.
    func test_projectKindAndFormatAreAskedByCapabilityNotByEquality() throws {
        let offenders = try kindEqualityOffenders(
            in: SourceTree.productionRootURLs, allowed: Set(Self.kindEqualityAllowed.keys))
        XCTAssertEqual(offenders, [],
            "equality on a ProjectType or DocumentFormat case — ask `holdsPieces`, "
            + "`primaryFormat.isScreenplay` or a `DocumentFormat` property, or switch "
            + "exhaustively:\n" + offenders.joined(separator: "\n"))
    }

    /// The control: every code spelling is caught — leading-dot, qualified,
    /// reversed, an optional pattern, an extension against a format's
    /// `fileExtension` either way round, a kind's raw value — while a
    /// word-bounded lookalike (`.fountainBoneyard`, `.collectionPiece`), a
    /// comment and a bare `.fileExtension ==` (an op-log segment's) are not.
    func test_theKindEqualityCensusFiresOnPlantedOffenders() throws {
        let dir = TestTemp.root
            .appendingPathComponent("kind-equality-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        let a = store.manifest.type == .collection
        let b = projectType != .screenplay
        if case .novel = type {}
        let d = format == .fountain
        let e = task.kind == .fountainBoneyard
        // type == .screenplay
        let g = type == ProjectType.screenplay
        let h = format != DocumentFormat.fountain
        let i = .screenplay == store.manifest.type
        let j = DocumentFormat.markdown != format
        if case .collection? = maybeType {}
        let k = url.pathExtension == DocumentFormat.fountain.fileExtension
        let l = DocumentFormat.fountain.fileExtension == ext
        let m = type.rawValue == "screenplay"
        let n = segment.fileExtension == ext
        let o = item.collectionPiece == other
        """.write(to: dir.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)

        let offenders = try kindEqualityOffenders(
            in: [dir], allowed: Set(Self.kindEqualityAllowed.keys))
        XCTAssertEqual(offenders.map { SourceTree.Hit(offender: $0)?.line },
                       [1, 2, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14],
                       "exactly the twelve code spellings:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - A project's kind is named in ProjectKindName only (report plan 4, Task 6)

    /// A kind named anywhere but `ProjectKindName` (R-4-8), in the two
    /// spellings a second namer takes: a string literal that IS a kind name
    /// (`"Novel"`, `"Short Story"`, `"Screenplay"`, `"Collection"`,
    /// `"Report"`), and a type's raw value projected as if it were one
    /// (`type.rawValue`, `projectType.rawValue`, `ProjectType.x.rawValue`).
    /// Whole literals only, so help copy that merely contains the word ("a
    /// novel in chapters") and lookalikes (`"Novella"`, `"Reports"`) pass;
    /// word-bounded, so `subtype.rawValue` and `kind.rawValue` pass.
    static let kindNamePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: [
            #"(?<![\w\\])"(Short Story|Novel|Screenplay|Collection|Report)""#,
            #"\b(type|projectType)\.rawValue\b"#,
            #"\bProjectType\.\w+\.rawValue\b"#,
        ].joined(separator: "|"))
    }()

    /// Where a kind name or a type's raw value may be spelled: the one home.
    /// Any other exception is a single LINE carrying `kindNameLineMarker`
    /// and its reason, never a `type:` key, which would exempt a whole
    /// declaration and every kind name later written inside it.
    static let kindNameAllowed: [String: String] = [
        "type:ProjectKindName": "the one home (R-4-8): \"Report\" for a Report, else the type's name",
    ]

    /// The per-line exception: a trailing `// kind-name-ok: <reason>`. Today
    /// it marks the two MCP wire lines that emit the raw `type` (the stable
    /// structure id beside `kind`) and PieceInspector's format label
    /// ("Screenplay" names a FORMAT, not a project's kind). A marker with
    /// no reason does not count.
    static let kindNameLineMarker = try! NSRegularExpression(pattern: #"//\s*kind-name-ok:\s*\S"#)

    private func kindNameOffenders(in roots: [URL], allowed: Set<String>) throws -> [String] {
        try grepSwift(
            in: roots, patterns: [], allowed: allowed,
            excludeLine: { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    || Self.kindNameLineMarker.firstMatch(
                        in: line, range: NSRange(line.startIndex..., in: line)) != nil
            },
            extraOffender: { line in
                Self.kindNamePattern.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)) != nil
            })
    }

    /// **A project's kind is named by `ProjectKindName` only** (R-4-8). New
    /// Project, the MCP tools and Project Settings ask it, so a Report says
    /// "Report" everywhere; a kind spelled anywhere else is a second namer
    /// that a Report (a profile, not a type) silently gets wrong. Mac, phone
    /// and Core are scanned.
    func test_kindNamesAreSpelledInProjectKindNameOnly() throws {
        let offenders = try kindNameOffenders(
            in: SourceTree.productionRootURLs, allowed: Set(Self.kindNameAllowed.keys))
        XCTAssertEqual(offenders, [],
            "a project's kind named outside ProjectKindName — ask `ProjectKindName.of(manifest)` "
            + "(or `.of(type)` for a choice that is not yet a project):\n" + offenders.joined(separator: "\n"))
    }

    /// The control: each literal kind name and each raw-value projection is
    /// caught, while a comment, help copy containing the word, lookalikes
    /// and other types' raw values are not; a line marked `kind-name-ok:`
    /// with a reason passes while its unmarked twin and a reasonless marker
    /// fail; declared inside `ProjectKindName` every spelling passes.
    func test_theKindNameCensusFiresOnPlantedOffenders() throws {
        let dir = TestTemp.root
            .appendingPathComponent("kind-name-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let planted = dir.appendingPathComponent("Planted.swift")
        try #"""
        let a = Text("Novel")
        let b = "Short Story"
        let c = Section("Screenplay") {}
        func d() -> String { return "Collection" }
        let e = Button("Report") {}
        let f = manifest.type.rawValue
        let g = projectType.rawValue
        let h = ProjectType.novel.rawValue
        // "Novel"
        let i = "A novel in chapters, with a Novel binder"
        let j = "Novella"
        let k = "Reports"
        let l = item.kind.rawValue
        let m = subtype.rawValue
        let n = "\(count) Screenplay pages"
        case .fountain: return "Screenplay"  // kind-name-ok: a format label
        case .fountain: return "Screenplay"
        let o = m.type.rawValue  // kind-name-ok:
        """#.write(to: planted, atomically: true, encoding: .utf8)

        let bare = try kindNameOffenders(in: [dir], allowed: [])
        XCTAssertEqual(bare.map { SourceTree.Hit(offender: $0)?.line }, [1, 2, 3, 4, 5, 6, 7, 8, 17, 18],
                       "the eight spellings, the unmarked twin and the reasonless marker; "
                       + "not the marked line:\n" + bare.joined(separator: "\n"))

        try Self.declare("ProjectKindName", in: planted)
        let allowed = try kindNameOffenders(in: [dir], allowed: Set(Self.kindNameAllowed.keys))
        XCTAssertEqual(allowed, [], "inside ProjectKindName every spelling passes:\n"
                       + allowed.joined(separator: "\n"))
    }
}

// MARK: - Every spawned process is a named one; every `claude` spawn is sealed

/// **Every production process launch lives in a named file with a count, and
/// the files that launch `claude` pass `--tools ""`.**
///
/// `--tools ""` is what seals a spawned `claude` off from the writer's disk:
/// without it the built-in Read/Glob/Grep reach any file in the working
/// directory, whatever `--allowedTools` says (ADR 0028 §2). The two spawners'
/// argument lists are pinned by their own tests
/// (`ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike`,
/// `DeclaredWorldDeriverTests`). This census closes the gap those tests
/// cannot see: a THIRD place that starts a process. A new launch anywhere in
/// `Maugham/` fails here until it is added to `processLaunchers`; a new
/// `claude` launcher also goes in `claudeLaunchers`, gets an argument-list
/// test of its own, and joins `AgentRoster` (Compiler guide).
extension TripwireGrepTests {
    /// File → number of launch lines. Counts, not just files, so a second
    /// launch inside a listed file is a decision someone makes here.
    static let processLaunchers: [String: Int] = [
        "ClaudeCLISession.swift": 2,     // the warm session + the login-shell `which claude` probe
        "DeclaredWorldDeriver.swift": 1, // the one-shot derivation call
        "UpdateInstaller.swift": 3,      // bash/python3 probes and the relaunch
        "EPUBZipPackager.swift": 1,      // /usr/bin/zip
        "TectonicInvoker.swift": 1,      // tectonic
    ]

    /// The listed files that launch `claude` itself.
    static let claudeLaunchers: Set<String> = [
        "ClaudeCLISession.swift", "DeclaredWorldDeriver.swift",
    ]

    static let processLaunchPatterns = ["Process()", "Process.run(", "NSTask", "posix_spawn"]

    private func processLaunchHits(in dir: URL) throws -> [String: Int] {
        let hits = try grepSwift(
            in: dir, patterns: Self.processLaunchPatterns,
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        var counts: [String: Int] = [:]
        for hit in hits {
            if let file = hit.split(separator: ":").first { counts[String(file), default: 0] += 1 }
        }
        return counts
    }

    func test_everyProcessLaunchIsNamedAndEveryClaudeLaunchIsSealed() throws {
        XCTAssertEqual(
            try processLaunchHits(in: sourceDir), Self.processLaunchers,
            "a process launch was added, moved or removed. Update "
            + "`processLaunchers`; if it starts `claude`, add it to "
            + "`claudeLaunchers`, pass `--tools \"\"`, and pin its argv in a test.")
        XCTAssertTrue(Self.claudeLaunchers.isSubset(of: Self.processLaunchers.keys))

        let fm = FileManager.default
        for file in Self.claudeLaunchers {
            guard let url = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == file }) else {
                XCTFail("\(file) is listed as a claude launcher but was not found"); continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("\"--tools\", \"\""),
                          "\(file) launches claude without `--tools \"\"`")
        }
    }

    // MARK: - Manifest bytes for disk come from one function (schema 10)

    /// The spellings that turn a value into JSON bytes. `makeEncoder()` is
    /// flagged in EVERY production file; the other two only in a file that
    /// names `ProjectManifest`, the only files that could be encoding one.
    static let manifestEncoderSpellings = ["makeEncoder()", "JSONEncoder()", ".encode("]

    /// Files that may spell an encoder, each with its reason. `lines: nil`
    /// allows the whole file; otherwise only those exact (trimmed) lines, so a
    /// file that writes the manifest through the door elsewhere still trips
    /// on a new raw encode.
    static let manifestEncoderAllowed: [String: (reason: String, lines: Set<String>?)] = [
        "ProjectManifest.swift": ("defines makeEncoder() and encodeForDisk, the one door", nil),
        // Link files, session logs, UI state and trash metadata, beside
        // manifest writes that go through the door.
        "ProjectStore+CollectionPieces.swift": ("the piece's .maugham-link.json encoder", [
            "let encoder = JSONEncoder()",
            "let linkData = try encoder.encode(linkFile)",
            "try encoder.encode(linkFile).write(to: linkURL, options: .atomic)",
        ]),
        "ProjectStore+References.swift": ("a reference piece's .maugham-link.json encoder", [
            "let encoder = JSONEncoder()",
            "try encoder.encode(linkFile).write(to: linkURL, options: .atomic)",
        ]),
        "DocumentStore.swift": ("the sessions log and ui-state.json, never the manifest", [
            "let encoder = JSONEncoder()",
            "let data = try encoder.encode(next)",
            "let data = try JSONEncoder().encode(state)",
        ]),
        "ProjectStore+Structure.swift": ("a trashed structure item's metadata", [
            "let metadata = try JSONEncoder().encode(item)",
        ]),
        // MCP projections: response DTOs built FROM the manifest, never written to it.
        "ProjectTools.swift": ("MCP project/metadata/outline projections", nil),
        "FirstReaderTools.swift": ("MCP first-reader response", nil),
        "TestProjectTools.swift": ("MCP test-tool response", nil),
        // Codable `encode(to:)` bodies: container writes, not bytes.
        "UIState.swift": ("UIState.encode(to:) containers", nil),
        "ActivePassMemory.swift": ("ActivePassMemory.encode(to:) container", nil),
        "ProjectProfile.swift": ("ProjectProfile.encode(to:) single-value container",
                                 ["try c.encode(rawValue)"]),
        "ResearchItem.swift": ("ResearchRole.encode(to:) single-value container",
                               ["try container.encode(rawValue)"]),
        "ProductionRole.swift": ("ProductionRole.Role.encode(to:) container",
                                 ["try container.encode(rawValue)"]),
        "Statement.swift": ("Statement kinds' encode(to:) containers",
                            ["try container.encode(rawValue)"]),
        // The phone's recents store: dates and ids, keyed by manifest id.
        "RecentsTracker.swift": ("phone recents (captured/opened dates)", nil),
    ]

    /// Every production root: the Mac app, the phone, and Core's sources.
    private var manifestEncodeRoots: [URL] {
        [sourceDir,
         repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true),
         repoRoot.appendingPathComponent("Packages/MaughamCore/Sources", isDirectory: true)]
    }

    private func manifestEncoderOffenders(in roots: [URL]) throws -> [String] {
        var offenders: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let name = url.lastPathComponent
                let allowance = Self.manifestEncoderAllowed[name]
                if let allowance, allowance.lines == nil { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let namesManifest = text.contains("ProjectManifest")
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    let hit = trimmed.contains("makeEncoder()")
                        || (namesManifest && Self.manifestEncoderSpellings.contains { trimmed.contains($0) })
                    guard hit else { continue }
                    if let lines = allowance?.lines, lines.contains(trimmed) { continue }
                    offenders.append("\(name):\(i + 1): \(trimmed)")
                }
            }
        }
        return offenders
    }

    /// **A manifest reaches disk through `ProjectManifest.encodeForDisk` only.**
    ///
    /// That door raises `schemaVersion` to `contentSchemaFloor`: a manifest
    /// carrying a profile, switches or a citation is written at 10, so an
    /// older build refuses it rather than re-saving it without them (Codable
    /// drops unknown keys). A second spelling of an encoder in a file that
    /// handles manifests is a write site that may skip the floor — the old
    /// build then opens the book and silently strips the writer's report
    /// settings and citations.
    func test_manifestBytesForDiskComeFromOneFunction() throws {
        let offenders = try manifestEncoderOffenders(in: manifestEncodeRoots)
        XCTAssertTrue(offenders.isEmpty,
            "A production file that names ProjectManifest encodes JSON outside "
            + "`ProjectManifest.encodeForDisk`, which may skip the schema-10 content floor. "
            + "Route a manifest through `encodeForDisk`; for bytes that are provably not a "
            + "manifest, allow-list the file (or the exact line) in `manifestEncoderAllowed` "
            + "with a reason. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL: every spelling is caught in a file naming ProjectManifest, a
    /// comment is not, a file that never names it is not caught for
    /// `JSONEncoder()`, a whole-file allowance passes, and a line allowance
    /// admits only its own lines.
    func test_theManifestEncoderCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-manifest-encode-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let text = """
        // A comment may name ProjectManifest.makeEncoder() and JSONEncoder().encode(manifest).
        let a = try ProjectManifest.makeEncoder().encode(manifest)
        let e = ProjectManifest.makeEncoder()
        let b = try JSONEncoder().encode(manifest)
        let c = try encoder.encode(manifest)
        """
        try text.write(to: tmp.appendingPathComponent("SecondDoor.swift"), atomically: true, encoding: .utf8)
        try "let d = try JSONEncoder().encode(somethingElse)\n"
            .write(to: tmp.appendingPathComponent("Unrelated.swift"), atomically: true, encoding: .utf8)
        let offenders = try manifestEncoderOffenders(in: [tmp])
        XCTAssertEqual(offenders.count, 4, offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.allSatisfy { $0.hasPrefix("SecondDoor.swift:") }, offenders.description)
        try fm.removeItem(at: tmp.appendingPathComponent("SecondDoor.swift"))

        // The whole-file allowance.
        try text.write(to: tmp.appendingPathComponent("ProjectManifest.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try manifestEncoderOffenders(in: [tmp]), [])
        try fm.removeItem(at: tmp.appendingPathComponent("ProjectManifest.swift"))

        // A line allowance admits its own line and nothing else.
        try """
        // ProjectManifest
        let data = try JSONEncoder().encode(state)
        let raw = try JSONEncoder().encode(manifest)
        """.write(to: tmp.appendingPathComponent("DocumentStore.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try manifestEncoderOffenders(in: [tmp]),
                       ["DocumentStore.swift:3: let raw = try JSONEncoder().encode(manifest)"])
    }

    /// CONTROL: the census sees a planted launch in each spelling, and not a
    /// comment that names one.
    func test_theProcessLaunchCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-spawn-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try """
        // A comment naming Process() is not a launch.
        func a() { let p = Process(); p.arguments = ["-p"] }
        func b() throws { try Process.run(url, arguments: []) }
        """.write(to: tmp.appendingPathComponent("Rogue.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try processLaunchHits(in: tmp), ["Rogue.swift": 2])
    }

    // MARK: - A synced path reaches the disk only through SafeRelativePath (tripwire 58)

    /// The checkers themselves: a type whose job is to decide whether a path
    /// stays inside its folder joins the path to look at it. `PublishPath`
    /// keeps its own rule for MCP input (report plan 6b Task 1 ruling), and
    /// `PublishConfigValidator` checks the publish config's paths on disk.
    static let syncedPathCheckers: Set<String> = [
        "type:SafeRelativePath", "type:PublishPath", "type:PublishConfigValidator",
    ]

    /// The identifiers in a join's argument, with string-literal text dropped
    /// and interpolations kept.
    static func identifiers(inJoinArgument argument: String) -> [String] {
        var code = ""
        var index = argument.startIndex
        var inString = false
        while index < argument.endIndex {
            let ch = argument[index]
            if inString {
                if ch == "\\" {
                    let next = argument.index(after: index)
                    if next < argument.endIndex, argument[next] == "(" {
                        // An interpolation: its code is kept.
                        var depth = 1
                        var cursor = argument.index(after: next)
                        code.append(" ")
                        while cursor < argument.endIndex, depth > 0 {
                            let c = argument[cursor]
                            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                            if depth > 0 { code.append(c) }
                            cursor = argument.index(after: cursor)
                        }
                        code.append(" ")
                        index = cursor
                        continue
                    }
                    index = next < argument.endIndex ? argument.index(after: next) : next
                    continue
                }
                if ch == "\"" { inString = false; code.append(" ") }
                index = argument.index(after: index)
                continue
            }
            if ch == "\"" { inString = true } else { code.append(ch) }
            index = argument.index(after: index)
        }
        var names: [String] = []
        var current = ""
        func flush() {
            if let first = current.first, first.isLetter || first == "_" { names.append(current) }
            current = ""
        }
        for ch in code {
            if ch.isLetter || ch.isNumber || ch == "_" { current.append(ch) } else { flush() }
        }
        flush()
        return names
    }

    /// **The names a synced path goes by**: an identifier ending in
    /// `path`/`Path`, `rel`/`Rel`, `filename`/`Filename` or `Id`/`ID`, or
    /// `relative` or `id` — never `UUID`, which is minted where it is read.
    /// That covers the synced fields — `.path`, `.filename`, `.relativePath`,
    /// `docId`, `sourceFilename`, `originalRelativePath`, `parkedPath`, a
    /// trash or export id — and the locals that carry them (`oldPath`,
    /// `parentPath`, `noteRelPath`, `trashId`, …).
    static func syncedPathNames(inJoinArgument argument: String) -> [String] {
        let suffixes = ["path", "Path", "rel", "Rel", "filename", "Filename", "Id", "ID"]
        return identifiers(inJoinArgument: argument).filter { name in
            name != "UUID"
                && (name == "relative" || name == "id" || suffixes.contains(where: { name.hasSuffix($0) }))
        }
    }

    /// **Whether a line has gone through the checker, or says why it need
    /// not**: `SafeRelativePath`, or the store's helper built on it
    /// (`resolvedProjectPath…`), in its CODE — a comment that names them does
    /// not count — or a `// local-path: <why>` comment with a reason after it.
    static func syncedPathLineIsChecked(_ line: String) -> Bool {
        let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        if code.contains("SafeRelativePath") || code.contains("resolvedProjectPath") { return true }
        return line.range(of: #"//.*local-path:\s*\S"#, options: .regularExpression) != nil
    }

    /// The nearest `let`/`var` of `name` at most 60 lines above `index`:
    /// its index, its line and the text after its `=`, or nil.
    static func syncedPathDefinition(
        of name: String, in lines: [String], before index: Int
    ) -> (index: Int, line: String, rhs: String)? {
        guard let definition = try? NSRegularExpression(
            pattern: #"\b(?:let|var)\s+"# + NSRegularExpression.escapedPattern(for: name)
                + #"\b\s*(?::[^=]*)?=\s*(.*)$"#) else { return nil }
        for j in stride(from: index - 1, through: max(0, index - 60), by: -1) {
            let line = lines[j]
            let range = NSRange(line.startIndex..., in: line)
            guard let match = definition.firstMatch(in: line, range: range),
                  let rhs = Range(match.range(at: 1), in: line) else { continue }
            return (j, line, String(line[rhs]))
        }
        return nil
    }

    /// The synced path names an argument reaches: its own — less a name
    /// whose nearest definition went through the checker (a checked value,
    /// `let fileId = try SafeRelativePath.requireDocId(docId)`) — or, up to
    /// `hops` definitions back, those of a local it reads
    /// (`let base = "\(stem)-\(docId)"` then `appendingPathComponent(base)`),
    /// looking at most 60 lines up. A checked definition ends the walk.
    static func syncedPathNames(
        inJoinArgument argument: String, lines: [String], before index: Int,
        hops: Int, seen: inout Set<String>
    ) -> [String] {
        let direct = syncedPathNames(inJoinArgument: argument).filter { name in
            guard let found = syncedPathDefinition(of: name, in: lines, before: index) else { return true }
            return !syncedPathLineIsChecked(found.line)
        }
        guard direct.isEmpty, hops > 0 else { return direct }
        for name in identifiers(inJoinArgument: argument) where seen.insert(name).inserted {
            guard let found = syncedPathDefinition(of: name, in: lines, before: index) else { continue }
            if syncedPathLineIsChecked(found.line) { continue }
            let names = syncedPathNames(
                inJoinArgument: found.rhs, lines: lines, before: found.index,
                hops: hops - 1, seen: &seen)
            if !names.isEmpty { return names }
        }
        return []
    }

    /// The text of the call's argument list from `start` (just past the open
    /// parenthesis) to its matching close, or to the end of the line.
    static func joinArgument(in line: String, from start: String.Index) -> String {
        var depth = 1
        var cursor = start
        while cursor < line.endIndex {
            let c = line[cursor]
            if c == "(" { depth += 1 } else if c == ")" {
                depth -= 1
                if depth == 0 { return String(line[start..<cursor]) }
            }
            cursor = line.index(after: cursor)
        }
        return String(line[start...])
    }

    /// Every `appendingPathComponent(` / `appending(path:` in `text` whose
    /// argument reaches a synced path name (`syncedPathNames`, following
    /// locals) and whose line neither goes through the checker nor carries a
    /// `// local-path:` reason (`syncedPathLineIsChecked`). A call whose
    /// argument starts on the next line is read from there, and either line
    /// may carry the checker or the reason. Comment lines are prose. Returns
    /// `(1-based line, trimmed text)`.
    static func syncedPathJoins(in text: String) -> [(line: Int, text: String)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hits: [(line: Int, text: String)] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            var searchFrom = line.startIndex
            var offends = false
            while let range = ["appendingPathComponent(", "appending(path:"]
                .compactMap({ line.range(of: $0, range: searchFrom..<line.endIndex) })
                .min(by: { $0.lowerBound < $1.lowerBound }) {
                searchFrom = range.upperBound
                var argument = joinArgument(in: line, from: range.upperBound)
                var context = line
                if argument.trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count {
                    let next = lines[i + 1]
                    argument = joinArgument(in: next, from: next.startIndex)
                    context += "\n" + next
                }
                var seen: Set<String> = []
                if !context.split(separator: "\n").contains(where: { Self.syncedPathLineIsChecked(String($0)) }),
                   !syncedPathNames(inJoinArgument: argument, lines: lines, before: i,
                                    hops: 3, seen: &seen).isEmpty {
                    offends = true
                }
            }
            if offends { hits.append((i + 1, trimmed)) }
        }
        return hits
    }

    /// `syncedPathJoins` over every Swift file under `roots`, as
    /// `"<basename>:<line>: <text>"`, less the lines inside a checker's own
    /// declaration (`allowed`, type keys resolved across all the roots).
    private func syncedPathJoinOffenders(
        in roots: [URL], allowed: Set<String> = TripwireGrepTests.syncedPathCheckers
    ) throws -> [String] {
        let (allowance, unresolved) = SourceTree.expandingTypeKeys(allowed, in: roots)
        var offenders = unresolved
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for hit in Self.syncedPathJoins(in: text)
                where !allowance.allows(file: url.lastPathComponent, line: hit.line) {
                    offenders.append("\(url.lastPathComponent):\(hit.line): \(hit.text)")
                }
            }
        }
        return offenders
    }

    /// Recurrence-tripper (report plan 6b Task 2; R-D3): a path or file name
    /// that came from synced data — a manifest row, an op payload, a registry
    /// or trash record, a sidecar, an inbox entry — is joined onto a folder
    /// only through `SafeRelativePath` (`resolve`, `resolveFile`,
    /// `requireDocId`, `isPlainFileName`, or a helper built on one such as
    /// `ProjectStore.resolvedProjectPath`). A raw join let `../outside.md`
    /// in a manifest, or a picture name in an op, write outside the project
    /// (570d724a). The population is derived (`syncedPathJoins`); a name that
    /// is minted locally says so on its line with `// local-path: <why>`.
    func test_syncedPathsReachTheDiskOnlyThroughSafeRelativePath() throws {
        let offenders = try syncedPathJoinOffenders(in: admissionRoots)
        XCTAssertTrue(offenders.isEmpty,
            "A synced path is joined onto a folder without SafeRelativePath (tripwire 58). "
            + "Resolve it through SafeRelativePath (or ProjectStore.resolvedProjectPath) "
            + "before any read, write, move or delete; if the name is minted locally, say "
            + "so on the line with `// local-path: <why>`. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL: a planted file's raw joins of a synced path fire — a field,
    /// an interpolated doc id, a local, a call whose argument is on the next
    /// line, a local built from a doc id, a synced id, a line that names the
    /// checker only in a comment, and a `// local-path:` with no reason —
    /// while a checked line, a marked local name, a constant, a `.path` read
    /// after the call, a comment, a value the checker returned, a `UUID` and a
    /// checker's own declaration do not.
    func test_syncedPathCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-synced-path-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try #"""
        extension Rogue {
            func f() throws {
                let a = url.appendingPathComponent(item.path)
                let b = dir.appendingPathComponent("\(docId).json")
                let c = url.appendingPathComponent(
                    oldRelPath)
                let d = try SafeRelativePath.resolve(item.path, under: url)
                let e = folder.appendingPathComponent(filename) // local-path: minted from the title
                let g = url.appendingPathComponent("research", isDirectory: true)
                let h = FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
                // url.appendingPathComponent(item.path) in prose
                let i = dir.appendingPathComponent("\(try SafeRelativePath.requireDocId(docId)).json")
                let base = "\(stem)-\(docId)-x"
                let j = dir.appendingPathComponent(base)
                let checked = try SafeRelativePath.requireDocId(docId)
                let k = dir.appendingPathComponent("\(checked).json")
                let l = trashRoot.appendingPathComponent(trashId) // SafeRelativePath checked it above
                let m = dir.appendingPathComponent(filename) // local-path:
                let n = trashRoot.appendingPathComponent(UUID().uuidString)
            }
        }
        enum PublishPath {
            static func check(_ relativePath: String) { _ = root.appendingPathComponent(relativePath) }
        }
        """#.write(to: tmp.appendingPathComponent("Rogue.swift"), atomically: true, encoding: .utf8)

        let offenders = Self.dropping(
            unplanted: ["type:SafeRelativePath", "type:PublishConfigValidator"],
            from: try syncedPathJoinOffenders(in: [tmp]))
        XCTAssertEqual(offenders, [
            "Rogue.swift:3: let a = url.appendingPathComponent(item.path)",
            #"Rogue.swift:4: let b = dir.appendingPathComponent("\(docId).json")"#,
            "Rogue.swift:5: let c = url.appendingPathComponent(",
            "Rogue.swift:14: let j = dir.appendingPathComponent(base)",
            "Rogue.swift:17: let l = trashRoot.appendingPathComponent(trashId) // SafeRelativePath checked it above",
            "Rogue.swift:18: let m = dir.appendingPathComponent(filename) // local-path:",
        ])
    }

    // MARK: - A change takes the change form of the checker (tripwire 58, review round 2)

    /// The file calls that CHANGE a path, and the argument labels that name
    /// what they change (`_` for an unlabeled first argument). A copy's or a
    /// move's SOURCE read is not a change, except a move's.
    static let syncedPathChangeCalls: [(spelling: String, changes: Set<String>)] = [
        ("write(", ["to"]), ("moveItem(", ["at", "to"]), ("copyItem(", ["to"]),
        ("removeItem(", ["at"]), ("trashItem(", ["at"]), ("replaceItemAt(", ["_"]),
        ("createFile(", ["atPath"]), ("createDirectory(", ["at", "atPath"]),
        ("coordinatedWrite(", ["to"]), ("coordinatedMove(", ["from", "to"]),
        ("executeCopy(", ["to"]), ("replaceFigureImage(", ["at"]),
    ]

    /// The READ form of the checker in a line's code: `SafeRelativePath.resolve(`
    /// or a `resolvedProjectPath(` helper — lexical, so a folder linked out of
    /// the project passes it. (`resolveForChange(`, `resolveFile(` and
    /// `resolvedProjectPathToChange(` are the change forms and do not match.)
    static func namesTheReadFormOfTheChecker(_ line: String) -> Bool {
        let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        return code.contains("SafeRelativePath.resolve(") || code.contains("resolvedProjectPath(")
    }

    /// A call's top-level arguments from just past its `(`: each label (`_`
    /// for the unlabeled first, `?` for a later unlabeled one) and its text.
    static func callArguments(in text: String, from start: String.Index) -> [(label: String, text: String)] {
        var depth = 1
        var parts: [String] = []
        var current = ""
        var cursor = start
        while cursor < text.endIndex {
            let c = text[cursor]
            if "([{".contains(c) { depth += 1 }
            if ")]}".contains(c) { depth -= 1; if depth == 0 { break } }
            if c == ",", depth == 1 { parts.append(current); current = "" } else { current.append(c) }
            cursor = text.index(after: cursor)
        }
        parts.append(current)
        return parts.enumerated().map { index, part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let colon = trimmed.firstIndex(of: ":"),
               trimmed[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
               !trimmed[..<colon].isEmpty,
               trimmed[trimmed.index(after: colon)...].first != ":" {
                return (String(trimmed[..<colon]), String(trimmed[trimmed.index(after: colon)...]))
            }
            return (index == 0 ? "_" : "?", trimmed)
        }
    }

    /// Every change call in `text` whose changed argument reaches the checker's
    /// READ form — inline, or through a local whose nearest definition (60
    /// lines up) calls it. Comment lines are prose; a call's arguments are read
    /// across up to four more lines. Returns `(1-based line, trimmed text)`.
    static func readFormAtAChange(in text: String) -> [(line: Int, text: String)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func code(_ line: String) -> String {
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }
        var hits: [(line: Int, text: String)] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            let lineCode = code(line)
            let joined = lines[i..<min(lines.count, i + 5)].map(code).joined(separator: "\n")
            var offends = false
            for call in syncedPathChangeCalls {
                var from = lineCode.startIndex
                while let range = lineCode.range(of: call.spelling, range: from..<lineCode.endIndex) {
                    from = range.upperBound
                    if call.spelling == "write(", range.lowerBound > lineCode.startIndex,
                       lineCode[lineCode.index(before: range.lowerBound)].isLetter { continue }
                    let offset = lineCode.distance(from: lineCode.startIndex, to: range.upperBound)
                    let start = joined.index(joined.startIndex, offsetBy: offset)
                    for argument in callArguments(in: joined, from: start)
                    where call.changes.contains(argument.label) {
                        if namesTheReadFormOfTheChecker(argument.text) { offends = true; continue }
                        for name in identifiers(inJoinArgument: argument.text) {
                            if let found = syncedPathDefinition(of: name, in: lines, before: i),
                               namesTheReadFormOfTheChecker(found.line) { offends = true }
                        }
                    }
                }
            }
            if offends { hits.append((i + 1, trimmed)) }
        }
        return hits
    }

    private func readFormAtAChangeOffenders(in roots: [URL]) throws -> [String] {
        var offenders: [String] = []
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for hit in Self.readFormAtAChange(in: text) {
                    offenders.append("\(url.lastPathComponent):\(hit.line): \(hit.text)")
                }
            }
        }
        return offenders
    }

    /// Recurrence-tripper (report plan 6b Task 2, review round 2): a write,
    /// copy destination, move, delete or directory creation takes its URL from
    /// the checker's CHANGE form (`resolveForChange`, `resolveFile`,
    /// `resolvedProjectPathToChange`), never from the lexical read form, which
    /// lets a write through a folder linked out of the project. The `Document`
    /// render and `Bootstrap` write to a URL handed in whole (lexical by ruling,
    /// so a linked chapter opens and saves) and are not a join this reads.
    func test_aChangeTakesTheChangeFormOfTheChecker() throws {
        let offenders = try readFormAtAChangeOffenders(in: admissionRoots)
        XCTAssertTrue(offenders.isEmpty,
            "A write, move, copy destination or delete takes its URL from the checker's "
            + "READ form (SafeRelativePath.resolve / resolvedProjectPath), which a folder "
            + "linked out of the project passes (tripwire 58). Use resolveForChange / "
            + "resolvedProjectPathToChange. Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// CONTROL: a write, a move and a directory creation fed by the read form
    /// fire, inline and through a local; a copy whose SOURCE is a read, the
    /// change form, and a read of a read-form URL do not.
    func test_theChangeFormCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = TestTemp.root
            .appendingPathComponent("tripwire-change-form-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try #"""
        func f() throws {
            let note = try store.resolvedProjectPath(path)
            try text.write(to: note, atomically: true, encoding: .utf8)
            try fm.moveItem(at: try SafeRelativePath.resolve(old, under: root),
                            to: newURL)
            try fm.createDirectory(at: try store.resolvedProjectPath(folder), withIntermediateDirectories: true)
            let source = try store.resolvedProjectPath(src)
            let dest = try store.resolvedProjectPathToChange(dst)
            try fm.copyItem(at: source, to: dest)
            let body = try String(contentsOf: note, encoding: .utf8)
            try body.write(to: try store.resolvedProjectPathToChange(path), atomically: true, encoding: .utf8)
        }
        """#.write(to: tmp.appendingPathComponent("Rogue.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try readFormAtAChangeOffenders(in: [tmp]), [
            "Rogue.swift:3: try text.write(to: note, atomically: true, encoding: .utf8)",
            "Rogue.swift:4: try fm.moveItem(at: try SafeRelativePath.resolve(old, under: root),",
            "Rogue.swift:6: try fm.createDirectory(at: try store.resolvedProjectPath(folder), withIntermediateDirectories: true)",
        ])
    }
}
