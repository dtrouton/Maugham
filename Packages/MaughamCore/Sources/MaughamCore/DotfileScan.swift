import Foundation

/// Name-based dotfile test for directory scans that must NOT honour the BSD
/// `hidden` flag. Shared by the Mac and the phone (tripwire 19): both read
/// the same iCloud-synced `.maugham/` tree.
///
/// `FileManager`'s `.skipsHiddenFiles` drops an entry whose name begins with
/// `.` OR whose `UF_HIDDEN` flag is set — and something outside Maugham sets
/// that flag, lazily, on files under a dot-directory in a synced Documents
/// folder (observed 2026-08-27 on `~/Documents/Maugham/Playlist/.maugham/…`:
/// tectonic's `template.log` and both preview PDFs were flagged; `body.tex`
/// was clean when written and flagged three minutes later; `touch` in the
/// same directory produced a clean file, so it is not inheritance). Under that
/// flag `read_preview_page` answered "No preview output — run preview_compile
/// first" over a directory holding two previews, and `list_publish_files`
/// would silently omit whatever the daemon had reached — and on the phone an
/// op-log file the flag reached would drop out of the cold-launch download.
/// The tree under `.maugham/` is Maugham's own; whether the OS considers a
/// file in it hidden is not a fact about the file. Scanners skip by NAME and
/// nothing else.
///
/// `TripwireGrepTests.test_noSkipsHiddenFilesInProductionScans` (Mac) and
/// `TripwirePhoneGrepTest.test_noSkipsHiddenFilesInPhoneScans` keep
/// `.skipsHiddenFiles` out of both source trees.
public enum DotfileScan {
    /// True for an entry whose own name starts with `.` — the only "hidden"
    /// a Maugham scan may skip. An enumerator walking into a dot-directory
    /// should also `skipDescendants()`.
    public static func isDotfile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".")
    }
}
