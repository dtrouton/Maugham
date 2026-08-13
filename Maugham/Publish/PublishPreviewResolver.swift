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
    /// **Every compiled PDF this project can actually put on screen, NEWEST
    /// FIRST** — and non-empty by construction: the walk answers
    /// `.nothingCompiled` when nothing survives its two guards.
    ///
    /// It became a LIST in the 2026-08-12 revision, for the header's publication
    /// picker (Denver: *"readable PDF publications only, newest first; selecting
    /// one swaps the rendered PDF"*). The head of it is still what the centre
    /// draws until the writer picks another, which is what `publication` means
    /// and why every caller that only wants "the book" is unchanged.
    case ready(newestFirst: [Publication])
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

    /// **The newest readable book** — what the centre draws until the writer
    /// picks another from the header, and nil for either degrade.
    var publication: Publication? { publications.first }

    /// **The picker's rows**, newest first; empty for either degrade. One
    /// spelling of "what this project can show", so the menu and the page
    /// cannot come to disagree about which books exist.
    var publications: [Publication] {
        if case .ready(let rows) = self { return rows }
        return []
    }
}

/// **Every compiled PDF the writer can be shown, newest first, resolved from
/// the tail of the catalog.**
///
/// `PublicationStore.load()` returns ASCENDING `compiledAt` (its own doc comment
/// says so, and `ListPublicationsTool` takes `suffix(limit)` for the same
/// reason), so the latest is `.last` and the walk goes backwards.
///
/// **It was `latestReadablePDF` and stopped at the first row it could draw**
/// until the 2026-08-12 revision gave the preview header a publication picker.
/// Generalising the walk rather than writing a second one is the whole point:
/// the two guards below are the reason a row is drawable at all, and a listing
/// that applied fewer of them would offer the writer a menu entry that renders
/// an empty page. The cost is honest and worth naming — every readable row is
/// OPENED on each refresh (window load, a compile finishing, an arrival into
/// Publish), where the old walk stopped at one.
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
    static func readablePDFs(store: PublicationStore,
                             projectURL: URL) async -> PublishPreviewResolution {
        await readablePDFs(in: projectURL, loading: { try await store.load() })
    }

    /// The rule, with the catalog handed in — so a loader failure is drivable
    /// without a squatted file on disk (see `.unreadableCatalog`). The
    /// store-taking overload above is what production calls, and
    /// `PublishPreviewCentreTests` drives a REAL unreadable catalog through it.
    static func readablePDFs(
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
        var readable: [Publication] = []
        for row in rows.reversed() where row.format == .pdf {
            let file = fileURL(of: row, in: projectURL)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard PDFDocument(url: file) != nil else { continue }
            readable.append(row)
        }
        return readable.isEmpty ? .nothingCompiled : .ready(newestFirst: readable)
    }

    /// **Which of the readable books the centre actually draws** — the writer's
    /// pick from the header when it is still there, and the newest otherwise.
    ///
    /// A pure function rather than a rule spelled in the header view, because
    /// the fallback is the load-bearing half: the picked publication's row can
    /// leave the list under the writer (they delete the export in the Finder, or
    /// a compile lands and the refresh re-walks the catalog), and a header that
    /// resolved its own selection would then draw nothing at all in a column
    /// whose whole job is to show the book.
    ///
    /// The selection is a `publicationID` rather than an index for the same
    /// reason: an index survives a list that changed underneath it and means
    /// something else afterwards.
    static func shown(_ selectedID: String?,
                      in publications: [Publication]) -> Publication? {
        guard let selectedID else { return publications.first }
        return publications.first { $0.publicationID == selectedID }
            ?? publications.first
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
