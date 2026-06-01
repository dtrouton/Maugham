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
