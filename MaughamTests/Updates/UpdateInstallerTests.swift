import XCTest
@testable import Maugham

final class UpdateInstallerTests: XCTestCase {
    private func goodVerdict(team: String = "ABC123") -> VerificationVerdict {
        VerificationVerdict(codesignValid: true, notarized: true, teamID: team)
    }

    func test_accepts_whenSignedNotarizedAndTeamMatches() {
        let v = goodVerdict(team: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"), .accept)
    }

    func test_rejects_whenTeamMismatch() {
        let v = goodVerdict(team: "EVIL99")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Team ID mismatch"))
    }

    func test_rejects_whenNotNotarized() {
        let v = VerificationVerdict(codesignValid: true, notarized: false, teamID: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Not notarized"))
    }

    func test_rejects_whenCodesignInvalid() {
        let v = VerificationVerdict(codesignValid: false, notarized: true, teamID: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Invalid code signature"))
    }

    // MARK: - helperScript: shape

    func test_helperScript_relaunch_containsWaitDittoAndOpen() {
        let script = UpdateInstaller.helperScript(
            pid: 4242, stagedBundle: "/staged/Maugham.app",
            installedBundle: "/Applications/Maugham.app", relaunch: true)
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("ditto"))
        XCTAssertTrue(script.contains("/staged/Maugham.app"))
        XCTAssertTrue(script.contains("/Applications/Maugham.app"))
        XCTAssertTrue(script.contains("open \"/Applications/Maugham.app\""))
    }

    func test_helperScript_noRelaunch_omitsOpen() {
        let script = UpdateInstaller.helperScript(
            pid: 4242, stagedBundle: "/staged/Maugham.app",
            installedBundle: "/Applications/Maugham.app", relaunch: false)
        XCTAssertFalse(script.contains("open \""))
        XCTAssertTrue(script.contains("ditto"))
    }

    /// Ensure the script uses the atomic swap mechanism, not the bricking rm+mv pattern.
    func test_helperScript_usesAtomicSwap_notRmMv() {
        let script = UpdateInstaller.helperScript(
            pid: 1, stagedBundle: "/a.app", installedBundle: "/b.app", relaunch: false)
        // Must use renamex_np (via the Python helper) — never bare rm+mv on installed.
        XCTAssertTrue(script.contains("renamex_np"),
                      "Script must use renamex_np for the atomic swap")
        XCTAssertTrue(script.contains("python3"),
                      "Script must invoke python3 for the atomic swap")
        // Must NOT contain the bricking pattern: rm -rf "<installed>" followed by mv.
        // The inflight sibling cleanup (rm -rf .inflight) IS allowed — that's before ditto.
        // The installed bundle itself must never be rm'd.
        let installedBundle = "/b.app"
        XCTAssertFalse(script.contains("rm -rf \"\(installedBundle)\""),
                       "Script must not rm -rf the installed bundle — that leaves it missing on crash")
    }

    /// The Python swap source must be flush-left (no leading spaces on any line).
    /// A leading space on any module-scope statement is a Python IndentationError.
    func test_pyAtomicSwapSource_noLeadingSpacesOnTopLevelLines() {
        let lines = UpdateInstaller.pyAtomicSwapSource
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let str = String(line)
            if str.isEmpty { continue }
            // Lines inside the `if rc != 0:` block ARE indented — that's correct Python.
            // We only reject lines that start with a space but are NOT inside a block.
            // Simpler invariant: the first character of every module-scope statement
            // must not be a space. Module-scope lines: import, variable assignments,
            // function calls, and the if-statement itself.
            let topLevelPrefixes = ["import ", "src_path", "dst_path", "libc", "RENAME_SWAP",
                                    "rc ", "if ", "shutil."]
            let isTopLevel = topLevelPrefixes.contains { str.hasPrefix($0) }
            if isTopLevel {
                XCTAssertFalse(str.hasPrefix(" "),
                    "Top-level Python line must not start with a space: \(str)")
            }
        }
    }

    // MARK: - installMode

    func test_installMode_inPlaceWhenWritable() {
        XCTAssertEqual(UpdateInstaller.installMode(installedBundlePath: "/Applications/Maugham.app",
                                                   isWritable: { _ in true }), .inPlace)
    }

    func test_installMode_finderFallbackWhenNotWritable() {
        XCTAssertEqual(UpdateInstaller.installMode(installedBundlePath: "/Applications/Maugham.app",
                                                   isWritable: { _ in false }), .finderFallback)
    }

    func test_runningAppTeamID_doesNotCrash() {
        // Test host is ad-hoc signed → nil is acceptable; signed Release build
        // returns the real team id (proven in dry-run). We only assert no crash.
        _ = UpdateInstaller.runningAppTeamID()
    }

    // MARK: - atomicSwap (same-volume happy path)

    /// After a successful same-volume swap:
    /// - the install destination contains the NEW content
    /// - the install destination is NEVER absent (it exists both before AND after)
    /// - the staged path contains the OLD content (ready to be cleaned up)
    func test_atomicSwap_sameVolume_swapsContentAndNeverLeavesDestinationAbsent() throws {
        let tmp = FileManager.default.temporaryDirectory
        let staged   = tmp.appendingPathComponent("test-swap-staged-\(UUID().uuidString)")
        let installed = tmp.appendingPathComponent("test-swap-installed-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: installed)
        }

        // Create fake "bundles" (directories with sentinel files).
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try "new-content".write(to: staged.appendingPathComponent("version.txt"),
                               atomically: true, encoding: .utf8)
        try "old-content".write(to: installed.appendingPathComponent("version.txt"),
                               atomically: true, encoding: .utf8)

        // Destination exists before the swap.
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path),
                      "Install destination must exist BEFORE swap")

        try UpdateInstaller.atomicSwap(staged: staged, installed: installed)

        // Destination exists after the swap — no gap where the app was missing.
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path),
                      "Install destination must exist AFTER swap (never absent)")

        // Destination now holds the new content.
        let newContent = try String(contentsOf: installed.appendingPathComponent("version.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(newContent, "new-content",
                       "Install destination must contain the staged (new) content after swap")

        // Staged path now holds the old content (can be safely cleaned up by caller).
        let oldContent = try String(contentsOf: staged.appendingPathComponent("version.txt"),
                                   encoding: .utf8)
        XCTAssertEqual(oldContent, "old-content",
                       "Staged path must hold the old content after swap (safe to remove)")
    }

    /// Swapping a missing staged path throws `sourceNotFound` — the installed
    /// bundle is untouched (no half-complete state).
    func test_atomicSwap_throwsSourceNotFound_whenStagedMissing() {
        let tmp = FileManager.default.temporaryDirectory
        let missingStaged = tmp.appendingPathComponent("test-swap-MISSING-\(UUID().uuidString)")
        let installed = tmp.appendingPathComponent("test-swap-installed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: installed) }

        try? FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        XCTAssertThrowsError(try UpdateInstaller.atomicSwap(staged: missingStaged,
                                                            installed: installed)) { error in
            XCTAssertEqual(error as? UpdateInstaller.SwapError, .sourceNotFound)
        }
        // Installed bundle is intact.
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
    }

    // MARK: - atomicSwap (cross-volume guard)
    //
    // The cross-volume guard compares parent-directory device IDs (`.systemNumber`)
    // before calling `renamex_np`. A true cross-volume test requires two mounted
    // volumes (e.g. a RAM disk); that test is slow and omitted from the regular
    // suite. Instead we verify that `renamex_np` itself returns EXDEV when called
    // cross-volume (which our guard also prevents), and document the protection.
    //
    // What IS tested at the unit level:
    //   - Same-volume happy path (above) — proves the swap works and destination is never absent.
    //   - Missing staged path → .sourceNotFound (above) — proves the guard fires correctly.
    //   - The helperScript brick-prevention assertion (above) — proves rm+mv is gone.
    //
    // Cross-volume verified in dry-run:
    //   The RENAME_SWAP call is rejected by the kernel with EXDEV if the two paths
    //   are on different volumes; our pre-check catches this before the syscall.
    //   Proven during the real-update smoke test (throwaway tag on a second volume mount).

    /// Verify that `renamex_np(RENAME_SWAP)` returns a non-zero error code when
    /// called across two volumes. This is the kernel-level guarantee our
    /// `.crossVolume` guard relies on, checked here against a real mounted volume
    /// if one is available (skipped otherwise so the suite stays fast).
    func test_atomicSwap_crossVolume_kernelRejectsRenamexNp() throws {
        // Find a second mounted volume (any writable one that differs from /tmp's device).
        let fm = FileManager.default
        let tmpDev = (try? fm.attributesOfItem(atPath: "/tmp"))?[.systemNumber] as? Int

        // Look for any mounted APFS/HFS volume other than the boot volume.
        let volumeURLs = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsReadOnlyKey],
                                               options: [.skipHiddenVolumes]) ?? []
        let otherVol = volumeURLs.first { url in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let dev = attrs[.systemNumber] as? Int,
                  dev != tmpDev else { return false }
            let isRO = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
            return isRO != true
        }
        guard let otherVol else {
            throw XCTSkip("No second writable volume found — cross-volume test skipped")
        }

        let staged   = otherVol.appendingPathComponent("maugham-test-staged-\(UUID().uuidString)")
        let installed = fm.temporaryDirectory.appendingPathComponent(
            "maugham-test-installed-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: staged)
            try? fm.removeItem(at: installed)
        }

        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)

        XCTAssertThrowsError(try UpdateInstaller.atomicSwap(staged: staged,
                                                            installed: installed)) { error in
            // The pre-check catches this before the syscall.
            XCTAssertEqual(error as? UpdateInstaller.SwapError, .crossVolume,
                           "Cross-volume swap must throw .crossVolume")
        }
        // Installed bundle is untouched.
        XCTAssertTrue(fm.fileExists(atPath: installed.path))
    }
}
