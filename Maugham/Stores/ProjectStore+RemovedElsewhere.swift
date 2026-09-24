import Foundation
import MaughamCore

/// Why a Restore from *Removed Elsewhere* did nothing.
enum RemovedElsewhereError: LocalizedError, Equatable {
    /// The piece is no longer listed — it came back another way (another Mac
    /// restored it, or its row arrived in a newer outline) since the list was
    /// drawn.
    case notListed(title: String)

    var errorDescription: String? {
        switch self {
        case .notListed(let title):
            return "“\(title)” is no longer listed as removed elsewhere, so nothing was restored."
        }
    }
}

/// What a Restore from *Removed Elsewhere* did, for the one sentence the window
/// shows beside it (nil when there is nothing to say beyond the row coming back).
struct RemovedElsewhereRestore: Equatable {
    /// The parent it had is gone, so it went to the top of the manuscript.
    var landedAtRoot = false
    /// Its old filename or title is someone else's now.
    var renamedFrom: String?
    var title: String

    var message: String? {
        var parts: [String] = []
        if landedAtRoot {
            parts.append("The group it was in is gone, so it is at the top of the manuscript.")
        }
        if let renamedFrom {
            parts.append("Another piece is called “\(renamedFrom)” now, so it came back as “\(title)”.")
        }
        return parts.isEmpty ? nil : "Restored “\(title)”. " + parts.joined(separator: " ")
    }
}

extension ProjectStore {

    /// Re-derive `removedElsewhere` (see `RemovedElsewhere` for the three legs).
    /// The file reads run off the main actor; only the answer lands here.
    func refreshRemovedElsewhere() async {
        let live = manifest.structure
        let statementIds = Set(manifest.statements.map(\.id))
        let entries = (try? await trashStore.list()) ?? trashEntries
        let trashed = RemovedElsewhere.trashedIds(in: entries)
        let projectURL = url
        let found = await Task.detached(priority: .utility) {
            RemovedElsewhere.scan(
                projectURL: projectURL, live: live,
                statementIds: statementIds, trashedIds: trashed)
        }.value
        // The structure may have moved while the scan ran (a restore, an
        // adoption); a row that is live again is not removed.
        let liveNow = Set(TreeWalk.collectIds(in: manifest.structure))
        let settled = found.filter { !liveNow.contains($0.id) }
        if settled != removedElsewhere { removedElsewhere = settled }
    }

    /// **Put a piece removed elsewhere back in the binder** (Denver's ruling,
    /// 2026-09-24).
    ///
    /// A structural verb: it inserts the row the archive held — the SAME id, so
    /// its op log joins again and nothing about its words is re-made — at its
    /// old parent and place when that parent still exists, else at the top of
    /// the manuscript, and saves the manifest through the ordinary door.
    ///
    /// **The file is DERIVED** (ADR 0019): after the save the piece is loaded
    /// through `Document.load` like any other open, and its render is written
    /// from the op log. A stale `.md` still at that path is never trusted: the
    /// load backs it up to `.maugham/conflicts/` when it differs, and the
    /// render replaces it. Because it goes through the load, every line the
    /// load holds or refuses stays held or refused — Restore is a binder act
    /// and moves no permit ("roles guard the words, not the binder").
    ///
    /// No file is moved, so the typed mover (tripwire 14) has nothing to do.
    /// Not undoable with ⌘Z: the binder's structural verbs are not on the undo
    /// stack (ADR 0023 covers op-log edits); moving the piece to Trash is the
    /// way back out, as for any row.
    @discardableResult
    func restoreRemovedElsewhere(id: String) async throws -> RemovedElsewhereRestore {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard let piece = removedElsewhere.first(where: { $0.id == id }) else {
            throw RemovedElsewhereError.notListed(title: id)
        }
        guard findItem(id: id, in: manifest.structure) == nil else {
            removedElsewhere.removeAll { $0.id == id }
            throw RemovedElsewhereError.notListed(title: piece.title)
        }

        let parentId = survivingParentId(piece.parentId, exists: { candidate in
            findItem(id: candidate, in: manifest.structure)?.type == .group
        })
        var outcome = RemovedElsewhereRestore(
            landedAtRoot: piece.parentId != nil && parentId == nil,
            title: piece.title)

        var item = piece.item
        let parentPath = parentId.flatMap { findItem(id: $0, in: manifest.structure)?.path }
        if let wanted = Self.restoreDestination(for: item.path, underParentPath: parentPath) {
            item.path = unclaimedPath(near: wanted)
        }
        let siblings = childrenOf(parentId: parentId)
        item.title = distinguishedTitle(item.title, amongst: siblings.map(\.title))
        if item.title != piece.title {
            outcome.renamedFrom = piece.title
            outcome.title = item.title
        }

        var children = siblings
        children.insert(item, at: max(0, min(piece.index, children.count)))
        replaceChildren(parentId: parentId, with: children)
        manifest.modified = Date()
        try await saveManifest()
        removedElsewhere.removeAll { $0.id == id }

        // Its words were in the book all along; they are not this session's.
        if let count = derivedWordCount(of: item) {
            recordWordCount(forDocumentId: item.id, wordCount: count)
            documentStore?.excludeForeignWords(count)
        }
        if let path = item.path { await renderRestoredPiece(at: path) }
        return outcome
    }

    /// Write the restored piece's `.md` from its op log, through the load.
    /// Best-effort: the row is already back, and a piece whose render failed
    /// still opens from its op log; the failure is logged.
    private func renderRestoredPiece(at path: String) async {
        if let open = documentStore?.document(for: path) {
            do { try await open.performAutosave() } catch {
                projectStoreLog.error(
                    "restore: render of open \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        do {
            let doc = try await Document.load(
                url: url.appendingPathComponent(path),
                actor: .author,
                session: "restore-\(UUID().uuidString.prefix(8))",
                presenter: documentStore?.presenter)
            do { try await doc.performAutosave() } catch {
                projectStoreLog.error(
                    "restore: render of \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            await doc.close()
        } catch {
            projectStoreLog.error(
                "restore: load of \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `wanted` unless a live row or a statement already claims it; else the
    /// first `<stem>-N.<ext>` that nothing claims and nothing on disk occupies.
    /// An UNCLAIMED file at `wanted` itself is this piece's own stale render
    /// (or an outside file with no row) and is replaced by the render, after
    /// the load has backed it up if it differs.
    private func unclaimedPath(near wanted: String) -> String {
        let claimed = Set(Self.allStructurePaths(in: manifest.structure))
            .union(manifest.statements.map(\.path))
        guard claimed.contains(wanted) else { return wanted }
        let ns = wanted as NSString
        let dir = ns.deletingLastPathComponent
        let ext = ns.pathExtension
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            let candidate = dir.isEmpty ? name : "\(dir)/\(name)"
            if !claimed.contains(candidate),
               !FileManager.default.fileExists(
                atPath: url.appendingPathComponent(candidate).path) {
                return candidate
            }
            n += 1
        }
    }

    private static func allStructurePaths(in items: [StructureItem]) -> [String] {
        items.flatMap { ($0.path.map { [$0] } ?? []) + allStructurePaths(in: $0.children ?? []) }
    }
}
