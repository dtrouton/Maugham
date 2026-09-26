import XCTest

/// Mirrors the Mac-side tripwire-13 enforcement (CLAUDE.md): no hardcoded
/// `"maugham"` / `"Maugham"` identity-string literals in MaughamPhone sources —
/// all six variant-dependent values route through `BuildVariant`, and the phone
/// bundle-id literals live only in `BuildVariantPhone.swift`.
///
/// iOS can't spawn `grep` (there is no `Process` on iOS), so this scans the
/// source tree in pure Swift via `#filePath`. The simulator shares the host
/// filesystem, so the compile-time absolute path still resolves at runtime —
/// the same trick `EmissionContractTests` uses on the Mac.
final class TripwirePhoneGrepTest: XCTestCase {
    func test_noHardcodedIdentityStringsInPhoneSources() throws {
        // .../MaughamPhoneTests/TripwirePhoneGrepTest.swift → repoRoot/MaughamPhone
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir,
                                         includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(sourceDir.path) — is the source layout intact?")
        }

        // The one sanctioned home for the phone bundle-id literals.
        let allowedFile = "BuildVariantPhone.swift"
        var offenders: [String] = []

        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == allowedFile { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n",
                                            omittingEmptySubsequences: false).enumerated() {
                if line.contains("\"maugham\"") || line.contains("\"Maugham\"") {
                    offenders.append("\(url.lastPathComponent):\(index + 1): "
                                     + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "Hardcoded \"maugham\"/\"Maugham\" identity strings found "
                      + "(route them through BuildVariant):\n"
                      + offenders.joined(separator: "\n"))
    }

    // MARK: - Meta-tests: tripwires fire on planted offenders (task 4.8 / test gap #14)

    /// Self-check: prove the identity-string tripwire FIRES on a planted
    /// `"maugham"` / `"Maugham"` literal. Writes a synthetic Swift file into a
    /// temp dir (not under MaughamPhone/) and confirms the grep catches it.
    func test_identityLiteralTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-identity-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Plant a standalone "Maugham" literal — the kind that should route
        // through BuildVariant.current.displayName, not be hardcoded directly.
        let planted = tmp.appendingPathComponent("BadIdentity.swift")
        try """
        let name = \"Maugham\"  // should be caught — route through BuildVariant
        """.write(to: planted, atomically: true, encoding: .utf8)

        var offenders: [String] = []
        let text = try String(contentsOf: planted, encoding: .utf8)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.contains("\"maugham\"") || line.contains("\"Maugham\"") {
                offenders.append("\(planted.lastPathComponent):\(index + 1): "
                    + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly one identity-literal offender. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("\"Maugham\"") == true,
            "Self-check: the planted \"Maugham\" literal should be caught.")
    }

    /// Mirrors the Mac's `test_noSkipsHiddenFilesInProductionScans`:
    /// `.skipsHiddenFiles` honours the BSD `hidden` FLAG as well as a dot-
    /// prefixed name, and the synced `.maugham/` tree the phone reads gets that
    /// flag set behind Maugham's back (2026-08-27) — an op-log file it reached
    /// would drop out of the cold-launch download. Skip by NAME via
    /// `DotfileScan.isDotfile` (MaughamCore) and nothing else.
    func test_noSkipsHiddenFilesInPhoneScans() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(sourceDir.path)")
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains(".skipsHiddenFiles") {
                    offenders.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "A phone directory scan passes `.skipsHiddenFiles`, which also drops "
            + "files carrying the BSD `hidden` flag. Pass `options: []` and skip by "
            + "name with `DotfileScan.isDotfile`. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the op-log filename tripwire FIRES on a planted
    /// `hasPrefix("d_")` call. Writes a synthetic Swift file into a temp dir and
    /// confirms the grep pattern matches it.
    func test_phoneOpLogFilenameTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-oplog-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("BadDocIdParser.swift")
        try """
        func isDocId(_ s: String) -> Bool {
            return s.hasPrefix(\"d_\")  // hand-rolled: should be caught
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let forbidden = ["hasPrefix(\"d_\")", ".hasSuffix(\".jsonl\")", ".jsonl\""]
        let text = try String(contentsOf: planted, encoding: .utf8)
        var offenders: [String] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for pat in forbidden where line.contains(pat) {
                offenders.append("\(planted.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly one op-log filename offender. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("hasPrefix") == true,
            "Self-check: the planted hasPrefix(\"d_\") call should be caught.")
    }

    /// Action-triggered guard: surface code must not hand-roll op-log filename /
    /// docId parsing — it must call OpLogStore. Catches the phone-v0.1.1 footgun
    /// class. Allowlist = files that legitimately ARE the choke-point or its tests.
    func test_noReachAroundOpLogFilenameParsing() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)
        // No legitimate op-log filename parsers or hand-rolled .jsonl filename
        // constructors in MaughamPhone — surfaces delegate to OpLogStore /
        // InboxManifest. The Task 7 audit finalizes this list.
        let allowed: Set<String> = []
        let forbidden = ["hasPrefix(\"d_\")", ".hasSuffix(\".jsonl\")", ".jsonl\""]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(sourceDir.path)")
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if allowed.contains(url.lastPathComponent) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for pat in forbidden where line.contains(pat) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "Hand-rolled op-log filename parsing or .jsonl filename construction found. "
            + "Use OpLogStore.docId(fromOpLogFilename:) for parsing; "
            + "use InboxManifest.inboxManifestURL for manifest construction. "
            + "See docs/superpowers/notes/cross-surface-contracts.md:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - Sealed-segment scope tripwire (ADR 0016)

    /// Scope guard (CLAUDE.md tripwire 17 footnote): sealing is Mac-only in v1.
    /// The phone reads sealed segments FOR FREE through the shared MaughamCore
    /// helpers (`loadSyncMerged` / `opLogFileURLs`) and must contain ZERO
    /// segment-name spellings or `sealTailIfNeeded` calls — a hand-rolled
    /// `.mzseg` template or seal invocation in MaughamPhone/ is the same
    /// reach-around class as the phone-v0.1.1 doc-id parser bug.
    func test_phoneNeverSealsOrHandRollsSegmentNames() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)
        // The phone has NO sanctioned home for either spelling: it never seals.
        let allowed: Set<String> = []
        let forbidden = [".mzseg", "sealTailIfNeeded"]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(sourceDir.path)")
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if allowed.contains(url.lastPathComponent) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for pat in forbidden where line.contains(pat) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "Segment-name spelling or sealTailIfNeeded call found in MaughamPhone/. "
            + "Sealing is Mac-only (ADR 0016); the phone reads segments through "
            + "OpLogStore.loadSyncMerged / opLogFileURLs (MaughamCore). "
            + "See docs/superpowers/notes/cross-surface-contracts.md:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the segment-scope tripwire FIRES on planted offenders —
    /// both a hand-rolled `.mzseg` template and a `sealTailIfNeeded` call.
    func test_phoneSegmentScopeTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-mzseg-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("BadSeg.swift")
        try """
        func badSegmentName(_ docId: String) -> String {
            return \"\\(docId).mac.seg0001.mzseg\"   // should be caught
        }
        func badSeal() async throws {
            _ = try await store.sealTailIfNeeded(docId: \"x\", deviceSlug: \"y\")
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let forbidden = [".mzseg", "sealTailIfNeeded"]
        let text = try String(contentsOf: planted, encoding: .utf8)
        var offenders: [String] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for pat in forbidden where line.contains(pat) {
                offenders.append("\(planted.lastPathComponent):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders.count, 2,
            "Self-check expected both the .mzseg name and the sealTailIfNeeded call. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains(".mzseg") })
        XCTAssertTrue(offenders.contains { $0.contains("sealTailIfNeeded") })
    }

    // MARK: - Manuscript-body read tripwire (ADR 0018) — phone twin

    /// Mirror of `TripwireGrepTests.adr0018ReadPatterns` (the two test targets
    /// can't share symbols, so the pattern list is duplicated by necessity —
    /// same reality as the `hasPrefix("d_")` / `.mzseg` spellings above). Widen
    /// BOTH copies together. Concrete file-read call shapes that could pull a
    /// manuscript body off disk, bypassing the op log.
    static let adr0018ReadPatterns: [String] = [
        "String(contentsOf",
        "Data(contentsOf",
        "contentsOfFile",
        ".contents(atPath",
        "FileHandle(forReadingFrom",
        ".resourceBytes",
    ]

    /// `.lines` compromise, identical to the Mac twin: a bare `.lines` is too
    /// greppy (the phone's `FountainSemanticRenderer` iterates
    /// `script.lines`), so flag only the async-line-read shape (`.lines` AND
    /// `await` — the `for try await … in url.lines` signature).
    static func adr0018IsAsyncURLLinesRead(_ line: String) -> Bool {
        line.contains(".lines") && line.contains("await")
    }

    /// A line is exempt when it carries `// adr-0018-ok: <reason>` or is a pure
    /// comment line. Mirror of the Mac twin's predicate.
    static func adr0018ExcludeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("// adr-0018-ok:") { return true }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { return true }
        return false
    }

    /// Walk all `.swift` files under `dir`, recording offenders for any
    /// `patterns` substring or the `extraOffender` predicate, skipping lines
    /// the `excludeLine` predicate rejects. Pure-Swift (no `Process` on iOS),
    /// mirroring the Mac `grepSwift`.
    private func grepSwiftDir(
        in dir: URL,
        patterns: [String],
        excludeLine: (String) -> Bool,
        extraOffender: (String) -> Bool
    ) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(dir.path)")
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                if excludeLine(lineStr) { continue }
                let hit = patterns.contains { lineStr.contains($0) } || extraOffender(lineStr)
                if hit {
                    offenders.append("\(url.lastPathComponent):\(i + 1): "
                        + lineStr.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return offenders
    }

    /// ADR 0018 phone twin (finding F9): every production file-read of a
    /// manuscript body under `MaughamPhone/` must carry a `// adr-0018-ok:`
    /// annotation. The phone's Read tab renders the on-disk `.md` for display
    /// (freshest render; no live cross-device Document) — a CONTRACTED
    /// divergence registered in docs/superpowers/notes/cross-surface-contracts.md;
    /// its read (through `CoordinatedFileIO.coordinatedRead`) is annotated as
    /// such. Anchors and sequence still derive from the op log via
    /// AnnotationLoading.
    func test_noManuscriptFileReadsOutsideReconciler() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)
        let offenders = try grepSwiftDir(
            in: sourceDir,
            patterns: Self.adr0018ReadPatterns,
            excludeLine: Self.adr0018ExcludeLine,
            extraOffender: Self.adr0018IsAsyncURLLinesRead)
        XCTAssertTrue(offenders.isEmpty,
            "A MaughamPhone/ file reads a manuscript body off disk without justification. "
            + "The Read-tab display read is a contracted divergence (annotate "
            + "`// adr-0018-ok: contracted display read — see cross-surface-contracts.md`); "
            + "any other non-manuscript read (inbox capture, manifest, checksum bytes) must "
            + "state what it is. See docs/adr/0018-manuscript-reads-derive-from-oplog.md and "
            + "docs/superpowers/notes/cross-surface-contracts.md. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the phone ADR 0018 tripwire FIRES on a planted
    /// unannotated read, and that the annotation + the synchronous
    /// `script.lines` exclusion both hold. Shares the pattern list + predicates
    /// with the production check.
    func test_phoneManuscriptReadTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-adr0018-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("SomeReader.swift")
        try """
        func read(at url: URL) throws -> Data {
            return try Data(contentsOf: url)  // should be caught
        }
        func display(at url: URL) throws -> Data {
            return try Data(contentsOf: url) // adr-0018-ok: contracted display read — see cross-surface-contracts.md
        }
        func render(_ script: FountainScript) {
            _ = script.lines.count  // must NOT fire — sync in-memory property
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let offenders = try grepSwiftDir(
            in: tmp,
            patterns: Self.adr0018ReadPatterns,
            excludeLine: Self.adr0018ExcludeLine,
            extraOffender: Self.adr0018IsAsyncURLLinesRead)
        XCTAssertEqual(offenders.count, 1,
            "Self-check expected exactly the unannotated Data(contentsOf:) to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.first?.contains("Data(contentsOf: url)") == true,
            "Self-check: the planted unannotated Data(contentsOf:) should be caught.")
    }

    // MARK: - InboxConvention subdir literal tripwire (E5a) — Mac twin

    /// Recurrence-tripper: `InboxCaptureWriter`'s inbox asset subdir literals
    /// (`"images"`/`"audio"`) must route through `InboxConvention`
    /// (MaughamCore) — the Mac twin lives in `TripwireGrepTests.
    /// test_noRawInboxSubdirLiteralsInInboxStore`.
    func test_noRawInboxSubdirLiteralsInInboxCaptureWriter() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let target = repoRoot.appendingPathComponent(
            "MaughamPhone/Capture/InboxCaptureWriter.swift")
        let text = try String(contentsOf: target, encoding: .utf8)
        let forbidden = ["\"images\"", "\"audio\""]
        var offenders: [String] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for pat in forbidden where line.contains(pat) {
                offenders.append("\(target.lastPathComponent):\(i + 1): "
                    + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "Raw inbox asset subdir literal (\"images\"/\"audio\") in "
            + "InboxCaptureWriter.swift. Route through InboxConvention.imagesSubdir / "
            + ".audioSubdir (MaughamCore) — the single source of truth shared with the "
            + "Mac reader (InboxStore). See docs/superpowers/notes/cross-surface-contracts.md. "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the tripwire FIRES on planted raw subdir literals.
    func test_inboxSubdirLiteralTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-inbox-subdir-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = tmp.appendingPathComponent("InboxCaptureWriter.swift")
        try """
        private var imagesDir: URL {
            inboxDir.appendingPathComponent("images", isDirectory: true)
        }
        private var audioDir: URL {
            inboxDir.appendingPathComponent("audio", isDirectory: true)
        }
        """.write(to: planted, atomically: true, encoding: .utf8)

        let forbidden = ["\"images\"", "\"audio\""]
        let text = try String(contentsOf: planted, encoding: .utf8)
        var offenders: [String] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for pat in forbidden where line.contains(pat) {
                offenders.append("\(planted.lastPathComponent):\(i + 1): "
                    + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertEqual(offenders.count, 2,
            "Self-check expected both the images and audio literal to fire. Got:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("\"images\"") },
            "Self-check: the planted \"images\" literal should be caught.")
        XCTAssertTrue(offenders.contains { $0.contains("\"audio\"") },
            "Self-check: the planted \"audio\" literal should be caught.")
    }

    // MARK: - The device string is the key (signed op log, spec §4.8)

    /// Twin of the Mac's `test_noHandBuiltDeviceIdOutsideDeviceIdentity`.
    /// The phone used to mint `"phone:<uuid>"` into `UserDefaults` and call
    /// that its device id; it now reads `DeviceIdentity.author.deviceId`
    /// (MaughamCore) like the Mac, so one install has one identity derived
    /// from its own key material. A literal here is a device that partitions
    /// its writes somewhere else — the failure tripwire 17 exists for.
    ///
    /// The Mac census scans MaughamPhone/ too; this twin is what makes the
    /// phone suite fail on its own, without waiting for a Mac gate.
    func test_noHandBuiltDeviceIdOutsideDeviceIdentity() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)
        let offenders = try Self.handBuiltDeviceIdOffenders(in: sourceDir)
        XCTAssertTrue(offenders.isEmpty,
                      "A phone production file hand-builds a device id or reads "
                      + "the host name. `DeviceIdentity.author.deviceId` is the "
                      + "one answer on both surfaces:\n"
                      + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the twin FIRES on planted offenders — the two retired
    /// id spellings and a host-name read — and lets the comments that merely
    /// NAME them through.
    func test_handBuiltDeviceIdTripwireFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-deviceid-\(UUID().uuidString)")
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

        let offenders = try Self.handBuiltDeviceIdOffenders(in: tmp)
        XCTAssertEqual(offenders.count, 3,
            "Self-check: the three planted uses should be caught and neither "
            + "comment. Caught:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let host") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let minted") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let fallback") }))
    }

    // MARK: - The palette aim has no writer on the phone (signed op log P1)

    /// The phone's capture aim picker was the ONE thing that ever stamped
    /// `InboxEntry.paletteSubject`/`sense`, and it is gone: a capture lands in
    /// the inbox plain, and the Mac aims it at a palette card when the writer
    /// promotes it. The two fields survive on the wire because rows already on
    /// disk carry them — decoded, tolerated, written by nobody.
    ///
    /// A census rather than a comment, because the removal is invisible: a
    /// re-added `paletteSubject:` argument or a new `PaletteAim` value would
    /// compile, pass every test, and quietly give the phone a second opinion
    /// about which card a note belongs to.
    func test_noPaletteAimWriterOnThePhone() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)
        let offenders = try Self.paletteAimOffenders(in: sourceDir)
        XCTAssertTrue(offenders.isEmpty,
                      "A phone production file writes a palette aim. The aim "
                      + "picker was removed in signed op log P1; a capture is "
                      + "aimed on the Mac at promote time. Offenders:\n"
                      + offenders.joined(separator: "\n"))
    }

    /// Self-check: prove the census FIRES on a planted writer and a planted
    /// `PaletteAim` value, and lets prose that merely NAMES them through.
    func test_paletteAimCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-aim-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // Prose may say paletteSubject: and PaletteAim — allowed.
        /// The aim picker wrote paletteSubject: and held a PaletteAim.
        let plain = try await writer.writeText(text)
        let aimed = try await writer.writeText(text, paletteSubject: aim.subject)
        var aim: PaletteAim?
        """.write(to: tmp.appendingPathComponent("BadAim.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try Self.paletteAimOffenders(in: tmp)
        XCTAssertEqual(offenders.count, 2,
            "Self-check: the two planted uses should be caught and neither "
            + "comment. Caught:\n" + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let aimed") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("var aim") }))
    }

    /// SHARED by the palette-aim census and its self-check.
    private static func paletteAimOffenders(in dir: URL) throws -> [String] {
        let patterns = ["paletteSubject:", "PaletteAim"]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n",
                                            omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                for pattern in patterns where lineStr.contains(pattern) {
                    offenders.append("\(url.lastPathComponent):\(index + 1): " + trimmed)
                    break
                }
            }
        }
        return offenders
    }

    /// SHARED by the census and its self-check — one place to widen the shape.
    /// Prose may name a host name or a retired id spelling; code may not use
    /// one.
    private static func handBuiltDeviceIdOffenders(in dir: URL) throws -> [String] {
        let patterns = [".hostName", "\"phone:", "\"unknown-host\""]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n",
                                            omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                let trimmed = lineStr.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                for pattern in patterns where lineStr.contains(pattern) {
                    offenders.append("\(url.lastPathComponent):\(index + 1): " + trimmed)
                    break
                }
            }
        }
        return offenders
    }

    // MARK: - The phone is the author and mints one key (P1b constraint 7)

    /// **Not a census.** This branch first guarded constraint 7 here, with a
    /// grep over phone sources for `LocalIdentities.current`, `identity(for:
    /// .assistant)` and the other spellings that reach an actor the phone is
    /// not. The whole-branch review's C1 showed why that could not work:
    /// `OpLogStore`'s `identities:` parameter has a DEFAULT, three phone sites
    /// take it, and the default minted all four keys — no spelling anywhere,
    /// the census green, three enclave keys in the container.
    ///
    /// A grep proves a spelling absent; it cannot prove a behaviour absent. The
    /// guard is now `PhoneOneKeyTests` in `PhoneDeviceIdentityTests.swift`,
    /// which runs the real read path and then asks the phone's own device
    /// folder what is in it. And the spellings this list held are no longer the
    /// hazard they named: `LocalIdentities` is lazy, so naming the value mints
    /// nothing at all.

    // MARK: - A seal line is recognised in OpLogChain only (tripwire 37, phone twin)

    /// The Mac's `TripwireGrepTests.isSealKeyLine`, spelled here because the two
    /// targets share no test code. Both spellings a Swift source can carry the
    /// seal's one top-level key in: escaped inside a string literal
    /// (`{\"seal\":`) and bare (`"seal":`).
    private func isSealKeyLine(_ line: String) -> Bool {
        line.contains(#"\"seal\":"#) || line.contains(#""seal":"#)
    }

    /// The phone reads seal lines through the SAME `JSONLAppendStore.parse` the
    /// Mac does — `OpLogChain.isSealLine` is its one recogniser, and it lives in
    /// MaughamCore. A phone-local recogniser would be tripwire 19's failure
    /// (the phone reimplementing what the Mac implements) arriving as tripwire
    /// 37's: a reader that hands a seal to an element decoder reports a healthy
    /// manifest as damaged, and nothing goes red.
    func test_noSealLineRecogniserOnThePhone() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)

        let offenders = try grepSwiftDir(
            in: sourceDir,
            patterns: [],
            excludeLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
            },
            extraOffender: isSealKeyLine)

        XCTAssertTrue(offenders.isEmpty,
            "A phone source spells the seal line's wire key. The one recogniser "
            + "is MaughamCore's `OpLogChain.isSealLine`, reached through the "
            + "shared `JSONLAppendStore.parse` (tripwires 19 and 37). "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// CONTROL: the same predicate catches both planted spellings and lets a
    /// comment naming the key through.
    func test_phoneSealLineCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-seal-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try #"""
        // A comment may name the {"seal": prefix — allowed.
        let escaped = data.starts(with: Data("{\"seal\":".utf8))
        let raw = line.hasPrefix(#"{"seal":"#)
        let innocent = OpLogChain.isSealLine(data)
        """#.write(to: tmp.appendingPathComponent("SecondSealReader.swift"),
                   atomically: true, encoding: .utf8)

        let offenders = try grepSwiftDir(
            in: tmp,
            patterns: [],
            excludeLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
            },
            extraOffender: isSealKeyLine)

        XCTAssertEqual(offenders.count, 2,
            "Self-check: both planted spellings should be caught, and neither "
            + "the comment nor the sanctioned call. Caught:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let escaped") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let raw") }))
    }

    // MARK: - People and admission (P2a, phone twins of tripwires 39 and 40)

    /// Prose may name a trust closure, the retired field, or a registry path;
    /// code may not build one. SHARED by the census and its self-check.
    private func admissionExcludeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
    }

    /// The Mac's `TripwireGrepTests.trustClosurePatterns` and
    /// `registryPathPatterns`, folded into one list because the phone's
    /// allow-list for both is EMPTY: no phone source may build a trust closure
    /// or spell a registry path at all.
    ///
    /// The phone judges nobody of its own accord. Its two writers take
    /// `ChainPolicy`'s default single-signer closure (MaughamCore), which a
    /// write-only store asks nothing but *is this key mine* — pinned equal to
    /// the table's answer by `PhoneChainPolicyTests`, and kept write-only by
    /// `test_thePhonesChainedStoresOnlyWrite`. Where the phone READS, it asks
    /// MaughamCore's own table through `OpLogStore` — the partition, and since
    /// P3c plan 2 Task 5 the annotation-ownership rule
    /// (`AnnotationLoading.loadJudged` → `annotationAmendments`) — and builds
    /// none of its own. It declares itself through `PhoneDeviceRecord`, which
    /// calls `RegistryPresence` in MaughamCore and never names a record, a
    /// path or a fingerprint. Both halves are tripwire 19 (the phone must not
    /// reimplement what the Mac implements) arriving as a silent one: a phone
    /// that decided trust locally would apply a stranger's sealed captures as
    /// this device's own, and a record it wrote by hand is one no reader can
    /// vouch for.
    ///
    /// **At PARITY with the Mac's list since the 2026-09-20 audit (PR #65, F3).**
    /// It used to carry the literal-with-a-leading-dot spelling of each
    /// directory and nothing else, so a phone source composing the path a
    /// component at a time — `.appendingPathComponent("people")
    /// .appendingPathComponent("claims")` — or writing it bare under some other
    /// prefix walked straight past it. Those are exactly the two shapes a
    /// second writer takes, which is why the Mac carries three spellings of
    /// each directory; the phone now carries the same three, and the control
    /// below plants one of each.
    private var admissionPatterns: [String] {
        ["trusted: {", "trustedFingerprints",
         "identities.fingerprints", ".fingerprints.contains",
         "\".maugham/devices", "\".maugham/people", "\".maugham/claims",
         "maugham/devices", "maugham/people", "maugham/claims", "maugham/events",
         "PathComponent(\"devices", "PathComponent(\"people",
         "PathComponent(\"claims", "PathComponent(\"events",
         "digestHex(ofRecord:", "RegistryWriter.url("]
    }

    func test_noTrustDecisionOrRegistryWriteOnThePhone() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)

        let offenders = try grepSwiftDir(
            in: sourceDir,
            patterns: admissionPatterns,
            excludeLine: admissionExcludeLine,
            extraOffender: { _ in false })

        XCTAssertTrue(offenders.isEmpty,
            "A phone source decides trust or writes a registry record. "
            + "`TrustTable` (MaughamCore) is the one answer to who a seal's key "
            + "is to this device, and `RegistryWriter` is the one door onto "
            + "`.maugham/devices` / `.maugham/people` / `.maugham/people/claims`; "
            + "the phone reaches both through `PhoneDeviceRecord` → "
            + "`RegistryPresence` and never spells either (tripwires 19, 39, 40). "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// CONTROL: the same patterns, over a planted file, catch every offender
    /// and let the comment naming them through.
    func test_phoneAdmissionCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-tripwire-admission-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name trusted: { _ in true } and .maugham/devices.
        let bad = chain.verify(bytes: data, trusted: { _ in true })
        let stale = policy.trustedFingerprints
        let dir = projectURL.appendingPathComponent(\".maugham/devices\", isDirectory: true)
        let digest = try RegistryCanonical.digestHex(ofRecord: record)
        let events = people.appendingPathComponent("events", isDirectory: true)
        let bare = container.appendingPathComponent("maugham/people", isDirectory: true)
        let composed = m.appendingPathComponent("people").appendingPathComponent("claims")
        let good = PhoneDeviceRecord.ensure(in: projectURL, identity: identity)
        """.write(to: tmp.appendingPathComponent("BadPhoneTrust.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwiftDir(
            in: tmp,
            patterns: admissionPatterns,
            excludeLine: admissionExcludeLine,
            extraOffender: { _ in false })

        XCTAssertEqual(offenders.count, 7,
            "Self-check: the seven planted offenders should be caught, and "
            + "neither the comment nor the sanctioned call. Caught:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let bad") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let stale") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let dir") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let digest") }))
        XCTAssertTrue(offenders.contains(where: { $0.contains("let events") }),
            "the permit-event directory is composed from its parent (P3a), "
            + "which is the one spelling a literal prefix would miss")
        XCTAssertTrue(offenders.contains(where: { $0.contains("let bare") }),
            "a registry path written without the leading dot is still one "
            + "(audit PR #65, F3)")
        XCTAssertTrue(offenders.contains(where: { $0.contains("let composed") }),
            "and so is one built a component at a time — which is exactly how "
            + "`RegistryWriter` builds it, and so exactly how a second writer "
            + "would (audit PR #65, F3)")
        XCTAssertFalse(offenders.contains(where: { $0.contains("let good") }))
    }

    // MARK: - The registry's writers are a census — the phone twin
    //         (P2b Task 10)

    /// The four verbs that put bytes into the registry folder. The Mac's twin
    /// (`TripwireGrepTests.registryWriterVerbs`) allow-lists three Core files;
    /// **the phone allow-lists none**, because the phone writes no registry
    /// record at all. Admission is a Mac act at a Mac surface (spec §4.11), and
    /// a phone that could sign a person record could admit itself.
    private let registryWriterVerbs = [
        "RegistryWriter.write(", "RegistryWriter.writeUnchecked(",
        "RegistryWriter.restore(", "RegistryWriter.resign(",
    ]

    func test_thePhoneWritesNoRegistryRecord() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)

        let offenders = try grepSwiftDir(
            in: sourceDir,
            patterns: registryWriterVerbs,
            excludeLine: admissionExcludeLine,
            extraOffender: { _ in false })

        XCTAssertTrue(offenders.isEmpty,
            "A phone source writes a registry record. The phone shows its "
            + "standing and offers nothing to press (spec §4.11): a phone that "
            + "could sign a person record could admit itself to a book the "
            + "writer never let it into. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    func test_theRegistryWriterPhoneCensusFiresOnAPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-writer-selfcheck-\(UUID().uuidString)")
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
        """.write(to: tmp.appendingPathComponent("PhoneAdmitsItself.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try grepSwiftDir(
            in: tmp,
            patterns: registryWriterVerbs,
            excludeLine: admissionExcludeLine,
            extraOffender: { _ in false })

        XCTAssertEqual(offenders.count, 4,
            "Self-check: all four write verbs should be caught, and neither the "
            + "comment nor the `directoryURL` read. Caught:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertFalse(offenders.contains(where: { $0.contains("let read") }),
            "reading where a record lives is not writing one")
    }

    // MARK: - The phone reads annotations judged, and its chained stores only
    //         write (P3c plan 2, Task 5)

    /// Every line under `dir` matching one of `patterns`, in a file whose
    /// name is not `allowedIn` and (when `onlyFilesContaining` is given) whose
    /// text contains that marker. Comment lines are let through.
    private func censusOffenders(
        in dir: URL, patterns: [String], allowedIn: Set<String> = [],
        onlyFilesContaining marker: String? = nil
    ) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(dir.path)")
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard !allowedIn.contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if let marker, !text.contains(marker) { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                if admissionExcludeLine(lineStr) { continue }
                if patterns.contains(where: { lineStr.contains($0) }) {
                    offenders.append("\(url.lastPathComponent):\(i + 1): "
                        + lineStr.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return offenders
    }

    private var phoneSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaughamPhone", isDirectory: true)
    }

    /// The op-log reads and annotation derives a phone source could make
    /// WITHOUT the ownership judgement. `AnnotationLoading.swift` is the one
    /// file allowed to spell them, because `loadJudged` is where the load and
    /// its judgement are put together and its derive overloads take the pair.
    ///
    /// Every `OpLogStore` read that hands back ops is named (fix round 1's M1
    /// added the partial and single-file reads), and so is the permissive
    /// judgement itself: `.honourEverything` spelled in production anywhere
    /// but here is a derive that has chosen not to be judged.
    private let unjudgedAnnotationReads = [
        ".load(docId:", "loadDiagnosed(", "loadDiagnosedPartial(",
        "loadFileDiagnosed(", "loadSyncMerged(",
        "AnnotationDeriver.derive(", "AnnotationDeriver.deriveWithdrawn(",
        "AnnotationAggregation.", ".honourEverything",
    ]

    /// **Every annotation read on the phone is judged** — through
    /// `AnnotationLoading.loadJudged`, the Mac's own two Core calls. A second
    /// read beside it would be a derive under `.honourEverything` again: in a
    /// narrowed book, a reviewer's edit of somebody else's note that every Mac
    /// refuses, shown on the phone as if it stood.
    func test_everyAnnotationReadOnThePhoneIsJudged() throws {
        let offenders = try censusOffenders(
            in: phoneSourceDir, patterns: unjudgedAnnotationReads,
            allowedIn: ["AnnotationLoading.swift"])
        XCTAssertTrue(offenders.isEmpty,
            "A phone source reads the op log or derives annotations outside "
            + "`AnnotationLoading`. Read through `AnnotationLoading.loadJudged` "
            + "and derive from the `JudgedOps` it returns, so the phone applies "
            + "the Mac's ownership rule (tripwire 19). Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL: the census catches each spelling in a planted file, and lets
    /// the judged spelling and a comment through.
    func test_theJudgedReadCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-judged-read-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name store.load(docId: and AnnotationDeriver.derive(.
        let a = try await store.load(docId: docId)
        let b = try await store.loadDiagnosed(docId: docId)
        let c = AnnotationDeriver.derive(ops: ops, paragraphs: p)
        let d = AnnotationAggregation.openAnnotations(ops: ops)
        let e = await store.loadDiagnosedPartial(docId: docId)
        let f = try OpLogStore.loadFileDiagnosed(url, trust: t)
        let g = AnnotationLoading.allAnnotations(ops: ops, amendments: .honourEverything)
        let good = try await AnnotationLoading.loadJudged(docId: docId, from: store)
        let fine = AnnotationLoading.allAnnotations(good)
        """.write(to: tmp.appendingPathComponent("UnjudgedRead.swift"),
                  atomically: true, encoding: .utf8)
        try "let x = try await store.load(docId: docId)\n"
            .write(to: tmp.appendingPathComponent("AnnotationLoading.swift"),
                   atomically: true, encoding: .utf8)

        let offenders = try censusOffenders(
            in: tmp, patterns: unjudgedAnnotationReads,
            allowedIn: ["AnnotationLoading.swift"])
        XCTAssertEqual(offenders.count, 7,
            "Self-check: the seven unjudged reads should be caught, and neither "
            + "the comment, the judged spelling, nor the allow-listed file. "
            + "Caught:\n" + offenders.joined(separator: "\n"))
        XCTAssertFalse(offenders.contains(where: { $0.contains("let good") }))
        XCTAssertFalse(offenders.contains(where: { $0.contains("let fine") }))
    }

    /// **C7: the phone's chained stores only write.** `AnnotationWriter` and
    /// `InboxCaptureWriter` build `ChainPolicy` with its default single-signer
    /// trust, which is the table's answer ONLY for a store that writes: the
    /// chained write asks nothing but *is this key mine*, while the chained
    /// read takes the full verdict and would need the table.
    ///
    /// Three halves, so the census does not hang on one spelling in one file
    /// (fix round 1's M1): every `ChainPolicy(` on the phone is in a NAMED
    /// file; those files read through no store; and the reads only a
    /// `JSONLAppendStore` offers appear in no phone source at all, so a store
    /// built in one file cannot be read in another.
    private let chainPolicyFiles: Set<String> = [
        "AnnotationWriter.swift", "InboxCaptureWriter.swift",
    ]
    private let storeReads = [
        ".load(", ".loadDiagnosed(", ".loadStrict(",
        ".loadDiagnosedStrict(", ".loadVerifiedStrict(",
    ]
    private let appendStoreOnlyReads = [
        ".loadStrict(", ".loadDiagnosedStrict(", ".loadVerifiedStrict(",
    ]

    private func writeOnlyOffenders(in dir: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(dir.path)")
            return []
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineStr = String(line)
                if admissionExcludeLine(lineStr) { continue }
                let where_ = "\(name):\(i + 1): " + lineStr.trimmingCharacters(in: .whitespaces)
                if lineStr.contains("ChainPolicy("), !chainPolicyFiles.contains(name) {
                    offenders.append("unnamed ChainPolicy — " + where_)
                }
                if chainPolicyFiles.contains(name),
                   storeReads.contains(where: { lineStr.contains($0) }) {
                    offenders.append("read in a chained writer — " + where_)
                }
                if appendStoreOnlyReads.contains(where: { lineStr.contains($0) }) {
                    offenders.append("store read — " + where_)
                }
            }
        }
        return offenders
    }

    func test_thePhonesChainedStoresOnlyWrite() throws {
        let offenders = try writeOnlyOffenders(in: phoneSourceDir)
        XCTAssertTrue(offenders.isEmpty,
            "A phone source builds a `ChainPolicy` outside the two named "
            + "writers, or reads through a chained store. The default "
            + "single-signer trust is the table's answer for a write and not "
            + "for a read: a store that reads takes the verified table "
            + "(`TrustTable.verdict(forSealKey:)`, from MaughamCore). "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// CONTROL: one planted offender per half, each caught; the sanctioned
    /// shape and a comment are not.
    func test_theWriteOnlyStoreCensusFiresOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-write-only-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may say ChainPolicy( and store.load( here.
        let store = JSONLAppendStore<Op>(fileURL: url, chain: ChainPolicy(
            identity: identity, state: .shared, docId: docId, projectURL: root))
        try await store.append(op)
        let read = try await store.load()
        """.write(to: tmp.appendingPathComponent("AnnotationWriter.swift"),
                  atomically: true, encoding: .utf8)
        try """
        let policy = ChainPolicy(identity: i, state: .shared, docId: d, projectURL: r)
        let identity = try DeviceIdentity.load(from: dir, actor: .author)
        """.write(to: tmp.appendingPathComponent("ThirdWriter.swift"),
                  atomically: true, encoding: .utf8)
        try """
        let elsewhere = try await sharedStore.loadVerifiedStrict()
        """.write(to: tmp.appendingPathComponent("SomeReader.swift"),
                  atomically: true, encoding: .utf8)

        let offenders = try writeOnlyOffenders(in: tmp)
        XCTAssertEqual(offenders.count, 3,
            "Self-check: one offender per half. Caught:\n"
            + offenders.joined(separator: "\n"))
        XCTAssertTrue(offenders.contains { $0.contains("let read") },
                      "a read in a named chained writer")
        XCTAssertTrue(offenders.contains { $0.contains("let policy") },
                      "a ChainPolicy in a file nobody named")
        XCTAssertTrue(offenders.contains { $0.contains("let elsewhere") },
                      "a store read anywhere else on the phone")
        XCTAssertFalse(offenders.contains { $0.contains("let identity") },
                       "`DeviceIdentity.load` in an unnamed file is not a store read")
    }

    // MARK: - The phone asks its posture in one place, and capture never asks
    //         (P3c plan 2, Task 6)

    /// The spellings of reaching the posture door or its not-yet answer.
    /// `PhonePosture.swift` is the phone's one door: it asks MaughamCore's
    /// `PostureDoor` and holds `Posture.settling` as its unanswered state, and
    /// every view asks `PhonePosture` rather than either. (The Mac's census,
    /// `TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`, already
    /// scans this target for the permit's own ask spellings.)
    private let phonePostureDoorSpellings = ["PostureDoor.", "Posture.settling"]

    /// Anything a capture could ask a posture through. Capture is on every
    /// rung — an inbox row is the reviewer row — so nothing under `Capture/`
    /// may consult one: a capture hidden behind a posture is a reviewer who
    /// can no longer send the writer anything.
    private let captureAsksAPosture = ["Posture", "posture", ".allows("]

    private var phoneCaptureDir: URL {
        phoneSourceDir.appendingPathComponent("Capture", isDirectory: true)
    }

    func test_thePhoneAsksItsPostureInOnePlace() throws {
        let offenders = try censusOffenders(
            in: phoneSourceDir, patterns: phonePostureDoorSpellings,
            allowedIn: ["PhonePosture.swift"])
        XCTAssertTrue(offenders.isEmpty,
            "A phone source reaches the posture door, or spells its not-yet "
            + "answer, outside `PhonePosture`. Ask "
            + "`PhonePosture.posture(forDocId:in:)` and decide a verb with "
            + "`PhonePosture.offers` (tripwires 19, 51). Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    func test_captureNeverAsksAPosture() throws {
        let offenders = try censusOffenders(
            in: phoneCaptureDir, patterns: captureAsksAPosture)
        XCTAssertTrue(offenders.isEmpty,
            "A capture source consults a posture. Capture is offered on every "
            + "rung: an inbox row is the reviewer row. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    /// CONTROL: both censuses fire on planted offenders, let a comment
    /// through, and the door's own file is admitted its spellings.
    func test_thePhonePostureCensusesFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("phone-posture-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let planted = """
        // A comment may say PostureDoor. and Posture.settling and posture.
        let asked = PostureDoor.posture(forDocId: d, in: u, using: s)
        let undecided = Posture.settling
        let fine = PhonePosture.offers(.accept, under: posture)
        """
        try planted.write(to: tmp.appendingPathComponent("SomeView.swift"),
                          atomically: true, encoding: .utf8)
        try planted.write(to: tmp.appendingPathComponent("PhonePosture.swift"),
                          atomically: true, encoding: .utf8)
        let door = try censusOffenders(
            in: tmp, patterns: phonePostureDoorSpellings,
            allowedIn: ["PhonePosture.swift"])
        XCTAssertEqual(door.count, 2,
            "Self-check: both door spellings caught in a view, none in the "
            + "door's own file, the comment let through. Caught:\n"
            + door.joined(separator: "\n"))
        XCTAssertFalse(door.contains { $0.contains("let fine") })
        XCTAssertFalse(door.contains { $0.hasPrefix("PhonePosture.swift") })

        try """
        // A capture is on every rung; no posture is asked.
        guard posture.allows(.annotate) else { return }
        let hidden = PhonePosture.offersCapture(under: p)
        let written = try await writer.writeText(text, to: project)
        """.write(to: tmp.appendingPathComponent("CaptureView.swift"),
                  atomically: true, encoding: .utf8)
        try fm.removeItem(at: tmp.appendingPathComponent("SomeView.swift"))
        try fm.removeItem(at: tmp.appendingPathComponent("PhonePosture.swift"))
        let capture = try censusOffenders(in: tmp, patterns: captureAsksAPosture)
        XCTAssertEqual(capture.count, 2,
            "Self-check: a capture asking a posture is caught, twice. Caught:\n"
            + capture.joined(separator: "\n"))
        XCTAssertFalse(capture.contains { $0.contains("let written") })
    }
}

