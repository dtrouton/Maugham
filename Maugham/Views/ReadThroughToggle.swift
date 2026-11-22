import SwiftUI

/// **The toolbar padlock: the open piece's read-through** (shell read-through
/// Task 4) — in the `.navigation` item the window's Lock held, so no toolbar
/// position moved. Closed (`lock`) while the piece open in the centre is in
/// read-through, open (`lock.open`) while it is being written.
///
/// It posts only what the window's offer gives it (`ReadThroughOffer
/// .toggleRequest`), as the View menu item and ⌘⌥⇧R do: Start only while the
/// piece's text is in the centre and a Start is allowed, Resume wherever the
/// piece is open. Where there is no offer (the Book, an edition, research,
/// the canvas) or it is refused, it is **drawn but disabled** — the chrome
/// never shifts — and its tooltip says why. Hidden with the toolbar under
/// `⌘\` (`ProjectWindow.windowToolbarIsVisible`).
struct ReadThroughToggle: View {
    let offer: ReadThroughOffer?

    static let startTooltip =
        "Start a read-through: typing is off; comments and decisions stay on. "
            + "Saves a checkpoint. (\u{2318}\u{2325}\u{21E7}R)"
    static let resumeTooltip = "Resume writing (\u{2318}\u{2325}\u{21E7}R)"
    static let noPieceTooltip = "Open a piece to start a read-through."

    /// `lock` in read-through, `lock.open` while writing.
    static func symbol(_ offer: ReadThroughOffer?) -> String {
        offer?.isOn == true ? "lock" : "lock.open"
    }

    /// What a press would post; nil where it is disabled.
    static func request(_ offer: ReadThroughOffer?) -> ReadThrough.Request? {
        offer?.toggleRequest
    }

    /// What a press does and its key — or, disabled, why not.
    static func tooltip(_ offer: ReadThroughOffer?) -> String {
        guard let offer else { return noPieceTooltip }
        if offer.isOn { return resumeTooltip }
        return offer.isEnabled ? startTooltip : (offer.reason ?? noPieceTooltip)
    }

    /// VoiceOver's label: what a press does.
    static func label(_ offer: ReadThroughOffer?) -> String {
        offer?.isOn == true ? "Resume writing" : "Start read-through"
    }

    /// VoiceOver's value: the piece's state.
    static func value(_ offer: ReadThroughOffer?) -> String {
        offer?.isOn == true ? "In read-through" : "Writing"
    }

    var body: some View {
        Button {
            if let request = Self.request(offer) { ReadThrough.post(request) }
        } label: {
            Image(systemName: Self.symbol(offer))
        }
        .disabled(Self.request(offer) == nil)
        .help(Self.tooltip(offer))
        .accessibilityLabel(Self.label(offer))
        .accessibilityValue(Self.value(offer))
        .accessibilityIdentifier("readThrough")
    }
}
