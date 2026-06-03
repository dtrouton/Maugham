import XCTest

/// Mac-side reach-around tripwire (twin of TripwirePhoneGrepTest). Scans
/// Maugham/ in pure Swift (mirrors the phone approach; no Process spawn). The
/// allowlist holds files that legitimately own op-log filename handling.
final class TripwireGrepTests: XCTestCase {
    func test_noReachAroundOpLogFilenameParsing() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = repoRoot.appendingPathComponent("Maugham", isDirectory: true)
        // OpLogStore lives in MaughamCore (not scanned). Mac files that legitimately
        // touch op-log/sidecar filenames go here; the Task 7 audit finalizes the list.
        let allowed: Set<String> = [
            "MaughamSidecarPath.swift",
        ]
        let forbidden = ["hasPrefix(\"d_\")"]
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
            "Hand-rolled doc-id parsing in Maugham/. Use OpLogStore.docId(fromOpLogFilename:). "
            + "See docs/superpowers/notes/cross-surface-contracts.md:\n" + offenders.joined(separator: "\n"))
    }
}
