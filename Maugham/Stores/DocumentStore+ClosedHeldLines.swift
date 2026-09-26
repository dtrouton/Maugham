// Maugham/Stores/DocumentStore+ClosedHeldLines.swift
import Foundation
import MaughamCore
import os

private let closedHeldLinesLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "ClosedHeldLines")

/// **The held lines in documents nobody has open** (signed op log P3 plan 3,
/// carry C4).
///
/// `heldLines()` is what the admission sheet and People & Devices count, and
/// until this it was the OPEN documents' loads plus the capture stream: a
/// stranger who had written only in chapters nobody had opened was asked about
/// when one of them was opened, and not before. This file keeps a second map,
/// `closedProvenance`, filled off the main actor by a sweep that asks
/// `OpLogStore.provenance(forDocId:in:trust:state:)` — the load's own per-file
/// classify, with the load's own permit context — one closed document at a
/// time.
///
/// **When it runs**: once at project open, after the silent admission; again
/// after every `invalidateTrust` (an admission, a revocation, *Theirs*, a
/// record syncing in — the same bytes hold different lines under a changed
/// table); and, for ONE document, when the presenter sees an op-log file land
/// in a closed document (debounced by the presenter's existing announcement
/// debounce, never a timer of its own).
///
/// **The union rule** (`heldLines()`): per docId, the OPEN document's own
/// provenance if it is open, else this map's entry. An entry is dropped when
/// its document registers (so the only way back in is the live provenance the
/// document carries when it closes), MOVED in from the live document when it
/// closes (so a close after the sweep keeps the count until the next sweep —
/// Review Focus 2), and pruned when the manifest stops listing its piece.
///
/// **What it posts**: `MaughamEvent.postAdmissionRequested` when a pass
/// changes what the closed half holds for a STRANGER (ruling C4-1: the sheet
/// re-describes itself when the sweep lands). Narrowed to strangers for
/// `announcePendingHistory`'s D5 reason — the sheet only ever asks about a
/// stranger, and the piece question is the open documents' — so a pass that
/// only moves an admitted person's permit-pending count, or moves nothing,
/// posts nothing.
extension DocumentStore {

    // MARK: - Triggers

    /// Queue a whole-book pass over every closed document the manifest lists.
    /// Chained behind any pass in flight; a pass already queued and not yet
    /// started absorbs this request, because it will read exactly what this
    /// one would.
    func sweepClosedProvenance() {
        guard !closedSweepQueued else { return }
        closedSweepQueued = true
        enqueueClosedPass(only: nil)
    }

    /// Drain the documents the presenter saw change while closed, as one pass
    /// over just those. Called from the presenter's debounce.
    func reclassifyPendingClosedDocuments() {
        let ids = closedReclassifyPending
        closedReclassifyPending = []
        guard !ids.isEmpty else { return }
        enqueueClosedPass(only: ids)
    }

    // MARK: - The close / open / adoption moves

    /// A document leaving the registry takes its live provenance into the
    /// closed map, so its held lines stay counted until the next sweep.
    func rememberClosedProvenance(of document: Document) {
        closedProvenanceStamps[document.docId, default: 0] += 1
        closedProvenance[document.docId] = document.provenance
    }

    /// A document that opened answers for itself.
    func forgetClosedProvenance(ofDocId docId: String) {
        closedProvenanceStamps[docId, default: 0] += 1
        closedProvenance.removeValue(forKey: docId)
    }

    /// A manifest adopted from elsewhere: a piece it no longer lists (trashed
    /// or removed on another Mac) stops counting now. In memory only.
    func pruneClosedProvenance(keepingDocIdsOf manifest: ProjectManifest) {
        let listed = Self.sweptDocIds(in: manifest)
        let gone = closedProvenance.keys.filter { !listed.contains($0) }
        guard !gone.isEmpty else { return }
        let before = closedStrangerHolding()
        for docId in gone { forgetClosedProvenance(ofDocId: docId) }
        announceIfClosedStrangersMoved(since: before)
    }

    // MARK: - The pass

    /// One pass: resolve which documents and one trust table off the main
    /// actor, then each closed document's provenance off the main actor, one
    /// at a time, and land the answers here.
    ///
    /// `self` is bound only inside scopes that end before a suspension, for
    /// `ProjectStore.recountFromOpLogs`' reason: a pass parked on a read must
    /// not hold a closed window's store alive.
    private func enqueueClosedPass(only: Set<String>?) {
        let previous = closedSweepTask
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let state = Document.loadDeviceState
        closedSweepTask = Task { @MainActor [weak self] in
            await previous?.value
            // Which documents: the live manifest where a project is attached,
            // else the one on disk (at open nothing is attached yet).
            let started: (listed: Set<String>?, epoch: Int)? = {
                guard let self else { return nil }
                if only == nil { self.closedSweepQueued = false }
                return (self.projectStore.map { Self.sweptDocIds(in: $0.manifest) },
                        self.closedTrustEpoch)
            }()
            guard let started else { return }
            let resolved = await Task.detached(priority: .utility) {
                () -> (listed: Set<String>, trust: TrustTable)? in
                // A book with no register holds nothing: every seal is
                // somebody's unsigned history and nobody is a stranger.
                guard TrustResolution.hasRegistry(in: projectURL) else { return nil }
                guard let listed = started.listed ?? Self.sweptDocIds(inManifestAt: projectURL)
                else {
                    closedHeldLinesLog.error(
                        "closed documents' held lines in \(projectURL.lastPathComponent, privacy: .public) were not counted: the manifest would not read")
                    return nil
                }
                do {
                    let trust = try TrustResolution.resolve(
                        projectURL: projectURL, identities: identities, cache: cache)
                    return (listed, trust)
                } catch {
                    closedHeldLinesLog.error(
                        "closed documents' held lines in \(projectURL.lastPathComponent, privacy: .public) were not counted: the registry would not read: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.value
            guard let resolved else { return }
            let wanted = (only.map { $0.intersection(resolved.listed) } ?? resolved.listed)
                .sorted()
            var swept: [String: OpLogProvenance] = [:]
            var stamps: [String: Int] = [:]
            for docId in wanted {
                if Task.isCancelled { return }
                // Open documents answer for themselves: skipped, never read.
                let proceed: Bool? = {
                    guard let self else { return nil }
                    guard self.document(forDocId: docId) == nil else { return false }
                    stamps[docId] = self.closedProvenanceStamps[docId] ?? 0
                    return true
                }()
                guard let proceed else { return }
                guard proceed else { continue }
                let trust = resolved.trust
                do {
                    swept[docId] = try await Task.detached(priority: .utility) {
                        try OpLogStore.provenance(
                            forDocId: docId, in: projectURL, trust: trust, state: state)
                    }.value
                } catch {
                    // RULING-54: never a short answer. The entry this map
                    // already holds for it stands, and the log names it.
                    closedHeldLinesLog.error(
                        "held lines in closed document \(docId, privacy: .public) were not re-counted: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let self else { return }
            self.landClosedPass(
                swept, stamps: stamps, listed: resolved.listed,
                epoch: started.epoch)
        }
    }

    /// Land one pass's answers, on the main actor.
    ///
    /// Nothing lands from a pass whose table was forgotten while it ran (the
    /// pass `invalidateTrust` queued behind it is the one that counts); a
    /// document that opened, or whose entry a close rewrote, since the pass
    /// read it keeps the fresher answer.
    private func landClosedPass(
        _ swept: [String: OpLogProvenance], stamps: [String: Int],
        listed: Set<String>, epoch: Int
    ) {
        guard epoch == closedTrustEpoch else { return }
        let before = closedStrangerHolding()
        for (docId, provenance) in swept
        where document(forDocId: docId) == nil
            && (closedProvenanceStamps[docId] ?? 0) == stamps[docId] {
            closedProvenance[docId] = provenance
        }
        for docId in closedProvenance.keys where !listed.contains(docId) {
            forgetClosedProvenance(ofDocId: docId)
        }
        closedPassesLandedForTesting += 1
        announceIfClosedStrangersMoved(since: before)
    }

    /// **What the closed half holds for strangers**: per holder, the held op
    /// lines and the streams they were held in — the two things the admission
    /// sheet's queue is derived from.
    private func closedStrangerHolding() -> ClosedStrangerHolding {
        var counts: [String: Int] = [:]
        var streams: [String: Set<String>] = [:]
        for (docId, provenance) in closedProvenance where document(forDocId: docId) == nil {
            for (holder, count) in provenance.pendingStrangersByDevice where count > 0 {
                counts[holder, default: 0] += count
            }
            for (holder, slugs) in provenance.pendingStreamsByDevice
            where provenance.pendingStrangersByDevice[holder] != nil {
                streams[holder, default: []].formUnion(slugs)
            }
        }
        return ClosedStrangerHolding(counts: counts, streams: streams)
    }

    private func announceIfClosedStrangersMoved(since before: ClosedStrangerHolding) {
        guard closedStrangerHolding() != before else { return }
        MaughamEvent.postAdmissionRequested(projectURL: projectURL)
    }

    // MARK: - Which documents

    /// Every manuscript document and every statement the manifest lists — the
    /// streams a closed load could hold a line in. `__project__` is not one:
    /// no open document counts it either.
    nonisolated static func sweptDocIds(in manifest: ProjectManifest) -> Set<String> {
        var ids = Set(TreeWalk.collect(in: manifest.structure) { $0.type == .document }
            .map(\.id))
        ids.formUnion(manifest.statements.map(\.id))
        return ids
    }

    /// The same, from the manifest on disk; nil where it will not read.
    nonisolated static func sweptDocIds(inManifestAt projectURL: URL) -> Set<String>? {
        let url = projectURL.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: url),  // adr-0018-ok: project manifest JSON read, not manuscript
              let manifest = try? ProjectManifest.makeDecoder()
                .decode(ProjectManifest.self, from: data)
        else { return nil }
        return sweptDocIds(in: manifest)
    }
}

/// The closed half's stranger holdings, compared before and after a pass.
struct ClosedStrangerHolding: Equatable {
    var counts: [String: Int]
    var streams: [String: Set<String>]
}
