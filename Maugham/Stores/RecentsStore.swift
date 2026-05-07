import Foundation
import SwiftUI

/// Tracks recently-opened project folder URLs in UserDefaults.
/// Most recent first. Capped at 10 entries.
@MainActor
@Observable
public final class RecentsStore {
    private static let storageKey = "maugham.recentProjectPaths"
    private static let maxEntries = 10

    private let defaults: UserDefaults
    public private(set) var recents: [URL]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: Self.storageKey) ?? []
        self.recents = paths.map { URL(fileURLWithPath: $0) }
    }

    /// Record a project URL as recently-opened. Moves to front if already present.
    public func record(_ url: URL) {
        var updated = recents.filter { $0.path != url.path }
        updated.insert(url, at: 0)
        if updated.count > Self.maxEntries {
            updated = Array(updated.prefix(Self.maxEntries))
        }
        recents = updated
        persist()
    }

    /// Remove a project URL from the recents list.
    public func remove(_ url: URL) {
        recents = recents.filter { $0.path != url.path }
        persist()
    }

    private func persist() {
        defaults.set(recents.map(\.path), forKey: Self.storageKey)
    }
}
