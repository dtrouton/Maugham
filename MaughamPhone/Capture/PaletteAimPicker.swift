import SwiftUI
import MaughamCore

/// A capture's optional palette aim: a subject the note is *about* (a palette
/// card's title, or a free-typed new one) plus an optional sense. Threaded into
/// the inbox write as `paletteSubject`/`sense`; the Mac maps `sense` to
/// `PaletteCard.Sense` at promote time (tolerant). Aiming is NEVER required —
/// a nil aim is a plain inbox capture.
struct PaletteAim: Equatable {
    var subject: String
    var sense: String?
}

/// Sheet for setting (or clearing) the capture aim. Presented like
/// `ProjectPickerSheet` so the capture context behind it is preserved.
///
/// The subject list is the project's palette-card titles pulled straight from
/// the already-decoded research tree — `cardTitles(in:)` does NO file I/O, and
/// the sheet holds no download seam. A free-text field lets the writer aim at a
/// subject that has no card yet.
struct PaletteAimPicker: View {
    /// The selected project's in-memory research tree (`manifest.research`).
    let research: [ResearchItem]
    /// The current aim, used to seed the editing state (nil = plain inbox).
    let current: PaletteAim?
    /// Commit callback: nil clears to plain inbox; non-nil sets the aim.
    let onCommit: (PaletteAim?) -> Void

    @State private var subject: String
    @State private var sense: String?
    @Environment(\.dismiss) private var dismiss

    /// The senses as raw strings, DERIVED from the Core vocabulary so a 6th
    /// sense added to `PaletteCard.Sense` automatically appears in the phone aim
    /// picker (never re-typed as a literal — tripwire 19). Plain strings on the
    /// phone; the Mac maps them back to `PaletteCard.Sense` at promote time (the
    /// mapping is the Mac's, the phone just carries the string). `internal`
    /// (not `private`) so `PaletteAimTests` can pin the parity against
    /// `PaletteCard.Sense.allCases`.
    static let senses = PaletteCard.Sense.allCases.map(\.rawValue)

    init(research: [ResearchItem], current: PaletteAim?, onCommit: @escaping (PaletteAim?) -> Void) {
        self.research = research
        self.current = current
        self.onCommit = onCommit
        _subject = State(initialValue: current?.subject ?? "")
        _sense = State(initialValue: current?.sense)
    }

    /// The project's palette-card titles, in manifest order — the direct
    /// `.asset`/`.document` children of the role-first palette group. Pure over
    /// the already-decoded manifest (NO file reads); mirrors the Mac's card
    /// filter in `ProjectStore+Palette.paletteCards()`.
    static func cardTitles(in research: [ResearchItem]) -> [String] {
        PaletteLookup.paletteCards(in: research).map(\.title)
    }

    private var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        onCommit(nil)
                        dismiss()
                    } label: {
                        Label("Plain inbox (no palette aim)", systemImage: "tray")
                    }
                    .buttonStyle(.plain)
                }

                Section("Subject") {
                    TextField("New subject…", text: $subject)
                        .autocorrectionDisabled(false)
                    ForEach(Self.cardTitles(in: research), id: \.self) { title in
                        Button {
                            subject = title
                        } label: {
                            HStack {
                                Text(title).foregroundStyle(.primary)
                                Spacer()
                                if title == trimmedSubject {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Sense (optional)") {
                    senseChips
                }
            }
            .navigationTitle("Palette Aim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Aim") {
                        onCommit(PaletteAim(subject: trimmedSubject, sense: sense))
                        dismiss()
                    }
                    .disabled(trimmedSubject.isEmpty)
                }
            }
        }
    }

    private var senseChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.senses, id: \.self) { name in
                    let selected = (sense == name)
                    Button {
                        // Tap the active chip to clear it — sense stays optional.
                        sense = selected ? nil : name
                    } label: {
                        Text(name.capitalized)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                in: Capsule())
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
