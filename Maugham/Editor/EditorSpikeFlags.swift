import Foundation

/// SPIKE (collab review) scratch flags. Throwaway — gates the spike-only
/// mechanisms (selection toolbar overlay, annotate-only read-only mode) so
/// they don't affect normal use unless explicitly turned on. The real plan
/// replaces these with proper feature wiring / settings.
enum EditorSpikeFlags {
    /// Install the floating selection toolbar overlay in EditorSurface.
    /// Default ON for the spike so the mechanism can be exercised by hand;
    /// flip to false to disable.
    static let selectionToolbar = true

    /// Force the editor into annotate-only (read-only manuscript) mode on
    /// attach. Default OFF — flip to true (or wire a debug keybinding) to
    /// verify the read-only guard rejects typing/paste/delete while leaving
    /// selection, scrolling, and copy working.
    static let annotateOnly = false
}
