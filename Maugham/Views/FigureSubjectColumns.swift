import SwiftUI
import AppKit
import MaughamCore

// MARK: - Where a figure subject lands

extension ProjectWindow {

    /// **What the window does about a subject that names a figure** (report
    /// plan 8a Task 5) — `ResearchSubjectPlacement`'s three-way answer, read
    /// by BOTH columns for the same reason: one value, so the centre and the
    /// right column cannot disagree about whether the subject is in force.
    ///
    /// - `takesTheCentre` — Author and Review: the figure is the centre
    ///   column (Review's read-only comes with the grid, Task 6).
    /// - `besideTheCanvas` — Plan: the canvas STAYS MOUNTED (one mount,
    ///   tripwires 27/30) and the right column shows the figure, revealed by
    ///   `revealResearchColumn`, so the click is never silently nothing.
    /// - `nothingMoves` — Publish, whose centre is the book, and every subject
    ///   that is not a figure.
    enum FigureSubjectPlacement: Equatable {
        case takesTheCentre(String)
        case besideTheCanvas(String)
        case nothingMoves

        /// The figure the CENTRE column shows, or `nil`.
        var centreFigureID: String? {
            if case .takesTheCentre(let id) = self { return id }
            return nil
        }

        /// The figure the RIGHT column shows (beside the canvas), or `nil`.
        var besideFigureID: String? {
            if case .besideTheCanvas(let id) = self { return id }
            return nil
        }
    }

    /// Pure and exhaustive over its inputs, asked through the same two persona
    /// predicates `researchSubjectPlacement` asks — no persona name.
    static func figureSubjectPlacement(
        persona: Persona, subject: BinderSubject?
    ) -> FigureSubjectPlacement {
        guard let id = subject?.figureID else { return .nothingMoves }
        guard !persona.previewsThePublishedBook else { return .nothingMoves }
        return persona.centresTheCanvas ? .besideTheCanvas(id) : .takesTheCentre(id)
    }
}

/// **What a figure subject shows** (report plan 8a Task 6), in the centre and
/// in Plan's right column alike: a table's grid (`FigureCentreGrid`, one mount
/// per figure), read-only where the persona does not edit figures or the
/// window's ⌘⌥⇧R is on; anything else — an image, a kind from a later build,
/// a window with no session — its name and number.
struct FigureSubjectSurface: View {
    let figureID: String
    let store: ProjectStore
    let documentStore: DocumentStore
    let figureWindows: FigureWindows?
    let presence: FigureGridPresence
    let listing: FigureListingModel
    let control: EditorControl
    let persona: Persona
    let window: NSWindow?

    var body: some View {
        if let figureWindows, store.manifest.figures?.first(where: { $0.id == figureID })?.kind == .table {
            FigureCentreGrid(
                figureId: figureID, store: store, documentStore: documentStore,
                figureWindows: figureWindows, presence: presence, listing: listing,
                typography: control.typography,
                isReviewMode: control.isManualReviewMode || !persona.editsFigures,
                shareIsReadOnly: control.shareIsReadOnly, window: window)
                .id(figureID)
        } else {
            FigureSubjectPlaceholder(figureID: figureID, listing: listing)
        }
    }
}

/// **A figure's name and number** where no grid opens on it (an image figure,
/// a kind from a later build): "—" when the registry has no such row.
struct FigureSubjectPlaceholder: View {
    let figureID: String
    let listing: FigureListingModel

    var body: some View {
        let row = listing.row(forFigureId: figureID)
        VStack(spacing: 6) {
            Text(row?.name ?? "—").font(.title3)
            Text(row?.number ?? "—").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
