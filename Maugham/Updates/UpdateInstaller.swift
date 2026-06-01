// Maugham/Updates/UpdateInstaller.swift
import Foundation
import Security

/// The result of inspecting a staged bundle's code signature.
public struct VerificationVerdict: Equatable {
    public let codesignValid: Bool
    public let notarized: Bool
    public let teamID: String?
    public init(codesignValid: Bool, notarized: Bool, teamID: String?) {
        self.codesignValid = codesignValid
        self.notarized = notarized
        self.teamID = teamID
    }
}

/// What to do with a staged bundle after verification.
public enum InstallDecision: Equatable {
    case accept
    case reject(reason: String)
}

public enum InstallMode: Equatable {
    case inPlace        // swap /Applications/Maugham.app via the helper
    case finderFallback // reveal the .dmg in Finder (current behavior)
}

public enum UpdateInstaller {
    /// Pure decision: a staged bundle is trustworthy iff its signature is valid,
    /// it is notarized, and its Team ID matches the running app's Team ID.
    /// Checks are ordered most-fundamental-first so the reason is the root cause.
    public static func decide(verdict: VerificationVerdict, expectedTeamID: String) -> InstallDecision {
        guard verdict.codesignValid else { return .reject(reason: "Invalid code signature") }
        guard verdict.notarized else { return .reject(reason: "Not notarized") }
        guard verdict.teamID == expectedTeamID else { return .reject(reason: "Team ID mismatch") }
        return .accept
    }

    /// Shell script run **detached** after the app quits. Polls until our PID is
    /// gone, then atomically swaps the bundle (ditto to a temp sibling + mv so a
    /// working app is never left half-overwritten), then optionally relaunches.
    public static func helperScript(
        pid: Int32, stagedBundle: String, installedBundle: String, relaunch: Bool
    ) -> String {
        let tmp = "\(installedBundle).inflight"
        var s = """
        #!/bin/bash
        set -e
        # Wait for the running Maugham (pid \(pid)) to fully exit.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(tmp)"
        ditto "\(stagedBundle)" "\(tmp)"
        rm -rf "\(installedBundle)"
        mv "\(tmp)" "\(installedBundle)"
        """
        if relaunch {
            s += "\nopen \"\(installedBundle)\"\n"
        }
        return s
    }
}

extension UpdateInstaller {
    /// Decide how to install based on whether the installed bundle is writable
    /// by the current user. Defaults are injected for testability.
    public static func installMode(
        installedBundlePath: String,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> InstallMode {
        isWritable(installedBundlePath) ? .inPlace : .finderFallback
    }
}

extension UpdateInstaller {
    /// The Team ID embedded in the *running* app's code signature, or nil if
    /// unsigned/ad-hoc (e.g. the test host). Self-anchoring: the staged update
    /// must be signed by the same team that signed us.
    public static func runningAppTeamID() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return nil }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as NSDictionary? else { return nil }
        return info[kSecCodeInfoTeamIdentifier] as? String
    }
}

extension UpdateInstaller {
    enum InstallError: LocalizedError {
        case unzipFailed, verifyFailed(String)
        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Couldn't unpack the update"
            case .verifyFailed(let r): return "Update failed verification: \(r)"
            }
        }
    }

    /// Run a tool synchronously, return (exitCode, combined stdout+stderr).
    private static func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Inspect a staged bundle's signature via codesign + spctl.
    static func verify(bundlePath: String) -> VerificationVerdict {
        let (csCode, _) = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundlePath])
        let (_, dvOut) = run("/usr/bin/codesign", ["-dv", "--verbose=4", bundlePath])
        let teamID = dvOut.split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
        // spctl assess: exit 0 == Gatekeeper would allow exec (our proxy for
        // "notarized + team-signed"). Caveat: if Gatekeeper is globally disabled
        // (spctl --master-disable) this returns 0 for unsigned apps too — the
        // codesign + Team-ID guards in decide() still protect against a tampered
        // or wrong-team bundle. spctl contacts Apple's OCSP servers; a network
        // timeout yields non-zero, which we conservatively treat as not-notarized.
        let (spctlCode, _) = run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", bundlePath])
        return VerificationVerdict(codesignValid: csCode == 0,
                                   notarized: spctlCode == 0,
                                   teamID: teamID)
    }

    /// Unzip `zip` into a staging dir and return the contained Maugham.app URL,
    /// verifying it against the running app's Team ID. Throws on any failure.
    /// Runs off the calling actor — the codesign/spctl/ditto Process calls are
    /// synchronous and spctl can block for seconds on Apple's OCSP servers, so
    /// this must never run on the main actor.
    static func stageAndVerify(zip: URL, version: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try stageAndVerifySync(zip: zip, version: version)
        }.value
    }

    /// Synchronous worker. MUST be called off the main actor (see stageAndVerify).
    private static func stageAndVerifySync(zip: URL, version: String) throws -> URL {
        let stageDir = zip.deletingLastPathComponent()
            .appendingPathComponent("staged-\(version)", isDirectory: true)
        try? FileManager.default.removeItem(at: stageDir)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let (code, _) = run("/usr/bin/ditto", ["-x", "-k", zip.path, stageDir.path])
        guard code == 0 else { throw InstallError.unzipFailed }
        let bundle = stageDir.appendingPathComponent("Maugham.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw InstallError.unzipFailed }
        // Strip quarantine so the swapped-in copy launches clean.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.path])
        let verdict = verify(bundlePath: bundle.path)
        let expected = runningAppTeamID() ?? ""
        switch decide(verdict: verdict, expectedTeamID: expected) {
        case .accept:
            return bundle
        case .reject(let reason):
            try? FileManager.default.removeItem(at: stageDir)
            throw InstallError.verifyFailed(reason)
        }
    }

    /// Launch the detached swap helper for a verified bundle. Returns false if it
    /// couldn't be launched (caller handles Finder fallback). `installedBundlePath`
    /// defaults to the running app's own location so we replace the right copy.
    @discardableResult
    static func launchSwapHelper(stagedBundle: URL, relaunch: Bool,
                                 installedBundlePath: String = Bundle.main.bundlePath) -> Bool {
        guard installMode(installedBundlePath: installedBundlePath) == .inPlace else {
            return false  // not writable → caller does Finder fallback
        }
        let script = helperScript(pid: ProcessInfo.processInfo.processIdentifier,
                                  stagedBundle: stagedBundle.path,
                                  installedBundle: installedBundlePath,
                                  relaunch: relaunch)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("maugham-update-\(UUID().uuidString).sh")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) }
        catch { return false }
        let p = Process()
        // Launch detached: the child reparents to launchd when we terminate and
        // keeps running (no controlling TTY → no SIGHUP). The script polls our
        // pid and only swaps after we've fully exited.
        // NOTE: on a normal Finder/Dock launch the orphaned child reparents to
        // launchd and survives our exit. When launched from Xcode/lldb, the
        // debugger kills the process group on app exit — so the in-place swap
        // won't apply in a debug session. Production launch only.
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]
        do { try p.run() } catch { return false }
        return true
    }
}
