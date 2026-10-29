import SwiftUI
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

/// **A figure's name and number, until the grid arrives** (Tasks 6/7 replace
/// it): the centre column's and Plan's right column's one placeholder, so the
/// route compiles and is visible. "—" when the registry has no such row.
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
