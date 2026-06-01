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
}
