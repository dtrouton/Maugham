import Foundation

/// Stable identifier for a project. Uses `ProjectManifest.id` (a minted ULID
/// string), NOT a file path — so recents survive folder rename/move in iCloud.
typealias ProjectId = String

/// Tracks which projects are "recent" so the cold-launch proactive-download
/// path knows which op logs to prefetch within the 50 MB budget. See §3.13.
///
/// Two signals define recency:
///   - **captured**: the 5 most-recently-captured-into projects (FIFO, most-recent-first).
///   - **openedDates**: the last-opened timestamp per project; within 14 days counts as recent.
///
/// `recents` is the union of both sets.
///
/// # Why not @AppStorage
/// `@AppStorage` is a SwiftUI `DynamicProperty` whose observation machinery only
/// activates inside a `View` body. Inside an `@Observable` class the mutations
/// happen without notifying the observation system, and the suite cannot be
/// redirected to a test-isolated `UserDefaults` instance. We store plain
/// properties (so `@Observable` tracks them naturally) and read/write `UserDefaults`
/// explicitly instead.
@MainActor
@Observable
final class RecentsTracker {

    // MARK: - Constants

    // Internal (not private) so tests reference the same key names rather than
    // duplicating string literals — a literal-duplicating corrupt-data test
    // would silently stop testing anything if a key were renamed.
    enum Keys {
        static let captured = "recentProjectIds"
        static let openedDates = "lastOpenedDates"
    }

    private static let capturedCap = 5
    private static let openedWindow: TimeInterval = 14 * 24 * 60 * 60  // 14 days in seconds

    // MARK: - Observed state

    /// The (up to 5) most-recently-captured-into project ids, most-recent-first.
    private(set) var captured: [ProjectId]

    /// Per-project last-opened timestamp; only entries within the last 14 days
    /// contribute to `recents`.
    private(set) var openedDates: [ProjectId: Date]

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let now: @MainActor () -> Date

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now

        // Load persisted state. Bad/absent data → start empty (never crash on
        // stale or corrupt UserDefaults, since these are soft app-preference
        // values, not critical data).
        self.captured = Self.loadCaptured(from: defaults)
        self.openedDates = Self.loadOpenedDates(from: defaults)
    }

    // MARK: - Computed recents

    /// The union of all captured project ids and any project opened within the
    /// last 14 days. No defined ordering.
    var recents: Set<ProjectId> {
        let cutoff = now().addingTimeInterval(-Self.openedWindow)
        let recentlyOpened = openedDates.filter { $0.value >= cutoff }.keys
        return Set(captured).union(recentlyOpened)
    }

    // MARK: - Mutations

    /// Records a capture into `projectId`. Moves it to the front of `captured`
    /// (dedup), then caps the list at 5, dropping the oldest entry if needed.
    func recordCapture(into projectId: ProjectId) {
        var list = captured.filter { $0 != projectId }  // remove existing occurrence
        list.insert(projectId, at: 0)                   // prepend (most-recent-first)
        if list.count > Self.capturedCap {
            list = Array(list.prefix(Self.capturedCap))
        }
        captured = list
        persistCaptured()
    }

    /// Records that `projectId` was opened right now. Upserts the timestamp.
    func recordOpen(_ projectId: ProjectId) {
        openedDates[projectId] = now()
        persistOpenedDates()
    }

    // MARK: - Persistence (read)

    private static func loadCaptured(from defaults: UserDefaults) -> [ProjectId] {
        guard let data = defaults.data(forKey: Keys.captured),
              let decoded = try? JSONDecoder().decode([ProjectId].self, from: data)
        else { return [] }
        return decoded
    }

    private static func loadOpenedDates(from defaults: UserDefaults) -> [ProjectId: Date] {
        guard let data = defaults.data(forKey: Keys.openedDates),
              let decoded = try? JSONDecoder().decode([ProjectId: Date].self, from: data)
        else { return [:] }
        return decoded
    }

    // MARK: - Persistence (write)

    private func persistCaptured() {
        guard let data = try? JSONEncoder().encode(captured) else { return }
        defaults.set(data, forKey: Keys.captured)
    }

    private func persistOpenedDates() {
        guard let data = try? JSONEncoder().encode(openedDates) else { return }
        defaults.set(data, forKey: Keys.openedDates)
    }
}
