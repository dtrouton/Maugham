import Foundation
import MaughamCore

/// What publishing needs to know about a project beyond its pieces' text: the
/// citable research, the profile and its switches, where the project really
/// lives, and where each piece's file sits (a figure path is relative to it).
///
/// Reached through `ProjectASTBuilder.Source.publishContext()`, never through a
/// downcast to `ProjectStoreASTSource`: the compilers hold a WRAPPED source (a
/// body's include filter, a preview's allowlist), and a downcast on a wrapper
/// fails silently. Every wrapper forwards it to its base.
///
/// `projectURL` is the source's project, never a compiler's: `SampleCompiler`
/// compiles against a scratch copy of the publish tree and hands that scratch
/// directory to `PreviewCompiler` as its `projectURL`, so a figure resolved
/// against the compiler's URL would look for research in the scratch.
public struct PublishContext: Sendable {
    /// Built from the manifest's LIVE research: a trashed item has left
    /// `manifest.research` for the Trash, so its key is not citable.
    public var library: CitationLibrary
    public var profile: ProjectProfile?
    /// `ProjectManifest.effectiveSwitches` less `webAccess`, which is not a
    /// publishing switch.
    public var switches: (numberSections: Bool, listOfFigures: Bool, listOfTables: Bool)
    /// The REAL project, never a compiler's scratch dir. Nil for a source that
    /// has no project (tests, the emission contract's examples).
    public var projectURL: URL?
    /// pieceID → the project-relative path of its manuscript file.
    public var piecePaths: [String: String]
    /// The project's title as the manifest holds it NOW. A Report's title page
    /// falls back to it when the config's title is still the starter's
    /// "Untitled" (`PDFCompiler.reportConfig`). Nil for a source with no project.
    public var projectTitle: String?

    public init(
        library: CitationLibrary,
        profile: ProjectProfile?,
        switches: (numberSections: Bool, listOfFigures: Bool, listOfTables: Bool),
        projectURL: URL?,
        piecePaths: [String: String],
        projectTitle: String? = nil
    ) {
        self.library = library
        self.profile = profile
        self.switches = switches
        self.projectURL = projectURL
        self.piecePaths = piecePaths
        self.projectTitle = projectTitle
    }

    /// No research, no profile, every switch off, no project, no paths: what a
    /// source with no project answers.
    public static let empty = PublishContext(
        library: CitationLibrary(items: []),
        profile: nil,
        switches: (numberSections: false, listOfFigures: false, listOfTables: false),
        projectURL: nil,
        piecePaths: [:])
}

extension PublishContext {
    /// **A Report is titled by its project until the writer names it** (Task 7
    /// M2, fix round 2) — the ONE rule the PDF title page and filename, the
    /// EPUB's `dc:title` and filename, and the .docx filename and `core.xml`
    /// title all ask. While the config's title is
    /// the starter's "Untitled" (`PublishConfig.Metadata.untitled`) or blank, a
    /// Report takes the manifest's current title. Every other book's config —
    /// and a Report the writer has titled — is returned unchanged, so its
    /// output keeps its bytes.
    public func reportTitled(_ config: PublishConfig) -> PublishConfig {
        guard case .report? = profile, let projectTitle, !projectTitle.isEmpty else { return config }
        let title = config.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty || title == PublishConfig.Metadata.untitled else { return config }
        var config = config
        config.metadata.title = projectTitle
        return config
    }
}
