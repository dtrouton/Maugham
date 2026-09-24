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
/// **Not now dismisses until the next open** (spec §4.1). `AdmissionQueue.dismissed` is window
/// `@State` and nothing persists it: closing the window and opening it again is
/// exactly the next open. The writer's own press of History's *Admit…* arrives
/// `forced` and clears it, because that is them asking rather than the book
/// telling.
struct AdmissionModifier: ViewModifier {
    let projectURL: URL
    let projectTitle: String
    let documentStore: DocumentStore?
    /// The open project, for the sheet's piece picker alone (P3b Task 4).
    /// Optional because a window whose load has not finished has none, and the
    /// sheet's *author of some pieces* arm then offers no pieces — which is the
    /// same real state as a book that has none.
    let projectStore: ProjectStore?
    @Binding var window: NSWindow?

    /// Who is waiting, who is up, and who was put off — every decision about
    /// ORDER is the value's (`AdmissionQueue`, pinned windowlessly; smoke find
    /// F4), and this modifier only calls it.
    @State private var admissions = AdmissionQueue()
    /// The refusal from the last attempt on the head request, if it refused.
    @State private var refusal: String?
    @State private var isAdmitting: Bool = false

    func body(content: Content) -> some View {
        content
            .sheet(item: presentedBinding, onDismiss: advance) { request in
                AdmissionSheet(
                    request: request,
                    projectTitle: projectTitle,
                    refusal: refusal,
                    isAdmitting: isAdmitting,
                    pieces: PermitControl.pieces(
                        in: projectStore?.manifest.structure ?? []),
                    checkTheBook: { await checkTheBook() },
                    onAdmit: { typed, permit in
                        admit(request, typedLabel: typed, permit: permit)
                    },
                    onNotNow: { notNow(request) })
            }
            // **What "the next open" actually means** (the review's Minor 2).
            // Spec §4.1 says *Not now* dismisses until the next open, and
            // relying on this modifier's `@State` being fresh does not deliver
            // that: SwiftUI retains a closed `WindowGroup` scene's view graph
            // (which is why `ProjectWindow.onDisappear` scorches its own heavy
            // state by hand), and a modifier's `@State` is outside that sweep —
            // so a reopened window could carry a dismissal from a session the
            // writer has already forgotten. A project open mints a NEW
            // `DocumentStore`, so its identity is the honest key, and the reset
            // rides on it rather than on a comment asking to be believed.
            .onChange(of: documentStore.map(ObjectIdentifier.init)) { _, _ in
                admissions = AdmissionQueue()
                refusal = nil
            }
            .task(id: projectURL) { await recompute(forced: false, cause: .open) }
            .onProjectEvent(.maughamAdmissionRequested, url: projectURL, window: window) { note in
                let forced = note.userInfo?[MaughamEvent.admissionForcedKey] as? Bool ?? false
                Task {
                    await recompute(
                        forced: forced, cause: forced ? .writersPress : .announcement)
                }
            }
            .onProjectEvent(.maughamAdmissionSettled, url: projectURL, window: window) { _ in
                // A second window on this book let somebody in, or the open
                // did. Whoever it was is no longer a stranger, so the queue is
                // re-derived rather than left holding a sheet about them.
                Task { await recompute(forced: false, cause: .settle) }
            }
    }

    /// SwiftUI writes nil here when the writer closes the sheet with Escape;
    /// nothing else is ever written through it.
    private var presentedBinding: Binding<AdmissionRequest?> {
        Binding(
            get: { admissions.presented },
            set: { admissions.presented = $0 })
    }

    /// One sheet has closed; put the next stranger up, if there is one. Escape
    /// means *Not now*, and `AdmissionQueue.sheetClosed` is where that is
    /// decided.
    private func advance() {
        admissions.sheetClosed()
        refusal = nil
    }

    // MARK: - Who is waiting

    /// Re-derive the queue from everything this window can see holding lines,
    /// the registry as it stands, and this device's label memory.
    ///
    /// **It admits before it asks** (find 4, 2026-09-17). Decision B2 is once
    /// per device, and a device this Mac has already named is let in here
    /// exactly as it is let in at a project open — the memory was being read
    /// for a LABEL and the sheet put up anyway, which asked the writer the one
    /// question they had already answered. The order lives in
    /// `AdmissionDecision.refreshedRequests` rather than in this method, so it
    /// is pinned with no window (`AdmissionDecisionTests`).
    ///
    /// The registry read is disk work and a signature verification per record,
    /// so it goes to a detached task (`TrustResolution`'s own rule). The
    /// pending counts do NOT: they are already in hand, stamped on each open
    /// `Document` by its load and re-stamped by every external-change merge,
    /// and counted by the inbox on its own refresh.
    ///
    /// **The open documents AND the capture stream** — one computation,
    /// `DocumentStore.heldLinesByDevice()`, the same union People & Devices
    /// lists its pending rows from. Built from the open documents alone this
    /// asked about nobody in the ordinary paired-release case: a phone used
    /// for capture writes into `inbox.<slug>.jsonl` and into no chapter, so
    /// the queue came back empty and all three *Admit…* controls — the Inbox
    /// banner's, History's, and Project Settings' — did nothing at all, with
    /// the captures held and no recourse from any surface.
    ///
    /// **Open documents only, on the manuscript half.** A closed document's
    /// held lines would cost a full read of its log to discover, and this runs
    /// at every project open — so a book whose stranger has written only in
    /// chapters nobody has opened yet is asked about when one of them is
    /// opened, not before. The load itself is what announces
    /// (`DocumentStore.register`), so no chapter can be opened without the
    /// question being put. **And a stranger's device RECORD puts it too**
    /// (P3b smoke find F10): the registry settle that brings one runs this, and
    /// the refresh's pre-check finds the record by a folder listing, so a
    /// collaborator who has written only in closed chapters — or not yet at
    /// all — is asked about when their machine arrives.
    @MainActor
    private func recompute(forced: Bool, cause: AdmissionDecision.RefreshCause) async {
        if forced { admissions.forgetDismissals() }
        guard let documentStore else { return }
        // A forced recompute is the writer pressing Admit…, and the press they
        // made was on a count the inbox last read. Re-read the stream first so
        // the queue is measured against what is there now rather than what was
        // there when the pane drew — the same order Project Settings uses
        // before it asks (`loadPeopleAndDevices`). The unforced call is the
        // book reporting a load it has just done, and re-reading every manifest
        // on every document open would be disk work for an answer already in
        // hand.
        if forced { await documentStore.inboxStore.refresh() }
        let url = projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let me = identities.author.fingerprint
        let requests = await AdmissionDecision.refreshedRequests(
            cause: cause,
            heldLines: { documentStore.heldLinesByDevice() },
            // The streams those held lines were in (P3b Task 4), read from the
            // same union in the same moment: a key that is not a person's must
            // not be offered as one, and only the file it wrote in says which
            // of a device's four writers it is.
            heldStreams: { documentStore.heldLines().streams },
            // **A stranger's device record raises the question on its own**
            // (P3b smoke find F10). A listing of two registry folders, off the
            // main actor and never a signature check — it only says whether the
            // verified read below is worth paying for; `requests` decides.
            arrivedDevices: {
                await Task.detached(priority: .userInitiated) {
                    AdmissionDecision.devicesWithNoPersonRecord(
                        in: url, excluding: me)
                }.value
            },
            // The settle that brought the record refreshed the inbox on a task
            // nobody awaits; a device asked about for its record alone is
            // measured against the captures actually there.
            recountCaptures: { await documentStore.inboxStore.refresh() },
            thisDevice: me,
            memory: Document.loadAdmissionMemory.remembered,
            // Decision B2 does not stop at the open (find 4). The same verb
            // `DocumentStore.open` calls, off the main actor like the resolve
            // beside it, and its own `invalidateTrust` + re-read is what lets
            // the held span into the draft in front of the writer — so a device
            // this Mac has already named never reaches the sheet a second time.
            admitRemembered: { _ = await documentStore.admitRemembered() },
            resolve: {
                await Task.detached(priority: .userInitiated) {
                    () -> (registry: Registry, myRoot: String?)? in
                    // A registry that will not read costs the writer the sheet,
                    // never the window: they can still write, and History still
                    // counts what is held. Named in the log so it is not a
                    // silence.
                    do {
                        let verified = try TrustResolution.resolveVerified(
                            projectURL: url, identities: identities, cache: cache)
                        // The sheet is a ROOT's question (Ruling AA): this
                        // Mac's own root record, never the root an admitted
                        // Mac judges by.
                        return (verified.registry, AdmissionDecision.askingRoot(
                            in: verified.registry, thisDevice: me))
                    } catch {
                        admissionLog.error(
                            "admission could not read \(url.lastPathComponent, privacy: .public)'s registry: \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }.value
            })
        // Nothing came back at all: the registry would not read, so the queue
        // this window already has stands. An EMPTY queue is the other answer —
        // nothing is held anywhere this window can see any more, including
        // whoever it is currently asking about, which is how an admission made
        // in a SECOND window reaches this one's sheet.
        guard let requests else { return }
        admissions.rederived(described(requests, in: documentStore))
    }

    /// **Each request with what it has waiting, and where** (P3b smoke find
    /// F2): the open documents' own descriptions of their held lines, joined to
    /// the binder's titles. Read from the loads, so this costs no disk.
    @MainActor
    private func described(
        _ requests: [AdmissionRequest], in documentStore: DocumentStore
    ) -> [AdmissionRequest] {
        guard !requests.isEmpty else { return requests }
        let held = documentStore.heldLines()
        let order = PermitControl.pieces(in: projectStore?.manifest.structure ?? [])
            .map { (id: $0.id, title: $0.title) }
        return requests.map { request in
            var request = request
            request.described = AdmissionWaiting.describe(
                holder: request.fingerprint, waiting: held.waiting,
                captures: held.captures, order: order)
            return request
        }
    }

    // MARK: - Answering

    private func notNow(_ request: AdmissionRequest) {
        // Down, not straight on to the next: `advance` puts that one up once
        // this dismissal has finished — and never the one just declined.
        admissions.notNow(request.fingerprint)
    }

    /// **What a narrowing would cost this book**, for the sheet's sentence.
    ///
    /// Both halves come off the folder rather than off this Mac's own enclave:
    /// whether anybody here has been narrowed already (`TrustTable
    /// .hasNarrowingPermits`) and whether any stream in the book answers to no
    /// key (`OpLogStore.unattributablePositions`, the same sweep the act
    /// itself takes its photograph with). Detached, for the resolve's own
    /// reason — a signature check per record and a walk of every op-log file.
    ///
    /// Nil is *the book could not be read*, which the sheet reports as nothing
    /// at all: the act runs the same sweep and refuses in the error's own
    /// words, so a guess here would only be a second, quieter account of a
    /// failure the writer is about to be told about properly.
    ///
    /// **One body, two callers** (P3b Task 5). People & Devices asks the same
    /// question for its unsigned rows and for the same first-narrowing
    /// sentence, so the read is `DocumentStore.readUnsigned` and both surfaces
    /// go through it — two bodies would let the sheet and the pane say
    /// different things about one folder on one afternoon.
    @MainActor
    private func checkTheBook() async -> PermitControl.BookNarrowing? {
        let url = projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let reading = await Task.detached(priority: .userInitiated) {
            DocumentStore.readUnsigned(
                in: url, identities: identities, cache: cache)
        }.value
        if let refusal = reading.refusal {
            admissionLog.error(
                "admission could not read \(url.lastPathComponent, privacy: .public) to say what a narrowing would cost: \(refusal, privacy: .public)")
            return nil
        }
        return PermitControl.BookNarrowing(
            alreadyNarrowed: reading.alreadyNarrowed,
            holdsAnUnsignedStream: reading.holdsAnUnsignedStream)
    }

    /// Write the admission, and let the held ops in.
    ///
    /// The typed label is put through `AdmissionDecision.outcome` rather than
    /// used raw, so a label matching one this book already has merges under
    /// that label's own spelling (spec §4.1) and an empty field writes nothing.
    /// A refusal keeps the sheet up carrying its own sentence — the one thing a
    /// dialog must never do is close on a write that did not happen.
    ///
    /// **`permit` is the rung the writer chose** (P3b Task 4). The store verb
    /// takes it from here and decides everything else about it — whether this
    /// act installs a permit at all, whether it owes the book's unsigned
    /// photograph, whether it gates older builds out. This modifier knows about
    /// none of those.
    private func admit(
        _ request: AdmissionRequest, typedLabel: String, permit: Permit
    ) {
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
                    ownName: request.recordedOwnName, permit: permit)
                // THIS request's sheet, never whatever is up by now (F4): the
                // settlement this write announced may already have re-derived
                // the queue and put the next stranger up.
                admissions.admitted(request.fingerprint)
            } catch {
                refusal = AdmissionDecision.refusal(error)
                admissionLog.error(
                    "admitting \(DeviceCode.short(request.fingerprint), privacy: .public) in \(projectURL.lastPathComponent, privacy: .public) refused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
