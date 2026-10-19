import SwiftUI

/// The banner over a canvas whose layout file this build refused (issue #44):
/// it says WHY the canvas takes no edits, and offers the way out from here —
/// **Start a Fresh Layout** for a damaged file, **Try Again** (and a retry of
/// its own) for files that could not be read just now (#88).
///
/// `ViewOnlyShareNotice`'s look and rules: a lock glyph on a cool slate, not
/// dismissable (the fact holds for as long as the file does), mounted as a
/// `safeAreaInset(edge: .top)` OUTSIDE `CanvasView`'s layer stack so the
/// composition censuses and the frontmost-editor rule (tripwire 27) never see
/// it, and visible with the chrome hidden (⌘\) because it is a safety fact,
/// not chrome. And for the same measured reason as that notice, no
/// `fixedSize(horizontal: false, vertical: true)` — see its comment.
///
/// **Its words are the refusal's own** (`CanvasStore.SidecarRefused.Reason
/// .sentence`), so the notice, the inbox alert and the tool's refusal cannot
/// say different things. Every decision is a `static`, pinned windowlessly
/// (tripwire 33); the button's press is the model's verb, tested on the model.
struct CanvasReadOnlyNotice: View {
    let refusal: CanvasStore.SidecarRefused
    /// `CanvasModel.startFreshLayout`, handed in so this view names no model.
    let startFreshLayout: () throws -> Void
    /// `CanvasModel.retryUnreadable` (issue #88): **Try Again**, and the
    /// automatic retry this notice runs while it is on screen. Answers whether
    /// the refusal changed; false means the files still can't be read.
    let tryAgain: () -> Bool

    @State private var failure: String?
    /// Set ONLY by a press of Try Again that still couldn't read
    /// (`stillUnreadableAfterPress`), never by the automatic retry — a line
    /// that appeared on its own every ten seconds would be noise.
    @State private var stillUnreadable = false
    @State private var stillUnreadableClear: Task<Void, Never>?

    /// The notice's sentence for `reason` — the refusal's own words.
    static func sentence(for reason: CanvasStore.SidecarRefused.Reason) -> String {
        reason.sentence
    }

    /// The button's label. The MCP refusal for a damaged file tells Claude to
    /// ask the writer to press a button by THIS name, so it is spelled once.
    static let startFreshTitle = "Start a Fresh Layout"

    /// Whether the notice offers Start a Fresh Layout. Only a DAMAGED file: a
    /// newer build's file is somebody's real layout, and its way out is
    /// updating Maugham, never setting it aside.
    static func offersStartFresh(for reason: CanvasStore.SidecarRefused.Reason) -> Bool {
        reason == .damaged
    }

    /// Whether the notice offers **Try Again** — and retries on its own. Only
    /// for files that could not be read just now (#88): they can change by
    /// themselves (a download finishing); a damaged or newer file cannot.
    static func offersTryAgain(for reason: CanvasStore.SidecarRefused.Reason) -> Bool {
        reason == .unreadable
    }

    static let tryAgainTitle = "Try Again"

    /// Said beside the button when a press found the files still unreadable.
    static let stillUnreadableSentence = "Still couldn't read it."
    /// How long that sentence stays.
    static let stillUnreadableSeconds: TimeInterval = 3

    /// Whether a retry's answer shows `stillUnreadableSentence`: only a PRESS
    /// that changed nothing. The automatic retry never shows it.
    static func showsStillUnreadable(afterPress pressed: Bool, lifted: Bool) -> Bool {
        pressed && !lifted
    }

    static func accessibilityLabel(for reason: CanvasStore.SidecarRefused.Reason) -> String {
        "Read-only canvas. " + sentence(for: reason)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(Self.sentence(for: refusal.reason))
                .font(.system(size: 11, weight: .medium))
                .accessibilityLabel(Self.accessibilityLabel(for: refusal.reason))
            Spacer(minLength: 8)
            if Self.offersTryAgain(for: refusal.reason) {
                if stillUnreadable {
                    Text(Self.stillUnreadableSentence)
                        .font(.system(size: 11))
                }
                Button(Self.tryAgainTitle) { pressTryAgain() }
                    .controlSize(.small)
            }
            if Self.offersStartFresh(for: refusal.reason) {
                Button(Self.startFreshTitle) {
                    do {
                        try startFreshLayout()
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .controlSize(.small)
                .alert("Couldn't start a fresh layout",
                       isPresented: Binding(get: { failure != nil },
                                            set: { if !$0 { failure = nil } })) {
                    Button("OK", role: .cancel) { failure = nil }
                } message: {
                    Text(failure ?? "")
                }
            }
        }
        .foregroundStyle(Self.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Self.border)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        // The automatic retry (#88). Keyed on the reason, so it starts when the
        // files become unreadable and is cancelled when the notice leaves —
        // the canvas left the screen, or a retry lifted the refusal.
        .task(id: refusal.reason) {
            var attempt = 0
            while let delay = CanvasUnreadableRetry.delay(before: attempt, reason: refusal.reason) {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                _ = tryAgain()
                attempt += 1
            }
        }
    }

    private func pressTryAgain() {
        let lifted = tryAgain()
        stillUnreadableClear?.cancel()
        stillUnreadable = Self.showsStillUnreadable(afterPress: true, lifted: lifted)
        guard stillUnreadable else { return }
        stillUnreadableClear = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.stillUnreadableSeconds * 1_000_000_000))
            if !Task.isCancelled { stillUnreadable = false }
        }
    }

    private static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkForNotice
            ? NSColor(srgbRed: 0.18, green: 0.20, blue: 0.24, alpha: 1.0)
            : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
    })

    private static let foreground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkForNotice
            ? NSColor(srgbRed: 0.82, green: 0.85, blue: 0.90, alpha: 1.0)
            : NSColor(srgbRed: 0.28, green: 0.32, blue: 0.40, alpha: 1.0)
    })

    private static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkForNotice
            ? NSColor(srgbRed: 0.40, green: 0.44, blue: 0.50, alpha: 0.5)
            : NSColor(srgbRed: 0.65, green: 0.68, blue: 0.74, alpha: 0.6)
    })
}

/// **When the canvas tries its unreadable files again on its own** (issue #88)
/// — a pure decision, so the schedule is pinned without a window or a clock.
///
/// Bounded in RATE rather than in count, because the ruling's sentence promises
/// *Maugham will keep trying*: every `interval` for the first `quickAttempts`
/// (iCloud usually finishes inside those minutes), then every `slowInterval`
/// for as long as the notice is on screen. Nothing at all for any other reason.
enum CanvasUnreadableRetry {
    static let interval: TimeInterval = 10
    static let quickAttempts = 30
    static let slowInterval: TimeInterval = 60

    /// The wait before retry number `attempt` (0-based), or nil for no retry.
    static func delay(before attempt: Int,
                      reason: CanvasStore.SidecarRefused.Reason?) -> TimeInterval? {
        guard let reason, CanvasReadOnlyNotice.offersTryAgain(for: reason) else { return nil }
        return attempt < quickAttempts ? interval : slowInterval
    }
}

private extension NSAppearance {
    var isDarkForNotice: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
