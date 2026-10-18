import SwiftUI
import MaughamCore
import AppKit

/// Owns this window's translation-review selection (Task 13): receives the
/// key-window picker / enter / exit commands (ADR 0021), resolves the active
/// doc's available languages for the picker, mirrors the chosen language
/// ONE-WAY into `editorControl.translationLanguage` (EditorHost swaps in the
/// derived surface and the coordinator flips its membrane from there — Tasks
/// 11/12), and renders the top indicator pill next to `ReviewModeIndicator`.
///
/// Menu-shape note: the app-global menu can't reach `activeDocId`/`projectURL`
/// (per-window state), so the menu posts a generic "show picker" command and
/// THIS window presents the picker — resolving languages is a direct local call
/// here, and the filesystem scan happens only on demand rather than on every
/// body render (as a focused-value publish of the list would). Extracted into a
/// ViewModifier to stay under ProjectWindow.body's type-checker ceiling.
struct TranslationReviewModifier: ViewModifier {
    let window: NSWindow?
    let projectURL: URL
    /// From `ProjectWindow`'s boundary, so this modifier sees the same value the
    /// right-hand panes do. It used to be handed the RAW selection under this
    /// name — the one consumer of `activeDocId` with no sentinel substitution at
    /// all, and a third spelling of the rule.
    let activeDocId: String
    /// The window's one subject-picker, written when a reveal names a chapter
    /// that is not the open one (P4 Task 5). The round report the row was
    /// clicked in is dismissed by the report's own `onReveal` (it clears
    /// `publishSelectedRound` before posting) — it used to fall out of the
    /// subject change, but since 2026-09-02 the report draws over a chapter
    /// subject too, so the dismissal is explicit.
    @Binding var selectedSubject: BinderSubject?
    /// For the pending reveal's one question: has that chapter's `Document`
    /// registered yet? The enter-review post reaches an `EditorCoordinator` that
    /// does not exist until it has.
    let documentStore: DocumentStore?
    @Binding var editorControl: EditorControl

    @State private var translationLanguage: String?
    @State private var pickerLanguages: [String] = []
    @State private var showingPicker = false
    /// A reveal whose chapter had to be selected first, held until `activeDocId`
    /// catches up. Nil at every other moment.
    @State private var pendingReveal: TranslationReveal?
    /// The two waits a reveal performs — for the chapter's document, then for
    /// its translated surface. Held so a second reveal cancels the first rather
    /// than racing it, and so closing the window ends it.
    @State private var revealTask: Task<Void, Never>?

    /// 50 ms × 60 = three seconds. Shared by both of the reveal's waits.
    private static let revealPollInterval = 50
    private static let revealPollAttempts = 60

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamShowTranslationPicker, window: window) { _ in
                // The sentinel names no document, so the store finds no
                // translations for it and the picker says so — the same empty
                // list the `nil` arm produced before.
                pickerLanguages = activeDocId == BinderSubject.noDocumentSubject
                    ? []
                    : TranslationStore.languages(
                        forDocId: activeDocId, in: projectURL).sorted()
                showingPicker = true
            }
            .onKeyWindowCommand(.maughamEnterTranslationReview, window: window) { note in
                guard let lang = note.userInfo?["language"] as? String else { return }
                translationLanguage = lang
                editorControl.translationLanguage = lang
            }
            .onKeyWindowCommand(.maughamExitTranslationReview, window: window) { _ in
                translationLanguage = nil
                editorControl.translationLanguage = nil
            }
            // **A report row as a way back into the manuscript** (P4 Task 5).
            //
            // The reveal names a chapter, an edition and a paragraph. Which
            // chapter is OPEN is this window's own answer and nobody else's, so
            // the poster posts and the plan is made here — `.now` when the
            // chapter is already up, `.afterSelecting` when it is not.
            .onKeyWindowCommand(.maughamRevealTranslation, window: window) { note in
                guard let reveal = TranslationReveal.decode(note.userInfo) else { return }
                switch TranslationReveal.plan(reveal, activeDocId: activeDocId) {
                case .now:
                    startReveal(reveal, waitingForDocument: false)
                case .afterSelecting(let subject):
                    pendingReveal = reveal
                    selectedSubject = subject
                }
            }
            // The chosen language belongs to the doc that was active when it was
            // picked; a doc switch must drop the posture back to the source.
            //
            // **And this is where a pending reveal lands.** The selection above
            // moves `activeDocId` on the same body pass, so this is the first
            // moment the window is looking at the chapter the reveal named. The
            // clear still runs first, on purpose: the reveal's own enter-review
            // post sets the language a moment later, and until it does the
            // writer is looking at the new chapter's SOURCE rather than at the
            // previous chapter's edition.
            .onChange(of: activeDocId) { _, newValue in
                if translationLanguage != nil {
                    translationLanguage = nil
                    editorControl.translationLanguage = nil
                }
                // Taken unconditionally: a pending reveal that did not get the
                // chapter it asked for is stale, and one left standing would
                // fire on some later, unrelated arrival at that document.
                let pending = pendingReveal
                pendingReveal = nil
                guard let reveal = pending, reveal.docId == newValue else { return }
                startReveal(reveal, waitingForDocument: true)
            }
            // A reveal's waits outlive the press by up to six seconds. A window
            // closing mid-wait must end them rather than let them poll a store
            // nobody is looking at any more.
            .onDisappear { revealTask?.cancel() }
            .confirmationDialog(
                "Translation Review",
                isPresented: $showingPicker,
                titleVisibility: .visible
            ) {
                // Mutate directly — do NOT post .keyWindow events from these
                // buttons. The confirmationDialog's own window holds key status
                // while its action runs, so a synchronous .keyWindow post from
                // here is dropped by shouldDeliver's isWindowKey check (the
                // v0.24.0 enter-does-nothing bug). The onKeyWindowCommand
                // receivers above remain for genuine out-of-window posters.
                ForEach(pickerLanguages, id: \.self) { tag in
                    Button(TranslationReviewIndicator.displayLabel(forLanguageTag: tag)) {
                        translationLanguage = tag
                        editorControl.translationLanguage = tag
                    }
                }
                if translationLanguage != nil {
                    Button("Show Source (Off)") {
                        translationLanguage = nil
                        editorControl.translationLanguage = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(pickerLanguages.isEmpty
                     ? "No translations are available for this document yet."
                     : "Choose a translation to review in read-only mode.")
            }
            .safeAreaInset(edge: .top) {
                if let lang = translationLanguage {
                    TranslationReviewIndicator(
                        languageTag: lang,
                        staleCount: TranslationReviewIndicator.staleCount(
                            in: editorControl.translationBadges.entries),
                        onExit: {
                            MaughamEvent.post(.maughamExitTranslationReview, to: .keyWindow)
                        })
                }
            }
    }

    /// **Perform a reveal, waiting for each thing it needs to exist** (P4 Task 5).
    ///
    /// Two waits, and neither is optional:
    ///
    /// - **The document**, when the chapter had to be selected first.
    ///   `EditorHost` registers the `Document` as it loads, and the enter-review
    ///   post is received by an `EditorCoordinator` that does not exist until it
    ///   has.
    /// - **The translated surface**, always. The enter-review post only writes
    ///   `translationLanguage`; the buffer is swapped in on the next body pass
    ///   (`EditorHost`'s `.onChange` → `recomputeTranslatedSurface` →
    ///   `applyExternalText`). Navigate without waiting and the coordinator
    ///   scrolls the source text, which the swap then discards — the reveal
    ///   lands at the top of the edition every time (fix round 1).
    ///
    /// The two facts the surface wait is judged against — which edition was on
    /// screen, and what its badge model held — are captured HERE, before the
    /// enter-review post, because that post is delivered synchronously and has
    /// already moved both of them by the time `ready` runs.
    ///
    /// Cancels whatever a previous reveal left running: the writer clicking a
    /// second row means the first is no longer what they asked for.
    private func startReveal(_ reveal: TranslationReveal, waitingForDocument: Bool) {
        revealTask?.cancel()
        let store = documentStore
        let control = editorControl
        revealTask = Task { @MainActor in
            if waitingForDocument {
                guard await Self.waitForDocument(reveal, in: store) else { return }
            }
            // Already showing this edition — the enter-review post changes
            // nothing, nothing recomputes, and there is no new surface to wait
            // for. Without this the common case (a reveal from the Translation
            // pane, review already up) would stall for the full three seconds.
            let alreadyShowing = control.translationLanguage == reveal.language
            let surfaceBefore = control.translationBadges
            await TranslationReveal.perform(
                reveal,
                ready: {
                    guard !alreadyShowing else { return }
                    await Self.waitForTranslatedSurface(
                        reveal, in: control, replacing: surfaceBefore)
                },
                post: { MaughamEvent.post($0, to: .keyWindow, payload: $1) })
        }
    }

    /// Poll until the chapter's document is registered. `true` if it arrived.
    ///
    /// A bare next-tick deferral loses this race — tripwire 16's lesson, one
    /// column over — so this polls on the coordinator's own idiom: 50 ms, up to
    /// three seconds, then gives up in silence. Giving up still leaves the
    /// writer with the right chapter open, which is honestly most of what the
    /// row was asked for; a notice for a load that is merely slow would be worse
    /// than the quiet.
    ///
    /// Static, and handed the store rather than reading `self`, so the `Task`
    /// captures sendable values instead of a whole `ViewModifier` whose `@State`
    /// it must not outlive.
    @MainActor
    private static func waitForDocument(
        _ reveal: TranslationReveal, in store: DocumentStore?
    ) async -> Bool {
        for _ in 0..<revealPollAttempts {
            // Checked before the read, not after: a cancelled reveal must not
            // go on to enter review for a chapter nobody is waiting on.
            if Task.isCancelled { return false }
            if store?.document(forDocId: reveal.docId) != nil { return true }
            // A cancelled sleep must END the poll — swallowing it with `try?`
            // would spin the loop sixty times with no wait at all.
            do { try await Task.sleep(for: .milliseconds(revealPollInterval)) }
            catch { return false }
        }
        return false
    }

    /// Poll until the translated surface the enter-review post asked for has
    /// reached `EditorControl`.
    ///
    /// **Both halves of the predicate are load-bearing.** `replacing` is the
    /// badge model as it stood before the post: without it, a reveal into a
    /// DIFFERENT edition than the one on screen would be satisfied instantly by
    /// the outgoing edition's entries, which is the bug this wait exists to
    /// prevent wearing a different hat. The `contains` is what says the surface
    /// that arrived actually holds the paragraph being revealed.
    @MainActor
    private static func waitForTranslatedSurface(
        _ reveal: TranslationReveal, in control: EditorControl,
        replacing previous: EditorControl.TranslationBadgeModel
    ) async {
        for _ in 0..<revealPollAttempts {
            if Task.isCancelled { return }
            let badges = control.translationBadges
            if badges != previous,
               badges.entries.contains(where: { $0.paragraphId == reveal.paragraphId }) {
                return
            }
            do { try await Task.sleep(for: .milliseconds(revealPollInterval)) }
            catch { return }
        }
    }
}
