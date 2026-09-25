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
/// fresh cache on every reload, so a promotion made on the Mac shows on the
/// next pull, the next foreground, or the next time a note is opened.
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
/// **Hide, don't disable.** A refused verb is not drawn. And because a posture
/// can change between drawing a verb and pressing it — the Mac narrowed her
/// while the note sat open — each perform re-asks through `settled(…)` before
/// it writes, and a refusal is SAID (`refusal(_:under:)`) rather than
/// swallowed.
@MainActor
final class PhonePosture {

    /// Answers a settled posture for one document. Production is
    /// `PhonePosture.settled(forDocId:in:)`; a test injects its own store.
    typealias Resolve = @MainActor (_ docId: String, _ projectURL: URL) async -> Posture

    private struct Key: Hashable {
        let projectURL: URL
        let docId: String
    }

    private var answers: [Key: Posture] = [:]
    private let resolve: Resolve

    init(resolve: @escaping Resolve = { docId, projectURL in
        await PhonePosture.settled(
            forDocId: docId, in: projectURL, using: OpLogStore(projectURL: projectURL))
    }) {
        self.resolve = resolve
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
        let answer = await resolve(docId, projectURL)
        answers[key] = answer
        return answer
    }

    /// **Re-ask before writing.** Never the cached answer: a perform acts on
    /// what the door says now, and the cache is brought up to date with it.
    func askAgain(forDocId docId: String, in projectURL: URL) async -> Posture {
        let answer = await resolve(docId, projectURL)
        answers[Key(projectURL: projectURL, docId: docId)] = answer
        return answer
    }

    /// The door's settled answer: the verified table resolved off the main
    /// actor (`prepareTrust`'s detached hop), then the permit asked on it —
    /// `PostureDoor`, never a `Posture` built here.
    static func settled(
        forDocId docId: String, in projectURL: URL, using store: OpLogStore
    ) async -> Posture {
        await store.prepareTrust()
        return PostureDoor.posture(forDocId: docId, in: projectURL, using: store)
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
        case nil:
            why = "What you may do in this book is still being read"
        }
        return "\(why), so nothing was written."
    }
}
