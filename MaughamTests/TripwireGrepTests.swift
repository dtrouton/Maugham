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
        excludeLine: ((String) -> Bool)? = nil
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
                for pat in patterns where lineStr.contains(pat) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(lineStr.trimmingCharacters(in: .whitespaces))")
                }
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
    /// specific `ProjectStore+*` seams that move user-editable paths.
    private func grepSwift(
        in dir: URL,
        files: Set<String>,
        patterns: [String],
        excludeLine: ((String) -> Bool)? = nil
    ) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard files.contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                if let exclude = excludeLine, exclude(lineStr) { continue }
                for pat in patterns where lineStr.contains(pat) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(lineStr.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return offenders
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
            // stable and dev update from dtrouton/Maugham on GitHub).
            if trimmed.contains("repo:") && trimmed.contains("\"Maugham\"") { return true }
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
               "ProjectStore+Research.swift", "ProjectStore+WikiLink.swift"]
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

    // MARK: - Meta-tests: tripwires fire on planted offenders (task 4.8 / test gap #14)

    /// Self-check: prove the op-log filename tripwire FIRES on a planted
    /// `hasPrefix("d_")` call. Writes a synthetic Swift file into a temp dir
    /// and confirms the grep catches it (guarding against a tripwire that
    /// silently never matches).
    func test_opLogFilenameTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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

        let offenders = try grepSwift(
            in: tmp,
            files: userContentMoverFiles,
            patterns: userContentMoverPatterns,
            excludeLine: { [self] in isInternalMoveLine($0) }
        )
        // The bare oldURL→newURL move fires; the marked internal move is excluded.
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the non-staging move to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("oldURL") == true,
            "Self-check: the planted oldURL→newURL offender should be the one caught.")
    }
}
