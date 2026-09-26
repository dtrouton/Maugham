import Foundation
import MaughamCore

/// How a `Document.load` should behave when the strict load would refuse
/// (RULING-54). Absent this parameter the load is strict, which is the floor
/// the whole recovery ladder stands on — a mode is opted into, never inferred.
public enum DocumentRecoveryMode: Equatable, Sendable {
    /// Spec §4: derive from the readable files only; the Document is
    /// read-only and can write nothing.
    case readOnlyPartial
}

/// A mutation was attempted on a Document that must not write — closed
/// (husked, abandoned) or a read-only recovery view (spec §4). Thrown only by
/// the value-returning entry points; the Void-returning ones no-op instead.
public struct DocumentNotWritableError: Error, Equatable {
    /// The refusing call site, for the message the caller shows.
    public let site: String
    public init(site: String) { self.site = site }
}

/// Why a recovery-mode load refused. Distinct from `OpLogStore.ReadError`:
/// these are refusals of the RECOVERY door itself, not read failures — the
/// door is only ever the right one when the strict load has already refused.
public enum DocumentRecoveryError: Error, Equatable {
    /// Every op-log file read cleanly, so there is no partial view to offer.
    /// Recovery mode is not a lenient open — the normal load is the right door.
    case nothingUnreadable
    /// The doc has no op log at all, so there is no history to derive from.
    /// A normal load would BOOTSTRAP one from the `.md`; a partial view must
    /// never mint anchors, so it refuses and says there is nothing to recover.
    case noOpLog
}

extension Document {

    /// Drop orphan paragraphs from the op-log-derived state: entries in
    /// `paragraphs` whose ids the current `sequence` no longer references.
    /// The deriver's `typing_burst` fold updates paragraph entries but never
    /// deletes them, so a paragraph the writer split / merged away in an
    /// earlier session lingers in the accumulator forever. Left in place these
    /// orphans poison the inline-task deriver (it walks every paragraph, not
    /// just `sequence`) — surfacing phantom checkbox rows in the Tasks pane
    /// with no matching paragraph in the `.md`. Pure and self-contained so it
    /// stays directly testable; operates on the post-crash-recovery derived
    /// state.
    ///
    /// Pre-ADR-0019 this carried three additional branches that rebuilt
    /// content / order from the parsed on-disk `.md`'s anchors (empty-derived
    /// seeding, empty-sequence rebuild, stale-sequence recovery). ADR 0019 made
    /// the op log authoritative — `Document.load` derives content + order from
    /// it alone via `deriveWithSequenceFallback`, never the `.md` — and F2's
    /// fix seeds the op log at Bootstrap for the one state (anchored file +
    /// empty log) branch 1 covered, so those branches were dead and removed.
    internal nonisolated static func reconcile(
        derived: Deriver.DerivedState
    ) -> Deriver.DerivedState {
        var initial = derived
        if !initial.sequence.isEmpty {
            let sequenceIdSet = Set(initial.sequence)
            let paragraphsHasOrphans = initial.paragraphs.keys.contains {
                !sequenceIdSet.contains($0)
            }
            if paragraphsHasOrphans {
                let trimmed = initial.paragraphs.filter {
                    sequenceIdSet.contains($0.key)
                }
                initial = Deriver.DerivedState(
                    paragraphs: trimmed, sequence: initial.sequence)
            }
        }
        return initial
    }

    /// **The production door: say WHICH of this device's four writers is
    /// acting, and the id follows from the key** (signed op log P1b).
    ///
    /// A device is not one writer. The person types; Claude answers through
    /// MCP; the translation pipeline files a round; the app rebalances task
    /// priorities on nobody's instruction. Each has its own key, so the actor
    /// decides which file the ops land in, which key chains and seals them, and
    /// what a later reader can vouch for. Before this, three of the four wrote
    /// under hand-built sentinels (`"mcp"`, `"wiki-rename"`, `"find-replace"`)
    /// that named no key at all, and `OpLogStore.append` took the plain
    /// unchained path for every line of it.
    ///
    /// The `device: String` overloads below survive as `internal`: the test
    /// suites that predate the actors keep naming a device directly, and
    /// `TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad` is what
    /// keeps production out of that door.
    public static func load(
        url: URL,
        actor: DeviceActor,
        session: String,
        presenter: NSFilePresenter?
    ) async throws -> Document {
        try await load(
            url: url, device: deviceId(for: actor), session: session,
            presenter: presenter,
            burstIdle: .seconds(30), burstMax: .seconds(90))
    }

    /// The actor's recovery-mode door. Reached only after the strict load has
    /// refused — the ladder's rungs offer this, nothing opens with it by
    /// default.
    public static func load(
        url: URL,
        actor: DeviceActor,
        session: String,
        presenter: NSFilePresenter?,
        recovery: DocumentRecoveryMode
    ) async throws -> Document {
        try await load(
            url: url, device: deviceId(for: actor), session: session,
            presenter: presenter, recovery: recovery)
    }

    /// The actor's burst-threshold door, for tests that mean an actor and also
    /// cannot wait 30 seconds for the default idle threshold.
    internal static func load(
        url: URL,
        actor: DeviceActor,
        session: String,
        presenter: NSFilePresenter?,
        burstIdle: Duration,
        burstMax: Duration
    ) async throws -> Document {
        try await load(
            url: url, device: deviceId(for: actor), session: session,
            presenter: presenter, burstIdle: burstIdle, burstMax: burstMax)
    }

    /// The device string an actor writes under, read from the SAME
    /// `LocalIdentities` the load's `OpLogStore` is built with
    /// (`Document.loadIdentities`). Taking `LocalIdentities.current` here
    /// instead would have a suite's injected quartet sign ops the store filed
    /// under the machine's real key.
    private static func deviceId(for actor: DeviceActor) -> String {
        loadIdentities[actor].deviceId
    }

    /// **What the LOAD itself writes is the writer's own hand, whatever door
    /// opened the file** (signed op log P3a Task 8, the controller's ruling on
    /// Task 5's census).
    ///
    /// Five emissions are the load path's or a derivation's rather than the
    /// caller's: `Bootstrap`'s opening op, the two pending-recovery folds, the
    /// task anchors spliced back into the paragraphs, and the `taskCreate`
    /// breadcrumb beside each. None of them is the act of whoever opened the
    /// document — they are the writer's own words arriving through whichever
    /// door happened to be first — and every one of them is a kind the
    /// permission table (Task 4) refuses to `assistant` and to `translator`.
    /// Signed under the loading actor they are lines the permit partition
    /// (Task 5) sets aside on the next read, and the census put `bootstrap` at
    /// the top of that list: a document whose opening op leaves the book
    /// derives EMPTY, and the first autosave writes the empty render over the
    /// manuscript.
    ///
    /// **The redirect fires only where the load NAMED one of this device's
    /// other actors.** A `device:` string naming no local key — every test call
    /// site, which is what tripwire 38's `internal` door is for — is left
    /// exactly as it was: it signs nothing, so there is nothing to
    /// re-attribute. And the lookup ENUMERATES (`LocalIdentities.existingActors`
    /// plus a subscript of an actor already on disk), so asking the question
    /// mints no key; only the answer does, and minting the author's key to
    /// write the writer's own words is the lazy rule's own case.
    internal static func authorEmissionDevice(loadedAs device: String) -> String {
        let identities = loadIdentities
        guard let actor = identities.existingActors.first(
                where: { identities[$0].deviceId == device }),
              actor != .author
        else { return device }
        return identities[.author].deviceId
    }

    internal static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?
    ) async throws -> Document {
        try await load(
            url: url, device: device, session: session, presenter: presenter,
            burstIdle: .seconds(30), burstMax: .seconds(90))
    }

    /// The recovery-mode load (spec §4). Reached only after the strict load
    /// above has refused — the ladder's rungs offer this, nothing opens with it
    /// by default.
    internal static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?,
        recovery: DocumentRecoveryMode
    ) async throws -> Document {
        // .readOnlyPartial is the only mode; the switch is here so a second
        // mode can't ship without deciding its load shape explicitly.
        switch recovery {
        case .readOnlyPartial:
            return try await loadReadOnlyPartial(
                url: url, device: device, session: session, presenter: presenter)
        }
    }

    /// Spec §4's read-only partial view: derive from the op-log files that
    /// READ, name the ones that don't, and write nothing at all — not an op,
    /// not the `.md`, not a quarantine record, not a conflict snapshot, not a
    /// sealed segment. It deliberately mirrors the strict load's docId /
    /// projectURL resolution and its deriver, and deliberately omits every one
    /// of that load's writes and repairs:
    ///
    ///   - **No `Bootstrap.run`** — a partial view must not mint anchors. A doc
    ///     with no op log at all has nothing to recover and refuses.
    ///   - **No pending fold** — the pending file holds a crashed session's
    ///     un-bursted keystrokes and belongs to the REAL open that follows
    ///     recovery. Folding it here would append an op AND clear the file,
    ///     spending the writer's only copy on a view they cannot save from.
    ///   - **No quarantine record** for parse skips, and no divergence
    ///     snapshot: both are writes, and the second is worse than redundant —
    ///     a partial view's render is missing whatever the unreadable files
    ///     held, so it would file the writer's intact `.md` as "diverged"
    ///     against an incomplete history.
    ///   - **No autosave**: the scheduler exists (the property is implicitly
    ///     unwrapped, and a nil one turns a stray future `schedule(())` into a
    ///     crash) but its fire closure is empty, so no debounced write can
    ///     reach this document.
    ///   - **No `unrecoveredPendingFailure` stamp**: that notice is delivered
    ///     once, by the real open, whose pending fold is what actually consumed
    ///     (or failed to consume) the file.
    private static func loadReadOnlyPartial(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?
    ) async throws -> Document {
        let docId = try resolveDocId(for: url)
        let projectURL = resolveProjectURL(for: url)

        // No op log means a normal load would have BOOTSTRAPPED one from the
        // `.md`. There is no history here to read partially, and minting
        // anchors is a write — refuse and let the caller offer another rung.
        guard !OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL).isEmpty else {
            throw DocumentRecoveryError.noOpLog
        }

        let opStore = Document.makeLoadOpStore(
            projectURL: projectURL, presenter: presenter)
        let partial = await opStore.loadDiagnosedPartial(docId: docId)

        // Recovery mode exists for the refusal path alone. If every file read,
        // the strict load would have opened this doc writably — handing back a
        // read-only view instead would quietly cost the writer their session.
        guard !partial.unreadableFiles.isEmpty else {
            throw DocumentRecoveryError.nothingUnreadable
        }

        let initial = Document.reconcile(
            derived: Deriver.deriveWithSequenceFallback(ops: partial.ops))

        // A `PendingBuffer` is constructed (the Document requires one) but
        // never loaded, never flushed and never cleared: constructing it
        // touches no disk.
        let pending = PendingBuffer(projectURL: projectURL, docId: docId, device: device)
        // Likewise the burst scheduler: it is handed no fire closure that can
        // reach this doc, so its timer can never trigger a flush. `flushBurstNow`
        // refuses on a recovery doc regardless — this is the belt on the braces.
        let burst = BurstScheduler(idle: .seconds(30), max: .seconds(90)) {}

        let doc = Document(
            url: url, docId: docId, device: device, session: session,
            presenter: presenter, opStore: opStore, pending: pending,
            burstScheduler: burst,
            paragraphs: initial.paragraphs, sequence: initial.sequence,
            lastDiskEcho: .initialLoad(bytes: ""))
        // And the autosave scheduler is given a fire closure that does
        // NOTHING rather than left nil: the property is implicitly unwrapped,
        // so an unguarded future path that schedules an autosave on a recovery
        // doc must no-op, not crash — `Document+Tasks.swift`'s
        // `autosaveScheduler.schedule(())` is the live near-miss, one guard
        // away from being reached here. Belt on braces, like the burst
        // scheduler above: nothing may write from a partial view, and the
        // failure mode of the belt breaking must not be a crash on the writer.
        doc.autosaveScheduler = DebounceScheduler<Void>(delay: .milliseconds(750)) { _ in }
        doc.recomputeDisplayText()
        doc._opLogMirror = partial.ops
        doc.invalidateRestoreStandingMemo()
        doc._annotationsCacheValid = false
        doc._hasAnyAnnotationOps = partial.ops.contains {
            Document.isAnnotationOpKind($0.kind)
        }
        doc.readOnlyRecovery = .init(unreadableFiles: partial.unreadableFiles)
        // Signed op log P1: a partial view is still entitled to say what its
        // readable files are made of. `loadDiagnosedPartial` counts only the
        // files that READ — an unreadable one is named in `unreadableFiles`,
        // which is a different fact and must not blur into "zero verified".
        doc.provenance = partial.provenance
        doc.ownLinesKeptInHistory = partial.provenance.ownLinesKeptInHistory
        return doc
    }

    /// Internal overload that accepts custom burst thresholds. Used by tests
    /// to avoid waiting 30 seconds for the default idle threshold.
    internal static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?,
        burstIdle: Duration,
        burstMax: Duration
    ) async throws -> Document {
        // Resolve doc-id by looking up the manifest. For tests + initial
        // setup, fall back to a deterministic id derived from the path.
        let docId = try resolveDocId(for: url)

        // projectURL is wherever `project.maugham.json` lives. Walk up
        // from the doc's URL until we find it. For Novel/Screenplay this
        // is 2 levels up (manuscript/<file>.md → project/); for Collection
        // it can be 3 (pieces/<piece-folder>/<file>.md → project/) or
        // deeper for research notes. Defaulting to a fixed 2-level
        // deletingLastPathComponent landed inside the piece folder for
        // Collections and made every .maugham/ops/<docId>.jsonl path
        // resolve to a non-existent location, silently dropping ops.
        let projectURL = resolveProjectURL(for: url)

        // Bootstrap detection. Per-device partitioning (ADR 0012) means a doc's
        // log may exist only as `<docId>.<slug>.jsonl` with no legacy
        // `<docId>.jsonl`; check the whole globbed set, or a doc whose only
        // writer was a non-current device reads as "no log" and re-bootstraps.
        // RULING-54: an ops directory that exists but cannot be listed throws
        // HERE — falling through would read as "no log" and re-bootstrap a
        // parallel history over the writer's intact one.
        try OpLogStore.verifyOpsDirectoryListable(in: projectURL)
        let logExists = !OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL).isEmpty
        let storedBytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""  // adr-0018-ok: sanctioned manuscript site — stored bytes as bootstrap-import / divergence reference; op log is authoritative
        // Fountain docs preserve the two-space "held blank" dialogue pause inside
        // the paragraph (E1); prose keeps whitespace-only = blank. The `.md` vs
        // `.fountain` extension decides — consistent with Bootstrap + setFullText.
        let isFountain = url.pathExtension.lowercased() == "fountain"
        let parsed = ParagraphParser.parse(
            storedBytes, preservesHeldBlankLines: isFountain)
        // ADR 0019: the .md is clean (no anchors), so "the .md has no anchors"
        // no longer signals "needs bootstrap" — that would re-bootstrap every
        // clean file now that clean-`.md` output has shipped. An existing op log
        // is authoritative;
        // only a doc with NO op log (a brand-new or imported plain file)
        // bootstraps from its .md. Reading the .md to MINT ids for that
        // new/imported doc is the sanctioned import read — not reading it as
        // truth for an existing doc. `!parsed.isEmpty` still filters out the
        // transient empty-.md case for a newly-created doc before first
        // autosave (there's nothing to bootstrap); Bootstrap.run also has its
        // own empty-parsed guard, so this is belt-and-braces.
        let needsBootstrap = !logExists && !parsed.isEmpty

        // Built BEFORE the bootstrap, and handed to it: the bootstrap op is
        // the first line of this document's history and must be chained by the
        // same store that will chain everything after it. A store of
        // `Bootstrap`'s own carries `LocalIdentities.current`, so under an
        // injected quartet the doc's opening op reads back as legacy forever.
        let opStore = Document.makeLoadOpStore(
            projectURL: projectURL, presenter: presenter)

        // P3a Task 8: everything the LOAD emits on its own account is the
        // author's, whatever actor opened the file. See
        // `authorEmissionDevice(loadedAs:)` for why. Everything the CALLER then
        // writes through the returned Document — an annotation through MCP, a
        // translation record — stays the loading actor's.
        let emissionDevice = Document.authorEmissionDevice(loadedAs: device)

        // P3a Task 8: and NOT AT ALL where this device's own hand may not write
        // this piece.
        //
        // **Asked WITHOUT suspending, and that is load-bearing.**
        // `Document.load`'s suspension points are part of its contract —
        // `ProjectStore.withStatementDocument`'s own comment is about a pane
        // binding mid-load — and a bare `await Task.yield()` inserted here
        // fails `PromotionPerformerTests
        // .test_promotingWhileTheIntentPaneIsOpenDoesNotOpenASecondDocument`
        // with none of this task's logic in the picture (measured). So the
        // permit resolves on this actor (`OpLogStore.trustOnThisActor`), which
        // also warms the table `loadDiagnosed` reads below. A project with no
        // register at all — every book written before P2a — asks nothing.
        //
        // **One manifest read for the whole load** (P3 plan 3 Task 6): the
        // class and the piece's starter here, and the class again for the
        // amendment table below, are answers about one file — so one
        // `ManifestPlacement` decodes it once, and only if one is asked.
        let placement = ManifestPlacement(docId: docId, in: projectURL)
        let writePermit = opStore.localWritePermit(placement: placement)

        if needsBootstrap {
            // Spec §4.6. A document with no op log usually means a new or
            // imported file whose `.md` is the seed; on a Mac that may not
            // write this piece the likelier reading is that its ops have not
            // synced yet, and minting the opening op would put a line in the
            // book the next read sets aside. Refuse, mint nothing, and say what
            // is happening — never a word of the `.md` as truth (tripwire 20).
            //
            // **Option A (P3c plan 2, OA-1/OA-2): only the piece's STARTER
            // mints.** In a book where somebody is narrowed, a piece whose
            // manifest records who started it (`StructureItem.startedBy`) is
            // minted by that Mac alone — the root's included, so the root
            // waits for her new piece rather than putting a root-signed
            // opening in front of the words she is typing. A piece with no
            // recorded starter, and every un-narrowed book, keep today's rule:
            // whoever may write its text mints it. The one predicate is
            // Core's (`LocalWritePermit.mayMintOpening`).
            guard writePermit.mayMintOpening else {
                // WHO the wait is for (fix round 1, M2): where the starter
                // rule bound and this Mac did not start the piece, it is
                // waiting for the STARTER's ops — named by the starter's label,
                // or nobody where the starter is this writer's own other Mac.
                // Otherwise it is this device's permit that refuses, and the
                // root (never itself) is who would change that.
                throw DocumentLoadError.waitingForPiece(
                    docId: docId,
                    from: writePermit.startedHere == false
                        ? Document.starterLabelForWaiting(docId: docId, in: projectURL)
                        : Document.rootLabelForWaiting(in: projectURL))
            }
            _ = try await Bootstrap.run(
                projectURL: projectURL, docId: docId,
                mdURL: url, device: emissionDevice, session: session,
                opStore: opStore)
        }
        let pending = PendingBuffer(projectURL: projectURL, docId: docId, device: device)
        // RULING-54: a pending file that exists but can't be read or decoded
        // holds un-bursted keystrokes from a crashed session. Not a refusal —
        // every SAVED word is intact in the op log — but never silent either:
        // quarantine what's salvageable (the next autosave overwrites the
        // pending file, so this record is the only copy that survives), then
        // STAMP the failure on the Document rather than posting a notice here:
        // a post from this windowless context is dropped by the receive
        // helpers' liveness guard (isLive(nil) == false), and a clean close
        // then deletes the trigger — the forbidden silence, relocated.
        // EditorHost consumes the stamp and posts once its window exists.
        // Best-effort like the torn-line block below: a quarantine-write
        // failure must never abort the load.
        var pendingFailure: Document.PendingRecoveryFailure?
        // P3a Task 8: a device that may not write this piece does not fold the
        // pending file — and does not READ it either. A buffer with something
        // in it is a buffer the next `close()` turns into a `typingBurst`, so
        // loading it here and merely declining to append would move the refusal
        // one hop and lose the same words. The bytes stay exactly where the
        // crashed session left them: not read, not decoded, not cleared, not
        // quarantined. A later load under a permit that allows the fold
        // recovers them normally, and the writer is told in the meantime.
        //
        // The presence check comes FIRST, and is what keeps the permit question
        // off the ordinary load: a clean close leaves no pending file at all
        // (Issue 2a), so on almost every open there is nothing here to ask
        // about. `loadFromDisk` answers `.absent` for exactly the same state,
        // so skipping it where there is no file changes nothing.
        let pendingOnDisk = pending.fileNameIfOnDisk()
        if let name = pendingOnDisk,
           writePermit.allows(.op(.typingBurst)) != .yes {
            pendingFailure = .init(
                name: name,
                reason: "this Mac can’t write this piece yet",
                cause: .notPermitted)
        } else if pendingOnDisk != nil,
                  case .unrecoverable(let name, let reason, let raw) =
                    await pending.loadFromDisk() {
            let stamp = ISO8601DateFormatter.quarantineStamp(from: Date())
            do {
                _ = try IntegrityQuarantine.record(
                    skipped: [.init(byteOffset: 0,
                                    raw: raw ?? "<pending file \(name) unreadable: \(reason)>")],
                    forDocId: docId, in: projectURL, stamp: stamp)
            } catch {
                documentLog.error(
                    "pending quarantine-record write failed for \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            pendingFailure = .init(name: name, reason: reason)
        }

        // P3a Task 6 fix round 1: the load collects the permit each amendment
        // line was written UNDER, as the partition judged it — a permit is
        // evaluated as of the line and never as of today, and the deriver has
        // no way to ask that question once the bytes are parsed.
        let amendmentPermits = AmendmentPermits()
        let loaded = try await opStore.loadDiagnosed(
            docId: docId, amendmentPermits: amendmentPermits)
        var ops = loaded.ops

        // Forensics (audit 0.6 / Sweep 6): any op-log line that failed to decode
        // — a crash/power-loss mid-`append` leaving a torn final line, or a line
        // written by a newer schema this build can't read — is dropped from the
        // op stream by `loadDiagnosed`. Before, that drop was silent on the
        // normal load path (`IntegrityQuarantine` only ran from the backup gate).
        // Persist a forensic record so nothing vanishes without a trace. This is
        // best-effort: a quarantine-write failure must NEVER abort the load —
        // the manuscript still opens; quarantining is forensics, not a gate.
        if !loaded.diagnostics.skipped.isEmpty {
            let stamp = ISO8601DateFormatter.quarantineStamp(from: Date())
            do {
                _ = try IntegrityQuarantine.record(
                    skipped: loaded.diagnostics.skipped,
                    forDocId: docId, in: projectURL, stamp: stamp)
            } catch {
                documentLog.error(
                    "quarantine-record write failed for \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Crash recovery: fold the pending buffer into a real op. Two triggers:
        //
        //   1. pending has un-bursted CHANGES (the classic text-edit path).
        //   2. pending has NO changes but carries a durable `sequence` that
        //      DIFFERS from the op-log-derived sequence — an ordering-only edit
        //      (paragraph delete / pure reorder) that recorded nothing in the
        //      buffer but was stamped onto `pending.sequence` by autosave's
        //      `setSequence` before the crash (F1). Without this the ordering
        //      change was silently dropped and the deleted paragraph resurrected.
        //
        // Trigger 2 is additionally gated on the pending file's `basis` being
        // CURRENT (Issue 2b — see below): a `{sequence, changes: []}` mirror
        // whose basis no longer matches the log's newest opId is stale relative
        // to ops it never saw, and folding it would reassert an order over a
        // peer's while-closed delete. Clean quits leave no pending file at all
        // now (Issue 2a), so trigger 2 fires only for a genuine crash-mid-reorder.
        //
        // Order comes from the pending buffer (durable, op-log-domain) — NOT the
        // .md (ADR 0019). A legacy pending file with un-bursted changes but no
        // sequence loads `sequence == []` → we fall back to `sequence: nil`,
        // which the deriver reads as "ordering unchanged", carrying the op log's
        // own last-explicit sequence forward.
        // NOTE (growth spec §4.2): this is a recovery op — correctness over
        // bytes. Keyframing applies only to flushBurstNow.
        let derivedSequenceBeforeRecovery =
            Deriver.deriveWithSequenceFallback(ops: ops).sequence

        // Issue 2b — basis-aware staleness. The pending file's `sequence` was
        // stamped against a known-newest op (`basis`). If ops it never saw have
        // merged in since (basis != the log's current newest opId — e.g. a peer's
        // while-closed delete synced in), the pending order is STALE: it must not
        // reassert an ordering over ops it predates. A legacy pending file has no
        // basis; for the empty-changes fold that's treated as stale (skip — the
        // safer default, and legacy files predate the sequence field anyway),
        // while non-empty changes keep today's text+sequence recovery.
        let newestFoldedOpId = ops.map(\.opId).max()
        let pendingBasis = pending.basis
        let basisStale = pendingBasis != nil && pendingBasis != newestFoldedOpId
        let basisCurrent = pendingBasis != nil && pendingBasis == newestFoldedOpId

        if !pending.isEmpty() {
            // Non-empty changes: ALWAYS recover the text. Attach the pending
            // sequence unless the basis is stale — a stale basis recovers text
            // with `sequence: nil` so the deriver carries the last explicit
            // sequence forward instead of reasserting a superseded order.
            let recoveredSequence = basisStale ? [] : pending.sequence
            // **It says what it is** (P3b Task 3, handoff ruling 3). This burst
            // is the LOAD's own — a crashed session's buffer, folded in before
            // the writer has touched anything — and until this label it was
            // indistinguishable on disk from a person typing. Provenance only:
            // `PermitPartition.writtenOp` decodes a KIND and nothing else, so
            // the field cannot reach the permission table from either side.
            let recovered = Op(
                opId: ULID.generate(), docId: docId, at: Date(),
                device: emissionDevice, session: session, kind: .typingBurst,
                changes: pending.snapshot(),
                sequence: recoveredSequence.isEmpty ? nil : recoveredSequence,
                provenance: Op.Provenance(synthesisSource: .pendingRecovery))
            try await opStore.append(recovered)
            try await pending.clear()
            ops.append(recovered)
        } else if basisCurrent
            && !pending.sequence.isEmpty
            && pending.sequence != derivedSequenceBeforeRecovery {
            // Empty-changes ordering-only fold: only when the basis is CURRENT
            // (present AND == the newest opId) and the pending order genuinely
            // diverges from the derived order. A stale or missing basis means the
            // order predates ops it never saw — skip, so a clean-quit
            // `{sequence, changes: []}` mirror (Issue 2a already deletes it) or a
            // peer's while-closed delete never reasserts a superseded order.
            // The same cause, its other half: the buffer's ORDER survived and
            // its text did not. One `SynthesisSource` for both arms — what a
            // reader needs to know is *the load wrote this*, and which half
            // survived is already legible from `changes` being empty.
            let recovered = Op(
                opId: ULID.generate(), docId: docId, at: Date(),
                device: emissionDevice, session: session, kind: .typingBurst,
                changes: [],
                sequence: pending.sequence,
                provenance: Op.Provenance(synthesisSource: .pendingRecovery))
            try await opStore.append(recovered)
            try await pending.clear()
            ops.append(recovered)
        }

        // ADR 0019: content + order come ONLY from the op log, never from the
        // `.md`'s anchors. `deriveWithSequenceFallback` synthesises a sequence
        // from first-appearance order for legacy logs whose typing bursts
        // predate the always-capture-sequence fix. `reconcile` then drops orphan
        // paragraphs (ids in the accumulator but not in `sequence`) so the
        // inline-task deriver doesn't surface phantom rows. The `.md` on disk is
        // clean (ADR 0019) and plays no part in content or order.
        let initial = Document.reconcile(
            derived: Deriver.deriveWithSequenceFallback(ops: ops))

        // F4: a file edited while Maugham was CLOSED is otherwise silently
        // overwritten by the first autosave, with no `.maugham/conflicts/`
        // trace — the backup-on-discard net (`handleExternalDiskChange`) only
        // covers live presenter events. When a log already existed (so this is
        // NOT the fresh-bootstrap path, whose `.md` IS the seed) and the
        // on-disk display form diverges from the op-log-derived display form,
        // snapshot the on-disk bytes forensically BEFORE the `Document` — and
        // its autosave — exist to clobber them. Compare DISPLAY forms
        // (`stripAnchors` both) so an unmigrated still-anchored file whose
        // content equals op-log truth does not false-positive. Dedup against
        // the newest existing snapshot so repeated open/close of an unchanged
        // divergent file doesn't accumulate identical copies. A backup-write
        // failure must NEVER abort the load — the manuscript still opens; the
        // snapshot is forensics, not a gate (mirrors the quarantine-write above).
        // A MISSING file has no bytes to keep, so it is not a divergence: a
        // piece restored from *Removed Elsewhere* is loaded to write its first
        // render, and snapshotting "" there would leave an empty "backup" of
        // nothing in `.maugham/conflicts/`.
        var divergedAtLoad = false
        if logExists && FileManager.default.fileExists(atPath: url.path) {
            let derivedRender = MarkdownDisplayFilter.stripAnchors(
                Materializer.materialize(
                    paragraphs: initial.paragraphs, sequence: initial.sequence))
            if MarkdownDisplayFilter.stripAnchors(storedBytes) != derivedRender {
                divergedAtLoad = true
                do {
                    let newest = Document.newestConflictBackup(
                        forFileAt: url, docId: docId)
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }  // adr-0018-ok: conflict-backup snapshot read for dedup, not manuscript truth
                    if newest != storedBytes {
                        _ = try Document.writeConflictBackup(
                            forFileAt: url, docId: docId, text: storedBytes,
                            kind: "diverged")
                    }
                } catch {
                    documentLog.error(
                        "divergence snapshot write failed for \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let lastWritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""  // adr-0018-ok: sanctioned manuscript site — echo-guard baseline; op log is authoritative
        let initialEcho = EchoState.initialLoad(bytes: lastWritten)

        // BurstScheduler with caller-supplied thresholds (defaults: 30s/90s).
        let burstHolder = WeakBurstHolder()
        let burst = BurstScheduler(
            idle: burstIdle, max: burstMax
        ) {
            Task { @MainActor in
                try? await burstHolder.document?.flushBurstNow()
            }
        }

        let doc = Document(
            url: url, docId: docId, device: device, session: session,
            presenter: presenter, opStore: opStore, pending: pending,
            burstScheduler: burst,
            paragraphs: initial.paragraphs, sequence: initial.sequence,
            lastDiskEcho: initialEcho)
        burstHolder.document = doc

        // Initialize autosave + displayText.
        doc.autosaveScheduler = DebounceScheduler<Void>(
            delay: .milliseconds(750)
        ) { [weak doc] _ in
            try? await doc?.performAutosave()
        }
        doc.recomputeDisplayText()
        doc._opLogMirror = ops
        doc.invalidateRestoreStandingMemo()
        doc._annotationsCacheValid = false
        doc._hasAnyAnnotationOps = ops.contains {
            Document.isAnnotationOpKind($0.kind)
        }
        doc.unrecoveredPendingFailure = pendingFailure
        // P3a Task 8: carried, so the derivations that emit on their own
        // account — `rebuildTasksCache`'s anchor splice and its `taskCreate`
        // breadcrumbs — can ask the same question the load asked, without a
        // registry read of their own on a path a plain `tasks(filter:)` READ
        // reaches.
        doc.stamp(localWritePermit: writePermit)
        // P3a Task 6: and the same for the OTHER direction — not what this
        // device may write, but which of the amendments already in the log this
        // derivation honours. Resolved here because the table `localWritePermit`
        // warmed is still warm; the projection it feeds is rebuilt at every
        // burst boundary and must not reach for a register of its own.
        doc.annotationAmendments = Document.judgedAmendments(
            opStore: opStore, permits: amendmentPermits, docId: docId,
            placement: placement)
        doc.invalidateRestoreStandingMemo()
        // Signed op log P1: what this document's history turned out to be made
        // of. STAMPED, never posted — a notice from this windowless context is
        // dropped by the receive helpers' liveness guard, exactly the pending
        // stamp's reasoning above. `HistoryPane` reads the stamp off the open
        // document; `EditorHost` is what tells the pane to look, once a window
        // exists for it to look in.
        doc.provenance = loaded.provenance
        doc.ownLinesKeptInHistory = loaded.provenance.ownLinesKeptInHistory
        // P3b Task 7: and which of the holders it is counting opened a piece
        // nobody has claimed — the one held line the writer can answer today.
        doc.startedAPiece = amendmentPermits.whoStartedAPiece
        doc.keptWritingInATakenPiece = amendmentPermits.whoKeptWritingInATakenPiece
        // **A diverged `.md` is re-rendered, not only snapshotted** (P3 plan
        // 3, carry C12, ruling C12-1's closed half). A trust change or a sync
        // that reached this piece while it was closed re-derived nothing on
        // disk; its next open is where the render catches up. The "diverged"
        // backup above stays, as evidence. Scheduled through the ordinary
        // debounce, so `performAutosave`'s guards decide, and asked last,
        // once `provenance` is stamped: a load HOLDING lines renders nothing
        // on its own account (`rendersOnItsOwnAccount`). A load that refused
        // (`waitingForPiece`) never reaches here, and a recovery load is a
        // different function whose scheduler does nothing.
        if divergedAtLoad && doc.rendersOnItsOwnAccount {
            doc.autosaveScheduler.schedule(())
        }
        return doc
    }
}

/// Looks up the doc-id for a manuscript path. Walks UP the directory tree
/// until it finds `project.maugham.json`, then resolves the doc against
/// that project's manifest. Falls back to a deterministic hash of the
/// path if no manifest is found (test fixtures, headless tooling).
///
/// The walk-up matters for nested doc layouts: Novel/Screenplay projects
/// keep manuscripts at `<project>/manuscript/<file>.md` (2 levels), but
/// Collection projects put pieces at `<project>/pieces/<piece-folder>/<file>`
/// (3 levels) and research notes can be deeper still. A fixed
/// `deletingLastPathComponent().deletingLastPathComponent()` lands inside
/// the piece folder for Collections and silently triggers the hash fallback,
/// producing a docId that doesn't match the manifest's StructureItem.id.
/// Op log files then go to the wrong file, MCP annotations stop resolving,
/// and the editor's live Document gets a fabricated id no other lookup
/// can find.
internal func resolveDocId(for url: URL) throws -> String {
    try resolveDocIdTellingIfNamed(for: url).docId
}

/// `resolveDocId`, telling the caller whether a manifest NAMED the id (a
/// structure item or a statement at that path) or it was fabricated — a hash,
/// because no manifest lists the path. The posture door's path cache keeps a
/// fabricated id only while the manifest it was fabricated from is unchanged
/// (P3 plan 3 Task 6); every other caller asks `resolveDocId` and cannot tell
/// the two apart.
internal func resolveDocIdTellingIfNamed(
    for url: URL
) throws -> (docId: String, named: Bool) {
    var probe = url.deletingLastPathComponent()
    let fm = FileManager.default
    // Cap the walk at 16 ancestors so a malformed URL can't infinite-loop.
    for _ in 0..<16 {
        let manifestURL = probe.appendingPathComponent(ProjectManifest.fileName)
        if fm.fileExists(atPath: manifestURL.path) {
            let relativePath = url.path
                .replacingOccurrences(of: probe.path + "/", with: "")
            if let data = try? Data(contentsOf: manifestURL) {  // adr-0018-ok: project manifest JSON read, not manuscript
                let dec = ProjectManifest.makeDecoder()
                if let manifest = try? dec.decode(
                    ProjectManifest.self, from: data) {
                    if let item = findItemByPath(
                        relativePath, in: manifest.structure) {
                        return (item.id, true)
                    }
                    // Statements (M1A) are ordinary Documents with ordinary op
                    // logs, so they need the same manifest-borne identity a
                    // manuscript has: `intent.md` renamed to
                    // `intent/weather.md` must keep every op ever written into
                    // it (tripwire 22). Structure is consulted FIRST — a path
                    // registered in both resolves as the manuscript, whose id
                    // predates this and is what its on-disk log was written
                    // against.
                    if let statement = manifest.statements.first(
                        where: { $0.path == relativePath }) {
                        return (statement.id, true)
                    }
                }
            }
            // Found the manifest but couldn't decode or match. Stop walking;
            // don't keep climbing into an unrelated parent project.
            let relativeFallback = url.path
                .replacingOccurrences(of: probe.path + "/", with: "")
            return ("doc-\(StableHash.fnv1a64Hex(relativeFallback))", false)
        }
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { break }   // hit root
        probe = parent
    }
    // No manifest found — hash-fallback against the basename so test fixtures
    // still get a stable id.
    let basename = url.lastPathComponent
    return ("doc-\(StableHash.fnv1a64Hex(basename))", false)
}

/// Walks up the directory tree from a doc's URL until it finds the directory
/// that contains `project.maugham.json`. Used by Document.load to anchor
/// `.maugham/ops/<docId>.jsonl` and other project-relative paths. Falls
/// back to two-level deletion (the legacy behavior) if no manifest is found,
/// which keeps test fixtures that fake a project structure without writing
/// a manifest working.
internal func resolveProjectURL(for url: URL) -> URL {
    var probe = url.deletingLastPathComponent()
    let fm = FileManager.default
    for _ in 0..<16 {
        if fm.fileExists(atPath:
            probe.appendingPathComponent(ProjectManifest.fileName).path) {
            return probe
        }
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { break }
        probe = parent
    }
    // Legacy fallback for tests that don't write a manifest: 2 levels up.
    return url.deletingLastPathComponent().deletingLastPathComponent()
}

private func findItemByPath(_ path: String, in items: [StructureItem]) -> StructureItem? {
    for item in items {
        if item.path == path { return item }
        if let kids = item.children,
           let found = findItemByPath(path, in: kids) { return found }
    }
    return nil
}

extension Document {
    /// **Whose annotation it is, for one document** — the table a load builds
    /// (P3a Task 6), spelled once so the load, the external re-read and a
    /// closed piece's history (`closedPieceHistory`) cannot build it
    /// differently (P3 plan 3 Task 5). `permits` is what the same read's
    /// partition collected.
    ///
    /// `placement` is the caller's own manifest read where it already holds
    /// one (the load, which asked the write permit through it — P3 plan 3
    /// Task 6), so the class is not decoded a second time; nil reads the
    /// manifest on disk, once, if the table asks for the class at all.
    static func judgedAmendments(
        opStore: OpLogStore, permits: AmendmentPermits, docId: String,
        placement: ManifestPlacement? = nil
    ) -> AnnotationAmendments {
        // Bound out here: the class closure is `@Sendable` and may reach
        // neither a Document nor a main-actor property of the store.
        // `ManifestPlacement` is `Sendable` and reads through `OpLogStore`'s
        // own door rather than `Document.documentClass`, which is the same
        // function behind a `@MainActor` extension.
        let placement = placement
            ?? ManifestPlacement(docId: docId, in: opStore.projectURL)
        return opStore.annotationAmendments(from: permits) {
            placement.documentClass
        }
    }

    /// **A piece nobody has open, read as a load reads it** (P3 plan 3 Task
    /// 5) — its ops and the amendment table a load would judge them by, for
    /// the rewind window's closed branch. Before this the window kept
    /// `.honourEverything` for a closed piece, so its preview honoured a
    /// reviewer's reopen of the root's archive that the same piece, opened,
    /// does not: two answers to one question (RULING-8).
    ///
    /// The load's own store (`makeLoadOpStore`: the same identities, device
    /// state and registry memory), its trust warmed first (`prepareTrust`),
    /// then the same partitioned read and the same table. A read that fails
    /// answers no ops, as the window's `try?` always did.
    static func closedPieceHistory(
        docId: String, projectURL: URL
    ) async -> (ops: [Op], amendments: AnnotationAmendments) {
        let opStore = makeLoadOpStore(projectURL: projectURL, presenter: nil)
        await opStore.prepareTrust()
        let permits = AmendmentPermits()
        guard let loaded = try? await opStore.loadDiagnosed(
            docId: docId, amendmentPermits: permits)
        else { return ([], .honourEverything) }
        return (loaded.ops,
                judgedAmendments(opStore: opStore, permits: permits, docId: docId))
    }
}

/// Indirection so BurstScheduler's fire closure can reference the
/// Document without a retain cycle.
@MainActor
private final class WeakBurstHolder {
    weak var document: Document?
}

extension ISO8601DateFormatter {
    /// A filesystem-safe timestamp for `.maugham/` sidecar filenames: ISO8601
    /// with fractional seconds, `:` replaced by `-` (colons are illegal in some
    /// filesystems / awkward in URLs). Mirrors the conflict-archive stamp in
    /// `DocumentStore.archiveManifestForConflict` so the two conventions match.
    /// Lives Mac-side because MaughamCore is wall-clock-free (the stamp is
    /// injected into `IntegrityQuarantine.record`).
    static func quarantineStamp(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
