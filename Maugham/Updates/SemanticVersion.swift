import Foundation

/// Strict semver `X.Y.Z`. Pre-release suffixes (`-beta`, etc.) are intentionally
/// unsupported in this milestone — see the production-release spec §3.4.
public struct SemanticVersion: Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ raw: String) {
        let stripped = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = stripped.split(separator: ".")
        guard parts.count == 3,
              let M = Int(parts[0]), let m = Int(parts[1]), let p = Int(parts[2]) else {
            return nil
        }
        self.init(major: M, minor: m, patch: p)
    }

    public var string: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
