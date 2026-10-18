// MaughamTests/Updates/UpdateSweepTests.swift
import XCTest
@testable import Maugham

/// #67 Task 6: the cleanup deletes only Maugham's own old downloads.
final class UpdateSweepTests: XCTestCase {
    private func stale(_ names: [String], keeping: String? = nil, running: String = "0.42.0") -> Set<String> {
        Set(UpdateSweep.staleUpdateArtifacts(in: names, keeping: keeping, runningVersion: running))
    }

    func test_noPending_removesAtOrBelowRunning_keepsNewer() {
        let names = ["Maugham-0.41.0.zip", "Maugham-0.42.0.zip", "staged-0.42.0", "staged-0.41.0",
                     "Maugham-0.43.0.zip", "staged-0.43.0", "Maugham-0.40.0.dmg"]
        XCTAssertEqual(stale(names), ["Maugham-0.41.0.zip", "Maugham-0.42.0.zip", "staged-0.42.0",
                                      "staged-0.41.0", "Maugham-0.40.0.dmg"])
    }

    func test_pending_keepsOnlyThatVersion() {
        let names = ["Maugham-0.43.0.zip", "staged-0.43.0", "Maugham-0.42.0.zip", "staged-0.41.0",
                     "Maugham-0.44.0.dmg", "Maugham-0.44.0.zip.download"]
        XCTAssertEqual(stale(names, keeping: "0.43.0"),
                       ["Maugham-0.42.0.zip", "staged-0.41.0", "Maugham-0.44.0.dmg", "Maugham-0.44.0.zip.download"])
    }

    func test_preReleaseVersionsCompareSemantically() {
        // 0.41.90 > 0.41.9 and 0.9.0 < 0.41.0: string order would get both wrong.
        let names = ["Maugham-0.41.90.zip", "Maugham-0.41.9.zip", "Maugham-0.9.0.zip", "staged-0.100.0"]
        XCTAssertEqual(stale(names, running: "0.41.9"), ["Maugham-0.41.9.zip", "Maugham-0.9.0.zip"])
        XCTAssertEqual(stale(names, keeping: "0.41.90"), ["Maugham-0.41.9.zip", "Maugham-0.9.0.zip", "staged-0.100.0"])
    }

    func test_foreignAndUnmatchedNamesAreNeverReturned() {
        let names = ["install-status", ".DS_Store", "Maugham-notaversion.zip", "Maugham-0.1.zip",
                     "Maugham-0.1.0.zip.partial", "Maugham-0.1.0.tar", "staged-", "staged-abc",
                     "other-0.1.0.zip", "Maugham-0.1.0.zip.bak", "notes.txt", "Maugham-v0.1.0.zip",
                     "Maugham-0.1.0", "staged-0.1.0.old"]
        XCTAssertEqual(stale(names), [])
        XCTAssertEqual(stale(names, keeping: "9.9.9"), [])
    }

    func test_downloadTempFilesMatchLikeArchives() {
        let names = ["Maugham-0.40.0.zip.download", "Maugham-0.40.0.dmg.download", "Maugham-0.50.0.zip.download"]
        XCTAssertEqual(stale(names), ["Maugham-0.40.0.zip.download", "Maugham-0.40.0.dmg.download"])
    }

    func test_realDirectory_launchSweepAndPostStageSweep() throws {
        let fm = FileManager.default
        let dir = TestTemp.root.appendingPathComponent("Updates", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ n: String, dir isDir: Bool = false) throws {
            let u = dir.appendingPathComponent(n)
            if isDir {
                try fm.createDirectory(at: u.appendingPathComponent("Maugham.app"), withIntermediateDirectories: true)
            } else { try Data("x".utf8).write(to: u) }
        }
        let all = ["Maugham-0.40.0.zip", "staged-0.40.0", "Maugham-0.42.0.zip", "Maugham-0.43.0.zip",
                   "Maugham-0.43.0.zip.download", "Maugham-0.41.0.dmg.download", "staged-0.43.0",
                   "install-status", ".DS_Store", "Maugham-junk.zip", "readme.txt"]
        for n in all { try make(n, dir: n.hasPrefix("staged-")) }
        func remaining() throws -> Set<String> { Set(try fm.contentsOfDirectory(atPath: dir.path)) }

        // Post-stage: keep 0.43.0; downloads untouched.
        UpdateSweep.sweep(in: dir, keeping: "0.43.0", runningVersion: "0.42.0", includingDownloads: false)
        XCTAssertEqual(try remaining(), ["Maugham-0.43.0.zip", "Maugham-0.43.0.zip.download",
                                         "Maugham-0.41.0.dmg.download", "staged-0.43.0", "install-status",
                                         ".DS_Store", "Maugham-junk.zip", "readme.txt"])
        // Launch: nothing pending, running 0.42.0.
        UpdateSweep.sweep(in: dir, keeping: nil, runningVersion: "0.42.0", includingDownloads: true)
        XCTAssertEqual(try remaining(), ["Maugham-0.43.0.zip", "Maugham-0.43.0.zip.download", "staged-0.43.0",
                                         "install-status", ".DS_Store", "Maugham-junk.zip", "readme.txt"])
    }
}
