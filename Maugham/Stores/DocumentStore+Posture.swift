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

    /// docId → the piece it is ABOUT (a piece, its statement, its
    /// translation), in THIS epoch — asked only while somebody is yielded to.
    @ObservationIgnored fileprivate var pieceOf: [String: String?] = [:]

    /// The permit answered for each `(docId, actor)` in THIS epoch.
    @ObservationIgnored fileprivate var permits: [Key: LocalWritePermit] = [:]

    /// The last permit answered for each key in ANY epoch — the provisional
    /// answer while a refresh is in flight, never a cache hit.
    @ObservationIgnored fileprivate var lastKnown: [Key: LocalWritePermit] = [:]

    /// Every `(docId, actor)` this window has asked about, in any epoch — what
    /// a refresh warms ahead of its epoch bump (Task 10, ruling AD), so the
    /// redraw the bump causes is answered from the cache rather than by one
    /// builder call per row on the main actor.
    @ObservationIgnored fileprivate var asked: Set<Key> = []

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

    /// Test-observable: how many times the door has asked the builder.
    @ObservationIgnored fileprivate(set) var builderCalls = 0

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
/// **Two accessors, and which one a caller uses is the rule** (controller
/// ruling I). A SURFACE draws from `posture(forDocId:)`; every door that ACTS
/// — Accept/Reject/Stet, ⌘S's op, a round's Run, a ruling, an inbox promote,
/// a translation write — asks `settledPosture(forDocId:as:)`, which never
/// answers provisionally.
///
/// **O(1) in a view body, and never a registry read on the main actor.** The
/// first question per `(docId, actor)` per epoch asks the builder of a store
/// whose table was warmed off the main actor (`OpLogStore.prepareTrust`), so it
/// costs a few stats; every later question is a dictionary hit. `open` awaits
/// the first warm, so a window never draws from a cold door. After a trust
/// change, before the refresh lands, the drawing accessor answers
/// PROVISIONALLY and caches nothing: the last answer it gave for that
/// document and actor, else that document's own stamp (same actor), else —
/// in a book that has a register — `Posture.settling`, which offers the
/// reviewer row alone. **About a document it has never answered, it never
/// fails open.** About one it HAS answered, the last answer is exactly what
/// it draws until the refresh lands — so between a registry change landing
/// and its refresh completing, a surface can still offer a verb the new
/// permit refuses (controller ruling AG's stated limit). The verb's own door
/// asks `settledPosture` and refuses it. A book with no register is always
/// warm and answers `.author` reading nothing.
///
/// **Fresh on every trust change.** `invalidateTrust` and manifest adoption
/// bump the epoch and clear the cache; the refresh that follows warms the new
/// answers into a staging dictionary, then — IN ONE TURN — publishes them to
/// the drawing cache, re-stamps every open `Document`'s `localWritePermit`
/// (the manuscript registry's and every open statement editor's) from the same
/// builder, and bumps the epoch that re-renders the editor. So once the
/// refresh lands a demotion stops the document's own writes, changes what a
/// surface draws and locks its editor together, and a promotion restores all
/// three, with no reopen. Until it lands, all three still answer as before the
/// change.
///
/// **The root's cooperative yield** (spec §2/§8, plan ruling R2). Where this
/// device is the book's root and `PieceWriters` names somebody on a piece — a
/// permit whose scope NAMES pieces; a co-writing whole-book author names none
/// and is never yielded to — the writer's-hand posture on that piece carries
/// `yieldingTo`, until `overrideYield(docId:)` in this window. The piece's
/// statement and its translation yield with it (controller ruling H): the
/// yield keys on the piece a document's CLASS is about. Never to this
/// device's own person — the root's own second Mac admitted under the
/// writer's label is the writer.
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
        _ = postureBook.epoch  // observed: a trust change re-renders whoever asked
        guard let permit = postureWritePermit(forDocId: docId, as: actor) else {
            return .settling
        }
        return assemble(permit, forDocId: docId, as: actor)
    }

    /// The permit plus the yield. The yield is decided here (it reads the
    /// window's `PieceWriters` answer and its *Edit Anyway* set); the `Posture`
    /// itself is put together by Core's `PostureDoor.posture(permit:)`, the one
    /// place a permit becomes a posture on either surface (P3c plan 2, Task 1).
    private func assemble(
        _ permit: LocalWritePermit, forDocId docId: String, as actor: DeviceActor
    ) -> Posture {
        let book = postureBook
        guard actor == .author, !book.yields.isEmpty,
              let piece = postureYieldPiece(forDocId: docId),
              !book.overridden.contains(piece),
              let yielding = book.yields[piece]
        else { return PostureDoor.posture(permit: permit) }
        return PostureDoor.posture(permit: permit, yieldingTo: yielding)
    }

    /// The piece a document is about, by its CLASS — the piece itself, its
    /// statement, its translation — cached per epoch. From the live manifest
    /// where the window holds one (pure), else the file.
    private func postureYieldPiece(forDocId docId: String) -> String? {
        let book = postureBook
        if let known = book.pieceOf[docId] { return known }
        let cls: DocumentClass
        if let manifest = projectStore?.manifest {
            cls = DocumentClass.resolve(docId: docId, statements: manifest.statements)
        } else {
            cls = Document.documentClass(forDocId: docId, in: projectURL)
        }
        book.pieceOf[docId] = .some(cls.piece)
        return cls.piece
    }

    /// The same door, for the document the window shows by PATH. Resolves the
    /// id through the open document or the manifest and asks `posture(forDocId:)`
    /// — never a second computation.
    func posture(forPath path: String, as actor: DeviceActor = .author) -> Posture {
        posture(forDocId: postureDocId(forPath: path), as: actor)
    }

    /// **The answer a verb's own door acts on** (controller ruling I) —
    /// never provisional, never `settling`.
    ///
    /// Waits for any refresh in flight; then, if the folder has moved since the
    /// table was warmed (a record that landed before the presenter's debounced
    /// invalidation), warms it again off the main actor, a bounded number of
    /// times. A registry that keeps moving under all of them is answered by the
    /// builder directly — a registry read on this actor, the price of a correct
    /// answer in a state that should not persist.
    func settledPosture(
        forDocId docId: String, as actor: DeviceActor = .author
    ) async -> Posture {
        await postureSettled()
        let book = postureBook
        for _ in 0..<Self.settleAttempts {
            if postureTableIsWarm() { break }
            let generation = book.generation
            let signature = TrustResolution.signature(of: projectURL)
            await postureOpStore.prepareTrust()
            // A trust change that arrived meanwhile forgot the table this
            // warmed; its own refresh will set the signature.
            if book.generation == generation { book.readySignature = signature }
            await postureSettled()
        }
        let key = PostureBook.Key(docId: docId, actor: actor)
        book.asked.insert(key)
        let permit = book.permits[key] ?? {
            let built = permitFromTheBuilder(forDocId: docId, as: actor)
            if postureTableIsWarm() { book.permits[key] = built }
            book.lastKnown[key] = built
            return built
        }()
        return assemble(permit, forDocId: docId, as: actor)
    }

    /// The acting answer for the document the window names by PATH — the
    /// same id resolution as `posture(forPath:)`, then `settledPosture(forDocId:)`.
    func settledPosture(
        forPath path: String, as actor: DeviceActor = .author
    ) async -> Posture {
        await settledPosture(forDocId: postureDocId(forPath: path), as: actor)
    }

    private static var settleAttempts: Int { 3 }

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
        postureBook.overridden.insert(postureYieldPiece(forDocId: docId) ?? docId)
    }

    // MARK: - The hooks DocumentStore.swift calls

    /// At open: warm the first table and read who writes what, off the main
    /// actor, and WAIT for it — `open` is async, so the first view never asks
    /// a cold door.
    func postureOpened() async {
        schedulePostureRefresh(force: true)
        await postureSettled()
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
    /// The table is still good; the answers and the stamps are re-asked, and
    /// — like a trust change's — published only in the refresh's one turn, so
    /// a redraw meanwhile draws the last answer rather than a new class's
    /// answer over a Document still stamped with the old one.
    func postureManifestAdopted() {
        postureBook.readySignature = nil
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

    /// The ONE builder, asked only where it will not resolve on this actor;
    /// nil where nothing is known and the table is cold (the caller draws
    /// `settling`).
    private func postureWritePermit(
        forDocId docId: String, as actor: DeviceActor
    ) -> LocalWritePermit? {
        let book = postureBook
        let key = PostureBook.Key(docId: docId, actor: actor)
        if let hit = book.permits[key] { return hit }
        book.asked.insert(key)
        if postureTableIsWarm() {
            let permit = permitFromTheBuilder(forDocId: docId, as: actor)
            book.permits[key] = permit
            book.lastKnown[key] = permit
            return permit
        }
        // Provisional, and NOT cached: the refresh's epoch bump re-asks.
        schedulePostureRefresh(force: false)
        if let last = book.lastKnown[key] { return last }
        if let open = document(forDocId: docId), open.localWritePermit.actor == actor {
            // Stamped by the load (or the last refresh) from the same builder.
            return open.localWritePermit
        }
        return nil
    }

    /// Would asking the builder now cost no registry resolution on this actor?
    /// True for a book with no register (the builder asks nothing at all), and
    /// for one whose folder still reads as it did when the table was warmed.
    private func postureTableIsWarm() -> Bool {
        postureTableIsWarm(readyAt: postureBook.readySignature)
    }

    /// The same question about a table warmed at `ready` — what a refresh asks
    /// of the table IT warmed before that table is published to the drawing
    /// accessor (`runPostureRefresh`).
    private func postureTableIsWarm(readyAt ready: String?) -> Bool {
        let cache = Document.loadRegistryCache
        guard TrustResolution.hasAnythingToResolve(in: projectURL, cache: cache) else {
            return true
        }
        guard let ready else { return false }
        return ready == TrustResolution.signature(of: projectURL)
    }

    /// The ONE builder (tripwire 46); only where the document's CLASS comes
    /// from is this door's choice. The window's live manifest where the store
    /// holds one — `DocumentClass.resolve(docId:statements:)`, pure and free,
    /// which is what `OpLogStore.documentClass(forDocId:in:)` asks of the
    /// statements it decodes — else that disk read (a headless store). A
    /// manifest adoption bumps the epoch, so the live manifest is never
    /// older than an answer cached from it (Task 10, ruling AD: the disk read
    /// was 0.47 ms of every 0.84 ms miss).
    private func permitFromTheBuilder(
        forDocId docId: String, as actor: DeviceActor
    ) -> LocalWritePermit {
        let projectURL = self.projectURL
        let manifest = projectStore?.manifest
        postureBook.builderCalls += 1
        // The piece's starter (Option A) from the same live manifest, for
        // ruling AD's reason; nil (a headless store) reads it off disk.
        let startedBy = manifest.map { live in { live.startedBy(ofPiece: $0) } }
        return postureOpStore.localWritePermit(
            as: actor,
            documentClass: {
                if let manifest {
                    return DocumentClass.resolve(
                        docId: docId, statements: manifest.statements)
                }
                return Document.documentClass(forDocId: docId, in: projectURL)
            },
            startedBy: startedBy)
    }

    /// **The drawn posture follows a Document's re-stamp** (P3c plan 2,
    /// controller ruling H). `Document.handleExternalLogChange` re-stamps a
    /// Document whose permit carries Option A's arm, because a book author's
    /// text arriving closes it. The door caches per epoch and prefers that
    /// cache, so a changed stamp forgets this document's cached answer (the
    /// next draw rebuilds it off the warm table and the live manifest), leaves
    /// the new stamp as the provisional answer, and bumps the epoch so every
    /// surface that asked redraws. An unchanged stamp — every re-read of every
    /// document outside Option A — touches nothing.
    func withPostureFollowingReStamp(
        of document: Document, _ reRead: () async throws -> Void
    ) async throws {
        let appliedBefore = document.externalChangesApplied
        try await reRead()
        // **One turn, from here to the bump** (fix round 2, N3): no `await`
        // between the re-stamp and `postureFollowsReStamp`, so no turn sees
        // the Document's stamp and the drawn answer disagree (ruling AG). And
        // only after a re-read that applied somebody else's change (N2): an
        // echo of her own burst cannot have claimed her piece, so her typing
        // never pays for the builder.
        guard document.externalChangesApplied != appliedBefore else { return }
        let before = document.localWritePermit
        document.restampWhereItsStarterArmMayHaveClosed()
        postureFollowsReStamp(of: document, from: before)
    }

    private func postureFollowsReStamp(of document: Document, from before: LocalWritePermit) {
        let after = document.localWritePermit
        guard after != before else { return }
        let key = PostureBook.Key(docId: document.docId, actor: after.actor)
        postureBook.permits[key] = nil
        postureBook.lastKnown[key] = after
        postureBook.epoch += 1
    }

    /// A new epoch: every view that asked re-renders. `clearing` forgets the
    /// cached answers too — a trust change or a manifest adoption, whose
    /// answers were taken off a table or a manifest being replaced. A refresh
    /// that has just WARMED the cache from the table it warmed bumps without
    /// clearing, so the redraw it causes is all hits.
    private func bumpPostureEpoch(clearing: Bool = true) {
        postureBook.epoch += 1
        guard clearing else { return }
        postureBook.permits.removeAll()
        postureBook.pieceOf.removeAll()
    }

    /// How many keys a refresh warms between yields of the main actor. The
    /// builder costs a fraction of a millisecond a key (its own
    /// is-there-a-register question and folder signature), so a chunk holds
    /// the actor for a few milliseconds and a redraw can land between chunks.
    private static var prewarmChunk: Int { 16 }

    /// **Warm every key this window has asked about, off the table just
    /// warmed — into a STAGING dictionary** (Task 10, rulings AD and AG; the
    /// whole-branch fix wave's Minor 1). The same builder over the same inputs
    /// a miss would use, for EVERY key, cached or not. Nothing here is visible
    /// to the drawing accessor: the staged answers are published by
    /// `runPostureRefresh` in the one turn that re-stamps the documents and
    /// bumps the epoch, so no redraw during the warm's yields can draw the new
    /// answer over a Document still stamped with the old one. The folder's
    /// signature is checked once per chunk rather than once per key; a chunk
    /// that finds the folder moved (or a newer refresh) abandons the warm and
    /// answers nil, and the caller falls back to the clearing bump.
    private func stagePostureCache(
        generation: Int, readyAt signature: String
    ) async -> [PostureBook.Key: LocalWritePermit]? {
        let book = postureBook
        let keys = Array(book.asked)
        var staged: [PostureBook.Key: LocalWritePermit] = [:]
        var index = 0
        while index < keys.count {
            guard book.generation == generation,
                  postureTableIsWarm(readyAt: signature) else { return nil }
            // EVERY key, cached or not (controller ruling AG): a refresh that
            // no clearing bump preceded — the one a drawing miss schedules when
            // the folder moved before the debounced invalidation — must not
            // keep an answer taken off the table it is replacing.
            for key in keys[index..<min(index + Self.prewarmChunk, keys.count)] {
                staged[key] = permitFromTheBuilder(forDocId: key.docId, as: key.actor)
            }
            index += Self.prewarmChunk
            if index < keys.count { await Task.yield() }
        }
        return book.generation == generation ? staged : nil
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

        // The staging pre-warm first: it yields the main actor between chunks,
        // so it must finish before anything this refresh changes becomes
        // visible — and until the one turn below, NOTHING it did is: the
        // table is not yet published (`readySignature` still names the old
        // one, or nil after a trust change), so a drawing miss during a yield
        // answers provisionally from the last answer or the Document's own
        // stamp, never from the new table.
        var staged: [PostureBook.Key: LocalWritePermit]?
        if postureTableIsWarm(readyAt: signature) {
            staged = await stagePostureCache(generation: generation, readyAt: signature)
            guard book.generation == generation else { return }
        }

        // **Publishing the table, the re-stamp and the epoch bump are ONE
        // main-actor turn** — controller ruling AG, and no `await` may come
        // between them. The Document's stamp decides whether its own writes
        // are made; the drawing cache is what a surface draws; the epoch is
        // what re-renders the editor's membrane. Between any two of them a
        // keystroke would reach an editor drawn one way over a Document
        // answering the other, and a burst could be signed in her name only to
        // be set aside. `DocumentStorePostureTests
        // .test_theRestampAndTheBumpAreOneTurn` samples every turn — the stamp
        // AND the drawn answer — to pin it.
        //
        // The re-stamp: every open document — the manuscript registry AND the
        // open statement editors, which are deliberately in no `DocumentStore`
        // registry (whole-branch fix wave, I1) — from the one builder, over the
        // table just warmed, for the SAME actor its stamp was made for (the
        // load stamps the author's, because what it emits on its own account
        // is the author's — tripwire 38 — so a re-stamp that named the loading
        // actor instead would change what the stamp means). Only when that
        // table still describes the folder — otherwise the builder would
        // resolve here, and the next refresh (the presenter's own
        // invalidation) re-stamps anyway.
        book.readySignature = signature
        let stillWarm = postureTableIsWarm()
        if stillWarm {
            if let staged {
                for (key, permit) in staged {
                    book.permits[key] = permit
                    book.lastKnown[key] = permit
                }
            }
            for document in postureRestampedDocuments() {
                document.stamp(localWritePermit: permitFromTheBuilder(
                    forDocId: document.docId, as: document.localWritePermit.actor))
            }
        }
        // Staged and still warm: the cache holds this table's answers, so the
        // bump re-renders without forgetting them. Otherwise (the folder moved
        // mid-resolve): forget, as before — the presenter's own invalidation
        // refreshes again.
        bumpPostureEpoch(clearing: !(staged != nil && stillWarm))

        let yields = await resolvePostureYields()
        guard book.generation == generation else { return }
        book.yields = yields
        // A permit does not depend on who is yielded to (`assemble` applies
        // the yield at the question), so the second bump keeps the cache.
        bumpPostureEpoch(clearing: false)
        book.refreshesLanded += 1
    }

    /// **Every `Document` a refresh re-stamps** — the manuscript registry and
    /// the open statement editors (whole-branch fix wave, I1). A statement is
    /// deliberately in no `DocumentStore` registry (`StatementEditorHost`), so
    /// `allOpenDocuments()` alone left a statement editor LOCKED by its
    /// surface over a Document still stamped as before: its pending file and
    /// its task-anchor question kept the load's answer until reopen.
    private func postureRestampedDocuments() -> [Document] {
        allOpenDocuments() + (projectStore?.liveStatementDocuments ?? [])
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
            // Never to this device's own person: the root's own second Mac,
            // admitted under the writer's own label, is the writer.
            let mine = resolved.registry.person(root)?.label
            var yields: [String: String] = [:]
            for piece in pieces {
                let others = writers.writers(of: piece.id).filter { $0 != mine }
                if let names = PieceWriters.sentence(naming: others) {
                    yields[piece.id] = names
                }
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

    /// How many times the door has asked the one builder — a cache hit asks it
    /// nothing, so a redraw that moves this is a redraw of misses.
    var postureBuilderCallsForTesting: Int { postureBook.builderCalls }
}
