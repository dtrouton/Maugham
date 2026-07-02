import Foundation

/// Loads the bundled documentation index (`guide/index.json`) and resolves
/// topic markdown. The single seam both `HelpWindow` and `GetHelpTool` read
/// through — neither hand-rolls bundle lookups. Directory is injected so
/// tests can point at a temp dir; production uses `.bundled()`.
struct HelpTopicIndex {
    struct Topic: Codable, Hashable {
        let slug: String
        let title: String
        let order: Int
    }

    enum LoadError: Error { case indexMissing, topicMissing(String) }

    let directory: URL
    let topics: [Topic]

    init(directory: URL) throws {
        self.directory = directory
        let indexURL = directory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL) else { throw LoadError.indexMissing }  // adr-0018-ok: bundled help index read, not manuscript
        let decoded = try JSONDecoder().decode([Topic].self, from: data)
        self.topics = decoded.sorted { $0.order < $1.order }
    }

    /// Production loader: the `guide/` folder bundled by `project.yml`.
    static func bundled() throws -> HelpTopicIndex {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("guide"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("index.json").path)
        else { throw LoadError.indexMissing }
        return try HelpTopicIndex(directory: url)
    }

    func markdown(for slug: String) throws -> String {
        guard topics.contains(where: { $0.slug == slug }) else { throw LoadError.topicMissing(slug) }
        let url = directory.appendingPathComponent("\(slug).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {  // adr-0018-ok: bundled help topic doc read, not manuscript
            throw LoadError.topicMissing(slug)
        }
        return text
    }
}
