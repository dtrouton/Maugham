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
}
