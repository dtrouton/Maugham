import Foundation

/// **A Describe… press in Project Settings, waiting for the sheet to close.**
///
/// `MaughamEvent.postDetailSegment` is scoped `.keyWindow`, and the sheet's
/// window is key while it is up, so the request is recorded here and acted on
/// from the `.sheet`'s `onDismiss`. **The hand-off WRITES the segment through
/// `selectDetailSegment`; it does not post it** — `onDismiss` runs before key
/// status returns, so a `.keyWindow` post would be dropped.
///
/// **Guarded twice**: `describeFirstReader`'s two awaits leave a window in
/// which the writer can Escape before the request is recorded, and the request
/// then stands over a sheet that is already gone — so every presentation
/// clears it, and the dismissal that acts on it must be Project Settings' own
/// (`ProjectWindow.opensFirstReader`) — otherwise closing any other sheet would
/// jump the right column to her statement.
///
/// A value with three verbs, so the whole hand-off is assertable with no
/// window (tripwire 33); `ProjectWindow` holds one as `@State` and calls each
/// verb from one place.
struct FirstReaderHandoff: Equatable {
    /// Describe… was pressed and nothing has acted on it yet.
    private(set) var requested = false
    /// **Which sheet is up** — `onDismiss` is told nothing about what closed,
    /// and the decision turns on it. Recorded at presentation rather than read
    /// at dismissal, because by then the window's `activeSheet` is already nil.
    private(set) var presented: ProjectActiveSheet?

    /// A sheet came up (or `activeSheet` went nil, which changes nothing). A
    /// presentation is the one moment every sheet has in common, so it is
    /// where a stale request dies.
    mutating func sheetPresented(_ sheet: ProjectActiveSheet?) {
        guard let sheet else { return }
        requested = false
        presented = sheet
    }

    /// Project Settings' Describe… button.
    mutating func describeRequested() {
        requested = true
    }

    /// A sheet closed: whether to hand the writer to the first reader's
    /// statement. Spends the request and forgets the sheet either way.
    mutating func sheetDismissed() -> Bool {
        let opens = ProjectWindow.opensFirstReader(requested: requested, dismissed: presented)
        requested = false
        presented = nil
        return opens
    }
}
