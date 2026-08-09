import SwiftUI
import MaughamCore

/// **Where the window has to be for the writer to read the manuscript document
/// something just navigated to.**
///
/// Denver's ruling, 2026-08-02: *"if I'm moving to the manuscript I'm moving to
/// Author — I shouldn't be writing the manuscript in plan."* Every route that
/// names a manuscript document and forces the binder onto its home can fire from
/// a persona whose column does not offer one, and before this they all left a
/// text editor in the middle of Plan.
///
/// **Which routes those are is a census, not a number.** A count in prose is
/// wrong the day a route is added and nothing goes red — this comment said
/// "three" over four named things while a fourth notification existed and was
/// not routed here at all, and that undercount is what hid the slugline click
/// (slice 2 review, F2/F4). The list lives in
/// `ManuscriptForceCensusTests` and
/// `TransientSegmentReturnTests.test_everyNavigationReceiverStillRoutesThroughTheNavigation`,
/// which enumerates the notifications by name; the notifications themselves are
/// `.maughamNavigateToDocument` (a `[[wiki-link]]` in the editor, the Inspector's
/// Links row, the separate Project Statistics window scene),
/// `.maughamNavigateToParagraph` (an annotation row, a history row, a task row)
/// and `.maughamNavigateToScene` (a slugline in the Scenes navigator or on
/// Plan's Structure tab).
///
/// **A value plus one applier, rather than a handler per poster doing it its own
/// way.** The receivers live in `ProjectWindow`'s `ViewModifier`s
/// (`ProjectWindow.body` is at the type-checker ceiling, so window behaviour is
/// split across modifiers), and a rule spelled once per receiver is a rule that
/// comes to differ — which is the whole of `BinderSegment.centresTheCanvas`'s
/// doc comment, one question over.
///
/// **What this is NOT.** It is not the answer for *leaving* a transient segment.
/// Closing Find and emptying the Trash also force the binder home, and they are
/// not navigations to anything: no document was named, so nobody should be moved
/// to Author. Those return to `Persona.binderHome(for:)` instead — see
/// `BinderPaneToggle`.
enum ManuscriptNavigation {

    /// One navigation, as a value — so the decision is assertable without
    /// hosting SwiftUI, which is this window's established shape
    /// (`PersonaModifier.Change`, `CanvasClaudeArrivalModifier.Destination`).
    struct Destination: Equatable {
        let persona: Persona
        let binderSegment: BinderSegment
        let detailSegment: DetailSegment
        /// The memory to persist, with the departing persona's position already
        /// recorded — **nil when the persona did not move**, because a
        /// navigation inside Author must not rewrite the remembered position of
        /// a persona the writer never left.
        let memory: PersonaMemory?

        var movesPersona: Bool { memory != nil }
    }

    /// - Parameters:
    ///   - persona: where the window is now.
    ///   - currentBinderSegment: what the departing persona will be remembered
    ///     standing on (`PersonaMemory.record` drops it if it is transient).
    ///   - currentDetailSegment: likewise for the right column.
    static func destination(from persona: Persona,
                            currentBinderSegment: BinderSegment,
                            currentDetailSegment: DetailSegment,
                            projectType: ProjectType,
                            memory: PersonaMemory) -> Destination {
        let home = BinderSegment.documentHome(for: projectType)
        // **The guard, and it is a question about the centre column rather than
        // a persona name** — see `Persona.showsManuscriptDocuments` for why that
        // distinction is the whole task, and why the basis moved off the binder
        // registry in stage 2b Task 6. Review and Publish both centre the
        // editor, so a reviewer clicking an annotation stays in Review.
        guard !persona.showsManuscriptDocuments else {
            return Destination(persona: persona, binderSegment: home,
                               detailSegment: currentDetailSegment, memory: nil)
        }
        // **Author, because Author is where drafting happens** (spec §2). Not
        // `Persona.default`, which answers a different question — what a fresh
        // project opens in — and would silently follow that answer if it moved.
        let change = PersonaModifier.applyPersonaChange(
            to: .author, from: persona,
            currentSegment: currentDetailSegment,
            currentBinderSegment: currentBinderSegment,
            projectType: projectType,
            memory: memory)
        // **`home`, not `change.binderSegment`.** `applyPersonaChange` carries a
        // TRANSIENT segment through a persona switch on purpose — a writer
        // mid-search is not ejected — so taking its answer would leave the
        // binder in Find on a window that had just been told to show a document
        // (`ManuscriptNavigationTests.test_aNavigationFromFindStillLandsOnTheDocument`).
        return Destination(persona: change.persona, binderSegment: home,
                           detailSegment: change.segment, memory: change.memory)
    }

    /// The one place a navigation is applied to a window.
    ///
    /// **Deliberately does NOT force the inspector column open**, unlike every
    /// persona switch and unlike `CanvasClaudeArrivalModifier`'s Show. Those
    /// take the writer to something in the RIGHT column, so opening it is the
    /// navigation; this takes them to the centre, and reopening a column they
    /// closed with `⌘⌥I` would be a side effect nobody asked for.
    ///
    /// **The persona is persisted; the memory only when the persona moved.**
    /// `updateUIState` mutates its in-memory copy synchronously, so the next
    /// read here sees this write.
    @MainActor
    static func go(to destination: Destination,
                   persona: Binding<Persona>,
                   binderSegment: Binding<BinderSegment>,
                   detailSegment: Binding<DetailSegment>,
                   documentStore: DocumentStore?) {
        binderSegment.wrappedValue = destination.binderSegment
        guard let memory = destination.memory else { return }
        persona.wrappedValue = destination.persona
        detailSegment.wrappedValue = destination.detailSegment
        documentStore?.updateUIState {
            $0.persona = destination.persona
            $0.personaMemory = memory
        }
    }
}
