// Maugham/Views/TranslationReveal.swift
import Foundation

/// **A row in the round report as a way back into the manuscript** (translation
/// pipeline P4 Task 5).
///
/// A departure row and a disagreement row each name one paragraph of one
/// edition of one chapter, and the honest answer to a click on either is *show
/// me that paragraph, in that edition* — which is `.maughamEnterTranslationReview`
/// followed by `.maughamNavigateToParagraph`, two events that already exist and
/// already have receivers. This type is what stands between the row and them.
///
/// **Three decisions, and every one of them is here rather than at the poster.**
///
/// - **What the payload is.** The report is one file, the window another, and
///   the three keys have one spelling apiece (`document_id`, `language`,
///   `paragraph_id` — the same names `.maughamRevealTranslation`'s own doc
///   comment declares). `post` and `decode` are the pair, so a rename cannot
///   make one side quietly read nil.
/// - **Whether the chapter has to be selected first** (`plan`). The row knows
///   which chapter it is about; only the window knows which chapter is *open*.
///   So the poster posts, and the window plans.
/// - **The order of the two posts, and the wait between them** (`perform`).
///   Entering review swaps the editor to the translated surface; navigating
///   scrolls it.
///
/// **The order alone is not enough, and the first draft of this file said it
/// was** (fix round 1). `.maughamEnterTranslationReview` only writes
/// `EditorControl.translationLanguage`; the translated buffer is swapped in on
/// the NEXT SwiftUI body pass, when `EditorHost`'s
/// `.onChange(of: control.translationLanguage)` recomputes the derived surface
/// and pushes it through `applyExternalText`. Posted back to back, the navigate
/// is delivered in between: `EditorCoordinator` scrolls the still-SOURCE text
/// and the swap throws that scroll away, so every reveal opens the edition at
/// the top. Hence `ready` — awaited between the two posts, and how production
/// says *not until the surface is actually there*. It defaults to doing
/// nothing, so the ordering stays assertable on its own.
///
/// `perform` takes its post closure rather than reaching for `MaughamEvent`
/// because the ordering is the fact worth pinning, and a test that has to grant
/// key-window status to observe two `.keyWindow` posts pins the ordering last.
/// Production hands it `{ MaughamEvent.post($0, to: .keyWindow, payload: $1) }`.
///
/// **A nil `language` is a reveal of the SOURCE paragraph** (report foundations
/// plan 2, Task 8, ruling R-S11). A publish problem names a paragraph of the
/// manuscript itself, and the window has exactly one path that selects a piece,
/// waits for its document and then scrolls — this one. So the source reveal
/// rides it rather than growing a second wait: the same post, the same plan,
/// the same pending reveal on `activeDocId`, and `perform` simply never enters
/// translation review (there is no edition to enter, and no translated surface
/// to wait for — `waitsForTranslatedSurface`). The name stays: the type's
/// event, census and receiver are all spelled for the translation reveal it
/// was built as, and a source reveal is that reveal with no edition.
struct TranslationReveal: Equatable, Sendable {
    let docId: String
    /// The edition to reveal the paragraph in, or `nil` for the source text.
    let language: String?
    let paragraphId: String
    /// Where in the paragraph the caret lands, in UTF-16 units of its display
    /// text; nil (every reveal before report plan 8a Task 7) is its start. A
    /// figure's Used-in link names a line inside a paragraph of several.
    var offset: Int? = nil

    /// The payload keys — one spelling, shared by `post`, `decode` and the two
    /// posts `perform` makes. `languageKey` and `paragraphIdKey` are also what
    /// `.maughamEnterTranslationReview`'s and `.maughamNavigateToParagraph`'s
    /// existing receivers read, which is why `perform` can reuse them.
    static let docIdKey = "document_id"
    static let languageKey = "language"
    static let paragraphIdKey = "paragraph_id"
    /// Also `.maughamNavigateToParagraph`'s optional offset, which
    /// `EditorCoordinator`'s receiver reads.
    static let offsetKey = MaughamEvent.paragraphOffsetKey

    /// What the window has to do before the reveal can be performed.
    enum Step: Equatable, Sendable {
        /// The chapter is already open — the two posts can go now.
        case now
        /// Some other chapter is open (or none). Select this subject first; the
        /// reveal waits for the document to arrive.
        case afterSelecting(BinderSubject)
    }

    /// `activeDocId` is the window's own answer, sentinel and all: the
    /// no-document sentinel is never a real doc id, so it takes the
    /// `.afterSelecting` arm without a case of its own.
    static func plan(_ reveal: TranslationReveal, activeDocId: String) -> Step {
        reveal.docId == activeDocId ? .now : .afterSelecting(.item(reveal.docId))
    }

    /// `.keyWindow` because this is a command, not a data event: the row was
    /// clicked in one window and it is that window that must move (ADR 0021).
    ///
    /// A source reveal carries no language key at all, rather than a key with
    /// nothing in it.
    static func post(_ reveal: TranslationReveal) {
        MaughamEvent.post(.maughamRevealTranslation, to: .keyWindow, payload: payload(reveal))
    }

    /// The reveal's payload — `post`'s, and a poster that posts through its
    /// own closure (`FigureUseTravel.perform`).
    static func payload(_ reveal: TranslationReveal) -> [String: Any] {
        var payload: [String: Any] = [
            docIdKey: reveal.docId,
            paragraphIdKey: reveal.paragraphId,
        ]
        if let language = reveal.language { payload[languageKey] = language }
        if let offset = reveal.offset { payload[offsetKey] = offset }
        return payload
    }

    /// The document and the paragraph, or nothing: a reveal missing either
    /// names no destination, and a half-built one would move the window
    /// somewhere the writer did not ask to go. The language is optional — its
    /// absence is a source reveal, and a post that names one still decodes to
    /// that edition's reveal.
    static func decode(_ userInfo: [AnyHashable: Any]?) -> TranslationReveal? {
        guard let docId = userInfo?[docIdKey] as? String,
              let paragraphId = userInfo?[paragraphIdKey] as? String
        else { return nil }
        return TranslationReveal(
            docId: docId, language: userInfo?[languageKey] as? String,
            paragraphId: paragraphId, offset: userInfo?[offsetKey] as? Int)
    }

    /// **Whether the window must wait for a translated surface before the
    /// navigate** — the modifier's decision, as a value. Only a reveal into an
    /// edition other than the one already showing waits: a source reveal has
    /// no translated surface to wait for, and waiting for one that never comes
    /// would stall the scroll for the whole poll.
    static func waitsForTranslatedSurface(_ reveal: TranslationReveal,
                                          showing current: String?) -> Bool {
        guard let language = reveal.language else { return false }
        return language != current
    }

    /// **Whether a source reveal must first leave Translation Review** (fix
    /// round 1, m4): the reveal names the SOURCE paragraph, and while an
    /// edition is up the open piece shows that edition instead. Only ever true
    /// for a source reveal; a translated one enters its own edition.
    static func leavesReview(_ reveal: TranslationReveal, showing current: String?) -> Bool {
        reveal.language == nil && current != nil
    }

    /// The two posts, in order: enter review for the language, then — once
    /// `ready` has returned — navigate.
    ///
    /// `ready` is where production waits for the translated surface to actually
    /// reach the text view (see the type's doc comment). It returns whether that
    /// surface arrived or the wait merely ran out of patience, and the navigate
    /// goes either way: a paragraph the coordinator's range provider cannot find
    /// is a no-op there, so refusing to post would turn a slow surface into a
    /// silent one and buy nothing.
    ///
    /// **A cancelled reveal stops here, and the rule lives in `perform` rather
    /// than at the caller** (fix round 2). `ready` opened an awaitable gap
    /// between two posts that used to be adjacent, and a window closing or a
    /// second row being clicked cancels the task sitting in it — but cancelling
    /// only unblocks the wait; control still returns HERE. Without this guard
    /// the first reveal fires a navigate for the paragraph the writer has just
    /// moved on from, racing or landing after the second reveal's own posts,
    /// which is precisely what cancelling was supposed to prevent. The check is
    /// in this function because the gap is this function's, and a caller that
    /// forgot it would fail silently. The enter-review post is NOT undone — it
    /// has already been delivered, and a superseding reveal posts its own a
    /// moment later, so unwinding it would only flicker the surface.
    ///
    /// `@MainActor` because both posts are `.keyWindow` events that drive the
    /// editor, and because `ready`'s production body reads window state.
    ///
    /// A source reveal (`language == nil`) never enters review. With no edition
    /// up it posts the navigate alone and never calls `ready`.
    ///
    /// **A source reveal while an edition is up leaves review first** (fix
    /// round 1, m4): `showing` is the edition on screen when the reveal starts;
    /// when `leavesReview` says so, `perform` posts
    /// `.maughamExitTranslationReview`, awaits `ready` (production: the badges
    /// emptying, i.e. the source surface back) and then navigates. `showing`
    /// defaults to nil, so every translated reveal is exactly as before.
    @MainActor
    static func perform(
        _ reveal: TranslationReveal,
        showing current: String? = nil,
        ready: () async -> Void = {},
        post: (Notification.Name, [String: Any]) -> Void
    ) async {
        if let language = reveal.language {
            post(.maughamEnterTranslationReview, [languageKey: language])
            await ready()
        } else if leavesReview(reveal, showing: current) {
            post(.maughamExitTranslationReview, [:])
            await ready()
        }
        guard !Task.isCancelled else { return }
        post(.maughamNavigateToParagraph, navigatePayload(reveal))
    }

    /// The paragraph navigation's payload: the paragraph, and the offset in
    /// it when the reveal names one.
    static func navigatePayload(_ reveal: TranslationReveal) -> [String: Any] {
        var payload: [String: Any] = [paragraphIdKey: reveal.paragraphId]
        if let offset = reveal.offset { payload[offsetKey] = offset }
        return payload
    }
}
