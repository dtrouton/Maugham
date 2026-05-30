import MaughamCore

// iOS-only knobs for the shared `BuildVariant` enum. The enum itself stays
// platform-agnostic in MaughamCore (Mac + future shared code); these two
// values are MaughamPhone-specific identity strings.
//
// Tripwire 13: per the project's "no hardcoded identity strings" rule, these
// literals (and the bundle-id literals in project.yml + the UserDefaults key
// in tests) are the ONE allowed home for MaughamPhone's variant-keyed identity.
// Everything else in MaughamPhone must route through `BuildVariant.current`.
extension BuildVariant {
    /// The app's bundle identifier per variant (matches project.yml).
    var phoneBundleId: String {
        self == .dev ? "com.maugham.MaughamPhone.dev" : "com.maugham.MaughamPhone"
    }

    /// UserDefaults key under which the security-scoped projects-root bookmark
    /// is persisted. Variant-keyed so dev and stable never trample each other's
    /// (distinct) folder grants on the same device.
    var bookmarkUserDefaultsKey: String {
        "projectsRootBookmark.\(self == .dev ? "dev" : "stable")"
    }
}
