// Maugham/Updates/UpdateCheckRequest.swift
import Foundation

/// A one-shot, in-memory "the writer asked for a check" flag for the Check for
/// Updates… window. The menu item sets it immediately before `openWindow`; the
/// window's `.task` checks only if it is set (`UpdateSheet.checksOnAppear`),
/// and clears it. A window macOS restores at launch finds no request, so it
/// shows the current state and fetches nothing the writer did not ask for;
/// its idle state offers Check Now instead. Never persisted: a request that
/// outlived the launch would make a restored window check after all.
@MainActor
final class UpdateCheckRequest {
    static let shared = UpdateCheckRequest()

    private(set) var isPending = false

    /// The menu item: ask the next appearance of the window to check.
    func request() {
        isPending = true
    }

    /// The window's appearance: true, and the request cleared, iff one is pending.
    func consume() -> Bool {
        defer { isPending = false }
        return isPending
    }
}
