import Foundation
import MaughamCore

/// **The posture door's state, one per `DocumentStore`** (P3c Task 2).
///
/// Held by the store as a single stored property (an extension cannot declare
/// one) and read only through `DocumentStore+Posture`. Two fields are observed
/// — `epoch`, which every trust change and manifest adoption bumps, and
/// `overridden`, the root's *Edit Anyway* set — so a view that asks
/// `posture(forDocId:)` in its `body` re-renders when either moves. Everything
/// else is bookkeeping a view must not re-render over.
@MainActor
@Observable
final class PostureBook {

    /// Bumped on every trust change (`DocumentStore.invalidateTrust`), on every
    /// manifest adoption, and again whenever the off-main refresh that follows
    /// either one lands. The permit cache is cleared with it.
    fileprivate(set) var epoch = 0

    /// **Pieces whose owner this window has chosen not to yield to** (plan
    /// ruling R2): the root's *Edit Anyway*. Per store — so per window — per
    /// piece, for the session. Never persisted, never synced.
    fileprivate(set) var overridden: Set<String> = []

    fileprivate struct Key: Hashable {
        let docId: String
        let actor: DeviceActor
    }

    /// The permit answered for each `(docId, actor)` in THIS epoch.
    @ObservationIgnored fileprivate var permits: [Key: LocalWritePermit] = [:]

    /// The last permit answered for each key in ANY epoch — the provisional
    /// answer while a refresh is in flight, never a cache hit.
    @ObservationIgnored fileprivate var lastKnown: [Key: LocalWritePermit] = [:]

    /// docId → the writers this device, as the root, yields to on that piece.
    /// Empty until the off-main `PieceWriters` read lands: until then nobody is
    /// yielded to, because a lock the writer did not earn is the worse error.
    @ObservationIgnored fileprivate var yields: [String: String] = [:]

    /// The registry signature taken just BEFORE the posture store's table was
    /// warmed — nil while no warm table is in hand. A cache miss builds only
    /// while the folder still reads this way; otherwise the builder would
    /// resolve the table on the main actor.
    @ObservationIgnored fileprivate var readySignature: String?

    /// Every scheduled refresh takes a generation; one that finds a newer
    /// generation when it wakes has been superseded and writes nothing.
    @ObservationIgnored fileprivate var generation = 0
    @ObservationIgnored fileprivate var refresh: Task<Void, Never>?

    /// The store the door asks — built through `Document.makeLoadOpStore`, so
    /// it has the loads' identities, device state and registry memory, and
    /// never appends a line.
    @ObservationIgnored fileprivate var opStore: OpLogStore?

    /// Test-observable: how many refreshes have run to the end.
    @ObservationIgnored fileprivate(set) var refreshesLanded = 0

    init() {}
}

/// **The Mac's one door onto *what may this window offer*** (P3c Task 2, plan
/// ruling B).
///
/// Every Mac surface asks `posture(forDocId:)` and then `allows(.someVerb)`;
/// nothing else on the Mac builds a `Posture` or asks a permit a question of
/// its own (`TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`). The
/// permit underneath is `OpLogStore.localWritePermit`, the one *may this
/// device's actor write here* (tripwire 46): the door wraps it and never
/// computes a second answer beside it.
///
/// **O(1) in a view body, and never a registry read on the main actor.** The
/// first question per `(docId, actor)` per epoch asks the builder of a store
/// whose table was warmed off the main actor (`OpLogStore.prepareTrust`), so it
/// costs a few stats; every later question is a dictionary hit. While no warm
/// table is in hand — the moments after a trust change, before the refresh
/// lands — the door answers PROVISIONALLY (the last answer it gave, else the
/// open document's own stamp, else the whole book) without caching it, and the
/// refresh's epoch bump re-asks. A verb that WRITES asks `settledPosture`, which
/// waits for the refresh instead.
///
/// **Fresh on every trust change.** `invalidateTrust` and manifest adoption
/// bump the epoch and clear the cache; the refresh that follows re-stamps every
/// open `Document`'s `localWritePermit` from the same builder, so a demotion
/// arriving mid-session stops the document's own writes at the next keystroke
/// and a promotion restores them, with no reopen.
///
/// **The root's cooperative yield** (spec §2/§8, plan ruling R2). Where this
/// device is the book's root and `PieceWriters` names somebody on a piece — a
/// permit whose scope NAMES pieces; a co-writing whole-book author names none
/// and is never yielded to — the writer's-hand posture on that piece carries
/// `yieldingTo`, until `overrideYield(docId:)` in this window.
extension DocumentStore {

    // MARK: - Asking

    /// The epoch views re-render on. Reading it is observing it.
    var postureEpoch: Int { postureBook.epoch }

    /// **What this window may offer for this document**, for `actor`'s key.
    ///
    /// Only the writer's hand (`.author`) is ever yielded: the root's
    /// cooperative posture is about her own typing, not about what the
    /// assistant or the translator may write.
    func posture(forDocId docId: String, as actor: DeviceActor = .author) -> Posture {
        let book = postureBook
        _ = book.epoch  // observed: a trust change re-renders whoever asked
        let permit = postureWritePermit(forDocId: docId, as: actor)
        guard actor == .author, !book.overridden.contains(docId),
              let yielding = book.yields[docId]
        else { return Posture(permit) }
        return Posture(permit, yieldingTo: yielding)
    }

    /// The same door, for the document the window shows by PATH. Resolves the
    /// id through the open document or the manifest and asks `posture(forDocId:)`
    /// — never a second computation.
    func posture(forPath path: String, as actor: DeviceActor = .author) -> Posture {
        posture(forDocId: postureDocId(forPath: path), as: actor)
    }

    /// **The answer after any refresh in flight has landed** — for a verb's
    /// own door, which must not act on a provisional posture.
    func settledPosture(
        forDocId docId: String, as actor: DeviceActor = .author
    ) async -> Posture {
        await postureSettled()
        return posture(forDocId: docId, as: actor)
    }

    /// Wait until no posture refresh is in flight.
    func postureSettled() async {
        while let task = postureBook.refresh {
            await task.value
            if postureBook.refresh == task { postureBook.refresh = nil }
        }
    }

    // MARK: - The root's override

    /// **Edit Anyway** (plan ruling R2): stop yielding on this piece, in this
    /// window, for the session. Not persisted and not synced — a second window
    /// on the same book still yields.
    func overrideYield(docId: String) {
        postureBook.overridden.insert(docId)
    }

    // MARK: - The hooks DocumentStore.swift calls

    /// At open: warm the first table and read who writes what, off the main
    /// actor, before the first view asks.
    func postureOpened() {
        schedulePostureRefresh(force: true)
    }

    /// From `invalidateTrust`: every answer this window holds was taken off the
    /// table being forgotten.
    func postureTrustChanged() {
        postureBook.opStore?.invalidateTrust()
        postureBook.readySignature = nil
        bumpPostureEpoch()
        schedulePostureRefresh(force: true)
    }

    /// From manifest adoption: a piece that moved or a statement that arrived
    /// may be a document whose class changed, and the book's writers may have.
    /// The table is still good; the answers and the stamps are re-asked.
    func postureManifestAdopted() {
        bumpPostureEpoch()
        schedulePostureRefresh(force: true)
    }

    // MARK: - Internals

    private var postureOpStore: OpLogStore {
        if let existing = postureBook.opStore { return existing }
        let store = Document.makeLoadOpStore(projectURL: projectURL, presenter: presenter)
        postureBook.opStore = store
        return store
    }

    /// The ONE builder, asked only where it will not resolve on this actor.
    private func postureWritePermit(
        forDocId docId: String, as actor: DeviceActor
    ) -> LocalWritePermit {
        let book = postureBook
        let key = PostureBook.Key(docId: docId, actor: actor)
        if let hit = book.permits[key] { return hit }
        if postureTableIsWarm() {
            let permit = permitFromTheBuilder(forDocId: docId, as: actor)
            book.permits[key] = permit
            book.lastKnown[key] = permit
            return permit
        }
        // Provisional, and NOT cached: the refresh's epoch bump re-asks.
        schedulePostureRefresh(force: false)
        if let last = book.lastKnown[key] { return last }
        if actor == .author, let open = document(forDocId: docId) {
            // Stamped by the load (or the last refresh) from the same builder.
            return open.localWritePermit
        }
        return .unrestricted
    }

    /// Would asking the builder now cost no registry resolution on this actor?
    /// True for a book with no register (the builder asks nothing at all), and
    /// for one whose folder still reads as it did when the table was warmed.
    private func postureTableIsWarm() -> Bool {
        let cache = Document.loadRegistryCache
        guard TrustResolution.hasAnythingToResolve(in: projectURL, cache: cache) else {
            return true
        }
        guard let ready = postureBook.readySignature else { return false }
        return ready == TrustResolution.signature(of: projectURL)
    }

    private func permitFromTheBuilder(
        forDocId docId: String, as actor: DeviceActor
    ) -> LocalWritePermit {
        let projectURL = self.projectURL
        return postureOpStore.localWritePermit(as: actor) {
            Document.documentClass(forDocId: docId, in: projectURL)
        }
    }

    private func bumpPostureEpoch() {
        postureBook.epoch += 1
        postureBook.permits.removeAll()
    }

    /// Warm the table, re-stamp the open documents, bump; then read who writes
    /// what and bump again. `force` supersedes a refresh already in flight
    /// (a trust change it did not see); otherwise one in flight is enough.
    private func schedulePostureRefresh(force: Bool) {
        let book = postureBook
        if !force, book.refresh != nil { return }
        book.generation += 1
        let generation = book.generation
        book.refresh = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPostureRefresh(generation: generation)
            if self.postureBook.generation == generation {
                self.postureBook.refresh = nil
            }
        }
    }

    private func runPostureRefresh(generation: Int) async {
        let book = postureBook
        let projectURL = self.projectURL
        let store = postureOpStore
        // Taken BEFORE the warm, so a registry that changes mid-resolve reads
        // as not-yet-warm rather than as a table it is not.
        let signature = TrustResolution.signature(of: projectURL)
        await store.prepareTrust()
        guard book.generation == generation else { return }
        book.readySignature = signature

        // The re-stamp: every open document, from the one builder, over the
        // table just warmed. Only when that table still describes the folder —
        // otherwise the builder would resolve here, and the next refresh (the
        // presenter's own invalidation) re-stamps anyway.
        if postureTableIsWarm() {
            for document in allOpenDocuments() {
                document.stamp(localWritePermit: permitFromTheBuilder(
                    forDocId: document.docId, as: .author))
            }
        }
        bumpPostureEpoch()

        let yields = await resolvePostureYields()
        guard book.generation == generation else { return }
        book.yields = yields
        bumpPostureEpoch()
        book.refreshesLanded += 1
    }

    /// **Who this device, as the root, yields to on which piece.** One
    /// verified read off the main actor; `PieceWriters.resolve` is the one
    /// decision about who writes which piece, so only a permit whose scope
    /// NAMES pieces yields — a co-writing whole-book author never does.
    ///
    /// Empty unless this device holds its own root record and judges by it: a
    /// whole-book author admitted by somebody else is not the root, and yields
    /// to nobody.
    private func resolvePostureYields() async -> [String: String] {
        let projectURL = self.projectURL
        let cache = Document.loadRegistryCache
        guard TrustResolution.hasAnythingToResolve(in: projectURL, cache: cache) else {
            return [:]
        }
        let identities = Document.loadIdentities
        let structure = projectStore?.manifest.structure
        return await Task.detached(priority: .utility) {
            guard let resolved = try? TrustResolution.resolveVerified(
                projectURL: projectURL, identities: identities, cache: cache),
                  let root = resolved.table.ownRootRecord,
                  resolved.table.myRoot == root
            else { return [:] }
            let items = structure ?? Self.structureOnDisk(in: projectURL)
            let pieces = PermitControl.pieces(in: items)
            let writers = PieceWriters.resolve(
                registry: resolved.registry, table: resolved.table, pieces: pieces)
            var yields: [String: String] = [:]
            for piece in pieces {
                if let names = writers.sentence(for: piece.id) { yields[piece.id] = names }
            }
            return yields
        }.value
    }

    /// A headless store holds no manifest of its own; the file is read.
    nonisolated private static func structureOnDisk(in projectURL: URL) -> [StructureItem] {
        let url = projectURL.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: url),  // adr-0018-ok: project manifest JSON read, not manuscript
              let manifest = try? ProjectManifest.makeDecoder().decode(
                ProjectManifest.self, from: data)
        else { return [] }
        return manifest.structure
    }

    /// The id a path names: the open document's, else the manifest's (a
    /// manuscript item first, then a statement — `resolveDocId`'s own order),
    /// else what `resolveDocId` answers from disk.
    private func postureDocId(forPath path: String) -> String {
        if let open = document(for: path) { return open.docId }
        if let manifest = projectStore?.manifest {
            if let item = TreeWalk.first(in: manifest.structure, where: { $0.path == path }) {
                return item.id
            }
            if let statement = manifest.statements.first(where: { $0.path == path }) {
                return statement.id
            }
        }
        return (try? resolveDocId(for: projectURL.appendingPathComponent(path))) ?? path
    }

    // MARK: - Test seams

    /// How many posture refreshes have landed in full.
    var postureRefreshesLandedForTesting: Int { postureBook.refreshesLanded }
}
