import Foundation
import PDFKit
import AppKit

/// Shared language-addressing rule for `list_publications`'s filter and
/// `read_publication_page`'s disambiguation (spec 2026-07-23): the
/// documented sentinel `"source"` selects the untagged source-language
/// edition (`language == nil`); any other string is an exact tag match.
/// Both tools must agree on this so a `language` value means the same thing
/// everywhere in this file.
private func languageMatches(_ actual: String?, requested: String) -> Bool {
    if requested == "source" { return actual == nil }
    return actual == requested
}

/// Shared imprint-addressing rule for `list_publications`'s filter and
/// `read_publication_page`'s disambiguation (spec 2026-08-27): the documented
/// sentinel `"book"` selects the rows no imprint compiled (`imprint == nil`);
/// any other string is an exact name match. A sibling of `languageMatches`,
/// and shared for the same reason — one meaning of a value everywhere in this
/// file. (A project MAY legally name an imprint `book`; the sentinel then
/// wins, exactly as `"source"` would over a language tag spelled `source`.)
private func imprintMatches(_ actual: String?, requested: String) -> Bool {
    if requested == "book" { return actual == nil }
    return actual == requested
}

// MARK: - list_publications

public enum ListPublicationsTool: MCPTool {
    public static let method = "list_publications"
    public static let description =
    "List publications recorded for a project. Optional filters: publication_id (exact, the unique key — prefer this when you need to address one specific publication), version (non-unique when init has reset the counter past a prior publication), language (exact tag match, e.g. \"es\" — a bilingual (or wider) publication's language is the joined list of the tongues it carries, in order, with the source body spelled by the book's own metadata.language, e.g. \"en+sr\", matched exactly; the sentinel \"source\" selects the untagged source-language rows, not a joined identity that happens to include the source), format, imprint (exact name match, e.g. \"special\"; the sentinel \"book\" selects the rows no imprint compiled), limit (default 50, takes the most recent N). A publication is keyed on (imprint, version, language, format), so the book's 0.1 and an imprint's 0.1 are different publications. When multiple publications share a version, all are returned by the version filter; use publication_id to disambiguate. Every row surfaces its language field explicitly — null for the source edition, the tag string (or joined tag list) for an edition — so a version's language family (spec 2026-07-23) can be enumerated with one call. Every row surfaces its imprint field the same way — null for the book, the name string for an imprint."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"},"publication_id":{"type":"string"},"version":{"type":"string"},"language":{"type":"string","description":"Exact tag match (e.g. \\"es\\"); sentinel \\"source\\" selects rows where language is null."},"imprint":{"type":"string","description":"Exact imprint name (e.g. \\"special\\"); sentinel \\"book\\" selects rows where imprint is null."},"format":{"type":"string","enum":["pdf","epub"]},"limit":{"type":"integer","default":50}},"required":["project_id"]}
    """

    struct Params: Codable {
        let projectID: String
        let publicationID: String?
        let version: String?
        let language: String?
        let imprint: String?
        let format: PublishConfig.Format?
        let limit: Int?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case publicationID = "publication_id"
            case version, language, imprint, format, limit
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.projectID, in: registry)
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: entry.url)
        var pubs = try await stores.publicationStore.load()
        if let pid = params.publicationID { pubs = pubs.filter { $0.publicationID == pid } }
        if let v = params.version { pubs = pubs.filter { $0.version == v } }
        if let lang = params.language {
            pubs = pubs.filter { languageMatches($0.language, requested: lang) }
        }
        if let imp = params.imprint {
            pubs = pubs.filter { imprintMatches($0.imprint, requested: imp) }
        }
        if let f = params.format  { pubs = pubs.filter { $0.format == f } }
        let limit = params.limit ?? 50
        if pubs.count > limit { pubs = Array(pubs.suffix(limit)) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let pubsData = try encoder.encode(pubs)
        guard var pubsArray = try JSONSerialization.jsonObject(with: pubsData) as? [[String: Any]] else {
            throw MCPError.internalError("failed to encode publications")
        }
        // `Publication.encode` uses `encodeIfPresent` for `language` and
        // `imprint` (so old JSONL records without the fields keep decoding),
        // which means a nil value OMITS the key rather than encoding JSON
        // null. The tool contract promises every row surfaces both
        // explicitly — backfill the keys here rather than changing the
        // on-disk encoding.
        for i in pubsArray.indices {
            if pubsArray[i]["language"] == nil { pubsArray[i]["language"] = NSNull() }
            if pubsArray[i]["imprint"] == nil { pubsArray[i]["imprint"] = NSNull() }
        }
        return try JSONSerialization.data(
            withJSONObject: ["publications": pubsArray], options: [.sortedKeys])
    }
}

// MARK: - read_publication_page

public enum ReadPublicationPageTool: MCPTool {
    public static let method = "read_publication_page"
    public static let description =
    "Rasterize one page of a publication's PDF as a JPEG. Address the publication by either publication_id (unique, preferred) or version (non-unique when init has reset the counter past a prior publication — first-write-wins). At least one must be provided. Optional language disambiguates a version shared across a language family (spec 2026-07-23): exact tag match (e.g. \"es\") — a bilingual (or wider) publication's language is the joined list of the tongues it carries, in order, with the source body spelled by the book's own metadata.language, e.g. \"en+sr\" — or the sentinel \"source\" for the untagged source edition; combined with version it resolves that specific family member, combined with publication_id it must agree with that publication's language (mirroring the publication_id+version agreement rule) — version-only addressing is unaffected and keeps first-write-wins. Optional imprint disambiguates the same way for imprints (spec 2026-08-27): exact name match (e.g. \"special\"), or the sentinel \"book\" for a publication no imprint compiled; with version it narrows the family, with publication_id it must agree. Optional max_dimension/quality/region (region is normalized 0–1, top-left origin). Returns the same image-response envelope as read_document. Pages are 1-indexed."
    public static let inputSchemaJSON = #"""
    {"type":"object","properties":{"project_id":{"type":"string"},"publication_id":{"type":"string","description":"Unique publication identifier (preferred). Mutually informative with version, language and imprint: if given alongside any of them, must refer to the same publication."},"version":{"type":"string","description":"Version string (e.g. \"0.1\"). First-write-wins when ambiguous, unless language or imprint narrows it."},"language":{"type":"string","description":"Exact tag match (e.g. \"es\") or sentinel \"source\" for the untagged source edition. With version, resolves the specific family member sharing that version; with publication_id, must agree with that publication's language."},"imprint":{"type":"string","description":"Exact imprint name (e.g. \"special\") or sentinel \"book\" for a publication no imprint compiled. With version, narrows the family to that imprint; with publication_id, must agree with that publication's imprint."},"page_number":{"type":"integer"},"max_dimension":{"type":"integer","description":"Longest-edge cap (256–4096, default 2048)."},"quality":{"type":"integer","description":"JPEG quality 10–100 (default 85)."},"region":{"type":"object","description":"Optional crop, normalized 0–1, top-left origin.","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"required":["x","y","width","height"]}},"required":["project_id","page_number"]}
    """#

    struct Params: Codable {
        let projectID: String
        let publicationID: String?
        let version: String?
        let language: String?
        let imprint: String?
        let pageNumber: Int
        let maxDimension: Int?
        let quality: Int?
        let region: ImageResponseBuilder.Region?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case publicationID = "publication_id"
            case version, language, imprint
            case pageNumber = "page_number"
            case maxDimension = "max_dimension"
            case quality, region
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.projectID, in: registry)
        let projectURL = entry.url
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: projectURL)
        let pubs = try await stores.publicationStore.load()

        // Resolution: publication_id is the unique key; version is a non-
        // unique display string, now shared across a language family
        // (spec 2026-07-23). Prefer publication_id; fall back to version
        // (optionally narrowed by language) with first-write-wins tiebreak
        // when language is absent; refuse if neither given.
        let pub: Publication
        if let pid = params.publicationID {
            guard let match = pubs.first(where: { $0.publicationID == pid }) else {
                throw MCPError.invalidArgument(
                    "no publication with publication_id='\(pid)'")
            }
            // If version is also given, it must agree.
            if let v = params.version, match.version != v {
                throw MCPError.invalidArgument(
                    "publication_id='\(pid)' has version='\(match.version)', not the requested version='\(v)'")
            }
            // If language is also given, it must agree (mirrors the version
            // agreement check above).
            if let lang = params.language, !languageMatches(match.language, requested: lang) {
                throw MCPError.invalidArgument(
                    "publication_id='\(pid)' has language='\(match.language ?? "source")', not the requested language='\(lang)'")
            }
            // And so must imprint — the same agreement rule, spelled in the
            // imprint's own sentinel so a book publication reads as 'book'
            // rather than as an absence.
            if let imp = params.imprint, !imprintMatches(match.imprint, requested: imp) {
                throw MCPError.invalidArgument(
                    "publication_id='\(pid)' has imprint='\(match.imprint ?? "book")', not the requested imprint='\(imp)'")
            }
            // Format must be PDF (only PDFs are rasterizable).
            guard match.format == .pdf else {
                throw MCPError.invalidArgument(
                    "publication '\(pid)' is format=\(match.format.rawValue); only PDF publications can be rasterized")
            }
            pub = match
        } else if let v = params.version {
            var candidates = pubs.filter { $0.version == v && $0.format == .pdf }
            // `imprint` narrows the family the way `language` does, and runs
            // first so a caller who named both gets the more specific refusal
            // when no publication under that imprint exists at all. With no
            // `imprint` given `candidates` is exactly what it was before —
            // version-only addressing keeps first-write-wins.
            if let imp = params.imprint {
                candidates = candidates.filter { imprintMatches($0.imprint, requested: imp) }
                guard !candidates.isEmpty else {
                    throw MCPError.invalidArgument(
                        "no PDF publication with version='\(v)' and imprint='\(imp)'")
                }
            }
            if let lang = params.language {
                guard let match = candidates.first(where: { languageMatches($0.language, requested: lang) }) else {
                    throw MCPError.invalidArgument(
                        "no PDF publication with version='\(v)' and language='\(lang)'")
                }
                pub = match
            } else {
                guard let match = candidates.first else {
                    throw MCPError.invalidArgument(
                        "no PDF publication with version='\(v)'")
                }
                pub = match
            }
        } else {
            throw MCPError.invalidArgument(
                "either publication_id or version must be provided")
        }

        // Resolve to absolute path; outputPath is stored relative to the project root.
        let path = pub.outputPath.hasPrefix("/")
            ? URL(fileURLWithPath: pub.outputPath)
            : projectURL.appendingPathComponent(pub.outputPath)

        guard let pdf = PDFDocument(url: path) else {
            throw MCPError.internalError("could not open PDF at \(path.path)")
        }
        let zeroBased = params.pageNumber - 1
        guard zeroBased >= 0, zeroBased < pdf.pageCount,
              let page = pdf.page(at: zeroBased) else {
            throw MCPError.invalidArgument(
                "page out of range: \(params.pageNumber) (publication has \(pdf.pageCount) pages)")
        }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw MCPError.internalError("page has zero dimensions")
        }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(bounds)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()

        return try ImageResponseBuilder.encodeEnvelope(
            nsImage: image,
            region: params.region,
            maxDimension: params.maxDimension,
            quality: params.quality)
    }
}

// MARK: - republish

public enum RepublishTool: MCPTool {
    public static let method = "republish"
    public static let description =
    "Recompile from a previous Publication's snapshot. Uses the snapshotted template/styles/config, not the current live ones. Produces a new Publication entry with republished_from set."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"},"snapshot_id":{"type":"string"},"format":{"type":"string","enum":["pdf","epub"],"default":"pdf"},"label":{"type":"string"}},"required":["project_id","snapshot_id"]}
    """

    struct Params: Codable {
        let projectID: String
        let snapshotID: String
        let format: PublishConfig.Format?
        let label: String?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case snapshotID = "snapshot_id"
            case format, label
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.projectID, in: registry)
        let store = entry.store
        let projectURL = entry.url
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: projectURL)
        // Resolve the prior publication BEFORE building astSource — its
        // `language` must drive translation substitution here exactly like
        // CompileTool threads `params.language`, or a republished translated
        // edition silently compiles the byte-identical source-language body
        // (found during Task 9 F1 hardening). `Republisher.republish` looks
        // up the SAME prior via `PublicationStore.publication(forSnapshotID:)`
        // — resolving it here too, rather than re-deriving it a second way,
        // keeps the two agreeing on which publication is "prior".
        let prior = try await stores.publicationStore.publication(
            forSnapshotID: params.snapshotID)
        // P2: `prior?.language` used to be threaded here, but for a bilingual
        // (or wider) edition it is now a JOINED identity ("en+sr") — not a
        // single tag `ProjectStoreASTSource` could bind to — and binding it
        // would be meaningless regardless: `Republisher.republish` rebinds
        // the source to EVERY body itself, once per tag, through
        // `BodyPlan.make` (Task 2's `LanguageRebindableSource`), so whatever
        // language this construction names is discarded and rebuilt per body
        // before a word is emitted. Bind unbound.
        let republisher = Republisher(
            projectURL: projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: store, language: nil),
            publicationStore: stores.publicationStore,
            snapshotStore: stores.snapshotStore,
            jobManager: stores.jobManager,
            mintGate: stores.mintGate,
            maughamVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            tectonicVersion: "0.15.0")
        let outcome = try await republisher.republish(
            snapshotID: params.snapshotID,
            format: params.format ?? .pdf,
            label: params.label)
        return try CompileResponseEncoder.encodeOutcome(outcome)
    }
}
