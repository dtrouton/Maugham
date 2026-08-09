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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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
    /// never reaches `CanvasView.handleClick`, which is the only caller of
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
            + "`CanvasView.handleClick`, which is the only thing that runs "
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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
    /// - `Maugham/Views/CollectionResearchPane.swift` — the same pairing **twice**
    ///   (`sharedSection`, `pieceSection`); this census only sees the first of
    ///   each token, which is why the swap was made in both.
    /// - `Maugham/Views/ResearchRow.swift` — has always had it right, and is the
    ///   only member whose order was ever validated by use.
    private static let bothDropKinds: Set<String> = [
        "CanvasView.swift",
        "CollectionResearchPane.swift",
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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
    /// - `ProjectStore+Statements.swift:mutateStatementText` — the transient
    ///   writer's arm, which every out-of-band write reaches (a promotion, a
    ///   dropped picture, a ruling). **This was `appendToStatement` until the
    ///   declared world (Task 4) needed a whole-text transform a paragraph
    ///   append cannot express; the append is now one call of it, so the arm
    ///   moved and the gate did not.** `PromotionPerformer` is NOT a taker, and
    ///   neither is `RulingPerformer`: both get here.
    /// - `ProjectStore+StatementAdoption.swift:adopt` — the third opener, safe
    ///   by circumstance before it took the gate and no longer relying on that.
    /// - `ProjectStore+CollectionPieces.swift:promotePieceToProject` — takes the
    ///   gate while opening nothing, because it MOVES the file the gate is over.
    private static let statementOpenGateTakers: Set<String> = [
        "ProjectStore+Statements.swift:lockStatementOpen",
        "ProjectStore+Statements.swift:mutateStatementText",
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
        let tmp = fm.temporaryDirectory
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
    /// payload that pane's own guard rejects was accepted on screen and then
    /// ignored. They are fixed and held here too; a census that covered only the
    /// file the finding arrived in would have left the older instances to be
    /// rediscovered.
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
                     "Views/CollectionResearchPane.swift",
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
        let tmp = fm.temporaryDirectory
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
        "routePieceRowDrop(", "routeResearchRowDrop(", "routeSharedSectionDrop("
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
            ["BinderView.swift": ["routePieceRowDrop("],
             "CollectionPiecesPane.swift": ["routePieceRowDrop("],
             "BinderTreeSections.swift": ["routeResearchRowDrop(",
                                          "routeSharedSectionDrop("],
             "BinderPieceFold.swift": ["routeResearchRowDrop("]],
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
        let tmp = fm.temporaryDirectory
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
        let tmp = fm.temporaryDirectory
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
}
