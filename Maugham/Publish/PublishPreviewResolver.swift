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
    /// **Production reaches this arm as of the 2026-08-12 reconcile.**
    /// `PublicationStore.load()` now reads each device file through the strict
    /// `JSONLAppendStore.loadStrict()` and throws a named
    /// `PublicationStore.ReadError.unreadableFile(name:underlying:)` when one
    /// exists and cannot be read (RULING-54). The `catch` in the resolver below
    /// answers with this case, carrying that error's `localizedDescription`, so
    /// the writer's placeholder names the file rather than claiming the book was
    /// never made.
    ///
    /// **One unreadable device file refuses the whole preview, even when another
    /// file holds a perfectly good row — and that is the right answer, not a
    /// casualty of the strict read.** The unreadable file may hold a NEWER
    /// edition, so drawing the newest row we happen to be able to see would
    /// present a stale PDF as "your latest compile". Refusing keeps the centre
    /// honest about what it cannot see.
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

    /// The rule, with the catalog handed in — so a loader failure is drivable
    /// without a squatted file on disk (see `.unreadableCatalog`). The
    /// store-taking overload above is what production calls, and
    /// `PublishPreviewCentreTests` drives a REAL unreadable catalog through it.
    static func latestReadablePDF(
        in projectURL: URL,
        loading load: () async throws -> [Publication]
    ) async -> PublishPreviewResolution {
        let rows: [Publication]
        do {
            rows = try await load()
        } catch {
            // **Deliberately catch-all, and it stays that way after the
            // reconcile.** `PublicationStore.ReadError` is what production
            // throws here and its `errorDescription` is the sentence the
            // placeholder shows — but a typed `catch is` arm would narrow this
            // to the one failure we thought of, and the loader is a closure: a
            // future caller's own error would fall through to a rethrow this
            // non-throwing function cannot make. What must never happen is this
            // becoming `.nothingCompiled` (RULING-7's forbidden shape); the
            // catch-all already answers with the right case and the right
            // sentence for every error that can arrive.
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
