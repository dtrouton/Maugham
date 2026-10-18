import XCTest
@testable import Maugham

/// Runs the real swap helper (`UpdateInstaller.helperScript`) with `/bin/bash`,
/// synchronously, against fake bundles under `TestTemp.root` (#67 F12, F13).
/// `codesign` and `spctl` are stub scripts that log their arguments and exit
/// 0 or 1, so no signed app and no network is needed; `ditto` and `python3`
/// (the `renamex_np` swap) are the real ones. The pid is one that has already
/// exited, so the quit-wait falls straight through.
///
/// What this cannot prove: that launchd adopts the helper when the app quits.
/// That is still the real-update smoke (`Maugham/Updates/AREA.md`).
final class UpdateSwapHelperEndToEndTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let staged: URL
        let installed: URL
        let updates: URL
        let codesignLog: URL
        let openLog: URL
        let tools: UpdateInstaller.HelperTools
        var status: URL { updates.appendingPathComponent(UpdateInstaller.installStatusFileName) }
        var inflight: URL { URL(fileURLWithPath: installed.path + ".inflight") }
        /// Each `open` call's arguments, one per line; nil if `open` never ran.
        var opened: [String]? {
            (try? String(contentsOf: openLog, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    private let version = "0.43.0"
    private let team = "ABCDE12345"

    override func setUpWithError() throws {
        guard UpdateInstaller.python3Available() else {
            throw XCTSkip("python3 is not on PATH; the helper's swap needs it")
        }
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func makeFixture(stagedParent: String = "staged", installedParent: String = "Applications",
                             codesignExit: Int, spctlExit: Int) throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("helper-e2e", isDirectory: true)
        let staged = root.appendingPathComponent(stagedParent).appendingPathComponent("Maugham.app")
        let installed = root.appendingPathComponent(installedParent).appendingPathComponent("Maugham.app")
        let updates = root.appendingPathComponent("Updates", isDirectory: true)
        try write("new", to: staged.appendingPathComponent("Contents/marker"))
        try write("old", to: installed.appendingPathComponent("Contents/marker"))
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        let toolsDir = root.appendingPathComponent("tools", isDirectory: true)
        let codesignLog = toolsDir.appendingPathComponent("codesign.log")
        let codesign = toolsDir.appendingPathComponent("codesign")
        let spctl = toolsDir.appendingPathComponent("spctl")
        let openLog = toolsDir.appendingPathComponent("open.log")
        let open = toolsDir.appendingPathComponent("open")
        try write("#!/bin/bash\nprintf '%s\\n' \"$@\" >> \"\(openLog.path)\"\n",
                  to: open, executable: true)
        try write("#!/bin/bash\nprintf '%s\\n' \"$@\" > \"\(codesignLog.path)\"\nexit \(codesignExit)\n",
                  to: codesign, executable: true)
        try write("#!/bin/bash\nexit \(spctlExit)\n", to: spctl, executable: true)
        return Fixture(root: root, staged: staged, installed: installed, updates: updates,
                       codesignLog: codesignLog, openLog: openLog,
                       tools: .init(codesign: codesign.path, spctl: spctl.path, ditto: "/usr/bin/ditto",
                                    open: open.path))
    }

    private func exitedPid() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    @discardableResult
    private func runHelper(_ f: Fixture, relaunch: Bool = false, team: String? = nil) throws -> Int32 {
        let script = f.root.appendingPathComponent("helper.sh")
        try write(UpdateInstaller.helperScript(tools: f.tools), to: script)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = UpdateInstaller.helperArguments(
            scriptPath: script.path, pid: try exitedPid(),
            stagedBundle: f.staged.path, installedBundle: f.installed.path,
            expectedTeamID: team ?? self.team, relaunch: relaunch, version: version,
            updatesDirectory: f.updates.path)
        // A `$(touch PWNED)` that ran would land here, inside the test root.
        p.currentDirectoryURL = f.root
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        // A reused pid would park the quit-wait; never hang the gate on it.
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            XCTFail("the helper did not finish within 10 s (was the exited pid reused?)")
        }
        return p.terminationStatus
    }

    private func marker(_ bundle: URL) -> String? {
        try? String(contentsOf: bundle.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func test_anAcceptedCopyIsSwappedIn_andNothingIsRecorded() throws {
        let f = try makeFixture(codesignExit: 0, spctlExit: 0)
        XCTAssertEqual(try runHelper(f), 0)
        XCTAssertEqual(marker(f.installed), "new")
        XCTAssertNil(f.opened, "relaunch 0 opens nothing")
        XCTAssertFalse(exists(f.inflight), "the old bundle left at .inflight is removed")
        XCTAssertFalse(exists(f.status), "success writes no status")
        XCTAssertEqual(marker(f.staged), "new", "the staged copy is copied, never moved")
        // codesign was asked about the .inflight copy, against our team.
        let logged = try String(contentsOf: f.codesignLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(logged, ["--verify", "--deep", "--strict",
                                "--test-requirement==anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"",
                                f.inflight.path])
    }

    func test_aCopyCodesignRefuses_isNeverSwappedIn_andTheRefusalIsRecorded() throws {
        let f = try makeFixture(codesignExit: 3, spctlExit: 0)
        let before = try Data(contentsOf: f.installed.appendingPathComponent("Contents/marker"))
        XCTAssertEqual(try runHelper(f, relaunch: true), 1)
        XCTAssertEqual(try Data(contentsOf: f.installed.appendingPathComponent("Contents/marker")), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.installed.path), ["Contents"])
        XCTAssertFalse(exists(f.inflight), "a refused copy is removed")
        XCTAssertEqual(try String(contentsOf: f.status, encoding: .utf8), "refused \(version)\n")
        // "Restart & Update" quit the app: the OLD app is reopened, by its path alone.
        XCTAssertEqual(f.opened, [f.installed.path])
    }

    func test_anAcceptedCopyWithRelaunch_opensTheInstalledPath() throws {
        let f = try makeFixture(codesignExit: 0, spctlExit: 0)
        XCTAssertEqual(try runHelper(f, relaunch: true), 0)
        XCTAssertEqual(marker(f.installed), "new")
        XCTAssertEqual(f.opened, [f.installed.path])
    }

    func test_aCopySpctlRefuses_isNeverSwappedIn_andTheRefusalIsRecorded() throws {
        let f = try makeFixture(codesignExit: 0, spctlExit: 1)
        XCTAssertEqual(try runHelper(f), 1)
        XCTAssertEqual(marker(f.installed), "old")
        XCTAssertNil(f.opened, "an ordinary quit is not reopened, refused or not")
        XCTAssertFalse(exists(f.inflight))
        XCTAssertEqual(try String(contentsOf: f.status, encoding: .utf8), "refused \(version)\n")
    }

    func test_aCopyThatFails_isRecordedWithItsStep_andOverwritesAnOlderLine() throws {
        let f = try makeFixture(codesignExit: 0, spctlExit: 0)
        try write("refused 0.42.0\nstale second line\n", to: f.status)
        try FileManager.default.removeItem(at: f.staged)  // nothing to copy
        XCTAssertEqual(try runHelper(f, relaunch: true), 1)
        XCTAssertEqual(marker(f.installed), "old")
        XCTAssertEqual(f.opened, [f.installed.path], "the old app comes back")
        XCTAssertFalse(exists(f.inflight))
        XCTAssertEqual(try String(contentsOf: f.status, encoding: .utf8), "failed \(version) ditto\n")
        XCTAssertFalse(exists(f.updates.appendingPathComponent("install-status.tmp")))
    }

    /// The script re-validates the team Swift validated: one that would be
    /// live inside the requirement string stops it before anything is touched.
    func test_aMalformedTeam_stopsTheHelperBeforeAnyStep() throws {
        let f = try makeFixture(codesignExit: 0, spctlExit: 0)
        for bad in ["ABCDE1234\"", "abcde12345", "ABCDE1234", "ABCDE\\(x)"] {
            XCTAssertEqual(try runHelper(f, team: bad), 2, bad)
            XCTAssertEqual(marker(f.installed), "old")
            XCTAssertFalse(exists(f.inflight))
            XCTAssertFalse(exists(f.status))
            XCTAssertFalse(exists(f.codesignLog), "codesign never ran")
            XCTAssertNil(f.opened)
        }
    }

    /// F13: a path carrying `"`, `$(…)` and a backtick is data. The swap
    /// happens, and nothing in the names runs.
    func test_hostileDirectoryNames_installAndExecuteNothing() throws {
        let f = try makeFixture(stagedParent: "Mau\"g$(touch PWNED)ham `touch PWNED`",
                                installedParent: "App \"$(touch PWNED)\" `touch PWNED` x",
                                codesignExit: 0, spctlExit: 0)
        XCTAssertEqual(try runHelper(f, relaunch: true), 0)
        XCTAssertEqual(marker(f.installed), "new")
        XCTAssertEqual(f.opened, [f.installed.path], "the hostile path reaches open as ONE argument")
        XCTAssertFalse(exists(f.inflight))
        XCTAssertFalse(exists(f.status))
        let all = FileManager.default.enumerator(atPath: TestTemp.root.path)?
            .compactMap { $0 as? String } ?? []
        XCTAssertFalse(all.contains { ($0 as NSString).lastPathComponent == "PWNED" }, "\(all)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("PWNED")))
    }
}
