import Foundation
import MaughamCore

/// A manuscript piece that left this book's structure WITHOUT going to Trash
/// (Denver's ruling, 2026-09-24) — most often an older build on another Mac
/// saving a stale outline over this one, which the window adopts
/// last-writer-wins (F7). Its words are still in its op log; its row is the
/// one it had in the newest archived outline that still held it.
struct RemovedElsewherePiece: Identifiable, Equatable, Sendable {
    /// The row as it last stood, from the archive: same id, so the op log joins
    /// again when it is put back (tripwire 22's path-keyed reload follows).
    let item: StructureItem
    /// Its parent in that archive (nil = the manuscript root).
    let parentId: String?
    /// Its place among that parent's children in that archive.
    let index: Int
    /// When the archive was written — the moment this Mac replaced the outline
    /// that still held it, which is when the removal reached this Mac.
    let removedAt: Date

    var id: String { item.id }
    var title: String { item.title }
}

/// **Which pieces were removed elsewhere** — derived on demand, never stored.
///
/// A piece qualifies when all three hold:
/// 1. **It has an op log in this book** (`OpLogStore.docIds(inOpsDirectoryFilenames:)`,
///    the one filename→docId reader, which already leaves out `__project__`),
///    and it is not a statement (statements are op-logged too).
/// 2. **Nothing in the book accounts for it**: no row in the live structure
///    and no Trash entry (a trashed group accounts for every row under it).
/// 3. **An archived outline in `.maugham/conflicts/` held it as a document.**
///
/// The third leg is not decoration. Trash does not delete a piece's op log
/// when it is emptied, and neither does the 30-day sweep, so without it every
/// chapter a writer ever deleted and let go of would come back here labelled
/// as something another device did. Archives are written only when another
/// device's outline replaces this window's (or arrives while a verb runs, or
/// from a later build), so a single-device book has none and lists nothing.
/// The stated limits both follow from that: a piece removed while every Mac
/// holding it was CLOSED left no archive and is not listed; and a piece that
/// appeared in some archive and was LATER trashed here and emptied is listed,
/// because nothing records the emptying.
enum RemovedElsewhere {

    /// Op-log doc ids nothing in the book accounts for (legs 1 and 2).
    static func candidates(
        opLogDocIds: Set<String>,
        live: [StructureItem],
        statementIds: Set<String>,
        trashedIds: Set<String>
    ) -> Set<String> {
        opLogDocIds
            .subtracting(TreeWalk.collectIds(in: live))
            .subtracting(statementIds)
            .subtracting(trashedIds)
    }

    /// One archived outline: when it was written, and its structure (decoded
    /// only when asked, so a scan stops reading once every candidate is found).
    struct Archive {
        let date: Date
        let structure: () -> [StructureItem]?
    }

    /// Leg 3: each candidate's row from the NEWEST archive holding it as a
    /// document. `archives` may come in any order. Newest removal first.
    static func pieces(
        candidates: Set<String>, archives: [Archive]
    ) -> [RemovedElsewherePiece] {
        guard !candidates.isEmpty else { return [] }
        var remaining = candidates
        var found: [RemovedElsewherePiece] = []
        for archive in archives.sorted(by: { $0.date > $1.date }) {
            guard !remaining.isEmpty else { break }
            guard let structure = archive.structure() else { continue }
            for located in documents(in: structure, parentId: nil)
            where remaining.contains(located.item.id) {
                remaining.remove(located.item.id)
                var row = located.item
                row.children = nil
                found.append(RemovedElsewherePiece(
                    item: row, parentId: located.parentId,
                    index: located.index, removedAt: archive.date))
            }
        }
        return found.sorted {
            $0.removedAt != $1.removedAt
                ? $0.removedAt > $1.removedAt
                : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// Every id a Trash entry accounts for: the row it recorded and every row
    /// beneath it. An entry whose record cannot be read still names its
    /// original id in its folder name (`yyyyMMdd-HHmmss-<id>`).
    static func trashedIds(in entries: [TrashEntry]) -> Set<String> {
        var ids = Set<String>()
        for entry in entries {
            if let item = try? JSONDecoder().decode(
                StructureItem.self, from: entry.itemMetadata) {
                ids.formUnion(TreeWalk.collectIds(in: [item]))
            }
            let parts = entry.id.split(separator: "-", maxSplits: 2)
            if parts.count == 3 { ids.insert(String(parts[2])) }
        }
        return ids
    }

    // MARK: - Reading the book

    /// Legs 1–3 against the files. Synchronous and actor-free, for a caller
    /// to run off the main actor. Cheap when nothing is missing: the conflicts
    /// directory is not listed at all unless some op log is unaccounted for.
    static func scan(
        projectURL: URL,
        live: [StructureItem],
        statementIds: Set<String>,
        trashedIds: Set<String>
    ) -> [RemovedElsewherePiece] {
        let fm = FileManager.default
        let opsNames = ((try? fm.contentsOfDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent)
        let unaccounted = candidates(
            opLogDocIds: OpLogStore.docIds(inOpsDirectoryFilenames: opsNames),
            live: live, statementIds: statementIds, trashedIds: trashedIds)
        guard !unaccounted.isEmpty else { return [] }

        let conflicts = projectURL.appendingPathComponent(".maugham/conflicts")
        let archiveURLs = (try? fm.contentsOfDirectory(
            at: conflicts, includingPropertiesForKeys: nil)) ?? []
        let archives = archiveURLs.compactMap { url -> Archive? in
            guard let date = ManifestConflictArchive.date(
                fromFileName: url.lastPathComponent) else { return nil }
            return Archive(date: date, structure: { decodeStructure(at: url) })
        }
        return pieces(candidates: unaccounted, archives: archives)
    }

    /// Only the structure, so an archive from a later build (whose other
    /// fields this build may not read) still names its rows.
    private static func decodeStructure(at url: URL) -> [StructureItem]? {
        struct Probe: Decodable { let structure: [StructureItem] }
        guard let data = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: archived manifest JSON read, not manuscript
        return (try? ProjectManifest.makeDecoder().decode(Probe.self, from: data))?.structure
    }

    // MARK: - Tree walking

    private struct Located {
        let item: StructureItem
        let parentId: String?
        let index: Int
    }

    private static func documents(
        in items: [StructureItem], parentId: String?
    ) -> [Located] {
        var out: [Located] = []
        for (index, item) in items.enumerated() {
            if item.type == .document, item.path != nil {
                out.append(Located(item: item, parentId: parentId, index: index))
            }
            if let children = item.children {
                out.append(contentsOf: documents(in: children, parentId: item.id))
            }
        }
        return out
    }
}
