import Foundation

/// **What made this book** — the two versions every compile stamps into the
/// `Publication` record it mints, in one place (imprints P3 Task 4).
///
/// Both are provenance rather than configuration: a `Publication` says which
/// build of Maugham assembled it and which tectonic typeset it, and that is the
/// only thing anybody can go on when a PDF from three months ago looks wrong.
///
/// **There were four spellings of this pair before this file existed** —
/// `CompileTools` twice (compile and preview), `PublicationTools` once
/// (republish) and `DesignerEnvironment+Project` once (the design sample),
/// the last of which carried a comment conceding that a literal in four places
/// was not an improvement. Nothing reads a record's stamp back, so a bump
/// applied to three of the four would have produced a catalog in which two
/// books made by the same build disagree about what made them, with no surface
/// anywhere that could show it. `TripwireGrepTests
/// .test_theToolchainsVersionsAreSpelledInExactlyOnePlace` is what keeps a
/// fifth from appearing; a planted-offender control sits beside it.
///
/// A `enum` with statics rather than a struct anybody could instantiate: there
/// is one running build and one bundled binary, and a second instance of either
/// is a fiction.
public enum PublishToolchain {

    /// The running build's version, as the bundle declares it.
    ///
    /// Computed rather than stored, because a `static let` initialised at first
    /// touch would freeze whatever the bundle said at that moment — which in a
    /// test host is not the app's `Info.plist` at all. The fallback is
    /// `"0.0.0"`, the spelling every compile site already used: a record whose
    /// stamp reads `0.0.0` says "this was not a released build", which is true
    /// and is more useful than an empty string.
    public static var maughamVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The bundled tectonic's version.
    ///
    /// A literal, because the binary that ships in `Resources/` is fetched by
    /// `scripts/fetch-tectonic.sh` and does not report a version this app can
    /// read cheaply at compile time. Bumping the fetch script means bumping
    /// this line, and now that is one line.
    public static let tectonicVersion = "0.15.0"
}
