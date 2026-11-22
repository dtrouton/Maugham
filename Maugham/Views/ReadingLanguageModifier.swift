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
    /// The book's structure, for which piece a find match is in.
    var structure: () -> [StructureItem] = { [] }
    /// The editions the writer removed (`ProjectManifest.removedEditions`):
    /// no piece is read in one (shell p4 closing round).
    var removedEditions: [String] = []

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
            // A choice for a piece that is not the one open opens it, and the
            // language is taken on its arrival (`reading.pending`).
            .onKeyWindowCommand(.maughamChooseReadingLanguage, window: window) { note in
                let asked = LanguageSwitch.choice(from: note.userInfo)
                if let docId = asked.docId, docId != openDocId {
                    reading.pending = (docId, asked.language)
                    ResolveNavigation.go(toDocId: docId)
                } else {
                    choose(asked.language)
                }
            }
            // The setting events — a reveal's, and a choice's own.
            .onKeyWindowCommand(.maughamReadInLanguage, window: window) { note in
                guard let language = note.userInfo?[TranslationReveal.languageKey] as? String else { return }
                editorControl.translationLanguage = language
            }
            .onKeyWindowCommand(.maughamReadInSource, window: window) { _ in
                editorControl.translationLanguage = nil
            }
            // The setting's one home is the project's `UIState`, which every
            // window on the book shares (fix M6); the control mirrors it.
            .onKeyWindowCommand(.maughamToggleSourceUnder, window: window) { _ in
                let on = !(documentStore?.uiState.showsSourceUnderTranslation ?? true)
                documentStore?.updateUIState { $0.showsSourceUnderTranslation = on }
            }
            .onChange(of: documentStore?.uiState.showsSourceUnderTranslation, initial: true) { _, on in
                let shows = on ?? true
                if editorControl.showsSourceUnder != shows { editorControl.showsSourceUnder = shows }
            }
            // **A find match is a range of the SOURCE** (fix I2): its piece is
            // read in Source, now if it is open, else on its arrival — never
            // a selection at source offsets in a translated surface.
            .onKeyWindowCommand(.maughamFindMatchSelected, window: window) { note in
                guard let match = note.userInfo?["match"] as? SearchMatch,
                      let docId = ReadingLanguage.findMatchPiece(match, structure: structure())
                else { return }
                if docId == openDocId {
                    reading.pending = nil
                    choose(nil)
                } else {
                    reading.pending = (docId, nil)
                }
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
                // A language asked for on the way is taken on ITS piece's
                // arrival only (fix M7); any other arrival drops it.
                let asked = reading.pending.map { $0.docId == newValue ? $0.language : nil }
                    ?? editorControl.translationLanguage
                reading.pending = nil
                let carried = ReadingLanguage.carried(asked, toPieceWith: reading.languages(for: newValue))
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
            // **An edition removed** (owner's answer 1): its language leaves
            // the switch, and a piece read in it is read in Source.
            .onChange(of: removedEditions, initial: true) { _, removed in
                reading.removed = Set(removed.map { $0.lowercased() })
                if let current = editorControl.translationLanguage,
                   reading.removed.contains(current.lowercased()) {
                    choose(nil)
                }
            }
            // **A promotion's end** (closing review M1): the piece promoted
            // away keeps its id but is a reference now — it reads in nothing.
            .onChange(of: documentStore?.promotionReturns) { _, _ in
                let item = TreeWalk.find(id: openDocId, in: structure())
                if ReadingLanguage.kept(editorControl.translationLanguage, openItem: item)
                    != editorControl.translationLanguage {
                    choose(nil)
                }
            }
            // Which languages each piece has: one listing per translation
            // change, off the main actor — a change of piece is a lookup. A
            // folder that is there but cannot be read says so (RULING-54; fix
            // (e)), rather than looking like a book with no translations.
            .task(id: translationsRevision) {
                let url = projectURL
                let listing = await Task.detached(priority: .userInitiated) {
                    ReadingLanguageModel.list(in: url)
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
            // A reveal's waits outlive the press by up to six seconds. A window
            // closing mid-wait must end them rather than let them poll a store
            // nobody is looking at any more.
            .onDisappear { revealTask?.cancel() }
    }

    /// **The writer's choice of language.** The place is kept by the editor
    /// itself, across the swap (`EditorSurface.reconcileTextBuffer` reads the
    /// paragraph the writer is LOOKING at and restores it, same distance in,
    /// same height — fix round (c)); the window only sets the language and
    /// posts the setting event the key window's coordinator turns its
    /// membrane on by.
    private func choose(_ language: String?) {
        guard language != editorControl.translationLanguage else { return }
        editorControl.translationLanguage = language
        if let language {
            MaughamEvent.post(.maughamReadInLanguage, to: .keyWindow,
                              payload: [TranslationReveal.languageKey: language])
        } else {
            MaughamEvent.post(.maughamReadInSource, to: .keyWindow)
        }
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
