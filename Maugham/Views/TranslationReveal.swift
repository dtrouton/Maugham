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
struct TranslationReveal: Equatable, Sendable {
    let docId: String
    let language: String
    let paragraphId: String

    /// The payload keys — one spelling, shared by `post`, `decode` and the two
    /// posts `perform` makes. `languageKey` and `paragraphIdKey` are also what
    /// `.maughamEnterTranslationReview`'s and `.maughamNavigateToParagraph`'s
    /// existing receivers read, which is why `perform` can reuse them.
    static let docIdKey = "document_id"
    static let languageKey = "language"
    static let paragraphIdKey = "paragraph_id"

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
    static func post(_ reveal: TranslationReveal) {
        MaughamEvent.post(.maughamRevealTranslation, to: .keyWindow, payload: [
            docIdKey: reveal.docId,
            languageKey: reveal.language,
            paragraphIdKey: reveal.paragraphId,
        ])
    }

    /// All three keys or nothing: a reveal missing any of them names no
    /// destination, and a half-built one would move the window somewhere the
    /// writer did not ask to go.
    static func decode(_ userInfo: [AnyHashable: Any]?) -> TranslationReveal? {
        guard let docId = userInfo?[docIdKey] as? String,
              let language = userInfo?[languageKey] as? String,
              let paragraphId = userInfo?[paragraphIdKey] as? String
        else { return nil }
        return TranslationReveal(
            docId: docId, language: language, paragraphId: paragraphId)
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
    @MainActor
    static func perform(
        _ reveal: TranslationReveal,
        ready: () async -> Void = {},
        post: (Notification.Name, [String: Any]) -> Void
    ) async {
        post(.maughamEnterTranslationReview, [languageKey: reveal.language])
        await ready()
        guard !Task.isCancelled else { return }
        post(.maughamNavigateToParagraph, [paragraphIdKey: reveal.paragraphId])
    }
}
