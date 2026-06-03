import Foundation
import MaughamCore

public enum ProjectFactoryError: Error, Equatable {
    case invalidName
    case projectAlreadyExists(URL)
    case ioError(String)
}

/// Creates new projects on disk. One-shot operations; does not retain state.
public enum ProjectFactory {
    private static let manifestFilename = ProjectManifest.fileName

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

            let manifestData = try ProjectManifest.makeEncoder().encode(manifest)
            try manifestData.write(to: projectURL.appendingPathComponent(manifestFilename))

            // Publishing: copy barebones starter so new projects can publish immediately.
            await PublishStarter.installIfMissing(into: projectURL)
        } catch let error as ProjectFactoryError {
            throw error
        } catch {
            try? fm.removeItem(at: projectURL)
            throw ProjectFactoryError.ioError(error.localizedDescription)
        }

        return projectURL
    }

    /// Creates a Novel project at `parent/<name>` with one Chapter 1 document.
    public static func createNovelProject(
        named rawName: String,
        in parent: URL
    ) async throws -> URL {
        try await createSingleDocumentProject(
            named: rawName,
            in: parent,
            type: .novel,
            initialDocumentTitle: "Chapter 1",
            initialDocumentExtension: "md")
    }

    /// Creates a Screenplay project at `parent/<name>` with one Scene 1.fountain.
    public static func createScreenplayProject(
        named rawName: String,
        in parent: URL
    ) async throws -> URL {
        try await createSingleDocumentProject(
            named: rawName,
            in: parent,
            type: .screenplay,
            initialDocumentTitle: "Scene 1",
            initialDocumentExtension: "fountain")
    }

    /// Creates a Collection project at `parent/<name>` with an empty manifest.
    public static func createCollectionProject(
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
            try fm.createDirectory(at: projectURL.appendingPathComponent("pieces"),
                                   withIntermediateDirectories: true)

            let now = Date()
            let manifest = ProjectManifest(
                type: .collection,
                title: name, author: "",
                created: now, modified: now,
                structure: [], research: [])
            try writeManifest(manifest, to: projectURL)

            // Publishing: copy barebones starter so new projects can publish immediately.
            await PublishStarter.installIfMissing(into: projectURL)
        } catch let e as ProjectFactoryError {
            try? fm.removeItem(at: projectURL)
            throw e
        } catch {
            try? fm.removeItem(at: projectURL)
            throw ProjectFactoryError.ioError(error.localizedDescription)
        }

        return projectURL
    }

    // MARK: - Shared helpers

    /// Shared logic for Novel + Screenplay (and any future "single-starter
    /// document" project type). Creates manuscript/, research/, notes/ and a
    /// single document with NN-slug naming under manuscript/.
    private static func createSingleDocumentProject(
        named rawName: String,
        in parent: URL,
        type: ProjectType,
        initialDocumentTitle: String,
        initialDocumentExtension: String
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
            try fm.createDirectory(at: projectURL.appendingPathComponent("manuscript"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("research"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("notes"),
                                   withIntermediateDirectories: true)

            let filename = FileNaming.nextDocumentFilename(
                title: initialDocumentTitle,
                extension: initialDocumentExtension,
                siblingFilenames: [])
            let docURL = projectURL.appendingPathComponent("manuscript/\(filename)")
            try Data().write(to: docURL)

            let now = Date()
            let item = StructureItem(
                id: "doc-\(UUID().uuidString.prefix(8).lowercased())",
                title: initialDocumentTitle,
                type: .document,
                path: "manuscript/\(filename)",
                status: "draft")
            let manifest = ProjectManifest(
                type: type,
                title: name, author: "",
                created: now, modified: now,
                structure: [item], research: [])
            try writeManifest(manifest, to: projectURL)

            // Publishing: copy barebones starter so new projects can publish immediately.
            await PublishStarter.installIfMissing(into: projectURL)
        } catch let e as ProjectFactoryError {
            try? fm.removeItem(at: projectURL)
            throw e
        } catch {
            try? fm.removeItem(at: projectURL)
            throw ProjectFactoryError.ioError(error.localizedDescription)
        }

        return projectURL
    }

    /// Atomic manifest write helper (shared with Collection).
    private static func writeManifest(
        _ manifest: ProjectManifest, to projectURL: URL
    ) throws {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        let data = try ProjectManifest.makeEncoder().encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }
}
