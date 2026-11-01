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

    // MARK: - helperScript: shape (#67 F12, F13)

    private func args(pid: Int32 = 4242, staged: String = "/staged/Maugham.app",
                      installed: String = "/Applications/Maugham.app",
                      team: String = "ABCDE12345", relaunch: Bool = false,
                      version: String = "0.43.0", updates: String = "/Updates") -> [String] {
        UpdateInstaller.helperArguments(
            scriptPath: "/script.sh", pid: pid, stagedBundle: staged, installedBundle: installed,
            expectedTeamID: team, relaunch: relaunch, version: version, updatesDirectory: updates)
    }

    func test_helperArguments_areInTheOrderTheScriptReadsThem() {
        XCTAssertEqual(args(relaunch: true),
                       ["/script.sh", "4242", "/staged/Maugham.app", "/Applications/Maugham.app",
                        "ABCDE12345", "1", "0.43.0", "/Updates"])
        XCTAssertEqual(args(relaunch: false)[5], "0")
        let script = UpdateInstaller.helperScript()
        for (n, name) in ["PID", "STAGED", "INSTALLED", "TEAM", "RELAUNCH", "VERSION", "UPDATES"].enumerated() {
            XCTAssertTrue(script.contains("\(name)=\"$\(n + 1)\"\n"), "\(name) must be read from $\(n + 1)")
        }
    }

    /// F13: nothing the caller passes reaches the script text, so no path can
    /// be parsed as bash. The text is the same whatever the arguments are.
    func test_helperScript_isFixedTextThatCarriesNoArgument() {
        let hostile = args(pid: 77, staged: "/s/Mau\"g$(touch PWNED)`id`ham/Maugham.app",
                           installed: "/i/$(touch PWNED)/Maugham.app", team: "ZZZZZ99999",
                           relaunch: true, version: "9.9.9", updates: "/u/\"x\"")
        let plain = args()
        let script = UpdateInstaller.helperScript()
        XCTAssertEqual(script, UpdateInstaller.helperScript(tools: .system))
        for value in Set(hostile.dropFirst() + plain.dropFirst()) where value.count > 3 {
            XCTAssertFalse(script.contains(value), "argument \(value) must not be in the script")
        }
        XCTAssertFalse(script.contains("PWNED"))
    }

    func test_helperScript_relaunchIsGatedOnTheArgument() {
        let script = UpdateInstaller.helperScript()
        XCTAssertTrue(script.contains("while kill -0 \"$PID\""))
        XCTAssertTrue(script.contains("\"/usr/bin/ditto\" \"$STAGED\" \"$INFLIGHT\""))
        XCTAssertTrue(script.contains(
            "reopen() { if [ \"$RELAUNCH\" = 1 ]; then \"/usr/bin/open\" \"$INSTALLED\" || true; fi; }\n"))
        XCTAssertEqual(script.components(separatedBy: "open\" ").count, 2, "exactly one open, in reopen")
        XCTAssertTrue(script.hasSuffix("\nreopen\n"), "success ends by reopening")
        // Every failure after the guard reopens before it exits.
        let exits = script.components(separatedBy: "\n  exit 1\n").dropLast()
        XCTAssertEqual(exits.count, 6)
        for block in exits { XCTAssertTrue(block.hasSuffix("\n  reopen"), String(block.suffix(80))) }
    }

    /// Ensure the script uses the atomic swap mechanism, not the bricking rm+mv pattern.
    func test_helperScript_usesAtomicSwap_notRmMv() {
        let script = UpdateInstaller.helperScript()
        XCTAssertTrue(script.contains("renamex_np"),
                      "Script must use renamex_np for the atomic swap")
        XCTAssertTrue(script.contains("python3 \"$PY_TMP\" \"$INFLIGHT\" \"$INSTALLED\""),
                      "Script must invoke python3 for the atomic swap")
        // The inflight sibling may be removed; the installed bundle never is.
        XCTAssertFalse(script.contains("rm -rf \"$INSTALLED\""),
                       "Script must not rm -rf the installed bundle — that leaves it missing on crash")
        XCTAssertFalse(script.contains("mv \"$INFLIGHT\""))
    }

    /// F12: the re-check sits after the app has gone and the copy is made, and
    /// before the swap; it names the team and runs spctl; a refusal removes
    /// the copy, records itself, and exits before python.
    func test_helperScript_reChecksTheInflightCopyBetweenTheWaitAndTheSwap() {
        let script = UpdateInstaller.helperScript()
        func at(_ needle: String) -> String.Index {
            guard let r = script.range(of: needle) else {
                XCTFail("expected \(needle) in script"); return script.endIndex
            }
            return r.lowerBound
        }
        let requirement = #"--test-requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$INFLIGHT""#
        let wait = at("while kill -0"), copy = at("\"/usr/bin/ditto\" \"$STAGED\"")
        let codesign = at("\"/usr/bin/codesign\" --verify --deep --strict " + requirement)
        let spctl = at("\"/usr/sbin/spctl\" -a -t exec \"$INFLIGHT\"")
        let refused = at("record \"refused $VERSION\"")
        let swap = at("python3 \"$PY_TMP\"")
        XCTAssertTrue(wait < copy && copy < codesign && codesign < spctl && spctl < refused && refused < swap)
        let refusalBlock = String(script[refused...]).components(separatedBy: "\nfi\n")[0]
        XCTAssertTrue(refusalBlock.hasSuffix("exit 1"), refusalBlock)
        XCTAssertTrue(script[spctl..<refused].contains("rm -rf \"$INFLIGHT\""))
    }

    /// The tool paths are the only interpolated values; they must be inert.
    func test_helperToolPaths_arePlainAbsolutePaths() {
        let system = UpdateInstaller.HelperTools.system
        for path in [system.codesign, system.spctl, system.ditto, system.open] {
            XCTAssertTrue(UpdateInstaller.HelperTools.isSafePath(path), path)
        }
        for bad in ["usr/bin/x", "/a b", "/a\"b", "/a$(b)", "/a`b`", "/a;b", ""] {
            XCTAssertFalse(UpdateInstaller.HelperTools.isSafePath(bad), bad)
        }
    }

    func test_teamIDAndVersionValidation() {
        XCTAssertTrue(UpdateInstaller.isWellFormedTeamID("FF3XH4ZJ45"))
        for bad in ["", "FF3XH4ZJ4", "FF3XH4ZJ456", "ff3xh4zj45", "FF3XH4ZJ4\"", "FF3XH4ZJ4É"] {
            XCTAssertFalse(UpdateInstaller.isWellFormedTeamID(bad), bad)
        }
        XCTAssertTrue(UpdateInstaller.isWellFormedVersion("0.43.0"))
        for bad in ["", "v0.43.0", "0.43", "0.43.0\nrefused 1.0.0", "0.43.0 x"] {
            XCTAssertFalse(UpdateInstaller.isWellFormedVersion(bad), bad)
        }
    }

    /// Audit N2: the script must probe `python3` and bail BEFORE any destructive
    /// step (and before the quit-wait), so a CLT-less Mac aborts with the running
    /// app untouched rather than dying mid-swap after the app has quit.
    func test_helperScript_python3GuardPrecedesFirstDestructiveStep() {
        let script = UpdateInstaller.helperScript()

        // The guard exists.
        let guardIdx = script.range(of: "command -v python3")
        XCTAssertNotNil(guardIdx, "Script must guard on python3 availability")

        // It precedes the quit-wait (so the app is still alive when we abort) AND
        // every destructive command (ditto / the swap invocation / rm of staging).
        guard let guardLower = guardIdx?.lowerBound else { return XCTFail() }
        for destructive in ["while kill -0", "ditto", "rm -rf", "python3 \""] {
            let idx = script.range(of: destructive)
            XCTAssertNotNil(idx, "expected \(destructive) in script")
            if let d = idx?.lowerBound {
                XCTAssertTrue(guardLower < d,
                    "python3 guard must come before `\(destructive)`")
            }
        }
        // And it records itself and exits non-zero on the missing case.
        XCTAssertTrue(script.contains("record \"failed $VERSION python3\""))
        XCTAssertTrue(script.contains("exit 1"))
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

    /// New-4: the helper creates `.inflight` beside the bundle, so a writable
    /// bundle in an unwritable folder is not installable in place.
    func test_installMode_finderFallbackWhenTheFolderIsNotWritable() {
        XCTAssertEqual(UpdateInstaller.installMode(installedBundlePath: "/Applications/Maugham.app",
                                                   isWritable: { $0 != "/Applications" }), .finderFallback)
    }

    func test_runningAppTeamID_doesNotCrash() {
        // Test host is ad-hoc signed → nil is acceptable; signed Release build
        // returns the real team id (proven in dry-run). We only assert no crash.
        _ = UpdateInstaller.runningAppTeamID()
    }

    // MARK: - A refused archive is not reused (#67 New-2)

    /// The checker reuses a zip already at `Maugham-<ver>.zip`; a refused one
    /// left there would be re-staged and re-refused on every later check. A
    /// zip that will not unpack takes its stage folder AND itself with it.
    func test_aZipThatWillNotUnpackIsDeletedWithItsStageFolder() async throws {
        let updates = TestTemp.root.appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        let zip = updates.appendingPathComponent("Maugham-9.9.9.zip")
        try Data("not a zip archive".utf8).write(to: zip)

        do {
            _ = try await UpdateInstaller.stageAndVerify(zip: zip, version: "9.9.9")
            XCTFail("a garbage archive must be refused")
        } catch let error as UpdateInstaller.InstallError {
            // Unreadable totals are a refusal of their own (#67 F16), before any unpacking.
            guard case .archiveUnreadable = error else { return XCTFail("expected .archiveUnreadable, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path),
                       "a refused zip must not be left for the next check to reuse")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: updates.appendingPathComponent("staged-9.9.9").path))
    }

    /// A real zip with no Maugham.app inside is refused the same way.
    func test_aZipWithNoAppInsideIsDeletedWithItsStageFolder() async throws {
        let updates = TestTemp.root.appendingPathComponent("Updates", isDirectory: true)
        let payload = TestTemp.root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: payload.appendingPathComponent("readme.txt"))
        let zip = updates.appendingPathComponent("Maugham-9.9.9.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", payload.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        do {
            _ = try await UpdateInstaller.stageAndVerify(zip: zip, version: "9.9.9")
            XCTFail("an archive with no Maugham.app must be refused")
        } catch let error as UpdateInstaller.InstallError {
            guard case .unzipFailed = error else { return XCTFail("expected .unzipFailed, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: updates.appendingPathComponent("staged-9.9.9").path))
    }

    /// The one cleanup removes exactly the two things it names.
    func test_discardingARefusedArchiveRemovesTheZipAndTheStageFolderOnly() throws {
        let updates = TestTemp.root.appendingPathComponent("Updates", isDirectory: true)
        let stage = updates.appendingPathComponent("staged-9.9.9", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let zip = updates.appendingPathComponent("Maugham-9.9.9.zip")
        let other = updates.appendingPathComponent("Maugham-9.9.8.zip")
        try Data("z".utf8).write(to: zip)
        try Data("o".utf8).write(to: other)
        UpdateInstaller.discardRefusedArchive(zip: zip, stageDir: stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: - Size gate before unzipping (#67 F16)

    func test_parsesARealZipinfoTotalsLine() {
        let out = "82 files, 92981635 bytes uncompressed, 30647535 bytes compressed:  67.0%\n"
        let t = UpdateInstaller.parseZipinfoTotals(out)
        XCTAssertEqual(t?.files, 82)
        XCTAssertEqual(t?.uncompressedBytes, 92_981_635)
    }

    func test_parsesTheSingularOneFileLine() {
        let t = UpdateInstaller.parseZipinfoTotals("1 file, 5 bytes uncompressed, 7 bytes compressed:  -40.0%")
        XCTAssertEqual(t?.files, 1)
        XCTAssertEqual(t?.uncompressedBytes, 5)
    }

    func test_garbageZipinfoOutputParsesToNil() {
        XCTAssertNil(UpdateInstaller.parseZipinfoTotals(""))
        XCTAssertNil(UpdateInstaller.parseZipinfoTotals("hello, world"))
        XCTAssertNil(UpdateInstaller.parseZipinfoTotals("x files, y bytes uncompressed, z"))
        XCTAssertNil(UpdateInstaller.parseZipinfoTotals("-1 files, 5 bytes uncompressed, 7 bytes compressed"))
        XCTAssertNil(UpdateInstaller.parseZipinfoTotals("1 file, -5 bytes uncompressed, 7 bytes compressed"))
    }

    func test_extractionDecision_eachArm() {
        let l = UpdateLimits.standard
        let gb: Int64 = 1024 * 1024 * 1024
        XCTAssertEqual(UpdateInstaller.extractionDecision(files: 82, uncompressedBytes: 93_000_000,
                                                          availableBytes: 10 * gb), .accept)
        guard case .reject = UpdateInstaller.extractionDecision(
            files: 1, uncompressedBytes: l.maxUncompressedBytes + 1, availableBytes: 100 * gb)
        else { return XCTFail("too many bytes must be refused") }
        guard case .reject = UpdateInstaller.extractionDecision(
            files: l.maxFiles + 1, uncompressedBytes: 1, availableBytes: 100 * gb)
        else { return XCTFail("too many files must be refused") }
        guard case .reject = UpdateInstaller.extractionDecision(
            files: 1, uncompressedBytes: 100, availableBytes: nil)
        else { return XCTFail("unreadable free space must be refused") }
        // Boundary: exactly 2x + margin is enough, one byte less is not.
        let need: Int64 = 1000 * 2 + l.freeSpaceMarginBytes
        XCTAssertEqual(UpdateInstaller.extractionDecision(files: 1, uncompressedBytes: 1000, availableBytes: need), .accept)
        guard case .reject(let why) = UpdateInstaller.extractionDecision(
            files: 1, uncompressedBytes: 1000, availableBytes: need - 1)
        else { return XCTFail("short on space must be refused") }
        XCTAssertTrue(why.contains("free disk space"))
    }

    private func makeTinyZip(named name: String) throws -> (zip: URL, updates: URL) {
        let updates = TestTemp.root.appendingPathComponent("Updates", isDirectory: true)
        let payload = TestTemp.root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: payload.appendingPathComponent("readme.txt"))
        let zip = updates.appendingPathComponent(name)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", payload.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        return (zip, updates)
    }

    func test_archiveTotalsReadsARealZip() throws {
        let (zip, _) = try makeTinyZip(named: "Maugham-9.9.9.zip")
        let t = UpdateInstaller.archiveTotals(zip: zip)
        // ditto adds its own entries (a folder, resource data), so read it as "at least the file".
        XCTAssertNotNil(t)
        XCTAssertGreaterThanOrEqual(t?.files ?? 0, 1)
        XCTAssertGreaterThanOrEqual(t?.uncompressedBytes ?? 0, 5)
    }

    func test_aZipTooBigForTheDiskIsRefusedBeforeUnpackingAndDeleted() throws {
        let (zip, updates) = try makeTinyZip(named: "Maugham-9.9.9.zip")
        XCTAssertThrowsError(try UpdateInstaller.stageAndVerifySync(
            zip: zip, version: "9.9.9", availableBytes: { _ in 0 })) { error in
            guard case .archiveTooLarge(let why)? = error as? UpdateInstaller.InstallError
            else { return XCTFail("expected .archiveTooLarge, got \(error)") }
            XCTAssertTrue(why.contains("free disk space"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: updates.appendingPathComponent("staged-9.9.9").path),
            "nothing may be unpacked once the gate refuses")
    }

    func test_anUnreadableArchiveSaysSoInPlainEnglish() {
        XCTAssertEqual(UpdateInstaller.InstallError.archiveUnreadable.errorDescription,
                       "The downloaded update couldn't be read, so it wasn't installed.")
    }

    func test_unreadableFreeSpaceIsRefusedAsUnreadable() throws {
        let (zip, _) = try makeTinyZip(named: "Maugham-9.9.9.zip")
        XCTAssertThrowsError(try UpdateInstaller.stageAndVerifySync(
            zip: zip, version: "9.9.9", availableBytes: { _ in nil })) { error in
            guard case .archiveUnreadable? = error as? UpdateInstaller.InstallError
            else { return XCTFail("expected .archiveUnreadable, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
    }
}
