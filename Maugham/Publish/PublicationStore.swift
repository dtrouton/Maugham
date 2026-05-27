import Foundation

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

    private var backing: JSONLAppendStore<Publication> {
        JSONLAppendStore<Publication>(
            fileURL: projectURL.appendingPathComponent(".maugham/publications.jsonl"),
            presenter: presenter)
    }
}
