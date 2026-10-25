import Foundation
import MaughamCore

/// **What a Word export sent** (report plan 4, R-4-4; spec §6.3): one folder
/// per export at `.maugham/exports/<book>/<export-id>/`, holding the
/// `export.docx` exactly as it left and a `sent.json` naming its label, its
/// draft and every exported piece's paragraphs (`¶id`, text). A returned file
/// is later compared against what was sent, not against the current text.
///
/// - `<book>` is `book`, or the imprint's name (`WordDraft.book(of:)`).
/// - `<export-id>` is `draft<N>-yyyyMMdd-HHmmss-<deviceSlug>` (UTC), with
///   `-2`, `-3`… after it for a second export from one device in one second.
///   The slug is the writing device's (tripwire 24), so two devices never
///   write one folder (tripwire 17); each folder is written once and never
///   rewritten. The id is chosen BEFORE the export is packaged
///   (`freeExportID`), because the `.docx` carries it as `MaughamExportID`
///   and `sent.json` as `exportID` (R-S8): a returned file names its sent
///   copy even when two devices sent the same N offline.
/// - A book's drafts are DERIVED from its folder's listing alone
///   (`drafts(book:)`): the draft is in each folder's name, so counting reads
///   no `sent.json` — a long report's records are megabytes — and no counter
///   is shared between devices.
///
/// A folder is written whole: staged under a dot-named sibling, then moved
/// into place, so a reader never meets half a sent copy. Written only after a
/// successful export (`CompileOrchestrator`); a Word file is never
/// republished (R-S8).
///
/// Backed up like the manuscript (R-S9): a sent copy is the only record of
/// what left, and nothing can rebuild it once the book moves on.
@MainActor
struct SentCopyStore {

    let projectURL: URL

    // MARK: the record

    /// `sent.json`.
    struct SentCopy: Codable, Equatable, Sendable {
        /// The folder this copy is kept in — the `.docx`'s `MaughamExportID`.
        var exportID: String
        /// "Draft 3, sent 21 October 2026" — as the `.docx` carries it.
        var label: String
        var draft: Int
        var sentAt: Date
        /// The edition's language identity (`en`, `en+sr`).
        var language: String
        /// `WordDraft.book(of:)`.
        var book: String
        /// The source body's pieces in book order (R-S2); a translated body is
        /// not recorded.
        var pieces: [Piece]
    }

    struct Piece: Codable, Equatable, Sendable {
        var pieceID: String
        var title: String
        var paragraphs: [Paragraph]
    }

    struct Paragraph: Codable, Equatable, Sendable {
        var id: String
        var text: String
    }

    /// One sent copy found on disk, by its folder's name alone. `draft` is
    /// nil when the name doesn't say (a folder this build didn't name): the
    /// folder still counts as a draft sent, its number unknown.
    struct Draft: Equatable {
        let exportID: String
        let draft: Int?
    }

    static let docxName = "export.docx"
    static let recordName = "sent.json"

    // MARK: paths

    /// `.maugham/exports/` — the one spelling of the folder.
    nonisolated static func directory(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/exports", isDirectory: true)
    }

    nonisolated static func directory(book: String, in projectURL: URL) -> URL {
        directory(in: projectURL).appendingPathComponent(book, isDirectory: true)
    }

    /// `draft<N>-yyyyMMdd-HHmmss-<slug>`, the time in UTC. The draft leads
    /// (`WordDraft.filenameToken`), so a listing alone says which draft each
    /// folder holds. The slug is interpolated here and nowhere else
    /// (tripwire 24).
    nonisolated static func exportID(draft: Int, sentAt: Date, device: DeviceSlug) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return WordDraft.filenameToken(draft) + "-" + formatter.string(from: sentAt) + "-" + device.raw
    }

    /// The draft an export id names — the `draft<N>-` `exportID` writes in
    /// front — or nil for a name that doesn't start with one.
    nonisolated static func draft(ofExportID id: String) -> Int? {
        WordDraft.leadingDraft(of: id)?.draft
    }

    /// The timestamp-and-device part of an export id.
    private nonisolated static func sentOrder(_ id: String) -> Substring {
        WordDraft.leadingDraft(of: id)?.rest ?? Substring(id)
    }

    // MARK: reading

    /// Every sent copy of `book`, oldest first, from the folder's LISTING
    /// alone (M2): the draft is in each name, so no `sent.json` is opened —
    /// a folder not yet downloaded, or one whose record is damaged, still
    /// counts and still names its draft. A dotfile (a staging folder, an
    /// iCloud placeholder) is skipped by name; the scan never uses
    /// `.skipsHiddenFiles` (`DotfileScan`).
    func drafts(book: String) -> [Draft] {
        let folder = Self.directory(book: book, in: projectURL)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return entries
            .filter { !DotfileScan.isDotfile($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            // Oldest first: by the timestamp after the draft, whatever N is.
            .sorted { (Self.sentOrder($0), $0) < (Self.sentOrder($1), $1) }
            .map { Draft(exportID: $0, draft: Self.draft(ofExportID: $0)) }
    }

    /// One sent copy's `sent.json`, or nil when it can't be read here (not
    /// yet downloaded, or damaged).
    func record(book: String, exportID: String) -> SentCopy? {
        guard let folderName = try? SafeRelativePath.requirePlainFileName(exportID) else { return nil }
        let url = Self.directory(book: book, in: projectURL)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(Self.recordName)
        guard let data = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: a Word export's sent.json, derived sidecar, not manuscript
        return try? Self.decoder().decode(SentCopy.self, from: data)
    }

    // MARK: writing

    /// How many `-n` suffixes one device's second is offered before the write
    /// gives up: far past any real burst of exports.
    static let suffixLimit = 100

    enum WriteError: Error, LocalizedError, Equatable {
        case noFreeExportID(String)
        case exportIDTaken(String)
        var errorDescription: String? {
            switch self {
            case .noFreeExportID(let id):
                return "every sent-copy name from \(id) on is taken; nothing was overwritten"
            case .exportIDTaken(let id):
                return "a sent copy named \(id) already exists; nothing was overwritten"
            }
        }
    }

    /// The export id a new sent copy of `draft` takes: the first of `id`,
    /// `id-2`, `id-3`… no folder of `book` holds. Asked before the export is
    /// packaged, since the file carries it; the mint gate holds the draft for
    /// the export's whole run, so nothing else of this device takes it
    /// before `write`.
    func freeExportID(book: String, draft: Int, sentAt: Date,
                      device: DeviceSlug = DeviceIdentity.author.slug) throws -> String {
        let folder = Self.directory(book: book, in: projectURL)
        let id = Self.exportID(draft: draft, sentAt: sentAt, device: device)
        for n in 1...Self.suffixLimit {
            let candidate = n == 1 ? id : "\(id)-\(n)"
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) { // local-path: minted here from the draft, time and device
                return candidate
            }
        }
        throw WriteError.noFreeExportID(id)
    }

    /// Writes one sent copy — `docx` copied in as `export.docx`, and `copy` as
    /// `sent.json` — at `copy.exportID` exactly, the id the file carries, and
    /// returns its folder. Staged whole in a dot-named sibling and moved into
    /// place; a folder already there is never overwritten (a move onto one
    /// fails) and the write is refused.
    @discardableResult
    func write(_ copy: SentCopy, docx: URL) throws -> URL {
        let fm = FileManager.default
        let book = Self.directory(book: copy.book, in: projectURL)

        try fm.createDirectory(at: book, withIntermediateDirectories: true)
        Self.sweepStaleStaging(in: book)
        let destination = book.appendingPathComponent(
            try SafeRelativePath.requirePlainFileName(copy.exportID), isDirectory: true)
        if fm.fileExists(atPath: destination.path) { throw WriteError.exportIDTaken(copy.exportID) }
        let staging = book.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: docx, to: staging.appendingPathComponent(Self.docxName))
        try Self.encoder().encode(copy).write(to: staging.appendingPathComponent(Self.recordName))
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch where fm.fileExists(atPath: destination.path) {
            throw WriteError.exportIDTaken(copy.exportID)  // taken between the look and the move
        }
        return destination
    }

    /// How old a staging folder must be before a write sweeps it: one a
    /// crash or a kill left behind, never another export's in progress.
    static let staleStagingAge: TimeInterval = 10 * 60

    /// Removes the `.staging-*` folders under `book` older than
    /// `staleStagingAge`. A failed removal is left for the next write.
    static func sweepStaleStaging(in book: URL, now: Date = Date()) {
        let fm = FileManager.default
        // The staging folders are dot-named on purpose, so the listing never
        // skips hidden files (`DotfileScan`'s rule, the other way round).
        guard let entries = try? fm.contentsOfDirectory(
            at: book, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])
        else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            guard let stamp = values?.contentModificationDate ?? values?.creationDate,
                  now.timeIntervalSince(stamp) > staleStagingAge else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: coding

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
