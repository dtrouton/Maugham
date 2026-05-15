import Foundation
import Observation

@Observable
@MainActor
public final class ProjectRegistry {
    public struct Entry {
        public let id: String
        public let url: URL
        public let store: ProjectStore
    }

    private var entriesById: [String: Entry] = [:]

    public init() {}

    public func register(url: URL, store: ProjectStore) {
        let id = ProjectIdentifier.id(for: url)
        entriesById[id] = Entry(id: id, url: url, store: store)
    }

    public func unregister(url: URL) {
        let id = ProjectIdentifier.id(for: url)
        entriesById.removeValue(forKey: id)
    }

    public func lookup(id: String) -> Entry? {
        entriesById[id]
    }

    public func list() -> [Entry] {
        Array(entriesById.values)
    }
}
