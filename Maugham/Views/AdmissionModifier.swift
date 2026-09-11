// Maugham/Views/AdmissionModifier.swift
import SwiftUI
import AppKit
import MaughamCore
import os

private let admissionLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "Admission")

/// **The window's half of admission** (signed op log P2b, spec §4.1).
///
/// Extracted as a `ViewModifier` for `ProjectWindow.body`'s established reason —
/// the type-check ceiling — and because everything here is one subject: which
/// stranger is being asked about, what the writer answered, and what happened
/// when the answer was written.
///
/// **One sheet per stranger, sequentially.** `pending` is a queue, the sheet
/// draws its head, and answering pops it. Two phones syncing into one book on
/// the same morning is two sheets one after another and never a list inside a
/// dialog — the writer is deciding about a device, and a device is a single
/// yes-or-no about a name.
///
/// **Not now dismisses until the next open** (spec §4.1). `dismissed` is window
/// `@State` and nothing persists it: closing the window and opening it again is
/// exactly the next open. The writer's own press of History's *Admit…* arrives
/// `forced` and clears it, because that is them asking rather than the book
/// telling.
struct AdmissionModifier: ViewModifier {
    let projectURL: URL
    let projectTitle: String
    let documentStore: DocumentStore?
    @Binding var window: NSWindow?

    /// The strangers still to be asked about, head first.
    @State private var queue: [AdmissionRequest] = []
    /// The one the sheet is drawing. Held apart from the queue's head on
    /// purpose: a `sheet(item:)` whose item changes from one request straight
    /// to another is asking SwiftUI to swap a presented sheet's identity in a
    /// single pass, and the second sheet is the one that does not appear. So
    /// this goes to nil, the dismissal completes, and `advance` puts the next
    /// one up from `onDismiss` — the sequential-sheet shape, deliberately.
    @State private var presented: AdmissionRequest?
    /// What `presented` last held, so `onDismiss` can tell an ANSWERED sheet
    /// from one the writer closed with Escape.
    @State private var shown: AdmissionRequest?
    /// Fingerprints the writer said *Not now* to in this window.
    @State private var dismissed: Set<String> = []
    /// The refusal from the last attempt on the head request, if it refused.
    @State private var refusal: String?
    @State private var isAdmitting: Bool = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $presented, onDismiss: advance) { request in
                AdmissionSheet(
                    request: request,
                    projectTitle: projectTitle,
                    refusal: refusal,
                    isAdmitting: isAdmitting,
                    onAdmit: { typed in admit(request, typedLabel: typed) },
                    onNotNow: { notNow(request) })
            }
            .task(id: projectURL) { await recompute(forced: false) }
            .onProjectEvent(.maughamAdmissionRequested, url: projectURL, window: window) { note in
                let forced = note.userInfo?[MaughamEvent.admissionForcedKey] as? Bool ?? false
                Task { await recompute(forced: forced) }
            }
            .onProjectEvent(.maughamAdmissionSettled, url: projectURL, window: window) { _ in
                // A second window on this book let somebody in, or the open
                // did. Whoever it was is no longer a stranger, so the queue is
                // re-derived rather than left holding a sheet about them.
                Task { await recompute(forced: false) }
            }
    }

    /// One sheet has closed; put the next stranger up, if there is one.
    ///
    /// **Escape means *Not now***, and this is where that is decided: a request
    /// still in the queue when its sheet closed was never answered, because
    /// both answers remove it. Treating a closed sheet as *ask me again in a
    /// moment* would put the same dialog straight back up over the writer's
    /// draft, which is the one behaviour a dismissal must not have.
    private func advance() {
        if let finished = shown,
           queue.contains(where: { $0.fingerprint == finished.fingerprint }) {
            dismissed.insert(finished.fingerprint)
            queue.removeAll { $0.fingerprint == finished.fingerprint }
        }
        refusal = nil
        shown = queue.first
        presented = shown
    }

    /// Draw the head, unless a sheet is already up — in which case `advance`
    /// will reach it when that one closes.
    private func presentHeadIfIdle() {
        guard presented == nil, let head = queue.first else { return }
        shown = head
        presented = head
    }

    // MARK: - Who is waiting

    /// Re-derive the queue from what the open documents' loads found, the
    /// registry as it stands, and this device's label memory.
    ///
    /// The registry read is disk work and a signature verification per record,
    /// so it goes to a detached task (`TrustResolution`'s own rule). The
    /// pending counts do NOT: they are already in hand, stamped on each open
    /// `Document` by its load and re-stamped by every external-change merge.
    ///
    /// **Open documents only.** A closed document's held lines would cost a
    /// full read of its log to discover, and this runs at every project open —
    /// so a book whose stranger has written only in chapters nobody has opened
    /// yet is asked about when one of them is opened, not before. The load
    /// itself is what announces (`DocumentStore.register`), so no chapter can
    /// be opened without the question being put.
    @MainActor
    private func recompute(forced: Bool) async {
        if forced { dismissed = [] }
        guard let documentStore else { return }
        let pending = documentStore.allOpenDocuments()
            .compactMap(\.provenance)
            .reduce(into: [String: Int]()) { total, provenance in
                for (device, count) in provenance.pendingByDevice {
                    total[device, default: 0] += count
                }
            }
        guard !pending.isEmpty else {
            queue = []
            return
        }

        let url = projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let remembered = Document.loadAdmissionMemory.remembered
        let resolved = await Task.detached(priority: .userInitiated) {
            () -> (registry: Registry, myRoot: String?)? in
            // A registry that will not read costs the writer the sheet, never
            // the window: they can still write, and History still counts what
            // is held. Named in the log so it is not a silence.
            do {
                let verified = try TrustResolution.resolveVerified(
                    projectURL: url, identities: identities, cache: cache)
                return (verified.registry, verified.table.myRoot)
            } catch {
                admissionLog.error(
                    "admission could not read \(url.lastPathComponent, privacy: .public)'s registry: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
        guard let resolved else { return }

        let requests = AdmissionDecision.requests(
            pending: pending, registry: resolved.registry,
            memory: remembered, myRoot: resolved.myRoot)
        queue = requests.filter { !dismissed.contains($0.fingerprint) }
        presentHeadIfIdle()
    }

    // MARK: - Answering

    private func notNow(_ request: AdmissionRequest) {
        dismissed.insert(request.fingerprint)
        queue.removeAll { $0.fingerprint == request.fingerprint }
        // Down, not straight on to the next: `advance` puts that one up once
        // this dismissal has finished.
        presented = nil
    }

    /// Write the admission, and let the held ops in.
    ///
    /// The typed label is put through `AdmissionDecision.outcome` rather than
    /// used raw, so a label matching one this book already has merges under
    /// that label's own spelling (spec §4.1) and an empty field writes nothing.
    /// A refusal keeps the sheet up carrying its own sentence — the one thing a
    /// dialog must never do is close on a write that did not happen.
    private func admit(_ request: AdmissionRequest, typedLabel: String) {
        guard let documentStore, !isAdmitting else { return }
        let label: String
        switch AdmissionDecision.outcome(for: request, typedLabel: typedLabel) {
        case .notNow: return
        case .admit(let chosen), .mergeUnder(let chosen): label = chosen
        }

        isAdmitting = true
        refusal = nil
        Task { @MainActor in
            defer { isAdmitting = false }
            do {
                _ = try await documentStore.admit(
                    device: request.fingerprint, label: label,
                    ownName: request.recordedOwnName)
                queue.removeAll { $0.fingerprint == request.fingerprint }
                presented = nil
            } catch {
                refusal = AdmissionDecision.refusal(error)
                admissionLog.error(
                    "admitting \(DeviceCode.short(request.fingerprint), privacy: .public) in \(projectURL.lastPathComponent, privacy: .public) refused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
