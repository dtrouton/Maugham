import SwiftUI
import MaughamCore
import os

/// Diagnostic channel for a Retry attempt that leaves a record `.held`
/// (`.stillUnreadable`/`.corrupt`) — the writer sees the standing notice
/// persist; this is the WHY for anyone debugging it. Mirrors
/// `PartialRestorePicker.swift`'s `partialRestoreLog`.
private let historyQuarantineLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "HistoryPaneQuarantine")

/// **`HistoryPane`'s verbs** — every reload and every press, over bindings to
/// the pane's `@State`.
///
/// Built fresh per call by `HistoryPane.verbs` and never stored (the
/// CanvasView split's shape): a binding writes the same storage the pane
/// reads, so nothing is copied and nothing is synchronised. The open
/// document's provenance arrives as a closure, so a read after an `await` is
/// the pane's live answer. Every store call is the one the pane made.
@MainActor
struct HistoryPaneVerbs {
    let projectURL: URL
    let activeDocId: String
    let documentStore: DocumentStore?
    let documentProvenance: () -> OpLogProvenance?
    @Binding var checkpoints: [Checkpoint]
    @Binding var unreadableCheckpointFiles: [CheckpointLoad.UnreadableFile]
    @Binding var ops: [Op]
    @Binding var heldQuarantineRecords: [QuarantineRecord]
    @Binding var setAsideRecordNames: [String]
    @Binding var setAsideRows: [SetAsideDoor.Row]
    @Binding var setAsideChangesByReason: [String: Int]
    @Binding var lostHistoryRows: [HistoryPane.LostHistoryRow]
    @Binding var chainDeviceNames: [String: String]
    @Binding var joinedChainLine: String?
    @Binding var retirementLine: String?
    @Binding var trustEventLines: [HistoryPane.TrustEventLine]
    @Binding var heldWordCounts: [String: Int]
    @Binding var heldSentCounts: [String: Int]
    @Binding var sendToInboxError: String?
    @Binding var isRetryingQuarantine: Bool
    @Binding var recoveredReport: RecoveredHistoryReport?
    @Binding var showingRecoveredHistorySheet: Bool

    func reload() async {
        let loaded = await CheckpointStore(projectURL: projectURL).load()
        // Show all project-scope checkpoints regardless of active doc.
        // Checkpoints are project-wide artefacts; filtering by active doc
        // would hide checkpoints captured while a different doc was open,
        // which is exactly what the user would expect to see for a
        // multi-doc novel/screenplay project.
        checkpoints = loaded.checkpoints
        unreadableCheckpointFiles = loaded.unreadableFiles
        // Prefer the live Document if it's loaded (its mirror reflects any
        // unflushed in-memory state). Otherwise read the op log directly
        // from disk — the History pane should always show typing bursts /
        // annotations for the active doc, even when the
        // user hasn't yet opened it in the editor this session.
        if let ds = documentStore,
           let doc = ds.document(forDocId: activeDocId) {
            ops = (try? await doc.opLog()) ?? []
        } else if activeDocId != BinderSubject.noDocumentSubject {
            let opStore = OpLogStore(projectURL: projectURL)
            ops = (try? await opStore.load(docId: activeDocId)) ?? []
        } else {
            ops = []
        }
        // Split by KIND, because the two kinds are two different offers. A
        // `.file` record is a whole per-device log that could not be read —
        // Retry may bring it back. A `.lines` record is a run of lines
        // something other than Maugham wrote, kept as forensics with nothing
        // to return, so it stays out of the Retry list and out of
        // `quarantineNotice`'s count (signed op log P1).
        let held = activeDocId == BinderSubject.noDocumentSubject
            ? []
            : OpLogQuarantine.records(forDocId: activeDocId, in: projectURL)
                .filter { $0.status == .held }
        heldQuarantineRecords = held.filter { $0.kind == .file }
        // The sentence counts only what this device has NOT yet told the
        // writer about (P2a, D2) — the disclosure below it keeps the whole
        // list. Both resolutions happen here rather than in `body`, because
        // each reads the quarantine directory.
        let setAside = held.filter { $0.kind == .lines }
        setAsideRecordNames = setAside.map {
            SetAsideAcknowledgement.name(for: $0, in: projectURL)
        }
        // **C16's input, resolved once for both readers** (P3b Task 8): the
        // rows below and the sentence beneath them ask the same question of the
        // same table, so a record cannot be listed under one reason and counted
        // under another. Nil for every book that has revoked nobody, which
        // costs nothing to establish.
        let keepsNothing = await HistoryPane.keepsNothingNow(setAside, in: projectURL)
        setAsideRows = SetAsideDoor.rows(
            records: setAside, in: projectURL,
            sent: documentStore?.uiState.sentRecoveredOpIds ?? [:])
        // `applied` is the ops this document is carrying RIGHT NOW — the list
        // read a few lines above, so nothing new is read from disk for it. An
        // op that was set aside and is now in the draft (the writer admitted the
        // device that wrote it) is evidence the disclosure keeps listing and a
        // change the sentence has stopped being about (P2 smoke, find 7).
        setAsideChangesByReason = HistoryPane.setAsideChangesByReason(
            records: SetAsideAcknowledgement.unacknowledged(
                records: setAside,
                acknowledged: documentStore?.uiState.acknowledgedSetAsideRecords ?? [],
                in: projectURL),
            in: projectURL,
            applied: Set(ops.map(\.opId)),
            nowKeepsNothing: { keepsNothing[SetAsideDoor.identity(of: $0)] ?? nil })
        // Read outside `reloadChain`'s registry guard: a book that has never
        // joined a chain can still hold another device's stream, and what this
        // Mac cannot find is true whether or not a register says whose it was.
        lostHistoryRows = await HistoryPane.lostHistoryRows(
            documentStore?.lostHistory() ?? [])
        await reloadChain()
        await reloadHeldWordCounts()
    }

    /// **What each unsigned holder is waiting with** — the disk half of the
    /// held-line rows (fix round 2, I1).
    ///
    /// Keyed off the LIVE provenance rather than a value captured earlier in
    /// `reload()`, and re-run by `body`'s `.task(id:)` whenever that set of
    /// holders changes — which is what a document whose provenance lands after
    /// the first reload looks like from here. A book with no unsigned holder
    /// asks nothing and costs nothing.
    func reloadHeldWordCounts() async {
        let holders = Array(documentProvenance()?.pendingByDevice.keys ?? [:].keys)
        let counts = await documentStore?.unsignedHeldWordCounts(
            forDocId: activeDocId, holders: holders) ?? .none
        heldWordCounts = counts.unsent
        heldSentCounts = counts.sent
    }

    /// The names the two chain sentences are told in, resolved off the main
    /// actor (signed op log P2a).
    ///
    /// **Why the registry and not `OpLogStore.trust()`.** A `TrustTable`
    /// answers verdicts and names nobody — that is deliberate, so that a table
    /// need only be rebuilt when the registry changes. The names live in the
    /// records, so this reads them.
    ///
    /// **Off the actor**, for `TrustResolution.resolve`'s own reason: it is a
    /// directory read plus a signature verification per record.
    ///
    /// **A project with no registry directory short-circuits without a read.**
    /// That is every project that has never joined a chain — the ordinary case,
    /// which must cost nothing beyond three `fileExists`. A registry deleted
    /// WHOLESALE therefore leaves both sentences quiet until something restores
    /// it, which the next document load does on its way to any verdict.
    ///
    /// Never fatal: `RegistryReader.load` throws on a record it cannot read
    /// (RULING-54) and refusing the whole pane over a name would be the wrong
    /// trade. The counts and the join do not come from it.
    func reloadChain() async {
        let url = projectURL
        guard TrustResolution.hasRegistry(in: url) else {
            chainDeviceNames = [:]
            joinedChainLine = nil
            retirementLine = nil
            trustEventLines = []
            return
        }
        // **The unsigned entries' two facts, read with everything else that
        // touches disk** (P3b Task 10). `onlyIfNarrowed` because an unsigned
        // entry exists only in a narrowed book: an un-narrowed one would pay
        // for a walk of every op file to draw nothing.
        let identities = Document.loadIdentities
        let registryCache = Document.loadRegistryCache
        let resolved = await Task.detached(priority: .userInitiated) {
            () -> (names: [String: String], joined: String?, retired: String?,
                   events: [HistoryPane.TrustEventLine]) in
            let registry = try? RegistryReader.load(projectURL: url)
            let unsigned = DocumentStore.readUnsigned(
                in: url, identities: identities, cache: registryCache,
                onlyIfNarrowed: true)
            var names: [String: String] = [:]
            var labels: [String: String] = [:]
            for device in registry?.devices ?? [] { names[device.device] = device.name }
            for person in registry?.people ?? [] { labels[person.person] = person.label }
            // The events are derived from whatever the read could vouch for —
            // an unreadable registry costs the writer names, never the pane
            // (RULING-54's trade, as P2a made it for the two banners). What a
            // device REMEMBERS is still read: the join and the claimants are
            // this Mac's own facts and survive a folder nobody can read.
            let events = TrustEvents.derive(
                registry: registry ?? Registry(), cache: .shared,
                mine: .current, for: url,
                unsigned: TrustEvents.UnsignedStreams(
                    narrowedAt: unsigned.narrowedAt, streams: unsigned.streams))
            // This Mac's own standing, for the one fact on it that the machine
            // itself has to be told: `DeviceStanding` owns the sentence so the
            // pane and People & Devices cannot word it differently (tripwire
            // 19), and the noun is this app's — a Mac.
            let standing = DeviceStanding.resolve(
                registry: registry ?? Registry(), cache: .shared,
                mine: .current, for: url)
            return (names,
                    HistoryPane.joinedChainNotice(
                        cache: .shared, projectURL: url, labels: labels),
                    HistoryPane.retirementNotice(standing: standing),
                    HistoryPane.trustEventLines(events, labels: labels))
        }.value
        chainDeviceNames = resolved.names
        joinedChainLine = resolved.joined
        retirementLine = resolved.retired
        trustEventLines = resolved.events
    }

    /// **Send one record's set-aside words to the Inbox** (spec §7.4).
    ///
    /// Nothing is applied and nothing on disk moves: the words are copied out
    /// as captures signed by this Mac's own author actor, and the record stays
    /// held with the same sentence on it. The press is remembered device-locally
    /// so the door is not offered a second time and the same paragraphs are not
    /// filed twice.
    func sendSetAsideToInbox(_ row: SetAsideDoor.Row) {
        guard let documentStore else { return }
        let projectURL = self.projectURL
        let records = OpLogQuarantine.records(forDocId: activeDocId, in: projectURL)
        guard let record = records.first(where: {
            SetAsideAcknowledgement.name(for: $0, in: projectURL) == row.name
        }) else { return }
        let already = documentStore.uiState.sentRecoveredOpIds[row.name] ?? []
        Task {
            let named = await HistoryPane.attributions(for: record, in: projectURL)
            let captures = SetAsideDoor.captures(
                forRecord: record, in: projectURL, alreadySent: already,
                // A record whose chain broke names nobody (fix round 2, M6):
                // the `device` field in those bytes is the one thing the
                // refusal exists to disbelieve.
                attribution: {
                    named[$0.device] ?? SetAsideDoor.attribution(
                        forRecord: record, deviceId: $0.device,
                        registry: Registry(),
                        table: TrustResolution.keyless(mine: .current))
                })
            do {
                // Recorded as each one lands, so a send that fails halfway
                // leaves a re-press with only the rest to do (fix round 2, M2).
                _ = try await documentStore.inboxStore.captureRecoveredWords(
                    captures,
                    onLanded: { landed in
                        documentStore.recordRecoveredCapturesSent(
                            door: row.name, ids: [landed.id])
                    })
                sendToInboxError = nil
            } catch {
                sendToInboxError = error.localizedDescription
            }
            await reload()
        }
    }

    /// **Send an unsigned holder's WAITING words to the Inbox** (spec §7.4).
    ///
    /// The set-aside door's twin over the other refusal: nothing is applied,
    /// no byte of the stream moves, the lines stay held under the same holder,
    /// and the words arrive as captures signed by this Mac's own author actor.
    /// A re-read that will not read, or that finds no prose, says so and sends
    /// nothing rather than filing a capture it is not sure of.
    func sendHeldWordsToInbox(_ row: SetAsideDoor.HeldRow) {
        guard let documentStore else { return }
        let docId = activeDocId
        Task {
            do {
                let landed = try await documentStore.sendHeldWordsToInbox(
                    forDocId: docId, heldBy: row.holder)
                sendToInboxError = landed > 0
                    ? nil
                    : "Nothing is waiting to send any more."
            } catch {
                sendToInboxError = error.localizedDescription
            }
            await reload()
        }
    }

    /// Put the set-aside sentence down: every record it could be about is
    /// recorded as seen in this device's UI state, and the reload recomputes
    /// the count from what is left. Nothing on disk moves — the disclosure
    /// above goes on listing exactly what it listed before.
    func acknowledgeSetAside() {
        documentStore?.acknowledgeSetAsideRecords(Set(setAsideRecordNames))
        Task { await reload() }
    }

    /// **The writer says they know this history is gone** (P3b Task 6).
    ///
    /// It writes nothing to the book — this Mac's own memory of having been
    /// told, and nothing another device will ever read — and what it changes is
    /// that the marking verbs stop waiting for that stream. The row stays,
    /// saying so.
    func acknowledgeLostHistory(_ streamKey: String) {
        documentStore?.acknowledgeLostHistory(streamKey: streamKey)
        Task { await reload() }
    }

    /// Runs `attemptReturn` for every held record, reloads, and surfaces
    /// what happened: a toast in EVERY case, plus the report sheet when the
    /// return turned up paragraphs the draft doesn't have.
    ///
    /// Each record's own `RecoveredHistoryReport` is carried through and the
    /// sweep's verdict is `RecoveredHistoryReport.aggregate` — never a report
    /// assembled here from loose orphans with `redundant` written in by hand,
    /// which is what shipped (the review's I1): the flag then said "sync had
    /// already delivered all of this" about sweeps where it had delivered none
    /// of it.
    ///
    /// A record that stays `.stillUnreadable`/`.corrupt` keeps its place in the
    /// standing notice via the next `reload()`, and — when NOTHING in the sweep
    /// came back — says so (`stillHeldNotice`) rather than leaving a pressed
    /// button looking dead.
    func retryQuarantine() {
        guard !isRetryingQuarantine else { return }
        isRetryingQuarantine = true
        Task {
            var reports: [RecoveredHistoryReport] = []
            var failureReasons: [String] = []
            for record in heldQuarantineRecords {
                let outcome = await OpLogQuarantine.attemptReturn(
                    record: record, in: projectURL, presenter: nil)
                switch outcome {
                case .returned(let report):
                    reports.append(report)
                case .supersededBySync(let report):
                    reports.append(report)
                    // The lossy shape, and the reason `redundant` is a field
                    // rather than an inference from the orphan count: nothing
                    // moved, and the archive carries history the live log has
                    // not got. The writer hears about it through the orphan
                    // notice; this is the WHY for whoever reads the log.
                    if !report.redundant {
                        historyQuarantineLog.notice("retryQuarantine: \(record.originalName, privacy: .public) stays an archive — its place was refilled by sync, and it holds \(report.orphans.count, privacy: .public) paragraph(s) the live history does not")
                    }
                case .stillUnreadable(let reason), .corrupt(let reason):
                    failureReasons.append(reason)
                    historyQuarantineLog.error("retryQuarantine: \(record.originalName, privacy: .public) still held — \(reason, privacy: .public)")
                case .setAsideByProvenance:
                    // Lines this device did not write, kept as forensics. There
                    // is no file to bring back, so this is neither a report nor
                    // a failure — nothing is offered to the writer about it.
                    // Unreachable from here since `reload()` keeps `.lines`
                    // records out of `heldQuarantineRecords` entirely; the arm
                    // is the belt, and the switch has to be exhaustive anyway.
                    historyQuarantineLog.notice("retryQuarantine: \(record.originalName, privacy: .public) holds lines set aside by provenance — nothing to return")
                }
            }
            await reload()
            isRetryingQuarantine = false
            guard !reports.isEmpty else {
                if let reason = failureReasons.first {
                    MaughamEvent.postNotice(
                        HistoryPane.stillHeldNotice(reason: reason), projectURL: projectURL)
                }
                return
            }
            let sweep = RecoveredHistoryReport.aggregate(reports)
            MaughamEvent.postNotice(
                HistoryPane.recoveredHistoryNotice(orphanCount: sweep.orphans.count),
                projectURL: projectURL)
            if !sweep.orphans.isEmpty {
                recoveredReport = sweep
                showingRecoveredHistorySheet = true
            }
        }
    }

    func jump(_ entry: HistoryEntry) {
        guard case .op(let op) = entry,
              let pid = op.changes.first?.paragraphId else { return }
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: ["paragraph_id": pid])
    }
}
