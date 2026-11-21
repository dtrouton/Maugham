import Foundation
import AppKit
@testable import Maugham

/// **The rows every fresh tree draws besides its manuscript** (shell p1
/// Task 3), named once so the mounted tree suites count the same furniture.
///
/// A fresh factory project has publishing initialised and no capture, so its
/// tree is: the Book row; the Canvas row (no Inbox row); the manuscript; the
/// Research section (header + empty placeholder); the Palette section (a
/// headerless `Section`'s leading row, the Palette row, its empty
/// placeholder); the Editions section (header + the source language's row).
enum TreeFurniture {
    /// The rows between the Book row and the manuscript: Canvas.
    static let topRows = 1
    /// The row index of the first manuscript row (after the Book and Canvas).
    static let firstManuscriptRow = 1 + topRows
    /// Research (header + placeholder).
    static let emptyResearch = 1 + 1
    /// Palette (the section's leading row, the Palette row, the placeholder —
    /// the group's child, which arrives a turn after the list: `isSettled`).
    static let emptyPalette = 1 + 1 + 1
    /// Palette with cards: the leading row and the Palette row, before them.
    static let paletteHead = 1 + 1
    /// Editions on a fresh project: header + the source language.
    static let editions = 1 + 1
    /// Everything below the manuscript on a fresh project.
    static let emptySections = emptyResearch + emptyPalette + editions
}

extension TreeFurniture {
    /// **Whether a fresh tree has finished opening in the outline.** The
    /// Palette is a `DisclosureGroup` (owner's hand check, 2026-11-21), and
    /// with it in the list the outline opens the sections one after another,
    /// a turn or more after the list first draws — the Editions header was
    /// measured still closed when the Palette had opened. So a suite that
    /// counts a fresh tree's rows waits on this first, or counts short: every
    /// section header open, and the Palette open with its first child drawn.
    /// A fresh tree's sections and Palette all start open.
    @MainActor
    static func isSettled(in table: NSTableView?) -> Bool {
        guard let outline = table as? NSOutlineView else { return false }
        var sawPalette = false
        for row in 0..<outline.numberOfRows {
            guard let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
            else { return false }
            let item = outline.item(atRow: row)
            if String(describing: type(of: view)).contains("ListTableHeaderView"),
               !outline.isItemExpanded(item) { return false }
            if contains(paletteMarkIn: view) {
                sawPalette = true
                guard outline.isItemExpanded(item), row + 1 < outline.numberOfRows,
                      outline.level(forRow: row + 1) == outline.level(forRow: row) + 1
                else { return false }
            }
        }
        return sawPalette
    }

    @MainActor
    private static func contains(paletteMarkIn view: NSView) -> Bool {
        if (view as? TreeTravelTargetView)?.subject == .palette { return true }
        return view.subviews.contains { contains(paletteMarkIn: $0) }
    }
}
