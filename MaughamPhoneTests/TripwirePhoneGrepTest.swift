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

    /// Action-triggered guard: surface code must not hand-roll op-log filename /
    /// docId parsing — it must call OpLogStore. Catches the phone-v0.1.1 footgun
    /// class. Allowlist = files that legitimately ARE the choke-point or its tests.
    func test_noReachAroundOpLogFilenameParsing() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("MaughamPhone", isDirectory: true)
        // No legitimate op-log filename parsers in MaughamPhone — surfaces delegate
        // to OpLogStore. The Task 7 audit finalizes this list.
        let allowed: Set<String> = []
        let forbidden = ["hasPrefix(\"d_\")", ".hasSuffix(\".jsonl\")"]
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
            "Hand-rolled op-log filename parsing found. Use OpLogStore.docId(fromOpLogFilename:). "
            + "See docs/superpowers/notes/cross-surface-contracts.md:\n" + offenders.joined(separator: "\n"))
    }
}
