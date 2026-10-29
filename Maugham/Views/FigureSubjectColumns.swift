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
/// window's ⌘⌥⇧R is on; an image, its picture large (`FigureImageSubject`);
/// anything else — a kind from a later build, a window with no session —
/// its name and number.
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

    /// What a figure subject shows: pure over the record, the book and
    /// whether the window has figure windows.
    enum Shows: Equatable {
        case grid
        case image(URL)
        case nameAndNumber
    }

    static func shows(_ record: FigureRecord?, projectURL: URL, hasFigureWindows: Bool) -> Shows {
        switch record?.kind {
        case .table?:
            return hasFigureWindows ? .grid : .nameAndNumber
        case .image?:
            guard let record, let url = FigureImageSubject.fileURL(of: record, in: projectURL) else {
                return .nameAndNumber
            }
            return .image(url)
        case .unknown?, nil:
            return .nameAndNumber
        }
    }

    var body: some View {
        let record = store.manifest.figures?.first(where: { $0.id == figureID })
        switch Self.shows(record, projectURL: store.url, hasFigureWindows: figureWindows != nil) {
        case .grid:
            if let figureWindows {
                FigureCentreGrid(
                    figureId: figureID, store: store, documentStore: documentStore,
                    figureWindows: figureWindows, presence: presence, listing: listing,
                    typography: control.typography,
                    isReviewMode: control.isManualReviewMode || !persona.editsFigures,
                    shareIsReadOnly: control.shareIsReadOnly, window: window)
                    .id(figureID)
            }
        case .image(let url):
            if let record { FigureImageSubject(record: record, fileURL: url, listing: listing) }
        case .nameAndNumber:
            FigureSubjectPlaceholder(figureID: figureID, listing: listing)
        }
    }
}

/// **An image figure, large** (read-only): the picture, then its number and
/// name. The file is the record's synced path, resolved inside the book.
struct FigureImageSubject: View {
    let record: FigureRecord
    let fileURL: URL
    let listing: FigureListingModel

    /// The image's file, or nil when the record's path would leave the book.
    static func fileURL(of record: FigureRecord, in projectURL: URL) -> URL? {
        try? SafeRelativePath.resolve(record.path, under: projectURL)
    }

    var body: some View {
        let number = listing.row(forFigureId: record.id)?.number ?? FigureListing.unusedNumber
        VStack(spacing: 8) {
            ImagePreview(fileURL: fileURL)
            Text("\(number) \u{00B7} \(record.name)")
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// **A figure's name and number** where nothing larger can be shown (a kind
/// from a later build, a path outside the book, no session): "—" when the
/// registry has no such row.
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
