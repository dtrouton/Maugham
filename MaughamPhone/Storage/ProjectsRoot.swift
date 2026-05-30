import Foundation
import MaughamCore

/// Abstracts the security-scoped-bookmark primitives so `ProjectsRoot`'s state
/// machine is unit-testable without a real UIDocumentPicker grant. A real
/// security-scoped bookmark can only be minted from a URL the system granted
/// via the document picker, which a unit test can't obtain — so the test fakes
/// this seam and asserts the state transitions directly.
protocol BookmarkResolving: Sendable {
    /// Resolve persisted bookmark bytes to a URL; reports staleness.
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    /// Create persistable bookmark bytes for a picked URL.
    func makeBookmark(for url: URL) throws -> Data
    /// Begin security-scoped access; returns false if denied.
    func startAccessing(_ url: URL) -> Bool
}

/// Production `BookmarkResolving` backed by the real Foundation security-scoped
/// bookmark APIs.
struct LiveBookmarkResolving: BookmarkResolving {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        // iOS has no `.withSecurityScope` resolution option (that's macOS-only);
        // on iOS the security scope rides along implicitly with `options: []`.
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }
}

/// Owns the lifecycle of the writer-chosen iCloud-Drive projects folder: the
/// writer picks it once via `UIDocumentPicker`, we persist a security-scoped
/// bookmark, and re-resolve it every launch — re-prompting if it's gone stale.
///
/// There is no shared iCloud container; the folder is an arbitrary user-chosen
/// path, the same posture as the Mac app. See spec §3.6.
///
/// # Why @Observable + plain properties (not ObservableObject/@Published)
/// Matches `RecentsTracker`: inside an `@Observable` class the observation
/// system tracks plain stored-property mutations naturally, and we keep the
/// `UserDefaults` suite injectable for tests.
@MainActor
@Observable
final class ProjectsRoot {

    /// What the UI should do about folder access right now.
    enum PickerState: Equatable {
        /// We have (or are mid-resolving) a working root; no prompt needed.
        case idle
        /// No bookmark stored yet — prompt the writer to pick a folder.
        case needed
        /// Bookmark resolved but is stale — the writer must re-pick.
        case stale
        /// Resolution succeeded but the OS denied security-scoped access.
        case accessDenied
        /// Bookmark resolution threw; carries a human-readable reason.
        case resolveFailed(String)
    }

    // MARK: - Observed state

    /// The resolved, access-started projects-root URL, or nil if we don't have
    /// a usable one (any non-`.idle` picker state).
    private(set) var rootURL: URL?

    /// Current folder-access state machine value; drives the UI's prompt.
    var picker: PickerState

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let resolver: BookmarkResolving

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        resolver: BookmarkResolving = LiveBookmarkResolving()
    ) {
        self.defaults = defaults
        self.resolver = resolver
        // Start idle; `resolveOnLaunch()` drives the real first transition so
        // construction stays side-effect-free and ordering is explicit.
        self.picker = .idle
        self.rootURL = nil
    }

    // MARK: - Launch resolution

    /// Re-establishes access to the persisted projects folder. Call once at
    /// launch. Sets `picker`/`rootURL` per the resolution outcome:
    ///   - no bookmark stored        → `.needed`
    ///   - resolves stale            → `.stale`
    ///   - access denied             → `.accessDenied`
    ///   - resolution throws         → `.resolveFailed`
    ///   - otherwise                 → `rootURL` set, `.idle`
    func resolveOnLaunch() {
        guard let data = defaults.data(forKey: BuildVariant.current.bookmarkUserDefaultsKey) else {
            rootURL = nil
            picker = .needed
            return
        }

        do {
            let (url, isStale) = try resolver.resolve(data)
            if isStale {
                // Bookmark no longer points at a valid grant; force a re-pick
                // rather than silently operating on a dead URL.
                rootURL = nil
                picker = .stale
                return
            }
            guard resolver.startAccessing(url) else {
                rootURL = nil
                picker = .accessDenied
                return
            }
            rootURL = url
            picker = .idle
        } catch {
            rootURL = nil
            picker = .resolveFailed(error.localizedDescription)
        }
    }

    // MARK: - Picking

    /// Records a freshly picked folder: mints a bookmark, persists it, starts
    /// security-scoped access, and adopts it as the root. Throws if the
    /// bookmark can't be created (the only failable step here).
    func pick(from url: URL) throws {
        let data = try resolver.makeBookmark(for: url)
        defaults.set(data, forKey: BuildVariant.current.bookmarkUserDefaultsKey)

        guard resolver.startAccessing(url) else {
            rootURL = nil
            picker = .accessDenied
            return
        }
        rootURL = url
        picker = .idle
    }
}
