import Foundation

public extension Notification.Name {
    /// Dev-only: posted by `test_create_project` / `test_open_project`. The
    /// Welcome window (which holds `openWindow` in its environment) observes it
    /// under `#if MAUGHAM_DEV_BUILD` and opens the project window.
    /// `userInfo["url"]` carries the project folder `URL`.
    ///
    /// The tools post this best-effort: in a headless XCTest there is no
    /// SwiftUI window to observe it, so posting opens nothing — the tools fall
    /// back to on-disk facts and never hang or hard-fail on a missing window.
    static let maughamTestOpenProject = Notification.Name("maughamTestOpenProject")
}
