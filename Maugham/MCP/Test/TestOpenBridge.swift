import Foundation

#if MAUGHAM_DEV_BUILD

public extension Notification.Name {
    /// Dev-only: posted by `test_create_project` / `test_open_project`. The
    /// Welcome window (which holds `openWindow` in its environment) observes it
    /// under `#if MAUGHAM_DEV_BUILD` and opens the project window.
    /// `userInfo["url"]` carries the project folder `URL`.
    ///
    /// The tools post this best-effort: in a headless XCTest there is no
    /// SwiftUI window to observe it, so posting opens nothing — the tools fall
    /// back to on-disk facts and never hang or hard-fail on a missing window.
    ///
    /// Scope: .allWindows (no liveness guard — must reach everything; ADR
    /// 0021). Zombie-harm audit: sole receiver is `WelcomeHost`
    /// (`MaughamApp.swift`, under the same `#if MAUGHAM_DEV_BUILD` gate),
    /// which calls the same `open(url)` helper as `maughamOpenProject` —
    /// `recents.record(url)` (idempotent MRU re-promotion) then
    /// `openWindow(id: "project", value: url)` (idempotent per-URL scene
    /// identity on `WindowGroup(for: URL.self)`, ADR 0021 audit note on
    /// `maughamOpenProject` in `MaughamNotifications.swift`). Harmless
    /// duplication at worst. OK.
    static let maughamTestOpenProject = Notification.Name("maughamTestOpenProject")
}
#endif
