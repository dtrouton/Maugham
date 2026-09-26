// Maugham/Views/AdmissionQueue.swift
import Foundation

/// **Which stranger the admission sheet is drawing, and which comes next**
/// (signed op log P2b, spec §4.1; P3b smoke find F4).
///
/// The window's queue as a VALUE, so every interleaving of an answer, a
/// re-derivation and a sheet closing is decidable with no window at all
/// (tripwire 33). `AdmissionModifier` holds one of these and does nothing with
/// the queue but call it.
///
/// **Find F4 was an interleaving.** Admitting writes the record and then
/// resumes, and between the two the book announces the settlement and the
/// window re-derives the queue — which, correctly, no longer holds the device
/// just admitted, so it takes that sheet down, and the close puts the NEXT
/// stranger up. Then the admission resumed and set the sheet to nil
/// unconditionally: it took down the second stranger's sheet, and because
/// that request was still in the queue when its sheet closed, the close read
/// as Escape — *Not now* — and the second stranger was dismissed until the
/// book was opened again. Every verb here now acts on the request it NAMES,
/// never on whatever happens to be up.
struct AdmissionQueue: Equatable {
    /// The strangers still to be asked about, head first.
    private(set) var queue: [AdmissionRequest] = []
    /// The one the sheet is drawing. Held apart from the queue's head on
    /// purpose: a `sheet(item:)` whose item changes from one request straight
    /// to another is asking SwiftUI to swap a presented sheet's identity in a
    /// single pass, and the second sheet is the one that does not appear. So
    /// this goes to nil, the dismissal completes, and `sheetClosed` puts the
    /// next one up — the sequential-sheet shape, deliberately.
    var presented: AdmissionRequest?
    /// What `presented` last held, so `sheetClosed` can tell an ANSWERED sheet
    /// from one the writer closed with Escape.
    private(set) var shown: AdmissionRequest?
    /// Fingerprints the writer said *Not now* to in this window. Spec §4.1:
    /// until the next open — or until the writer asks, which `forgetDismissals` is.
    private(set) var dismissed: Set<String> = []
    /// **Every request still queued was derived BEFORE an admission this
    /// window just made** (F1/F4 review, Important 1).
    ///
    /// A registry change can change what the others should be asked: two new
    /// Macs both called "MacBook Air" each propose that name, and once the
    /// first is admitted under it the second's proposal is a MERGE. The
    /// settlement's re-derivation says so (`proposedLabel` empty,
    /// `sharesItsNameWith` set) — but it lands after the first sheet closes,
    /// and a close that put the next request up from the old queue drew the
    /// merge-valued field the fresh request no longer proposes. So nothing
    /// goes up from a queue an admission has overtaken; the next `rederived`
    /// clears this and puts the head up from the fresh answer.
    private(set) var awaitingSettlement = false
    /// A close with no report behind it has now been seen by one derivation
    /// (review Minor 3). The second derivation that still sees it gives up on
    /// the report and treats the sheet as closed.
    private var unreportedCloseSeen = false

    /// **Whether a sheet is closing** — taken down (by an answer, by a
    /// re-derivation, or by Escape) with its `sheetClosed` still to come.
    ///
    /// Nothing is put up while one is: SwiftUI reports the close of the sheet
    /// that WAS up, and if the next stranger were already up by then the close
    /// would be read as the writer dismissing THEM — F4's second route to the
    /// same silence.
    var isClosing: Bool { presented == nil && shown != nil }

    /// The writer pressed *Admit…* somewhere: they are asking, rather than the
    /// book telling, so everything they put off is askable again.
    ///
    /// And a close that never reported is forgotten too. A press made at human
    /// speed from another surface comes long after any real close, so a
    /// `shown` with nothing up can only be a close SwiftUI never delivered —
    /// which would otherwise keep the queue from ever putting a sheet up again.
    mutating func forgetDismissals() {
        dismissed = []
        if presented == nil { shown = nil }
    }

    /// **A fresh derivation of who is waiting.** Anybody put off stays put off;
    /// a sheet whose subject is no longer waiting comes down (the review's
    /// Minor 1: a second window's admission must not leave this one's sheet up,
    /// where pressing Admit would RELABEL a settled person); and if nothing is
    /// up, the head goes up.
    mutating func rederived(_ requests: [AdmissionRequest]) {
        queue = requests.filter { !dismissed.contains($0.fingerprint) }
        awaitingSettlement = false
        // **A close SwiftUI never reported** (review Minor 3) — `onDismiss`
        // for a presentation it never started. Two derivations in a row that
        // find a sheet closing with no report is not a dismissal animation (a
        // derivation is a registry read, far slower than one); it is a report
        // that is not coming, and waiting for it would block every later sheet
        // until the writer pressed Admit… or reopened the book. No timer: the
        // book's own next announcement is the clock.
        if isClosing {
            if unreportedCloseSeen {
                shown = nil
                unreportedCloseSeen = false
            } else {
                unreportedCloseSeen = true
            }
        } else {
            unreportedCloseSeen = false
        }
        if let shown, !queue.contains(where: { $0.fingerprint == shown.fingerprint }),
           presented?.fingerprint == shown.fingerprint {
            presented = nil
        }
        // The same stranger, freshly described (F2's *what is waiting* moves as
        // their lines arrive): the sheet up keeps its identity and shows the
        // newer words.
        if let up = presented,
           let fresh = queue.first(where: { $0.fingerprint == up.fingerprint }),
           fresh != up {
            presented = fresh
            shown = fresh
        }
        presentHeadIfIdle()
    }

    /// **The same requests, described again** (P3c plan 2 Task 8, F10's late
    /// capture). A capture that syncs in while a sheet is up moves what the
    /// sheet should say (*1 capture in the Inbox*) without moving WHO is
    /// waiting, so nothing but each request's description changes here: not
    /// the order, not a dismissal, not `awaitingSettlement`, not whether a
    /// sheet is up — none of which a description may decide. The sheet up
    /// keeps its identity and shows the newer words, as `rederived`'s same-
    /// stranger arm does.
    mutating func redescribed(_ describe: (AdmissionRequest) -> AdmissionWaiting?) {
        queue = queue.map { request in
            var request = request
            request.described = describe(request)
            return request
        }
        if let up = presented,
           let fresh = queue.first(where: { $0.fingerprint == up.fingerprint }),
           fresh != up {
            presented = fresh
            shown = fresh
        }
    }

    /// **This request was admitted.** Off the queue, and its sheet down — ITS
    /// sheet, and only if it is still the one up (F4).
    ///
    /// Where the queue still held it, no re-derivation has seen this admission
    /// yet, so every other request in it is from before — and nothing more
    /// goes up until one has (`awaitingSettlement`).
    mutating func admitted(_ fingerprint: String) {
        if queue.contains(where: { $0.fingerprint == fingerprint }) {
            awaitingSettlement = true
        }
        queue.removeAll { $0.fingerprint == fingerprint }
        takeDown(fingerprint)
    }

    /// **This request was put off.** Remembered for the window, off the queue,
    /// and its sheet down. The next stranger goes up from `sheetClosed`, once
    /// this dismissal has finished — never the one just declined.
    mutating func notNow(_ fingerprint: String) {
        dismissed.insert(fingerprint)
        queue.removeAll { $0.fingerprint == fingerprint }
        takeDown(fingerprint)
    }

    /// **A sheet has closed; put the next stranger up, if there is one.**
    ///
    /// Escape means *Not now*, and this is where that is decided: a request
    /// still in the queue when its sheet closed was never answered, because
    /// both answers remove it. Treating a closed sheet as *ask me again in a
    /// moment* would put the same dialog straight back up over the writer's
    /// draft.
    ///
    /// Answers whether the close was read as a dismissal, for the caller's
    /// refusal bookkeeping and for the test that pins F4.
    @discardableResult
    mutating func sheetClosed() -> Bool {
        var wasDismissal = false
        if let finished = shown,
           queue.contains(where: { $0.fingerprint == finished.fingerprint }) {
            dismissed.insert(finished.fingerprint)
            queue.removeAll { $0.fingerprint == finished.fingerprint }
            wasDismissal = true
        }
        unreportedCloseSeen = false
        guard !awaitingSettlement else {
            // Closed, and nothing up until the settlement re-derives.
            shown = nil
            presented = nil
            return wasDismissal
        }
        shown = queue.first
        presented = shown
        return wasDismissal
    }

    private mutating func takeDown(_ fingerprint: String) {
        guard presented?.fingerprint == fingerprint else { return }
        presented = nil
    }

    private mutating func presentHeadIfIdle() {
        guard presented == nil, !isClosing, !awaitingSettlement,
              let head = queue.first else { return }
        shown = head
        presented = head
    }
}
