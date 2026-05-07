import Foundation

public enum ProjectFactoryError: Error, Equatable {
    case invalidName
    case projectAlreadyExists(URL)
    case ioError(String)
}

/// Creates new projects on disk. One-shot operations; does not retain state.
public enum ProjectFactory {
    private static let manifestFilename = "project.maugham.json"

    /// Creates a Short Story project folder at `parent/<name>`.
    /// Returns the URL of the created project folder.
    public static func createShortStoryProject(
        named rawName: String,
        in parent: URL
    ) async throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectFactoryError.invalidName }

        let fm = FileManager.default
        let projectURL = parent.appendingPathComponent(name, isDirectory: true)

        if fm.fileExists(atPath: projectURL.path) {
            throw ProjectFactoryError.projectAlreadyExists(projectURL)
        }

        do {
            try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("research"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("notes"),
                                   withIntermediateDirectories: true)

            let storyURL = projectURL.appendingPathComponent("story.md")
            try Data().write(to: storyURL)

            let now = Date()
            let manifest = ProjectManifest(
                type: .shortStory,
                title: name,
                author: "",
                created: now,
                modified: now,
                structure: [
                    StructureItem(
                        id: "manuscript",
                        title: name,
                        type: .document,
                        path: "story.md"
                    )
                ],
                research: []
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: projectURL.appendingPathComponent(manifestFilename))
        } catch let error as ProjectFactoryError {
            throw error
        } catch {
            try? fm.removeItem(at: projectURL)
            throw ProjectFactoryError.ioError(error.localizedDescription)
        }

        return projectURL
    }
}
