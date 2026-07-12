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
        let viewsDir = repoRoot.appendingPathComponent("Maugham/Views", isDirectory: true)
        let offenders = try Self.findFramelessContentUnavailableViews(in: viewsDir)
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
    static func findFramelessContentUnavailableViews(in dir: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            for (i, line) in lines.enumerated() where line.contains("ContentUnavailableView(") {
                let lookahead = lines[i..<min(i + contentUnavailableViewFrameWindow + 1, lines.count)]
                let hasFrame = lookahead.contains { $0.contains(".frame(maxWidth: .infinity") }
                if !hasFrame {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return offenders
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
        """.write(to: tmp.appendingPathComponent("SelfCheckPane.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try Self.findFramelessContentUnavailableViews(in: tmp)
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the frameless BadPane to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("Nothing here") == true,
            "Self-check: the planted frameless BadPane offender should be the one caught.")
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
    /// matching either token pattern, and report every one whose characters
    /// aren't a subset of `paragraphIdAlphabet`. SHARED between the
    /// production check and the self-test. `allowed` skips files by
    /// `lastPathComponent` — the production call excludes
    /// `TripwireGrepTests.swift` itself (ADR-0021-tripwire precedent): its
    /// self-check test embeds a planted bad-alphabet literal as literal
    /// source text, which would otherwise self-match this very scan.
    static func scanParagraphIdAlphabetViolations(
        in dirs: [URL], allowed: Set<String> = []
    ) throws -> [String] {
        let regexes = try [paragraphIdAnchorTokenPattern, paragraphIdConstructorTokenPattern]
            .map { try NSRegularExpression(pattern: $0) }
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
    /// three test targets: MaughamTests, MaughamPhoneTests,
    /// Packages/MaughamCore/Tests.
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
    /// anchor literal AND a planted bad-alphabet `ParagraphID("...")`
    /// construction, and does NOT fire on a comment-prose placeholder, a
    /// deliberate `XCTAssertNil`-guarded malformed-rejection literal, or a
    /// valid literal.
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
            func test_rejectsMalformed() {
                XCTAssertNil(ParagraphID.parseComment("<!-- ¶ABCD -->"))
            }
        }
        """.write(to: tmp.appendingPathComponent("PlantedTests.swift"),
                  atomically: true, encoding: .utf8)

        let dirs = [tmp]
        let offenders = try Self.scanParagraphIdAlphabetViolations(in: dirs)
        XCTAssertEqual(offenders.count, 2,
            "Self-check expected exactly the bad anchor and bad constructor "
            + "literals to fire (comment placeholder and XCTAssertNil-guarded "
            + "rejection test excluded). Got:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("[ilou]") && $0.contains("¶ilou") },
            "Self-check: the planted bad anchor literal should be caught.")
        XCTAssertTrue(offenders.contains { $0.contains("[ilou]") && $0.contains("ParagraphID(\"ilou\")") },
            "Self-check: the planted bad ParagraphID(\"...\") construction should be caught.")
        XCTAssertFalse(offenders.contains { $0.contains("a3f9") },
            "Self-check: the valid literal must NOT fire.")
        XCTAssertFalse(offenders.contains { $0.contains("ABCD") },
            "Self-check: the XCTAssertNil-guarded rejection literal must NOT fire.")
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
}
