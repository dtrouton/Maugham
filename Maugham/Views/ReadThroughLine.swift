import SwiftUI
import AppKit

/// **The quiet line over a piece in read-through** (shell read-through Task
/// 3): "In read-through · typing is off", and the one press back to writing.
/// Plain secondary text over the editor, as `ReadingLanguageLine` is, mounted
/// beside it in `EditorHost`'s top inset and inside `.id(path)`, so a piece
/// flip tears it down. Not toolbar chrome: in ⌘\ focus mode it is the only
/// thing over the text that says so.
///
/// A piece whose checkpoint was not saved says that instead of "typing is
/// off", with **Save one** beside Resume writing (`ReadThroughOffer
/// .saveCheckpointRequest`). The buttons post only what the offer gives them,
/// and they always stay: only the words shorten (`ViewThatFits`, three widths).
///
/// It reads the control (`EditorControl.readThroughLineOffer(docId:)`) and
/// feeds nothing back (tripwire 6). A refused keystroke pulses it
/// (`TypingRefusedPulse`).
///
/// **Over a read-through piece's research** (a note, table or card, in the
/// centre or pulled up) the same line names the piece — "“Alpha” is in
/// read-through" — and its Resume writing resumes THAT piece
/// (`ReadThroughRefusal.resumeOffer`, whose `pieceTitle` it reads).
struct ReadThroughLine: View {
    let offer: ReadThroughOffer
    /// The hosting window, for the typing-refused pulse's key-window scope.
    var window: NSWindow? = nil

    static let lead = "In read-through"
    static let typingIsOff = "typing is off"
    static let noCheckpoint = "no checkpoint was saved"
    static let resumeTitle = "Resume writing"
    static let saveTitle = "Save one"

    /// The full line: the lead and what the state means now.
    static func fullText(lacksCheckpoint: Bool) -> String {
        "\(lead) \u{00b7} \(lacksCheckpoint ? noCheckpoint : typingIsOff)"
    }

    /// What VoiceOver hears, as one sentence (two with a missing checkpoint).
    static func accessibilityText(lacksCheckpoint: Bool) -> String {
        "In read-through. Typing is off." + (lacksCheckpoint ? " No checkpoint was saved." : "")
    }

    /// The lead for an offer: the piece named where it is not the one open
    /// (its research is in front of the writer).
    static func lead(for offer: ReadThroughOffer) -> String {
        offer.pieceTitle.map { "\u{201C}\($0)\u{201D} is in read-through" } ?? lead
    }

    /// The full line for an offer.
    static func fullText(for offer: ReadThroughOffer) -> String {
        offer.pieceTitle == nil ? fullText(lacksCheckpoint: offer.lacksCheckpoint) : lead(for: offer)
    }

    /// What VoiceOver hears for an offer.
    static func accessibilityText(for offer: ReadThroughOffer) -> String {
        offer.pieceTitle == nil ? accessibilityText(lacksCheckpoint: offer.lacksCheckpoint)
            : lead(for: offer) + ". Its research can be read, not changed."
    }

    var body: some View {
        HStack(spacing: 8) {
            // Three widths: the whole line, the lead, and the lead cut short
            // — the last is flexible, so the buttons always stay whole.
            ViewThatFits(in: .horizontal) {
                text(Self.fullText(for: offer)).fixedSize()
                text(Self.lead(for: offer)).fixedSize()
                text(Self.lead(for: offer)).truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityText(for: offer))
            Spacer(minLength: 0)
            if let save = offer.saveCheckpointRequest {
                Button(Self.saveTitle) { ReadThrough.post(save) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .fixedSize()
                    .help("Save a checkpoint of the text as it stands")
            }
            if let resume = offer.resumeRequest {
                Button(Self.resumeTitle) { ReadThrough.post(resume) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .fixedSize()
                    .help("Turn typing back on (\u{2318}\u{2325}\u{21E7}R)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .modifier(TypingRefusedPulse(window: window))
        .help("Typing is off while you read it through. Comments, suggestions "
              + "and accepting or rejecting them still work.")
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// **The tree's lock on a piece in read-through**: a small `lock.fill` on the
/// document's row, after the stage dot and the figure count and before the
/// presence dot, so no title moves and the presence dot keeps the trailing
/// edge. Secondary ink, primary on a selected row (as `ResolvePresenceMark`
/// does). Takes no hits (tripwire 9): it is a mark, never a control. No
/// roll-up onto a Part or the Book.
struct ReadThroughMark: View {
    static let label = "In read-through"
    static let symbol = "lock.fill"
    static let pointSize: CGFloat = 9

    let isOn: Bool

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if isOn {
            Image(systemName: Self.symbol)
                .font(.system(size: Self.pointSize))
                .foregroundStyle(prominence == .increased
                                 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(Self.label)
        }
    }
}
