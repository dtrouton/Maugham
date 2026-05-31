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
    ///
    /// Capital "M" in "Maugham": the registered Apple App ID is
    /// `com.Maugham.MaughamPhone`, and codesign matches the bundle id
    /// case-sensitively. Diverges intentionally from the Mac's `com.maugham.Maugham`
    /// (Apple namespaces App IDs case-insensitively, so the lowercase form can't be
    /// re-registered). See CLAUDE.md → phone bundle-id note. Must stay in sync with
    /// `PRODUCT_BUNDLE_IDENTIFIER` in project.yml + the ExportOptions key in
    /// phone-release.yml.
    var phoneBundleId: String {
        self == .dev ? "com.Maugham.MaughamPhone.dev" : "com.Maugham.MaughamPhone"
    }

    /// UserDefaults key under which the security-scoped projects-root bookmark
    /// is persisted. Variant-keyed so dev and stable never trample each other's
    /// (distinct) folder grants on the same device.
    var bookmarkUserDefaultsKey: String {
        "projectsRootBookmark.\(self == .dev ? "dev" : "stable")"
    }
}
