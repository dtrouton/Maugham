import Foundation
import MaughamCore

public enum ProjectFactoryError: Error, Equatable {
    case invalidName
    case projectAlreadyExists(URL)
    case ioError(String)
    /// A profile this kind cannot carry (R-4-6): a screenplay, a collection,
    /// or a profile this build does not know. Refused before anything is
    /// written.
    case profileNotOffered(ProjectProfile, on: ProjectType)
}

/// Creates new projects on disk. One-shot operations; does not retain state.
public enum ProjectFactory {
    private static let manifestFilename = ProjectManifest.fileName

    /// The two shapes a Report takes (R-4-6).
    public enum ReportShape: Hashable, CaseIterable {
        /// One document at the root, `report.md`: the short-story shape.
        case singleDocument
        /// Sections in a binder, the first "Introduction": the novel shape.
        case sections
    }

    /// Creates a Report at `parent/<name>` in `shape`: the short-story or
    /// novel structure with `profile: .report` (and nothing else — the
    /// switches default from the profile), and the Report publish starter.
    public static func createReportProject(
        named rawName: String,
        in parent: URL,
        shape: ReportShape
    ) async throws -> URL {
        switch shape {
        case .singleDocument:
            return try await createShortStoryProject(named: rawName, in: parent, profile: .report)
        case .sections:
            return try await createNovelProject(named: rawName, in: parent, profile: .report)
        }
    }

    /// **The factory's precondition on a profile** (R-4-6): only the prose
    /// shapes a Report sits on — a short story and a novel — carry one, and
    /// only a profile this build knows. A screenplay, a collection or a newer
    /// build's type with a profile is refused before anything is written.
    static func refuseUnofferedProfile(_ profile: ProjectProfile?, on type: ProjectType) throws {
        guard let profile else { return }
        let offered: Bool
        switch type {
        case .shortStory, .novel: offered = true
        case .screenplay, .collection, .unknown: offered = false
        }
        switch profile {
        case .report where offered: return
        case .report, .unknown: throw ProjectFactoryError.profileNotOffered(profile, on: type)
        }
    }

    /// The root document's file name, by profile: `report.md` for a
    /// single-document Report, `story.md` otherwise.
    private static func rootBasename(for profile: ProjectProfile?) -> String {
        switch profile {
        case .report?: return "report"
        case .unknown?, nil: return "story"
        }
    }

    /// Creates a Short Story project folder at `parent/<name>` — with
    /// `profile: .report`, a single-document Report whose root file is
    /// `report.md`. Returns the URL of the created project folder.
    public static func createShortStoryProject(
        named rawName: String,
        in parent: URL,
        profile: ProjectProfile? = nil
    ) async throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectFactoryError.invalidName }
        try refuseUnofferedProfile(profile, on: .shortStory)

        let fm = FileManager.default
        let projectURL = parent.appendingPathComponent(name, isDirectory: true)

        if fm.fileExists(atPath: projectURL.path) {
            throw ProjectFactoryError.projectAlreadyExists(projectURL)
        }
        let starter = await thisMacAsAStarter()

        do {
            try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("research"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: projectURL.appendingPathComponent("notes"),
                                   withIntermediateDirectories: true)

            let storyPath = rootBasename(for: profile) + "." + DocumentFormat.markdown.fileExtension
            let storyURL = projectURL.appendingPathComponent(storyPath)
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
                        path: storyPath,
                        // The book's first piece is started on this Mac like
                        // any other (P3c plan 2, Option A).
                        startedBy: starter
                    )
                ],
                research: [],
                profile: profile
            )

            let manifestData = try ProjectManifest.encodeForDisk(manifest)
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

    /// Creates a Novel project at `parent/<name>` with one Chapter 1 document
    /// — with `profile: .report`, a sectioned Report whose first section is
    /// "Introduction".
    public static func createNovelProject(
        named rawName: String,
        in parent: URL,
        profile: ProjectProfile? = nil
    ) async throws -> URL {
        let firstTitle: String
        switch profile {
        case .report?: firstTitle = "Introduction"
        case .unknown?, nil: firstTitle = "Chapter 1"
        }
        return try await createSingleDocumentProject(
            named: rawName,
            in: parent,
            type: .novel,
            initialDocumentTitle: firstTitle,
            profile: profile,
            startedBy: await thisMacAsAStarter())
    }

    /// Creates a Screenplay project at `parent/<name>` with one Scene 1.fountain.
    /// A screenplay takes no profile: one is refused
    /// (`ProjectFactoryError.profileNotOffered`) before anything is written.
    public static func createScreenplayProject(
        named rawName: String,
        in parent: URL,
        profile: ProjectProfile? = nil
    ) async throws -> URL {
        try await createSingleDocumentProject(
            named: rawName,
            in: parent,
            type: .screenplay,
            initialDocumentTitle: "Scene 1",
            profile: profile,
            startedBy: await thisMacAsAStarter())
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

    /// Who the new book's first piece records as its starter (P3c plan 2,
    /// Option A): `ProjectStore.thisMacAsAStarter`, read once, BEFORE anything
    /// is written — the factory is nonisolated and the identity seam is the
    /// main actor's.
    private static func thisMacAsAStarter() async -> String {
        await MainActor.run { ProjectStore.thisMacAsAStarter }
    }

    /// Shared logic for Novel + Screenplay (and any future "single-starter
    /// document" project type). Creates manuscript/, research/, notes/ and a
    /// single document with NN-slug naming under manuscript/, in
    /// `type.primaryFormat` — the kind decides the format, so no caller can
    /// pass two answers that disagree.
    private static func createSingleDocumentProject(
        named rawName: String,
        in parent: URL,
        type: ProjectType,
        initialDocumentTitle: String,
        profile: ProjectProfile?,
        startedBy starter: String
    ) async throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectFactoryError.invalidName }
        try refuseUnofferedProfile(profile, on: type)

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
                extension: type.primaryFormat.fileExtension,
                siblingFilenames: [])
            let docURL = projectURL.appendingPathComponent("manuscript/\(filename)")
            try Data().write(to: docURL)

            let now = Date()
            // **No seeded `status`** (M3 P1 Task 4). The free-string field was
            // minted `"draft"` here and then written only by the two inspector
            // status pickers; those are the pass ladder now, and the verdict is
            // derived (`ReviewStatus`). A seed would make every brand-new
            // document arrive already *touched* — which is exactly the
            // distinction `StatusSwatch.showsDot` draws — while saying nothing
            // a reader cannot derive: no passes and no string both read
            // `.draft`. A Collection's loose pieces have never carried a seed,
            // so this also ends a disagreement between the two creation paths.
            // The book's first piece is started on this Mac like any other
            // (P3c plan 2, Option A).
            let item = StructureItem(
                id: ProjectStore.newId(prefix: "doc"),
                title: initialDocumentTitle,
                type: .document,
                path: "manuscript/\(filename)",
                startedBy: starter)
            let manifest = ProjectManifest(
                type: type,
                title: name, author: "",
                created: now, modified: now,
                structure: [item], research: [], profile: profile)
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
        let data = try ProjectManifest.encodeForDisk(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }
}
