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
                      version: String = "0.43.0", updates: String = "/Updates",
                      swapTool: String = "/Applications/Maugham.app/Contents/Helpers/maugham-swap",
                      identifier: String = "com.maugham.Maugham") -> [String] {
        UpdateInstaller.helperArguments(
            scriptPath: "/script.sh", pid: pid, stagedBundle: staged, installedBundle: installed,
            expectedTeamID: team, relaunch: relaunch, version: version, updatesDirectory: updates,
            swapTool: swapTool, bundleIdentifier: identifier)
    }

    func test_helperArguments_areInTheOrderTheScriptReadsThem() {
        XCTAssertEqual(args(relaunch: true),
                       ["/script.sh", "4242", "/staged/Maugham.app", "/Applications/Maugham.app",
                        "ABCDE12345", "1", "0.43.0", "/Updates",
                        "/Applications/Maugham.app/Contents/Helpers/maugham-swap", "com.maugham.Maugham"])
        XCTAssertEqual(args(relaunch: false)[5], "0")
        let script = UpdateInstaller.helperScript()
        XCTAssertTrue(script.contains("[ \"$#\" -eq 9 ] || exit 2\n"), "exactly nine arguments")
        for (n, name) in ["PID", "STAGED", "INSTALLED", "TEAM", "RELAUNCH", "VERSION", "UPDATES",
                          "SWAP_TOOL", "IDENTIFIER"].enumerated() {
            XCTAssertTrue(script.contains("\(name)=\"$\(n + 1)\"\n"), "\(name) must be read from $\(n + 1)")
        }
    }

    /// F13: nothing the caller passes reaches the script text, so no path can
    /// be parsed as bash. The text is the same whatever the arguments are.
    func test_helperScript_isFixedTextThatCarriesNoArgument() {
        let hostile = args(pid: 77, staged: "/s/Mau\"g$(touch PWNED)`id`ham/Maugham.app",
                           installed: "/i/$(touch PWNED)/Maugham.app", team: "ZZZZZ99999",
                           relaunch: true, version: "9.9.9", updates: "/u/\"x\"",
                           swapTool: "/t/$(touch PWNED)/maugham-swap", identifier: "com.example.Other-App")
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
        // Every failure after the guard reopens before it exits: the copy,
        // the refusal, the volume that cannot swap, any other swap failure.
        let exits = script.components(separatedBy: "\n  exit 1\n").dropLast()
        XCTAssertEqual(exits.count, 4)
        for block in exits { XCTAssertTrue(block.hasSuffix("\n  reopen"), String(block.suffix(80))) }
    }

    /// Ensure the script uses the atomic swap mechanism, not the bricking rm+mv pattern.
    func test_helperScript_usesAtomicSwap_notRmMv() {
        let script = UpdateInstaller.helperScript()
        XCTAssertTrue(script.contains("\"$SWAP_TOOL\" \"$INFLIGHT\" \"$INSTALLED\" || SWAP_EXIT=$?\n"),
                      "Script must run the compiled swap tool on .inflight and the installed bundle")
        XCTAssertFalse(script.contains("python"), "the python3 swap is retired")
        XCTAssertFalse(script.contains(".bak"), "atomic or Finder: no non-atomic backup fallback")
        // The inflight sibling may be removed; the installed bundle never is.
        XCTAssertFalse(script.contains("rm -rf \"$INSTALLED\""),
                       "Script must not rm -rf the installed bundle — that leaves it missing on crash")
        XCTAssertFalse(script.contains("mv \"$INFLIGHT\""))
    }

    /// F12: the re-check sits after the app has gone and the copy is made, and
    /// before the swap; it names the team and runs spctl; a refusal removes
    /// the copy, records itself, and exits before the swap.
    func test_helperScript_reChecksTheInflightCopyBetweenTheWaitAndTheSwap() {
        let script = UpdateInstaller.helperScript()
        func at(_ needle: String) -> String.Index {
            guard let r = script.range(of: needle) else {
                XCTFail("expected \(needle) in script"); return script.endIndex
            }
            return r.lowerBound
        }
        let requirement = #"--test-requirement="=identifier \"$IDENTIFIER\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$INFLIGHT""#
        let wait = at("while kill -0"), copy = at("\"/usr/bin/ditto\" \"$STAGED\"")
        let codesign = at("\"/usr/bin/codesign\" --verify --deep --strict " + requirement)
        let spctl = at("\"/usr/sbin/spctl\" -a -t exec \"$INFLIGHT\"")
        let refused = at("record \"refused $VERSION\"")
        let swap = at("\"$SWAP_TOOL\" \"$INFLIGHT\"")
        XCTAssertTrue(wait < copy && copy < codesign && codesign < spctl && spctl < refused && refused < swap)
        // The version is read off the copy after spctl, inside the same refusal.
        let versionCheck = at(#"|| [ "$("/usr/libexec/PlistBuddy" -c 'Print :CFBundleShortVersionString' "$INFLIGHT/Contents/Info.plist" 2>/dev/null)" != "$VERSION" ]; then"#)
        XCTAssertTrue(spctl < versionCheck && versionCheck < refused)
        let refusalBlock = String(script[refused...]).components(separatedBy: "\nfi\n")[0]
        XCTAssertTrue(refusalBlock.hasSuffix("exit 1"), refusalBlock)
        XCTAssertTrue(script[spctl..<refused].contains("rm -rf \"$INFLIGHT\""))
    }

    /// The tool paths are the only interpolated values; they must be inert.
    func test_helperToolPaths_arePlainAbsolutePaths() {
        let system = UpdateInstaller.HelperTools.system
        XCTAssertEqual(system.plistBuddy, "/usr/libexec/PlistBuddy")
        for path in [system.codesign, system.spctl, system.ditto, system.open, system.plistBuddy] {
            XCTAssertTrue(UpdateInstaller.HelperTools.isSafePath(path), path)
        }
        for bad in ["usr/bin/x", "/a b", "/a\"b", "/a$(b)", "/a`b`", "/a;b", ""] {
            XCTAssertFalse(UpdateInstaller.HelperTools.isSafePath(bad), bad)
        }
    }

    func test_bundleIdentifierValidation() {
        for good in ["com.maugham.Maugham", "com.maugham.Maugham.dev", "a-b.C9"] {
            XCTAssertTrue(UpdateInstaller.isWellFormedBundleIdentifier(good), good)
        }
        for bad in ["", "com.maugham.Maugham\"", "com maugham", "com.$(x)", "com.x`id`", "com.é", "com/x", "com_x"] {
            XCTAssertFalse(UpdateInstaller.isWellFormedBundleIdentifier(bad), bad)
        }
    }

    // MARK: - decideIdentity: which app, at which version

    private let stable = "com.maugham.Maugham"

    func test_decideIdentity_acceptsThisAppAtThisVersion() {
        XCTAssertEqual(UpdateInstaller.decideIdentity(
            stagedInfo: ["CFBundleIdentifier": stable, "CFBundleShortVersionString": "0.43.0"],
            expectedBundleIdentifier: stable, expectedVersion: "0.43.0"), .accept)
        // A dry-run build (patch >= 90) carries its tag's version like any other.
        XCTAssertEqual(UpdateInstaller.decideIdentity(
            stagedInfo: ["CFBundleIdentifier": stable, "CFBundleShortVersionString": "0.43.90"],
            expectedBundleIdentifier: stable, expectedVersion: "0.43.90"), .accept)
    }

    func test_decideIdentity_rejectsAMissingInfoPlist() {
        XCTAssertEqual(UpdateInstaller.decideIdentity(stagedInfo: nil, expectedBundleIdentifier: stable,
                                                      expectedVersion: "0.43.0"),
                       .reject(reason: "Missing Info.plist"))
    }

    func test_decideIdentity_rejectsAnotherApp() {
        for info: [String: Any] in [["CFBundleIdentifier": "com.example.OtherApp", "CFBundleShortVersionString": "0.43.0"],
                                    ["CFBundleIdentifier": "com.maugham.Maugham.dev", "CFBundleShortVersionString": "0.43.0"],
                                    ["CFBundleShortVersionString": "0.43.0"],
                                    ["CFBundleIdentifier": 42, "CFBundleShortVersionString": "0.43.0"]] {
            XCTAssertEqual(UpdateInstaller.decideIdentity(stagedInfo: info, expectedBundleIdentifier: stable,
                                                          expectedVersion: "0.43.0"),
                           .reject(reason: "Bundle identifier mismatch"), "\(info)")
        }
        // The running app's identifier missing (nil → "") never matches.
        XCTAssertEqual(UpdateInstaller.decideIdentity(
            stagedInfo: ["CFBundleIdentifier": "", "CFBundleShortVersionString": "0.43.0"],
            expectedBundleIdentifier: "", expectedVersion: "0.43.0"),
            .reject(reason: "Bundle identifier mismatch"))
    }

    func test_decideIdentity_rejectsAnotherVersion() {
        for version: Any? in ["0.42.0", "0.43.1", "v0.43.0", "0.0.0-dev", nil] {
            var info: [String: Any] = ["CFBundleIdentifier": stable]
            if let version { info["CFBundleShortVersionString"] = version }
            XCTAssertEqual(UpdateInstaller.decideIdentity(stagedInfo: info, expectedBundleIdentifier: stable,
                                                          expectedVersion: "0.43.0"),
                           .reject(reason: "Version mismatch"), "\(String(describing: version))")
        }
    }

    /// A zip holding `Maugham.app` with this Info.plist (none when nil).
    private func makeAppZip(info: [String: Any]?, version: String = "9.9.9") throws -> (zip: URL, updates: URL) {
        let updates = TestTemp.root.appendingPathComponent("Updates", isDirectory: true)
        let payload = TestTemp.root.appendingPathComponent("app-payload-\(UUID().uuidString)", isDirectory: true)
        let contents = payload.appendingPathComponent("Maugham.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let info {
            XCTAssertTrue((info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        } else {
            try Data("x".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        }
        let zip = updates.appendingPathComponent("Maugham-\(version).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", payload.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        return (zip, updates)
    }

    private func stage(_ zip: URL, version: String = "9.9.9") throws -> URL {
        try UpdateInstaller.stageAndVerifySync(
            zip: zip, version: version, availableBytes: { _ in 100 * 1024 * 1024 * 1024 },
            verifyBundle: { _ in VerificationVerdict(codesignValid: true, notarized: true, teamID: "ABCDE12345") },
            expectedTeamID: { "ABCDE12345" }, expectedBundleIdentifier: stable)
    }

    /// Staging runs `decideIdentity` after the team check, through the same
    /// `verifyFailed` path that discards the archive.
    func test_stagingRefusesAnotherAppOrVersion_andDiscardsTheArchive() throws {
        let cases: [([String: Any]?, String)] = [
            (["CFBundleIdentifier": "com.example.OtherApp", "CFBundleShortVersionString": "9.9.9"], "Bundle identifier mismatch"),
            (["CFBundleIdentifier": stable, "CFBundleShortVersionString": "9.9.8"], "Version mismatch"),
            (nil, "Missing Info.plist"),
        ]
        for (info, reason) in cases {
            let (zip, updates) = try makeAppZip(info: info)
            XCTAssertThrowsError(try stage(zip)) { error in
                guard case .verifyFailed(let why)? = error as? UpdateInstaller.InstallError
                else { return XCTFail("expected .verifyFailed, got \(error)") }
                XCTAssertEqual(why, reason)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path), reason)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: updates.appendingPathComponent("staged-9.9.9").path), reason)
        }
    }

    func test_stagingAcceptsThisAppAtThisVersion() throws {
        let (zip, updates) = try makeAppZip(info: ["CFBundleIdentifier": stable, "CFBundleShortVersionString": "9.9.9"])
        let bundle = try stage(zip)
        XCTAssertEqual(bundle.path, updates.appendingPathComponent("staged-9.9.9/Maugham.app").path)
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

    /// The swap tool argument is validated — absolute, a regular executable
    /// file — BEFORE the quit-wait and before every destructive step, so a
    /// bad one stops the helper with the running app untouched.
    func test_helperScript_swapToolIsValidatedBeforeAnyStep() {
        let script = UpdateInstaller.helperScript()
        guard let check = script.range(of: "[ -f \"$SWAP_TOOL\" ] && [ -x \"$SWAP_TOOL\" ] || exit 2")?.lowerBound,
              let absolute = script.range(of: "\"$UPDATES\" \"$SWAP_TOOL\"; do [ \"${p#/}\" != \"$p\" ] || exit 2")?.lowerBound
        else { return XCTFail("the swap tool must be checked for an absolute executable file") }
        for step in ["while kill -0", "ditto", "rm -rf", "codesign", "\"$SWAP_TOOL\" \""] {
            guard let at = script.range(of: step)?.lowerBound else { XCTFail("expected \(step)"); continue }
            XCTAssertTrue(check < at && absolute < at, "the swap tool check must come before `\(step)`")
        }
    }

    /// A volume that cannot swap is its own recorded step, and the copy goes;
    /// any other swap failure keeps `.inflight`.
    func test_helperScript_recordsAVolumeThatCannotSwapAsItsOwnStep() {
        let script = UpdateInstaller.helperScript()
        let unsupported = "if [ \"$SWAP_EXIT\" -eq 3 ]; then\n  rm -rf \"$INFLIGHT\" || true\n"
            + "  record \"failed $VERSION swap-unsupported\" || true\n  reopen\n  exit 1\nfi\n"
        let other = "if [ \"$SWAP_EXIT\" -ne 0 ]; then\n  record \"failed $VERSION swap\" || true\n"
            + "  reopen\n  exit 1\nfi\n"
        XCTAssertTrue(script.contains(unsupported), script)
        XCTAssertTrue(script.contains(other), script)
        XCTAssertEqual(UpdateInstaller.swapUnsupportedExitCode, 3)
    }

    // MARK: - installMode

    /// An executable regular file under the test root, standing in for the
    /// running app's swap tool.
    private func executableTool(mode: Int = 0o755) throws -> URL {
        let tool = TestTemp.root.appendingPathComponent("Helpers/maugham-swap")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tool.path)
        return tool
    }

    private func mode(isWritable: @escaping (String) -> Bool = { _ in true },
                      swapTool: URL?, volumeSupportsSwap: Bool = true) -> InstallMode {
        UpdateInstaller.installMode(installedBundlePath: "/Applications/Maugham.app",
                                    isWritable: isWritable, swapTool: { swapTool },
                                    volumeSupportsSwap: { _ in volumeSupportsSwap })
    }

    func test_installMode_inPlaceWhenWritable() throws {
        XCTAssertEqual(mode(swapTool: try executableTool()), .inPlace)
    }

    func test_installMode_finderFallbackWhenNotWritable() throws {
        XCTAssertEqual(mode(isWritable: { _ in false }, swapTool: try executableTool()), .finderFallback)
    }

    /// New-4: the helper creates `.inflight` beside the bundle, so a writable
    /// bundle in an unwritable folder is not installable in place.
    func test_installMode_finderFallbackWhenTheFolderIsNotWritable() throws {
        XCTAssertEqual(mode(isWritable: { $0 != "/Applications" }, swapTool: try executableTool()),
                       .finderFallback)
    }

    func test_installMode_finderFallbackWithoutTheSwapTool() throws {
        XCTAssertEqual(mode(swapTool: nil), .finderFallback, "no tool at all")
        XCTAssertEqual(mode(swapTool: TestTemp.root.appendingPathComponent("no-such-tool")), .finderFallback,
                       "a tool path with nothing there")
    }

    func test_installMode_finderFallbackWhenTheSwapToolIsNotExecutable() throws {
        XCTAssertEqual(mode(swapTool: try executableTool(mode: 0o644)), .finderFallback)
        let directory = TestTemp.root.appendingPathComponent("a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(mode(swapTool: directory), .finderFallback, "a directory is not a tool")
    }

    /// Atomic or Finder, nothing in between.
    func test_installMode_finderFallbackOnAVolumeThatCannotSwap() throws {
        XCTAssertEqual(mode(swapTool: try executableTool(), volumeSupportsSwap: false), .finderFallback)
    }

    /// The probe reads the folder's volume; the test root is on APFS, which swaps.
    func test_theVolumeProbeSaysYesForTheTestRootsVolume_andNoOnceAFailureIsRemembered() throws {
        let suite = "UpdateInstallerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(UpdateInstaller.volumeSupportsSwapRenaming(at: TestTemp.root, defaults: defaults))
        NoSwapVolumeMemory.remember(folder: TestTemp.root, defaults: defaults)
        XCTAssertFalse(UpdateInstaller.volumeSupportsSwapRenaming(at: TestTemp.root, defaults: defaults),
                       "after a swap-unsupported failure, never in place on that volume again")
    }

    /// The default tool is the running app's own (`Contents/Helpers`), which
    /// every build embeds — the test host included.
    func test_theRunningAppCarriesItsSwapTool() throws {
        let tool = try XCTUnwrap(UpdateInstaller.swapToolURL(),
                                 "the app bundle must embed \(UpdateInstaller.swapToolRelativePath)")
        XCTAssertEqual(tool.path, Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/maugham-swap").path)
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
