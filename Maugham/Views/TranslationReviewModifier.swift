import SwiftUI
import MaughamCore
import AppKit

/// Owns this window's translation-review selection: receives the key-window
/// picker / enter / exit commands (ADR 0021), resolves the active doc's
/// available languages for the picker, mirrors the chosen language ONE-WAY
/// into `editorControl.translationLanguage` (EditorHost swaps in the derived
/// surface and the coordinator flips its membrane from there), and renders
/// the top indicator pill next to `ReviewModeIndicator`.
///
/// The app-global menu can't reach `activeDocId`/`projectURL`, so it posts a
/// generic "show picker" command and THIS window presents the picker — the
/// filesystem scan happens only on demand, never on every body render.
struct TranslationReviewModifier: ViewModifier {
    let window: NSWindow?
    let projectURL: URL
    /// From `ProjectWindow`'s boundary (`BinderSubject.activeDocId`), so this
    /// modifier sees the same value the right-hand panes do.
    let activeDocId: String
    /// The window's one subject-picker, written when a reveal names a chapter
    /// that is not the open one. The round report the row was clicked in is
    /// dismissed explicitly by its own `onReveal`
    /// (`PublishCentreModel.clearRound`), since it draws over a chapter too.
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
            // **A report row as a way back into the manuscript.** Which chapter is
            // OPEN is this window's own answer, so the poster posts and the plan is
            // made here — `.now` when the chapter is up, `.afterSelecting` when not.
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
            // **And this is where a pending reveal lands** — the first moment the
            // window looks at the chapter it named. The clear still runs first, on
            // purpose: until the reveal's enter-review post sets the language, the
            // writer sees the new chapter's SOURCE, never the previous edition.
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
                // Mutate directly — do NOT post .keyWindow events from these buttons.
                // The dialog's own window holds key status while its action runs, so
                // a synchronous .keyWindow post is dropped by shouldDeliver's
                // isWindowKey check (the v0.24.0 enter-does-nothing bug). The
                // onKeyWindowCommand receivers above remain for genuine
                // out-of-window posters.
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

    /// **Perform a reveal, waiting for each thing it needs to exist.** Two waits,
    /// neither optional:
    ///
    /// - **The document**, when the chapter had to be selected first: the
    ///   enter-review post is received by an `EditorCoordinator` that does not
    ///   exist until `EditorHost` has registered the `Document`.
    /// - **The translated surface**, always: the buffer is swapped in on the
    ///   next body pass (`recomputeTranslatedSurface` → `applyExternalText`), so
    ///   navigating without waiting scrolls source text the swap then discards.
    ///
    /// The edition on screen and its badge model are captured HERE, before the
    /// enter-review post, because that post is delivered synchronously and has
    /// moved both by the time `ready` runs. Cancels any previous reveal: a
    /// second row clicked means the first is no longer what was asked for.
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
            //
            // A source reveal (no language) never waits either: it enters no
            // edition, so nothing will be swapped in.
            let showing = control.translationLanguage
            let waits = TranslationReveal.waitsForTranslatedSurface(reveal, showing: showing)
            // A source reveal while an edition is up leaves review first, and
            // waits for the source surface to come back (fix round 1, m4).
            let leaves = TranslationReveal.leavesReview(reveal, showing: showing)
            let surfaceBefore = control.translationBadges
            await TranslationReveal.perform(
                reveal,
                showing: showing,
                ready: {
                    if leaves {
                        await Self.waitForSourceSurface(in: control)
                        return
                    }
                    guard waits else { return }
                    await Self.waitForTranslatedSurface(
                        reveal, in: control, replacing: surfaceBefore)
                },
                post: { MaughamEvent.post($0, to: .keyWindow, payload: $1) })
        }
    }

    /// Poll until the chapter's document is registered. `true` if it arrived.
    ///
    /// A bare next-tick deferral loses this race (tripwire 16's lesson), so
    /// this polls 50 ms, up to three seconds, then gives up in silence — the
    /// right chapter is still open, and a notice for a slow load would be worse.
    /// Static and handed the store, so the `Task` captures sendable values
    /// rather than a `ViewModifier` whose `@State` it must not outlive.
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

    /// Poll until leaving review has put the source surface back — the badge
    /// model empties when `recomputeTranslatedSurface` finds no language.
    /// `waitForTranslatedSurface`'s poll, mirrored.
    @MainActor
    private static func waitForSourceSurface(in control: EditorControl) async {
        for _ in 0..<revealPollAttempts {
            if Task.isCancelled { return }
            if control.translationBadges.entries.isEmpty { return }
            do { try await Task.sleep(for: .milliseconds(revealPollInterval)) }
            catch { return }
        }
    }

    /// Poll until the translated surface the enter-review post asked for has
    /// reached `EditorControl`.
    ///
    /// **Both halves of the predicate are load-bearing.** `replacing` is the
    /// badge model from before the post: without it, a reveal into a DIFFERENT
    /// edition would be satisfied instantly by the outgoing edition's entries.
    /// The `contains` says the arrived surface holds the revealed paragraph.
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
