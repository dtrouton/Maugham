import Foundation
import MaughamCore

/// **What this phone may OFFER for one piece** (signed op log P3c plan 2,
/// Task 6; spec §8, §12) — the phone's thin per-piece cache over MaughamCore's
/// `PostureDoor`, the one door both surfaces build a `Posture` through
/// (tripwires 19, 46, 51).
///
/// The phone decides nothing about a permit. It asks the door per `(project,
/// docId)`, with the table warmed OFF the main actor first
/// (`OpLogStore.prepareTrust`, the Mac door's own shape), and remembers the
/// answer for as long as the load that asked it — `AnnotationsStore` makes a
/// fresh cache on every reload and `refresh()`es it on every foreground, so a
/// promotion made on the Mac shows on the next pull or foreground. Each
/// project gets ONE `OpLogStore` for the load, so its verified table is
/// resolved once and reused until the registry's signature moves.
///
/// **Which verb needs what** is `offers(_:under:)`, a pure function over a
/// `Posture`, so every decision the detail view draws is pinned without a
/// window (tripwire 33):
///
/// - Accept / Mark answered, Reject… / Reply…, and Reopen & Revert move the
///   words (or undo a move of them), so they follow `.acceptOrReject`.
/// - Archive and Reopen settle somebody's note, so they follow `.dispose`.
///   The phone offers Reopen only for a rejected, archived or stetted note —
///   it has no withdraw and lists no withdrawn note — so its Reopen follows
///   `.dispose` alone (controller Ruling A).
/// - **Capture is on every rung.** An inbox row is the reviewer row, which
///   every permit contains, and `Posture` has no capture verb on purpose; the
///   Capture tab never asks this type (`TripwirePhoneGrepTest` keeps it so).
///
/// **A piece somebody else started that nobody has claimed is LOCKED here**
/// (P3c plan 2 fix wave, Ruling W). Accept, Reject and Reopen & Revert write
/// manuscript-text lines (`claudeAccept`/`claudeReject`/`claudeAcceptRevert`),
/// and a book author's manuscript-text line in such a piece claims it and sets
/// its starter's words aside on every Mac (§4.5) — even a Reject that changes
/// nothing. The Mac yields there with *Edit Anyway*; the phone has no *Edit
/// Anyway*, so it asks Core's `PostureDoor.postureYieldingToItsStarter`, which
/// yields wherever the permit carries `unsettledStarter` and leaves only
/// `annotate` — the piece is settled from a Mac.
///
/// **Hide, don't disable.** A refused verb is not drawn. And because a posture
/// can change between drawing a verb and pressing it — the Mac narrowed her
/// while the note sat open — each perform re-asks through `settled(…)` before
/// it writes, and a refusal is SAID (`refusal(_:under:)`) rather than
/// swallowed.
@MainActor
final class PhonePosture {

    /// Makes the one `OpLogStore` a project gets for the life of this load.
    typealias MakeStore = @MainActor (_ projectURL: URL) -> OpLogStore
    /// Resolves a store's verified table off the main actor. Production is
    /// `OpLogStore.prepareTrust`; a test counts it.
    typealias Prepare = @MainActor (_ store: OpLogStore) async -> Void
    /// Asks the door, on a store whose table is warm. Production is
    /// `PostureDoor.postureYieldingToItsStarter(forDocId:in:using:)` (Ruling
    /// W); a test injects answers.
    typealias Ask = @MainActor (_ docId: String, _ projectURL: URL, _ store: OpLogStore) -> Posture

    private struct Key: Hashable {
        let projectURL: URL
        let docId: String
    }

    private var answers: [Key: Posture] = [:]
    /// **ONE store per project for the life of the load** (Task 6 fix round
    /// 1). `OpLogStore`'s resolved table is per INSTANCE, so a store per ask
    /// paid a folder read and a P256 verify per record on every first ask,
    /// every re-ask before a write and every foreground return.
    private var stores: [URL: OpLogStore] = [:]
    /// **One warm-up in flight per project** (P3 plan 3 Task 7). Asks that
    /// arrive while a project's table is being prepared await THAT
    /// preparation rather than each starting one. Whether a preparation costs
    /// anything is the store's to decide: `OpLogStore.prepareTrust` →
    /// `trust()` compares the registry signature against the table in hand
    /// and resolves only when it has MOVED (a revocation or a permit change
    /// writes a record, which moves it) or after `refresh()` invalidated it —
    /// so the phone keeps no signature of its own and scans nothing on the
    /// main actor that the store would scan again.
    private var warming: [URL: Task<OpLogStore, Never>] = [:]
    private let makeStore: MakeStore
    private let prepare: Prepare
    private let ask: Ask

    init(
        makeStore: @escaping MakeStore = { OpLogStore(projectURL: $0) },
        prepare: @escaping Prepare = { await $0.prepareTrust() },
        ask: @escaping Ask = { docId, projectURL, store in
            PostureDoor.postureYieldingToItsStarter(
                forDocId: docId, in: projectURL, using: store)
        }
    ) {
        self.makeStore = makeStore
        self.prepare = prepare
        self.ask = ask
    }

    /// A new, empty cache for one load. Spelled as a factory rather than a
    /// bare initializer call because the Mac's posture census (tripwire 51)
    /// reads any `…Posture(` as a posture being BUILT.
    static func forANewLoad() -> PhonePosture { .init() }

    /// **Not yet answered.** Only the reviewer row is offered, so a view that
    /// draws before the door answers draws no disposition at all: a verb
    /// appearing a moment late is fine, and one appearing that must not is not.
    /// The one spelling of the door's not-yet answer on the phone.
    static let unanswered: Posture = Posture.settling

    /// The posture this load has for `docId`, asking the door once.
    func posture(forDocId docId: String, in projectURL: URL) async -> Posture {
        let key = Key(projectURL: projectURL, docId: docId)
        if let known = answers[key] { return known }
        return await askAgain(forDocId: docId, in: projectURL)
    }

    /// **Re-ask before writing.** Never the cached answer: a perform acts on
    /// what the door says now, and the cache is brought up to date with it.
    /// The TABLE is reused unless the registry's signature moved since it was
    /// prepared, so a revocation that landed since the load is seen, and a
    /// re-ask over an unchanged register verifies nothing.
    func askAgain(forDocId docId: String, in projectURL: URL) async -> Posture {
        let store = await warmStore(for: projectURL)
        let answer = ask(docId, projectURL, store)
        answers[Key(projectURL: projectURL, docId: docId)] = answer
        return answer
    }

    /// **The perform door** (Ruling W): re-ask (`askAgain`), hand the settled
    /// answer to `onAnswer` — before the write, so a write that throws still
    /// leaves the view drawing it — and run `write` only where that answer
    /// offers `verb`. A refusal is returned as
    /// its sentence (`refusal(_:under:)`) and nothing is written. The detail
    /// view's every write passes here, so what a press may write is decided
    /// off the same answer the verbs are drawn from — pinned on real disk
    /// without a window (tripwire 33).
    func perform(
        _ verb: Verb, forDocId docId: String, in projectURL: URL,
        onAnswer: (Posture) -> Void = { _ in },
        write: () async throws -> Void
    ) async rethrows -> (posture: Posture, refusal: String?) {
        let now = await askAgain(forDocId: docId, in: projectURL)
        // Handed over BEFORE the write (P3 plan 3 Task 7): a write that throws
        // must not leave the view drawing the answer it had before the re-ask.
        onAnswer(now)
        guard Self.offers(verb, under: now) else {
            return (now, Self.refusal(verb, under: now))
        }
        try await write()
        return (now, nil)
    }

    /// **Forget what this load knows** — the answers, and every store's
    /// table — so the next ask resolves the register afresh. The foreground
    /// return (C5) calls it: the phone has no file presenter, and a change
    /// that left the signature where it was must still be seen on return.
    func refresh() {
        answers.removeAll()
        // An ask after the refresh must not piggyback on a warm-up that began
        // before it.
        warming.removeAll()
        for store in stores.values { store.invalidateTrust() }
    }

    /// The project's one store, its table prepared under the register as it
    /// stands now.
    private func warmStore(for projectURL: URL) async -> OpLogStore {
        if let inFlight = warming[projectURL] { return await inFlight.value }
        let store: OpLogStore
        if let known = stores[projectURL] {
            store = known
        } else {
            store = makeStore(projectURL)
            stores[projectURL] = store
        }
        let prepare = self.prepare
        let task = Task { @MainActor in
            await prepare(store)
            return store
        }
        warming[projectURL] = task
        let warmed = await task.value
        // Forget it only if it is still ours: a `refresh()` in the meantime
        // may have dropped it and a later ask started another.
        if warming[projectURL] == task { warming[projectURL] = nil }
        return warmed
    }

    /// The door's settled answer: the verified table resolved off the main
    /// actor (`prepareTrust`'s detached hop), then the permit asked on it —
    /// `PostureDoor`, never a `Posture` built here.
    static func settled(
        forDocId docId: String, in projectURL: URL, using store: OpLogStore
    ) async -> Posture {
        await store.prepareTrust()
        return PostureDoor.postureYieldingToItsStarter(
            forDocId: docId, in: projectURL, using: store)
    }

    // MARK: - The verbs (pure)

    /// Every lifecycle verb the phone's detail view can draw. *Mark answered*
    /// and *Reply…* are a query's labels for `accept` and `reject`.
    enum Verb: CaseIterable, Sendable {
        case accept
        case reject
        case archive
        /// Reopen a rejected, archived or stetted note.
        case reopen
        /// Reopen an accepted suggestion and restore the text it replaced.
        case reopenAndRevert
    }

    /// The surface verb each phone verb is asked as. No `default:`, so a verb
    /// added here has to say what it would write.
    nonisolated static func postureVerb(_ verb: Verb) -> Posture.Verb {
        switch verb {
        case .accept, .reject, .reopenAndRevert: return .acceptOrReject
        case .archive, .reopen: return .dispose
        }
    }

    /// **May the detail view draw `verb`?**
    nonisolated static func offers(_ verb: Verb, under posture: Posture) -> Bool {
        posture.allows(postureVerb(verb))
    }

    /// The verbs drawn for an open note, in the order the view draws them.
    nonisolated static func openNoteVerbs(under posture: Posture) -> [Verb] {
        [.accept, .reject, .archive].filter { offers($0, under: posture) }
    }

    /// The reopen drawn for a resolved note of `status`, or nil where none is
    /// — because the status has no reopen, or because the posture refuses it.
    nonisolated static func reopenVerb(
        for status: AnnotationStatus, under posture: Posture
    ) -> Verb? {
        let verb: Verb
        switch status {
        case .rejected, .archived, .stetted: verb = .reopen
        case .accepted: verb = .reopenAndRevert
        case .open: return nil
        }
        return offers(verb, under: posture) ? verb : nil
    }

    /// **Is capture offered?** Always: an inbox row is on every rung, and the
    /// posture is not consulted. Stated as a function of the posture so the
    /// both-directions test can hold it against every one.
    nonisolated static func offersCapture(under posture: Posture) -> Bool { true }

    /// **What the writer is told when a verb she pressed is refused** by the
    /// re-ask — her standing changed on the Mac while the note sat open. It
    /// names why, from the posture's own `reason`, and says nothing was
    /// written.
    nonisolated static func refusal(_ verb: Verb, under posture: Posture) -> String {
        let why: String
        switch posture.reason {
        case .reviewer:
            why = "In this book you leave notes rather than settle them"
        case .notYourPiece:
            why = "This piece isn\u{2019}t one of yours in this book"
        case .waitingToBeClaimed:
            why = "This piece is still waiting for the Mac the book was "
                + "started on to say it\u{2019}s yours"
        case .cannotJudge:
            why = "This book says something about what you may do that this "
                + "version of Maugham doesn\u{2019}t recognise"
        case .yielding(let name):
            why = "This piece is \(name)\u{2019}s to settle"
        case .yieldingToItsStarter(let name):
            // Ruling W: a lock on the phone, which has no *Edit Anyway*.
            return "\(name) started this piece and it isn\u{2019}t settled "
                + "whose it is yet, so nothing was written \u{2014} settle it "
                + "from your Mac."
        case nil:
            why = "What you may do in this book is still being read"
        }
        return "\(why), so nothing was written."
    }
}
