import Foundation
import MaughamCore

@MainActor
public final class PublicationStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    public func load() async throws -> [Publication] {
        try await backing.load()
    }

    public func append(_ pub: Publication) async throws {
        try await backing.append(pub)
    }

    /// The `Publication` a given snapshot was first compiled as. Single
    /// source of truth for the "prior publication" lookup `republish` needs —
    /// both `Republisher.republish` and its caller (`RepublishTool.handle`,
    /// which must know the prior edition's `language` before building the
    /// astSource) resolve through here, so the two can't disagree.
    public func publication(forSnapshotID snapshotID: String) async throws -> Publication? {
        try await load().first(where: { $0.snapshotID == snapshotID })
    }

    private var backing: JSONLAppendStore<Publication> {
        JSONLAppendStore<Publication>(
            fileURL: projectURL.appendingPathComponent(".maugham/publications.jsonl"),
            presenter: presenter)
    }
}
