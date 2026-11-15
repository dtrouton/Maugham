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
        guard Self.waitBounded(p, seconds: 10) else {
            kill(p.processIdentifier, SIGKILL)
            throw NSError(domain: "UpdateSwapHelperEndToEndTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "/usr/bin/true did not exit within 10 s"])
        }
        return p.processIdentifier
    }

    @discardableResult
    private func runHelper(_ f: Fixture, relaunch: Bool = false, team: String? = nil,
                           allowance: TimeInterval = helperAllowance) throws -> Int32 {
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
        // A reused pid would park the quit-wait, and a stuck step (ditto, a
        // stub, the swap) would park the helper; never hang the gate on either.
        return runBounded(p, allowance: allowance)
    }

    /// Waits for a launched `p` at most `allowance`. Past it the process tree
    /// is captured first, so the failure names the stuck step, then the whole
    /// tree is SIGKILLed: a bash that ignores or traps SIGTERM keeps waiting
    /// on its foreground child, so a `terminate()` followed by an unbounded
    /// wait hangs as long as the child does. Every wait here is bounded.
    private func runBounded(_ p: Process, allowance: TimeInterval) -> Int32 {
        let deadline = Date().addingTimeInterval(allowance)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            let tree = Self.processTree(under: p.processIdentifier)
            Self.killTree(under: p.processIdentifier)
            let exited = Self.waitBounded(p, seconds: 5)
            XCTFail("the helper did not finish within \(Int(allowance)) s "
                    + "(was the exited pid reused?)\(exited ? "" : "; it survived SIGKILL for 5 s")"
                    + "\nprocess tree at the timeout:\n\(tree)")
            return exited ? p.terminationStatus : -1
        }
        return p.terminationStatus
    }

    /// How long one helper run may take before the harness stops it.
    private static let helperAllowance: TimeInterval = 10

    /// Polls until `p` exits or `seconds` pass. Never blocks longer.
    private static func waitBounded(_ p: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !p.isRunning
    }

    /// Every process as `(pid, ppid, line)` from one bounded `ps` run. The
    /// output goes to a file, not a pipe, so a full pipe can never stall it.
    private static func processTable() -> [(pid: Int32, ppid: Int32, line: String)] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,stat=,etime=,command="]
        let out = TestTemp.root.appendingPathComponent("ps-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: out) else { return [] }
        defer { try? handle.close() }
        ps.standardOutput = handle
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        guard waitBounded(ps, seconds: 5) else {
            kill(ps.processIdentifier, SIGKILL)
            return []
        }
        guard let text = try? String(contentsOf: out, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return (pid, ppid, String(row))
        }
    }

    /// `root` and its descendants, parents before children.
    private static func descendants(of root: Int32,
                                    in table: [(pid: Int32, ppid: Int32, line: String)]) -> [Int32] {
        var result = [root]
        var index = 0
        while index < result.count {
            let parent = result[index]
            result += table.filter { $0.ppid == parent && $0.pid != parent && !result.contains($0.pid) }
                .map(\.pid)
            index += 1
        }
        return result
    }

    /// `PID PPID STAT ELAPSED COMMAND` for `root` and every descendant.
    private static func processTree(under root: Int32) -> String {
        let table = processTable()
        let lines = descendants(of: root, in: table).compactMap { pid in table.first { $0.pid == pid }?.line }
        return lines.isEmpty
            ? "(ps gave nothing)"
            : "  PID  PPID STAT ELAPSED COMMAND\n" + lines.joined(separator: "\n")
    }

    /// SIGKILL the descendants, deepest first, then `root` itself.
    private static func killTree(under root: Int32) {
        for pid in descendants(of: root, in: processTable()).reversed() { kill(pid, SIGKILL) }
        kill(root, SIGKILL)
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

    // MARK: - The harness itself

    /// A helper that ignores SIGTERM while it waits on a child that never
    /// finishes is stopped within seconds of the allowance: SIGTERM alone
    /// would leave it (and the gate) waiting on the child.
    func test_aHelperThatIgnoresSIGTERM_isKilledWithinTheAllowance() throws {
        let marker = "\(Int.random(in: 100_000...999_999))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The trailing `:` keeps bash the parent, waiting on the sleep.
        p.arguments = ["-c", "trap '' TERM; /bin/sleep 7\(marker); :"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()

        var messages: [String] = []
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { issue in
            messages.append(issue.compactDescription)
            return issue.compactDescription.contains("did not finish within 1 s")
        }
        let started = Date()
        XCTExpectFailure("the stuck helper must be reported", options: options) {
            _ = runBounded(p, allowance: 1)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 12, "bounded: no unbounded wait after the kill")
        XCTAssertEqual(messages.count, 1, "\(messages)")
        XCTAssertTrue(messages.first?.contains("/bin/sleep 7\(marker)") ?? false, messages.first ?? "")
        XCTAssertFalse(p.isRunning, "the helper itself was killed")
        XCTAssertFalse(processStillListed("/bin/sleep 7\(marker)"), "its child was killed too")
    }

    /// Whether a process whose command line ends with `suffix` is still
    /// listed (or `ps` gives nothing), polling for up to 2 s while a
    /// SIGKILLed one is reaped.
    private func processStillListed(_ suffix: String) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let table = Self.processTable()
            // An empty table is ps failing, not proof of absence.
            if !table.isEmpty, !table.contains(where: { $0.line.hasSuffix(suffix) }) { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    /// A step that never finishes, and ignores SIGTERM, fails the test within
    /// seconds of the allowance instead of hanging the suite; the failure
    /// carries the captured process tree, naming the stuck step; and the
    /// stuck step is killed, not left running.
    func test_aStuckStepThatIgnoresSIGTERM_failsWithinTheAllowance_andNamesTheStep() throws {
        let f = try makeFixture(codesignExit: 0, spctlExit: 0)
        // Unique, so the process-table search below finds only this run's.
        let marker = "\(Int.random(in: 100_000...999_999))"
        try write("#!/bin/bash\ntrap '' TERM\nexec /bin/sleep 6\(marker)\n",
                  to: URL(fileURLWithPath: f.tools.codesign), executable: true)

        var messages: [String] = []
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { issue in
            messages.append(issue.compactDescription)
            return issue.compactDescription.contains("did not finish within 1 s")
        }
        let started = Date()
        XCTExpectFailure("the stuck stub must be reported", options: options) {
            _ = try? runHelper(f, allowance: 1)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 12, "bounded: no unbounded wait after the kill")
        XCTAssertEqual(messages.count, 1, "\(messages)")
        XCTAssertTrue(messages.first?.contains("/bin/sleep 6\(marker)") ?? false, messages.first ?? "")
        XCTAssertFalse(processStillListed("/bin/sleep 6\(marker)"), "the stuck step survived the harness")
    }
}
