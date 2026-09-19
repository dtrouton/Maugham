// Maugham/Updates/MinimumSystemVersion.swift
import Foundation

/// The macOS a build needs, and the macOS this Mac runs — the one comparison
/// that stands between the updater and a download the Mac cannot launch.
///
/// `UpdateChecker` compared versions only until the deployment target moved to
/// macOS 27 (plan `2026-09-19-macos-27-shell-slice.md`, D4). From that release
/// on, a Mac still on 26 would have downloaded, verified and swapped in a
/// binary that will not start. The build's minimum is carried in the release
/// body, which the checker already fetches; see `parse(releaseBody:)`.
public struct MinimumSystemVersion: Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `"27"`, `"27.1"` or `"14.4.1"`. Anything else — including an empty
    /// component (`"27."`) or a fourth one — is not a version.
    public init?(_ raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        self.init(major: numbers[0],
                  minor: numbers.count > 1 ? numbers[1] : 0,
                  patch: numbers.count > 2 ? numbers[2] : 0)
    }

    /// How a writer hears it: trailing zero components are not spoken, so
    /// `27.0.0` reads "27" and `14.4.1` reads "14.4.1".
    public var displayString: String {
        if patch != 0 { return "\(major).\(minor).\(patch)" }
        if minor != 0 { return "\(major).\(minor)" }
        return "\(major)"
    }

    public static func < (lhs: MinimumSystemVersion, rhs: MinimumSystemVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    /// True when a Mac running `system` can launch a build that requires `self`.
    public func isSatisfied(by system: MinimumSystemVersion) -> Bool {
        self <= system
    }

    /// This Mac's macOS.
    public static var runningSystem: MinimumSystemVersion {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return MinimumSystemVersion(major: os.majorVersion,
                                    minor: os.minorVersion,
                                    patch: os.patchVersion)
    }

    // MARK: - The fact on the wire

    /// The key of the machine line `release.yml` appends to every release body,
    /// read out of the built app's own `LSMinimumSystemVersion`.
    ///
    /// **Why the body.** The checker already fetches the release list, so the
    /// body costs no second request and no second failure mode. A sidecar JSON
    /// asset would need its own fetch; encoding the minimum in the `.zip`/`.dmg`
    /// asset name would make the download filename a wire format and put data
    /// where a human reads a name. An HTML comment is invisible on the GitHub
    /// release page and unambiguous to parse — prose cannot collide with it —
    /// and `strippingMarker(from:)` keeps it out of the sheet, which renders the
    /// body as plain text.
    public static let markerKey = "maugham-minimum-macos"

    private static let markerRegex = try? NSRegularExpression(
        pattern: "<!--\\s*\(markerKey)\\s*:\\s*([0-9.]+)\\s*-->")

    /// The build's minimum macOS, or nil when the release carries no such fact.
    ///
    /// **Nil is not a refusal.** Every release before 0.40.0 predates the marker
    /// and is offered exactly as it is today. The last marker wins: the workflow
    /// appends its line after the hand-written notes, so a stray earlier one
    /// (notes quoting a marker) loses to the authoritative one.
    public static func parse(releaseBody: String) -> MinimumSystemVersion? {
        guard let regex = markerRegex else { return nil }
        let range = NSRange(releaseBody.startIndex..., in: releaseBody)
        guard let match = regex.matches(in: releaseBody, range: range).last,
              let valueRange = Range(match.range(at: 1), in: releaseBody) else { return nil }
        return MinimumSystemVersion(String(releaseBody[valueRange]))
    }

    /// The release body with every marker removed, for display. The sheet shows
    /// `releaseNotes` as plain `Text`, so an unstripped HTML comment would read
    /// as literal markup at the bottom of the notes.
    public static func strippingMarker(from releaseBody: String) -> String {
        guard let regex = markerRegex else { return releaseBody }
        let range = NSRange(releaseBody.startIndex..., in: releaseBody)
        let stripped = regex.stringByReplacingMatches(
            in: releaseBody, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
