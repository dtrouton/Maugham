import Foundation
import PDFKit
import AppKit

// MARK: - list_publications

public enum ListPublicationsTool: MCPTool {
    public static let method = "list_publications"
    public static let description =
    "List publications recorded for a project. Optional filters: publication_id (exact, the unique key — prefer this when you need to address one specific publication), version (non-unique when init has reset the counter past a prior publication), format, limit (default 50, takes the most recent N). When multiple publications share a version, all are returned by the version filter; use publication_id to disambiguate."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"project_id":{"type":"string"},"publication_id":{"type":"string"},"version":{"type":"string"},"format":{"type":"string","enum":["pdf","epub"]},"limit":{"type":"integer","default":50}},"required":["project_id"]}
    """

    struct Params: Codable {
        let projectID: String
        let publicationID: String?
        let version: String?
        let format: PublishConfig.Format?
        let limit: Int?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case publicationID = "publication_id"
            case version, format, limit
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: entry.url)
        var pubs = try await stores.publicationStore.load()
        if let pid = params.publicationID { pubs = pubs.filter { $0.publicationID == pid } }
        if let v = params.version { pubs = pubs.filter { $0.version == v } }
        if let f = params.format  { pubs = pubs.filter { $0.format == f } }
        let limit = params.limit ?? 50
        if pubs.count > limit { pubs = Array(pubs.suffix(limit)) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let pubsData = try encoder.encode(pubs)
        let pubsObj = try JSONSerialization.jsonObject(with: pubsData)
        return try JSONSerialization.data(
            withJSONObject: ["publications": pubsObj], options: [.sortedKeys])
    }
}

// MARK: - read_publication_page

public enum ReadPublicationPageTool: MCPTool {
    public static let method = "read_publication_page"
    public static let description =
    "Rasterize one page of a publication's PDF as a JPEG. Address the publication by either publication_id (unique, preferred) or version (non-unique when init has reset the counter past a prior publication — first-write-wins). At least one must be provided. Optional max_dimension/quality/region (region is normalized 0–1, top-left origin). Returns the same image-response envelope as read_document. Pages are 1-indexed."
    public static let inputSchemaJSON = #"""
    {"type":"object","properties":{"project_id":{"type":"string"},"publication_id":{"type":"string","description":"Unique publication identifier (preferred). Mutually informative with version: if both given, must refer to the same publication."},"version":{"type":"string","description":"Version string (e.g. \"0.1\"). First-write-wins when ambiguous."},"page_number":{"type":"integer"},"max_dimension":{"type":"integer","description":"Longest-edge cap (256–4096, default 2048)."},"quality":{"type":"integer","description":"JPEG quality 10–100 (default 85)."},"region":{"type":"object","description":"Optional crop, normalized 0–1, top-left origin.","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"required":["x","y","width","height"]}},"required":["project_id","page_number"]}
    """#

    struct Params: Codable {
        let projectID: String
        let publicationID: String?
        let version: String?
        let pageNumber: Int
        let maxDimension: Int?
        let quality: Int?
        let region: ImageResponseBuilder.Region?
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case publicationID = "publication_id"
            case version
            case pageNumber = "page_number"
            case maxDimension = "max_dimension"
            case quality, region
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        let projectURL = entry.url
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: projectURL)
        let pubs = try await stores.publicationStore.load()

        // Resolution: publication_id is the unique key; version is a non-
        // unique display string. Prefer publication_id; fall back to version
        // with first-write-wins tiebreak; refuse if neither given.
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
            // Format must be PDF (only PDFs are rasterizable).
            guard match.format == .pdf else {
                throw MCPError.invalidArgument(
                    "publication '\(pid)' is format=\(match.format.rawValue); only PDF publications can be rasterized")
            }
            pub = match
        } else if let v = params.version {
            guard let match = pubs.first(where: {
                $0.version == v && $0.format == .pdf
            }) else {
                throw MCPError.invalidArgument(
                    "no PDF publication with version='\(v)'")
            }
            pub = match
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
        guard let json = paramsJSON else {
            throw MCPError.invalidArgument("missing params")
        }
        let params = try JSONDecoder().decode(Params.self, from: json)
        guard let entry = registry.lookup(id: params.projectID) else {
            throw MCPError.invalidArgument("unknown project_id")
        }
        let store = entry.store
        let projectURL = entry.url
        let stores = PublishingStores.sharedFor(
            projectID: params.projectID, projectURL: projectURL)
        let republisher = Republisher(
            projectURL: projectURL,
            astSource: ProjectStoreASTSource(projectStore: store),
            publicationStore: stores.publicationStore,
            snapshotStore: stores.snapshotStore,
            jobManager: stores.jobManager,
            maughamVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            tectonicVersion: "0.15.0")
        let outcome = try await republisher.republish(
            snapshotID: params.snapshotID,
            format: params.format ?? .pdf,
            label: params.label)
        return try CompileResponseEncoder.encodeOutcome(outcome)
    }
}
