import Foundation

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
    /// Palette (the section's leading row, the Palette row, the placeholder).
    static let emptyPalette = 1 + 1 + 1
    /// Palette with cards: the leading row and the Palette row, before them.
    static let paletteHead = 1 + 1
    /// Editions on a fresh project: header + the source language.
    static let editions = 1 + 1
    /// Everything below the manuscript on a fresh project.
    static let emptySections = emptyResearch + emptyPalette + editions
}
