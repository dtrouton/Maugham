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

    /// Self-check: prove the palette-write tripwire FIRES on a planted raw
    /// write, and that the funnel's own marked fallback write is excluded.
    func test_paletteWriteTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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

    // MARK: - Dev-only TestMCPToolCatalog registration tripwire

    /// Repo root, computed the same way `sourceDir` does (2x
    /// `deletingLastPathComponent()` off this file's `#filePath`), but without
    /// appending `Maugham/` — used to reach `Maugham/MaughamApp.swift` itself.
    private var repoRoot: URL {
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent()
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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

    /// How many lines after a `ContentUnavailableView(` opener the required
    /// `.frame(maxWidth: .infinity` must appear. Measured against the actual
    /// codebase (2026-07-11): the shortest single-line calls chain the frame
    /// on the very next line (distance 1); the longest multi-line calls —
    /// title + systemImage + description args each on their own line, then
    /// the closing paren, then `.frame(...)` — land at distance 4
    /// (e.g. DetailPaneToggle.swift, InboxPane.swift, HistoryPane.swift all
    /// legitimately sit at 4). A 3-line window would false-positive on those
    /// real, correct call sites, so the window is 4 — still crisp enough to
    /// catch a genuinely frameless CUV (tripwire 15: recurred 4+ times
    /// because `ContentUnavailableView` sizes to intrinsic content and an
    /// unframed one lets the enclosing pane's toolbar float to window center).
    private static let contentUnavailableViewFrameWindow = 4

    /// Recurrence-tripper: every `ContentUnavailableView(` in Maugham/Views/
    /// must chain `.frame(maxWidth: .infinity` within the next
    /// `contentUnavailableViewFrameWindow` lines. Canonical examples:
    /// HistoryPane, AnnotationsPane, OutlinePane (CLAUDE.md tripwire 15).
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
        let offenders = try Self.findFramelessContentUnavailableViews(in: appDir)
        XCTAssertTrue(offenders.isEmpty,
            "ContentUnavailableView( without a .frame(maxWidth: .infinity within "
            + "\(Self.contentUnavailableViewFrameWindow) lines (tripwire 15). "
            + "SwiftUI sizes ContentUnavailableView to intrinsic content, so an "
            + "unframed one lets the enclosing pane's toolbar float to window "
            + "center — this has recurred 4+ times. Canonical examples: "
            + "HistoryPane, AnnotationsPane, OutlinePane. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Shared scan: walk every `.swift` file in `dir`, and for each
    /// `ContentUnavailableView(` opener, look ahead up to
    /// `contentUnavailableViewFrameWindow` lines for the required frame
    /// chain. SHARED between the production check and the self-test.
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
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            for (i, line) in lines.enumerated() where line.contains("ContentUnavailableView(") {
                let lookahead = lines[i..<min(i + contentUnavailableViewFrameWindow + 1, lines.count)]
                // Comment lines don't count — a comment merely DISCUSSING the
                // frame chain (e.g. explaining why one is missing) must not
                // satisfy the requirement. Caught in dev: an early self-check
                // fixture's own explanatory comment contained the frame
                // substring and silently passed a frameless CUV.
                let hasFrame = lookahead.contains {
                    let trimmed = $0.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") else { return false }
                    return trimmed.contains(".frame(maxWidth: .infinity")
                }
                if !hasFrame {
                    let resolved = url.resolvingSymlinksInPath().path
                    let shown = resolved.hasPrefix(base + "/")
                        ? String(resolved.dropFirst(base.count + 1))
                        : url.lastPathComponent
                    offenders.append("\(shown):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return offenders
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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

    // MARK: - Segmented-picker child uniformity (2026-07-25 smoke, defect C)

    /// A segmented `Picker` whose `ForEach` emits more than one KIND of child
    /// is a shipped-bug shape. The `if let symbol { Image } else { Text }`
    /// spelling makes a `_ConditionalContent` whose branch is cached per
    /// position; the picker updates its `NSSegmentedControl` in place, so the
    /// first list reshape (a persona change) leaves stale branches on the wrong
    /// indices — the binder rendered `Pieces | 🎨Research | 🎨`, and a persona
    /// with no Palette segment showed a palette icon that selected Research.
    ///
    /// Both binder toggles share `BinderSegmentPicker`, and the right pane's
    /// picker has the same shape, so both files are checked: inside the
    /// `ForEach` that feeds a `Picker`, there must be no branch.
    func test_segmentedPickerForEachBodiesHaveNoConditionalChildren() throws {
        for relative in ["Views/BinderSegmentPicker.swift", "Views/DetailPaneToggle.swift"] {
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
    ///     consult `visibleSegments(persona:, hideOutline:)` WITHOUT `including:` —
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
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("tripwire-coercion-swapped-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Plant a synthetic file with the call sites swapped (the bug)
        let planted = tmp.appendingPathComponent("DetailPaneToggle.swift")
        try """
        struct DetailPaneToggle<Inspector: View>: View {
            func snapSegmentIntoPicker() {
                // WRONG: calling with bare list instead of including:
                let snapped = Self.mountSelection(segment, persona: persona, hideOutline: hideOutline)
                if snapped != segment { segment = snapped }
            }

            private func coerceSegmentIntoView(of persona: Persona) {
                // WRONG: calling with including: instead of bare list
                let visible = Self.visibleSegments(persona: persona, hideOutline: hideOutline, including: segment)
                let coerced = Self.snappedSelection(segment, in: visible, fallback: persona.defaultPane)
                if coerced != segment { segment = coerced }
            }

            static func mountSelection(
                _ current: DetailSegment,
                persona: Persona,
                hideOutline: Bool
            ) -> DetailSegment {
                let carrying = visibleSegments(
                    persona: persona, hideOutline: hideOutline, including: current)
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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

    /// The one view that IS the canvas. Everything it does is inside its own
    /// bracket by construction, so it uses the inside verbs.
    private static let theCanvasSurface = "CanvasView.swift"

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
    private static let canvasInsideVerbs = [
        "mutate", "beginGesture", "endGesture", "breakGesture",
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
        var census: [String: [String]] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name != Self.theCanvasSurface,
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
    private static func codeLines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { return nil }
            guard let comment = line.range(of: "//") else { return line }
            return String(line[..<comment.lowerBound])
        }
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
    ///   `CanvasView.deleteSelection`'s `isInGesture` guard. Closing it would
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
    func test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly() throws {
        let census = try canvasBracketCensus(in: sourceDir)
        XCTAssertEqual(
            census,
            ["LineInspector.swift": [Self.canvasOutsideVerb],
             "PromotionPerformer.swift": [Self.canvasOutsideVerb],
             "RegionInspector.swift": [Self.canvasOutsideVerb]],
            "The canvas's undo bracket is reached from outside `CanvasView.swift` "
            + "by the inspector column only, using exactly one verb.\n\n"
            + "If you have ADDED a surface that changes the canvas scene: it must "
            + "use `CanvasModel.mutateFromInspector`, and it belongs in the "
            + "expectation above. `mutate`/`beginGesture`/`endGesture` nest "
            + "inside the \"Edit Scrap\" gesture a focused scrap holds open — "
            + "nothing outside `CanvasView.handleClick` closes it, and a "
            + "double-click never reassigns the selection. Repro: double-click a "
            + "region's CHROME BAR — click 1 selects it, click 2 mints a scrap "
            + "and opens the bracket. NOT a card: AppKit sends clickCount 1 "
            + "first and that click selects the card. Nested, your edit "
            + "registers NO undo step and rides into the writer's next one.\n\n"
            + "From the canvas itself the answer is the opposite — refuse "
            + "mid-gesture (`deleteSelection`'s `isInGesture` guard), because "
            + "closing the bracket would end one the writer still holds.\n\n"
            + "Found:\n\(census)")
    }

    /// The converse, so the two verbs cannot simply be swapped: the canvas
    /// surface uses the inside verbs and never the outside one. Reaching for
    /// `mutateFromInspector` from `CanvasView` would close a bracket the writer
    /// is still inside.
    func test_theCanvasSurfaceItselfUsesTheInsideVerbs() throws {
        let url = sourceDir.appendingPathComponent("Canvas/\(Self.theCanvasSurface)")
        let code = Self.codeLines(of: try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(code.contains { $0.contains(".mutate(") },
            "\(Self.theCanvasSurface) is the canvas's own surface and mutates "
            + "through the inside verb. If this moved, the census above needs to "
            + "know where it moved to.")
        XCTAssertFalse(code.contains { $0.contains(Self.canvasOutsideVerb) },
            "\(Self.theCanvasSurface) must NOT use \(Self.canvasOutsideVerb): "
            + "close-run-reopen from inside the canvas ends a gesture the writer "
            + "is still in the middle of.")
    }

    /// Self-check: prove the census FIRES on a planted offender — a second
    /// column reaching the bracket with the inside verb. A census of a REQUIRED
    /// token is exactly the shape that can pass while blind, so it is measured
    /// rather than assumed.
    func test_canvasUndoBracketCensusFiresOnAPlantedInsideVerb() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
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

        let census = try canvasBracketCensus(in: tmp)
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
}
