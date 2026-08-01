import Foundation
import MaughamCore

/// Adoption (M1A, spec §5): the writer's existing craft-intent research notes
/// become the project's intent `Statement`, once, on the first open by a build
/// that has statements.
///
/// **This is the one seam in the milestone that touches prose the writer already
/// wrote**, so every judgement here is biased toward not destroying it: bodies
/// are read before anything is created, duplicates are concatenated rather than
/// chosen between, the note is TRASHED (recoverable) rather than deleted, and
/// any failure leaves the legacy note exactly where it was.
///
/// The shape is `ProjectStore.load`'s project-id backfill, exactly: a one-time,
/// on-open, self-limiting migration that runs before the store is handed out.
extension ProjectStore {

    /// The schema version that introduced `statements`.
    ///
    /// Deliberately a fixed number and **not** `ProjectManifest.currentSchemaVersion`:
    /// the gate means "this manifest was written before statements existed", so
    /// a future bump to 5 must not re-run adoption across every schema-4
    /// project. The STAMP below writes `currentSchemaVersion`, because what this
    /// build saves is this build's shape.
    private static var statementsSchemaVersion: Int { 4 }

    /// Adopt legacy craft intent, once. Called from `ProjectStore.load` after
    /// `healPaletteRolesEagerly` (which stamps the durable `role` the detection
    /// below prefers) and before the store is returned.
    ///
    /// **Never throws.** A project that cannot be adopted still opens, with its
    /// legacy note untouched and the failure logged: losing access to a
    /// manuscript because an intent note was odd is a far worse outcome than
    /// un-adopted intent.
    func adoptLegacyCraftIntentIfNeeded() async {
        // The gate is the ON-DISK schema version. Gating on "has no `statements`
        // section" would re-scan, forever, every writer who legitimately has no
        // intent — absence is a valid, deliberate state (spec §5).
        guard manifest.schemaVersion < Self.statementsSchemaVersion else { return }
        #if DEBUG
        _debugAdoptionScanCount += 1
        #endif

        // Per-scope isolation: one odd note must not cost a different scope its
        // adoption.
        for (scope, notes) in legacyCraftIntentByScope() {
            do {
                try await adopt(notes: notes, into: scope)
            } catch {
                projectStoreLog.error(
                    "Craft-intent adoption failed for scope \(scope.rawValue, privacy: .public) in \(self.url.path, privacy: .public); the legacy note is left in place: \(error.localizedDescription, privacy: .public)")
            }
        }

        // The stamp is UNCONDITIONAL, including after a failure, and that is the
        // deliberate reading of "once". A manifest that carries a `statements`
        // section while still declaring schema 3 is the exact hazard §2.5
        // names: an older build would read it happily and re-save it WITHOUT the
        // section, orphaning the statement files it points at. Leaving the
        // version behind to earn a retry would buy an incomplete migration at
        // the price of a destroyed registry. An un-adopted note, by contrast,
        // costs nothing — it is still in the research tree, still the writer's.
        //
        // `modified` is untouched here, for the id backfill's reason: stamping a
        // schema version is not a content edit. Adoption of actual prose DOES
        // shift it — `createStatement` and `deleteResearchItems` each set it —
        // because moving the writer's words between files genuinely changes the
        // project.
        manifest.schemaVersion = ProjectManifest.currentSchemaVersion
        do {
            try await saveManifest()
        } catch {
            projectStoreLog.error(
                "Statement schema stamp failed for \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // `deleteResearchItems` arms the undo affordance as a side effect. A
        // migration is not something the writer just did, and a stray ⌘⌥Z on a
        // freshly opened project should not restore a note they never deleted.
        lastDeletedTrashId = nil
    }

    // MARK: - Detection

    /// Every legacy craft-intent note in the tree, grouped by the statement
    /// scope it belongs to and ordered oldest-first within each group.
    ///
    /// **Detection is role-first with the legacy filename as fallback**, the two
    /// tiers `PaletteLookup.craftIntentItem` uses, so a note the writer renamed
    /// away from `craft-intent.md` is still found. Taken as a UNION rather than
    /// a preference: a role-bearing note and a filename-bearing one are both
    /// craft intent, and this pass is the last one that will ever look.
    ///
    /// **Scope is read off the manifest, most specific evidence first:**
    ///
    /// 1. a Collection loose piece's research folder (containment — the note
    ///    lives inside the piece);
    /// 2. **a `linkedResearchIds` record naming exactly one document**;
    /// 3. otherwise the project.
    ///
    /// **Tier 2 is the milestone's headline case, not an edge.** §3's defect is
    /// a NOVEL's: a chapter's intent routes through `.sharedPlusLink`
    /// (`ResearchScope.swift:57-62`) into shared `research/`, where the old
    /// prefix lookup could never find it — but that same route writes a
    /// `linkedResearchIds` record, so **the manifest knows whose it is**.
    /// Without this tier a writer with intent on ten chapters would open the new
    /// pane to one headingless blob, with the records that said whose was whose
    /// trashed alongside it. Nothing would be destroyed and nothing would be
    /// right.
    ///
    /// Tier 3 remains deliberately generous: a note linked to nothing, or under
    /// no recognised prefix, goes to the project rather than being left where
    /// nothing looks. A note listed by TWO documents falls here too — that
    /// ambiguity is real, and guessing between claimants would file a writer's
    /// intent under a heading the manifest never claimed.
    ///
    /// **A note with no file is not a candidate at all.** It has no prose to
    /// adopt, and including it would hand it to `deleteResearchItems`, which
    /// drops a pathless item from the manifest with **no trash entry** — a
    /// silent, unrecoverable removal in the one seam that must never make one.
    private func legacyCraftIntentByScope() -> [(Statement.Scope, [ResearchItem])] {
        let notes = TreeWalk.collect(in: manifest.research) { item in
            item.type == .asset
                && !(item.path ?? "").isEmpty
                && (item.role == .craftIntent
                    || (item.path as NSString?)?.lastPathComponent
                        == PaletteConvention.craftIntentFileName)
        }
        guard !notes.isEmpty else { return [] }

        let piecePrefixes: [(prefix: String, pieceId: String)] =
            manifest.structure.compactMap { piece in
                Self.pieceResearchPrefix(for: piece).map { ($0, piece.id) }
            }

        // An ordered dictionary by hand: scope order follows first appearance in
        // the tree, so a failure log reads in the order the writer's tree does.
        var grouped: [(Statement.Scope, [ResearchItem])] = []
        var positionOfScope: [String: Int] = [:]
        for note in notes {
            let path = note.path ?? ""
            let scope: Statement.Scope
            if let piece = piecePrefixes.first(where: { path.hasPrefix($0.prefix) }) {
                scope = .document(piece.pieceId)
            } else if let linked = documentClaiming(researchId: note.id) {
                scope = .document(linked)
            } else {
                scope = .project
            }
            if let at = positionOfScope[scope.rawValue] {
                grouped[at].1.append(note)
            } else {
                positionOfScope[scope.rawValue] = grouped.count
                grouped.append((scope, [note]))
            }
        }
        return grouped.map { ($0.0, Self.oldestFirst($0.1)) }
    }

    /// The one manuscript document whose `linkedResearchIds` names this note, or
    /// nil for none — **or for more than one**, where the ambiguity is real and
    /// the project is the honest answer.
    ///
    /// Restricted to `.document` items: `linkResearch` mutates whatever id
    /// matches and does not check, and `createStatement` refuses a group scope
    /// anyway — which would fail the whole scope rather than fall back.
    private func documentClaiming(researchId: String) -> String? {
        let claimants = TreeWalk.collect(in: manifest.structure) { item in
            item.type == .document
                && (item.linkedResearchIds?.contains(researchId) ?? false)
        }
        return claimants.count == 1 ? claimants[0].id : nil
    }

    /// Oldest first by `addedAt` — the only age a research note records — with
    /// ties and undated notes falling back to tree order. An undated note
    /// predates the field, so `.distantPast` is the honest guess for nil.
    private static func oldestFirst(_ notes: [ResearchItem]) -> [ResearchItem] {
        notes.enumerated().sorted { a, b in
            let left = a.element.addedAt ?? .distantPast
            let right = b.element.addedAt ?? .distantPast
            if left != right { return left < right }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - The move

    /// Move one scope's craft intent into its statement.
    ///
    /// The order of the steps is the safety property. Every body is read
    /// **before** anything is created, so a note this build cannot read costs
    /// nothing but the adoption; the notes are trashed **last**, so nothing
    /// leaves the research tree until its words are durably somewhere else.
    private func adopt(notes: [ResearchItem], into scope: Statement.Scope) async throws {
        let bodies = try notes.map { note -> String in
            // Non-empty by construction: `legacyCraftIntentByScope` excludes a
            // pathless item, because there is nothing in it to adopt.
            let path = note.path ?? ""
            // adr-0018-ok: sanctioned import read — a legacy craft-intent
            // research note is plain, op-log-free markdown, and this is the one
            // pass that turns it into op-log truth. NOT `try?`: a body this
            // build cannot read today (an undownloaded iCloud file is the
            // everyday version) must fail its scope, or it would be adopted as
            // nothing and then trashed.
            return try String(
                contentsOf: url.appendingPathComponent(path), encoding: .utf8)
        }
        let joined = Self.concatenated(bodies: bodies)
        // Nothing written is nothing to adopt. Minting an empty statement for an
        // empty note would swap one absence for another and cost a file.
        guard !joined.isEmpty else { return }

        let statement = try await createStatement(kind: .intent, scope: scope)
        let fileURL = url.appendingPathComponent(statement.path)
        try Data((joined + "\n").utf8).write(to: fileURL, options: .atomic)

        // **The third opener takes the gate too** (whole-branch review, I2).
        // Adoption is safe without it by circumstance — it runs inside
        // `ProjectStore.load`, before the store is handed out, on a statement it
        // created moments earlier, and `openStatementDocuments` is per-store so
        // no lock could span two windows anyway. But "safe because of where it
        // happens to sit" is a property the next edit to `ProjectStore.load`
        // silently removes, and the gate costs one uncontended set insertion.
        // Held across the close, as `appendToStatement`'s transient arm is, so
        // nothing opens this path until the bootstrap ops are on disk.
        await lockStatementOpen(statement.id)
        defer { unlockStatementOpen(statement.id) }

        // The content becomes a BOOTSTRAP OP, through the path `Document.load`
        // already takes for an imported plain file with an empty op log
        // (`Document+Load.swift`'s `needsBootstrap` branch — the sanctioned
        // import read). Writing the file and stopping here would look identical
        // on screen and leave the writer's adopted intent with no history at
        // all; `Document.load` is also the contract surface `Bootstrap.run` must
        // be reached through, and the only way to construct a `Document`.
        let doc = try await Document.load(
            url: fileURL, device: projectOpDevice, session: projectOpSession,
            presenter: documentStore?.presenter)
        await doc.close()

        // Trashed, not deleted: recoverable from the Trash pane if this pass got
        // something wrong. Routed through `deleteResearchItems`, which removes
        // the manifest entries in one save.
        //
        // **At adoption time that trash does NOT run the typed mover's
        // close-flush-unregister discipline, and it does not need to.**
        // `documentStore` is wired by `ProjectWindow` only after
        // `ProjectStore.load` has returned, so `trashResearchItemCore` takes its
        // `// internal-move:` branch and calls `trashStore.moveToTrash`
        // directly. That is safe here for the reason that branch already gives —
        // with no DocumentStore there is no registry to race, no open Document
        // to close and no debounced save to flush — but it is safe for *that*
        // reason and not because the discipline ran, and a reader who assumes
        // otherwise will reason wrongly about this window.
        try await deleteResearchItems(ids: notes.map(\.id))
    }

    /// The writer's notes as one body: **oldest first, separated by a blank
    /// line**.
    ///
    /// Concatenating rather than choosing is the whole ruling. The §3 defect has
    /// been minting second copies for as long as it has shipped, so a writer can
    /// hold two notes for one scope with no way to tell which is "the" one —
    /// and concatenation is recoverable where a discarded body is not.
    private static func concatenated(bodies: [String]) -> String {
        bodies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
