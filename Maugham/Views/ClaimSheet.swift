// Maugham/Views/ClaimSheet.swift
import SwiftUI
import MaughamCore

/// **One book, one question** (signed op log P2b Task 8, spec §5).
///
/// > **Is this book yours?**
/// > This book’s history was written by devices this Mac doesn’t know
/// > (Denver’s old MacBook, Denver’s iPhone). Is it yours?
/// > [Not mine] [Claim]
///
/// Everything it says comes from a `ClaimOffer`, and what a press MEANS is
/// `RegistryAdmission.claim`. This view holds no state at all: it draws a value
/// and calls one of two closures.
///
/// **Both consequences are on screen before either press**, because the two
/// answers are not symmetrical. Claim writes two signed records and there is no
/// way back through the app; *Not mine* writes nothing and leaves the book
/// exactly as decision B3 already reads it. A writer who cannot tell which is
/// the reversible one will press the wrong one.
struct ClaimSheet: View {
    let offer: ClaimOffer
    let projectTitle: String
    /// A refusal from the last attempt, in the error's own words (RULING-7) —
    /// the sheet stays up carrying it rather than closing on a write that did
    /// not happen.
    let refusal: String?
    /// True while the claim is being written, so a second Claim cannot be
    /// pressed on top of the first.
    let isClaiming: Bool
    let onClaim: () -> Void
    let onNotMine: () -> Void

    init(
        offer: ClaimOffer,
        projectTitle: String,
        refusal: String? = nil,
        isClaiming: Bool = false,
        onClaim: @escaping () -> Void,
        onNotMine: @escaping () -> Void
    ) {
        self.offer = offer
        self.projectTitle = projectTitle
        self.refusal = refusal
        self.isClaiming = isClaiming
        self.onClaim = onClaim
        self.onNotMine = onNotMine
    }

    /// *Is this book yours?* — the book named, because a writer with three
    /// windows open is being asked about one of them.
    static func title(projectTitle: String) -> String {
        "Is \(projectTitle) yours?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title(projectTitle: projectTitle))
                .font(.headline)
            Text(offer.question)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(ClaimDecision.claimConsequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ClaimDecision.notMineConsequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(ClaimDecision.notMineTitle, role: .cancel) { onNotMine() }
                    .disabled(isClaiming)
                Button(ClaimDecision.claimTitle) { onClaim() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isClaiming)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
