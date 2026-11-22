import SwiftUI
import MaughamCore
import AppKit

/// **The window's reading language** (shell p4 Task 8, which replaced
/// translation review's mode): it receives the writer's choice (the toolbar's
/// language switch, View ▸ Read In, ⌃⌘L), the setting events a reveal posts,
/// and View ▸ Show Source Under Translation; it carries the language across a
/// change of piece (`ReadingLanguage.carried`, Denver's answer 2); it reads
/// which languages each piece has, once per translation change and off the
/// main actor; and it is the reveal's window half.
///
/// The language lives in ONE place, `EditorControl.translationLanguage`: this
/// modifier writes it one-way and reads nothing back from the editor
/// (tripwire 2). EditorHost swaps the surface in from there; the coordinator
/// flips its membrane from the setting events and from `reconcileTextBuffer`.
///
/// Everything here asks about the piece the CENTRE has open
/// (`TranslationReveal.openDocId`) — the one the editor holds — never the
/// faces (shell p1 final fix, C1 and M9).
struct ReadingLanguageModifier: ViewModifier {
    let window: NSWindow?
    let projectURL: URL
    @Binding var subject: WindowSubject
    /// The centre item's cover: a reveal closes it, as every place does.
    @Binding var centreItem: CentreItem?
    /// For the pending reveal's one question (has that chapter's `Document`
    /// registered yet?), the caret a choice keeps, and the remembered
    /// source-under setting.
    let documentStore: DocumentStore?
    @Binding var editorControl: EditorControl
    let reading: ReadingLanguageModel

    /// A reveal whose chapter had to be opened first, held until `openDocId`
    /// catches up. Nil at every other moment.
    @State private var pendingReveal: TranslationReveal?
    /// The two waits a reveal performs — for the chapter's document, then for
    /// its surface. Held so a second reveal cancels the first rather than
    /// racing it, and so closing the window ends it.
    @State private var revealTask: Task<Void, Never>?
    /// Moves on every translation write and round record heard, so the
    /// languages listing is read again.
    @State private var translationsRevision = 0

    /// 50 ms × 60 = three seconds. Shared by both of the reveal's waits.
    private static let revealPollInterval = 50
    private static let revealPollAttempts = 60

    /// The piece the centre has open, or the no-document sentinel.
    private var openDocId: String { TranslationReveal.openDocId(subject) }

    func body(content: Content) -> some View {
        content
            // The writer's choice: keep the place, then read.
            .onKeyWindowCommand(.maughamChooseReadingLanguage, window: window) { note in
                choose(note.userInfo?[TranslationReveal.languageKey] as? String)
            }
            // The setting events — a reveal's, and a choice's own.
            .onKeyWindowCommand(.maughamReadInLanguage, window: window) { note in
                guard let language = note.userInfo?[TranslationReveal.languageKey] as? String else { return }
                editorControl.translationLanguage = language
            }
            .onKeyWindowCommand(.maughamReadInSource, window: window) { _ in
                editorControl.translationLanguage = nil
            }
            .onKeyWindowCommand(.maughamToggleSourceUnder, window: window) { _ in
                let on = !reading.showsSourceUnder
                reading.showsSourceUnder = on
                editorControl.showsSourceUnder = on
                documentStore?.updateUIState { $0.showsSourceUnderTranslation = on }
            }
            // **A report row as a way back into the manuscript.** Which chapter is
            // OPEN is this window's own answer, so the poster posts and the plan is
            // made here — `.now` when the chapter is up, `.afterSelecting` when not.
            .onKeyWindowCommand(.maughamRevealTranslation, window: window) { note in
                guard let reveal = TranslationReveal.decode(note.userInfo) else { return }
                switch TranslationReveal.plan(reveal, subject: subject) {
                case .now:
                    if centreItem != nil { centreItem = nil }
                    startReveal(reveal, waitingForDocument: false)
                case .afterSelecting:
                    pendingReveal = reveal
                    ManuscriptNavigation.go(
                        to: TranslationReveal.destination(reveal, current: subject),
                        subject: $subject, centreItem: $centreItem)
                }
            }
            // **A change of piece carries the language** where the new piece
            // has it, else reads it in Source (`ReadingLanguage.carried`) —
            // and a language a click asked for on the way (`pending`) is
            // taken here. **And this is where a pending reveal lands**, the
            // first moment the window looks at the chapter it named; its own
            // language then wins over the carried one.
            .onChange(of: openDocId) { _, newValue in
                let carried = ReadingLanguage.carried(
                    reading.pending ?? editorControl.translationLanguage,
                    toPieceWith: reading.languages(for: newValue))
                reading.pending = nil
                if editorControl.translationLanguage != carried {
                    editorControl.translationLanguage = carried
                }
                // Taken unconditionally: a pending reveal that did not get the
                // chapter it asked for is stale, and one left standing would
                // fire on some later, unrelated arrival at that document.
                let pending = pendingReveal
                pendingReveal = nil
                guard let reveal = pending, reveal.docId == newValue else { return }
                startReveal(reveal, waitingForDocument: true)
            }
            // Which languages each piece has: one listing per translation
            // change, off the main actor — a change of piece is a lookup.
            .task(id: translationsRevision) {
                let url = projectURL
                let listing = await Task.detached(priority: .userInitiated) {
                    TranslationStore.languagesByDocId(in: url)
                }.value
                guard !Task.isCancelled else { return }
                reading.adopt(listing)
            }
            .onProjectEvent(.maughamTranslationDidUpdate, url: projectURL, window: window) { _ in
                translationsRevision += 1
            }
            .onProjectEvent(.maughamTranslationRoundChanged, url: projectURL, window: window) { _ in
                translationsRevision += 1
            }
            // The remembered setting, once the project's UI state is in hand.
            .task(id: documentStore.map(ObjectIdentifier.init)) {
                guard let documentStore else { return }
                let on = documentStore.uiState.showsSourceUnderTranslation
                reading.showsSourceUnder = on
                if editorControl.showsSourceUnder != on { editorControl.showsSourceUnder = on }
            }
            // A reveal's waits outlive the press by up to six seconds. A window
            // closing mid-wait must end them rather than let them poll a store
            // nobody is looking at any more.
            .onDisappear { revealTask?.cancel() }
    }

    /// **The writer's choice of language, keeping their place**: the caret's
    /// paragraph is read from the source caret (which a translated surface
    /// keeps in step, `EditorHost.sourceCaret`) BEFORE the swap, and the swap
    /// is a reveal of that paragraph in the chosen language — so the editor
    /// lands on the same paragraph whichever way it went. With no paragraph to
    /// keep, the language is simply set.
    private func choose(_ language: String?) {
        guard language != editorControl.translationLanguage else { return }
        let docId = openDocId
        guard let paragraph = documentStore?.document(forDocId: docId)
            .flatMap({ $0.paragraphId(at: $0.cursorLocation) }) else {
            editorControl.translationLanguage = language
            return
        }
        if centreItem != nil { centreItem = nil }
        startReveal(TranslationReveal(docId: docId, language: language, paragraphId: paragraph),
                    waitingForDocument: false)
    }

    /// **Perform a reveal, waiting for each thing it needs to exist.** Two waits,
    /// neither optional:
    ///
    /// - **The document**, when the chapter had to be selected first: the
    ///   coordinator the setting post reaches does not exist until `EditorHost`
    ///   has registered the `Document`.
    /// - **The surface it reads in**, always: the buffer is swapped in on the
    ///   next body pass (`recomputeTranslatedSurface` → `applyExternalText`), so
    ///   navigating without waiting scrolls text the swap then discards.
    ///
    /// The language on screen and its badge model are captured HERE, before
    /// the setting post, because that post is delivered synchronously and has
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
            let showing = control.translationLanguage
            // A chapter just opened in the language it was carried in has a
            // surface still to come though the language did not move.
            let waits = TranslationReveal.waitsForTranslatedSurface(
                reveal, showing: showing, arrivingAtPiece: waitingForDocument)
            // A source reveal while a translation is up leaves it first, and
            // waits for the source surface to come back (fix round 1, m4).
            let leaves = TranslationReveal.leavesReview(reveal, showing: showing)
            let surfaceBefore = waitingForDocument ? .empty : control.translationBadges
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
                post: { name, payload in
                    // The setting events are this window's own: the language
                    // is set here as well as by the key window's receiver, so
                    // a reveal begun while a menu or a sheet held the key
                    // still swaps this window.
                    if name == .maughamReadInLanguage {
                        control.translationLanguage = reveal.language
                    } else if name == .maughamReadInSource {
                        control.translationLanguage = nil
                    }
                    MaughamEvent.post(name, to: .keyWindow, payload: payload)
                })
        }
    }

    /// Poll until the chapter's document is registered. `true` if it arrived.
    ///
    /// A bare next-tick deferral loses this race (tripwire 16's lesson), so
    /// this polls 50 ms, up to three seconds, then gives up in silence — the
    /// right chapter is still open, and a notice for a slow load would be worse.
    @MainActor
    private static func waitForDocument(
        _ reveal: TranslationReveal, in store: DocumentStore?
    ) async -> Bool {
        for _ in 0..<revealPollAttempts {
            if Task.isCancelled { return false }
            if store?.document(forDocId: reveal.docId) != nil { return true }
            do { try await Task.sleep(for: .milliseconds(revealPollInterval)) }
            catch { return false }
        }
        return false
    }

    /// Poll until the source surface is back — the badge model empties when
    /// `recomputeTranslatedSurface` finds no language.
    @MainActor
    private static func waitForSourceSurface(in control: EditorControl) async {
        for _ in 0..<revealPollAttempts {
            if Task.isCancelled { return }
            if control.translationBadges.entries.isEmpty { return }
            do { try await Task.sleep(for: .milliseconds(revealPollInterval)) }
            catch { return }
        }
    }

    /// Poll until the translated surface the setting post asked for has
    /// reached `EditorControl`.
    ///
    /// **Both halves of the predicate are load-bearing.** `replacing` is the
    /// badge model from before the post: without it, a reveal into a DIFFERENT
    /// language would be satisfied instantly by the outgoing one's entries.
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
