import Foundation
import PDFKit

/// **What the Publish persona's centre column has to show** — an answer with a
/// REASON attached, never a bare optional.
///
/// The two non-`ready` cases degrade to the same surface (the project at
/// altitude, spec §4's "the centre never renders nothing"), which is exactly why
/// they must stay distinguishable in the value: *"this project has never been
/// compiled"* and *"the catalog is there and cannot be read"* are different
/// facts about the writer's book, and collapsing them is RULING-7's forbidden
/// shape ("unreadable is never presented as empty"). A window that later grows
/// copy for the degrade reads the reason off this value rather than inventing
/// one.
enum PublishPreviewResolution: Equatable {
    /// The most recent compiled PDF this project can actually put on screen.
    case ready(Publication)
    /// The catalog was read and holds no PDF whose file is there and opens.
    case nothingCompiled
    /// The catalog exists and could not be read, carrying what the failure said
    /// — so a surface that grows copy for this has the sentence rather than
    /// having to invent one.
    ///
    /// **Today nothing in production reaches this arm**: `PublicationStore.load()`
    /// funnels through the lenient `JSONLAppendStore.load()`, which reads an
    /// unreadable-yet-present file as an empty list. A branch already on
    /// `origin/main` makes `load()` throw a named `PublicationStore.ReadError`
    /// for this fact; when it merges, the `catch` in the resolver below starts
    /// answering with this case, carrying that error's `localizedDescription`,
    /// and nothing else has to move.
    case unreadableCatalog(reason: String)

    /// The publication to draw, or nil for either degrade.
    var publication: Publication? {
        if case .ready(let publication) = self { return publication }
        return nil
    }
}

/// **The most recent compiled PDF, resolved from the tail of the catalog.**
///
/// `PublicationStore.load()` returns ASCENDING `compiledAt` (its own doc comment
/// says so, and `ListPublicationsTool` takes `suffix(limit)` for the same
/// reason), so the latest is `.last` and the walk goes backwards.
///
/// **Two guards, and both are load-bearing facts about disk rather than
/// belt-and-braces:**
///
/// - The file must EXIST. `ExportsListView`'s Delete removes the file and never
///   the JSONL, so a row outliving its file is the ordinary state of a working
///   writer's catalog, not a corruption case.
/// - It must OPEN as a PDF. `format` is a decoded field and an unknown format
///   decodes to `.pdf` (ADR 0015 forward-tolerance, `PublishConfig.Format`), so
///   a newer build's third output format arrives here claiming to be a PDF.
///
/// Either failure walks PAST the row to the next-newest, rather than giving up:
/// the writer who deleted yesterday's export still has the day before's.
@MainActor
enum PublishPreviewResolver {

    /// Production's entry point.
    static func latestReadablePDF(store: PublicationStore,
                                  projectURL: URL) async -> PublishPreviewResolution {
        await latestReadablePDF(in: projectURL, loading: { try await store.load() })
    }

    /// The rule, with the catalog handed in — so the failure arm is drivable
    /// today, before the `throws`-ing loader lands (see `.unreadableCatalog`).
    static func latestReadablePDF(
        in projectURL: URL,
        loading load: () async throws -> [Publication]
    ) async -> PublishPreviewResolution {
        let rows: [Publication]
        do {
            rows = try await load()
        } catch {
            // Deliberately catch-all rather than a typed arm: the type that
            // means this (`PublicationStore.ReadError`) does not exist on this
            // branch yet, and a `catch is` naming it would not compile. What
            // must never happen is this becoming `.nothingCompiled` — the
            // reconcile can add the typed arm above this one, but it does not
            // have to, because this one already answers with the right case and
            // the right sentence.
            return .unreadableCatalog(reason: error.localizedDescription)
        }
        for row in rows.reversed() where row.format == .pdf {
            let file = fileURL(of: row, in: projectURL)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard PDFDocument(url: file) != nil else { continue }
            return .ready(row)
        }
        return .nothingCompiled
    }

    /// `Publication.outputPath` is documented relative to the project root, and
    /// the absolute-prefix branch is `PublicationTools`' idiom rather than an
    /// invention here — the records a republish wrote before the field was
    /// normalised carry absolute paths.
    static func fileURL(of publication: Publication, in projectURL: URL) -> URL {
        publication.outputPath.hasPrefix("/")
            ? URL(fileURLWithPath: publication.outputPath)
            : projectURL.appendingPathComponent(publication.outputPath)
    }
}
