// Maugham/Views/AdmissionSheet.swift
import SwiftUI
import MaughamCore

/// **One device, one sheet** (signed op log P2b, spec §4.1).
///
/// > **Denver’s iPhone wants to write in *Playlist*** — 14 notes waiting.
/// > Label: [Denver ▾]
/// > Code **4F2K** is shown on the device’s Settings too.
/// > [Not now] [Admit]
///
/// Everything it says comes from an `AdmissionRequest`, and what a press MEANS
/// is `AdmissionDecision.outcome`. This view holds one piece of state — what the
/// writer has typed — and hands it back; it writes nothing, reads no folder, and
/// decides nothing it could get wrong in a way a windowless test could not see.
///
/// **The code is shown, never demanded.** There is no field to type it into and
/// no comparison Maugham makes: the writer looks at the phone, looks at this,
/// and decides. Demanding it would turn a labels-only admission into a
/// pretend-cryptographic one — the record proves who SIGNED it and nothing about
/// which hand held the phone, and a matched code would only make the writer more
/// confident of something that was never being proved.
struct AdmissionSheet: View {
    let request: AdmissionRequest
    let projectTitle: String
    /// A refusal from the last attempt, in the error's own words (RULING-7).
    /// The sheet stays up carrying it rather than closing on a write that did
    /// not happen.
    let refusal: String?
    /// True while the admission write is in flight, so a second Admit cannot be
    /// pressed on top of the first.
    let isAdmitting: Bool
    let onAdmit: (String) -> Void
    let onNotNow: () -> Void

    @State private var typedLabel: String

    init(
        request: AdmissionRequest,
        projectTitle: String,
        refusal: String? = nil,
        isAdmitting: Bool = false,
        onAdmit: @escaping (String) -> Void,
        onNotNow: @escaping () -> Void
    ) {
        self.request = request
        self.projectTitle = projectTitle
        self.refusal = refusal
        self.isAdmitting = isAdmitting
        self.onAdmit = onAdmit
        self.onNotNow = onNotNow
        _typedLabel = State(initialValue: request.proposedLabel)
    }

    // MARK: - The copy, as values

    /// *Denver’s iPhone wants to write in Playlist* — the device's own name
    /// where the folder has one, else the code, which is the one thing about it
    /// the writer can check against another screen.
    static func title(request: AdmissionRequest, projectTitle: String) -> String {
        "\(request.displayName) wants to write in \(projectTitle)"
    }

    /// *14 notes waiting* — plural because the count is the whole point of the
    /// line, and "1 notes waiting" is the shape that makes a writer distrust
    /// the number beside it.
    static func waitingLine(count: Int) -> String {
        count == 1 ? "1 note waiting" : "\(count) notes waiting"
    }

    static func codeLine(code: String) -> String {
        "Code \(code) is shown on the device’s Settings too."
    }

    static let labelFieldTitle = "Label"
    static let labelFieldPrompt = "What to call this device’s writer"
    static let knownLabelsTitle = "this is also…"
    static let admitTitle = "Admit"
    static let notNowTitle = "Not now"

    /// **How the known-labels menu is named to the accessibility tree** (macOS
    /// 27 shell slice, Task 4).
    ///
    /// On 27 this `Menu`'s explicit `.accessibilityLabel` arrives as an EMPTY
    /// `accessibilityLabel` beside an `NSAttributedString` `accessibilityTitle`
    /// — so a walk that reads labels and values, as the app's own
    /// `axTexts` reader does, cannot see this control at all. An identifier is
    /// a plain `String` in a single attribute on both this AppKit-backed cell
    /// and the SwiftUI-native nodes beside it, which is what lets ONE test
    /// helper serve this menu and the pass ladder without knowing which is
    /// which. Additive: the label below is untouched and is still what
    /// VoiceOver announces.
    static let knownLabelsIdentifier = "admissionSheet.knownLabels"

    /// What the writer is being told the label is FOR. A label is the author's
    /// word for a person, not the device's name, and the distinction is the
    /// whole of labels-only.
    static let labelExplanation =
        "A label is your word for whoever writes on this device. Two devices "
        + "under one label are one person in this book."

    // MARK: - Drawing it

    private var outcome: AdmissionOutcome {
        AdmissionDecision.outcome(for: request, typedLabel: typedLabel)
    }

    /// Nil unless the typed label would merge this device under a label the
    /// book already has — in which case the sheet says so BEFORE the press,
    /// because a merge is not what "Admit" ordinarily means.
    private var mergeNotice: String? {
        guard case .mergeUnder(let label) = outcome else { return nil }
        return "This device will join \(label), who already writes in this book."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title(request: request, projectTitle: projectTitle))
                .font(.headline)
            Text(Self.waitingLine(count: request.waitingCount))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(
                        Self.labelFieldTitle, text: $typedLabel,
                        prompt: Text(Self.labelFieldPrompt))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(Self.labelFieldTitle))
                    if !request.knownLabels.isEmpty {
                        // A picker rather than a free list: every entry writes
                        // the field, so choosing one and typing it are the same
                        // act and reach `AdmissionDecision.outcome` the same
                        // way. Present only when the book HAS other labels —
                        // an empty menu is a control that explains nothing.
                        Menu {
                            ForEach(request.knownLabels, id: \.self) { label in
                                Button(label) { typedLabel = label }
                            }
                        } label: {
                            Text(Self.knownLabelsTitle)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(Text(Self.knownLabelsTitle))
                        .accessibilityIdentifier(Self.knownLabelsIdentifier)
                    }
                }
                Text(Self.labelExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let mergeNotice {
                    Text(mergeNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Label(Self.codeLine(code: request.code), systemImage: "number")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(Self.notNowTitle, role: .cancel) { onNotNow() }
                    .disabled(isAdmitting)
                Button(Self.admitTitle) { onAdmit(typedLabel) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAdmitting || outcome == .notNow)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
