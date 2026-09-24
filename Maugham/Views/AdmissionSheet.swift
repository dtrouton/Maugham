// Maugham/Views/AdmissionSheet.swift
import SwiftUI
import MaughamCore

/// **One device, one sheet** (signed op log P2b, spec §4.1).
///
/// > **Denver’s iPhone wants to write in *Playlist***
/// > 1 paragraph waiting in “Chapter 3”, and 14 captures in the Inbox
/// > “The rain came in sideways…”
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
    /// The book's manuscript documents, for the piece picker (P3b Task 4).
    /// Empty is a real state — a book with no pieces yet — and the picker says
    /// so rather than drawing an empty list.
    let pieces: [PermitControl.Piece]
    /// **What this book is, asked only when the writer narrows it.**
    ///
    /// Answering costs a walk of every op-log file in the project (*does any
    /// stream here answer to no key*), so it is not paid by the ordinary
    /// admission — which is every admission before this milestone, and still
    /// the common one. It is asked the moment the writer picks a rung that
    /// narrows, and Admit waits for it: the first-narrowing sentence is
    /// something the writer is owed BEFORE they press, not after.
    ///
    /// Nil back means the book could not be read. The sheet then says nothing
    /// it cannot stand behind and lets the act itself refuse — the same sweep
    /// runs inside `DocumentStore.admit`, and its refusal arrives here in the
    /// error's own words.
    let checkTheBook: () async -> PermitControl.BookNarrowing?
    let onAdmit: (String, Permit) -> Void
    let onNotNow: () -> Void

    @State private var typedLabel: String
    @State private var choice: PermitControl.Choice = .wholeBook
    @State private var chosenPieces: Set<String> = []
    /// What the check answered, and nil both before one is made and where the
    /// book could not be read.
    @State private var book: PermitControl.BookNarrowing?
    /// **Whether the check has been MADE**, which is a different fact from
    /// whether it answered — and the difference is a dead end. Keyed on *was it
    /// answered*, a book this Mac cannot read leaves Admit disabled for ever;
    /// keyed on *is one in flight*, the tick between the writer picking a
    /// narrowing rung and the task starting is a window in which they can press
    /// past the sentence they are owed.
    @State private var haveAskedTheBook = false

    init(
        request: AdmissionRequest,
        projectTitle: String,
        refusal: String? = nil,
        isAdmitting: Bool = false,
        pieces: [PermitControl.Piece] = [],
        checkTheBook: @escaping () async -> PermitControl.BookNarrowing? = { nil },
        onAdmit: @escaping (String, Permit) -> Void,
        onNotNow: @escaping () -> Void
    ) {
        self.request = request
        self.projectTitle = projectTitle
        self.refusal = refusal
        self.isAdmitting = isAdmitting
        self.pieces = pieces
        self.checkTheBook = checkTheBook
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
    ///
    /// **Nothing is not a count** (P3b smoke find F10): a stranger asked about
    /// because their device record arrived, with none of their writing, is
    /// told as `AdmissionRequest.nothingYet` rather than *0 notes waiting*.
    static func waitingLine(count: Int) -> String {
        if count <= 0 { return AdmissionRequest.nothingYet }
        return count == 1 ? "1 note waiting" : "\(count) notes waiting"
    }

    /// **What is waiting, in the writer's terms** (P3b smoke find F2): the
    /// request's own description where the loads gave one — *1 paragraph
    /// waiting in “Chapter 3”* — else the plain count, as the sheet always said.
    static func waitingLine(for request: AdmissionRequest) -> String {
        request.described?.line ?? waitingLine(count: request.waitingCount)
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

    /// **Why the label field is empty** when the device's own name is already
    /// somebody's label here (P3b smoke find F1).
    ///
    /// Two Macs sharing a name is the ordinary case, so the sheet must neither
    /// pre-fill the merge nor leave the writer wondering why the name they can
    /// see on the other screen is not in the field. It names both ways on:
    /// a name of their own, or — deliberately — the existing person.
    static func sharedNameNotice(ownName: String, existing: String) -> String {
        "This device calls itself \u{201C}\(ownName)\u{201D}, which is already the "
            + "name of someone who writes in this book. Give whoever writes on it "
            + "a name of their own \u{2014} or, if they are the same person, choose "
            + "\u{201C}\(existing)\u{201D} from \u{201C}\(knownLabelsTitle)\u{201D}."
    }

    /// **What the field holds when the same stranger arrives freshly derived**
    /// (F1/F4 review, Important 1).
    ///
    /// The field is `@State`, seeded once, and a re-derivation swaps the
    /// request under a sheet that keeps its identity — so a proposal the
    /// registry has since withdrawn (a name that became somebody's label a
    /// moment ago) would sit in the field as a merge. Where the writer has not
    /// touched it — it still holds the OLD proposal — it follows the new one;
    /// anything they typed or chose is theirs and is never replaced.
    static func reseeded(
        typed: String, from old: AdmissionRequest, to new: AdmissionRequest
    ) -> String {
        typed == old.proposedLabel ? new.proposedLabel : typed
    }

    /// Drawn while the writer has not yet chosen a label — once they type one
    /// or choose one, the merge notice (or nothing) says what Admit will do.
    static func sharedNameNotice(
        for request: AdmissionRequest, typedLabel: String
    ) -> String? {
        guard let existing = request.sharesItsNameWith,
              let ownName = request.ownName,
              AdmissionDecision.outcome(for: request, typedLabel: typedLabel) == .notNow
        else { return nil }
        return sharedNameNotice(ownName: ownName, existing: existing)
    }

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

    /// The permit the writer has chosen — built by the permit layer, never
    /// compared to a rung here (tripwire 47).
    private var permit: Permit {
        PermitControl.permit(for: choice, pieces: chosenPieces)
    }

    /// What this choice would do to the book, where it would do anything.
    private var narrowingNotice: String? {
        guard let book else { return nil }
        return PermitControl.notice(forGranting: permit, in: book)
    }

    /// **Admit waits for the book to be checked, and only where the choice
    /// narrows it.** A writer must not be able to make a book's first narrowing
    /// in the moment before it has been told what that means.
    ///
    /// Static, so the rule is assertable with no window: a mounted test that
    /// pressed a control and waited for the answer is the shape tripwire 33
    /// forbids, and this is the whole of what the disabled state means.
    static func admitWaits(whileNarrowing narrows: Bool, asked: Bool) -> Bool {
        narrows && !asked
    }

    private var isWaitingForTheBook: Bool {
        Self.admitWaits(whileNarrowing: permit.narrows, asked: haveAskedTheBook)
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
            Text(Self.waitingLine(for: request))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let peek = request.described?.peek {
                // A peek at the words, so the writer can tell whose they are
                // before deciding — never the whole span, and never editable.
                Text(peek)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

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
                if let shared = Self.sharedNameNotice(
                    for: request, typedLabel: typedLabel) {
                    Text(shared)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

            Divider()

            // **What they may write** (P3b Task 4, spec §7.1). Whole book by
            // default, which is what every admission meant before this
            // milestone — so a writer who reads nothing and presses Admit
            // makes exactly the admission P2b made.
            PermitPicker(
                pieces: pieces, choice: $choice, chosenPieces: $chosenPieces)

            if let narrowingNotice {
                Label(narrowingNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button(Self.admitTitle) { onAdmit(typedLabel, permit) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isAdmitting || outcome == .notNow || isWaitingForTheBook)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onChange(of: request) { old, new in
            typedLabel = Self.reseeded(typed: typedLabel, from: old, to: new)
        }
        // Asked when the choice starts narrowing, and never before: the answer
        // is a walk of the project's whole op log, and an ordinary admission
        // owes it nothing.
        .task(id: permit.narrows) {
            guard permit.narrows, !haveAskedTheBook else { return }
            let answer = await checkTheBook()
            book = answer
            haveAskedTheBook = true
        }
    }
}
