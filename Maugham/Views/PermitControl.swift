// Maugham/Views/PermitControl.swift
import SwiftUI
import MaughamCore

/// **What somebody may write, as a control** (signed op log P3b, spec §7.1).
///
/// Two surfaces ask the same question — the admission sheet, when a device is
/// let in, and People & Devices, when what somebody may write is changed — and
/// they must ask it in the same words and build the same value. So the choice,
/// the piece picker, and the sentence that says what a first narrowing DOES all
/// live here, once.
///
/// **It names no wire word at all, and compares no rung** (tripwires 44 and
/// 47). The ladder is `Permit.Rung`, a chosen rung becomes a permit through
/// `Permit.permit(offering:pieces:)`, and an existing permit comes back through
/// `Permit.rung(of:)` — all three in the permit layer, because a view
/// assembling `Permit.parse(role: Permit.reviewerRole, …)` is a second opinion
/// about what a rung is MADE of, one step before the failure tripwire 47 names.
/// (That was this file's first spelling, and both censuses refused it.)
///
/// What lives here is what the WRITER reads: the three titles, the sentence
/// under each, the piece picker, and the sentence that says what a book's first
/// narrowing does.
enum PermitControl {

    // MARK: - The pieces

    /// One document of the book, as the picker lists it.
    ///
    /// `id` is the document id a permit's scope names — the same string the op
    /// log files are keyed on — and `title` is only ever drawn.
    struct Piece: Identifiable, Equatable, Hashable, Sendable {
        let id: String
        let title: String
        /// **Who the manifest says started it** (`StructureItem.startedBy`,
        /// P3 plan 3 Task 8) — a device id, a CLAIM in an unsigned manifest,
        /// so it is only ever handed to the trust table to be matched
        /// forwards and never believed on its face. Nil for a piece no
        /// creation site recorded. People & Devices reads it to say what a
        /// stranded piece is waiting for; the picker never draws it.
        let startedBy: String?

        init(id: String, title: String, startedBy: String? = nil) {
            self.id = id
            self.title = title
            self.startedBy = startedBy
        }
    }

    /// Every manuscript document in the book, in the binder's own order.
    ///
    /// Groups are not pieces: a permit's scope names documents, and a group is
    /// a place to keep them. Pre-order, so the list reads down the tree the way
    /// the binder draws it.
    static func pieces(in structure: [StructureItem]) -> [Piece] {
        TreeWalk.collect(in: structure) { $0.type == .document }
            .map { Piece(id: $0.id, title: $0.title, startedBy: $0.startedBy) }
    }

    // MARK: - The choice

    /// **The rung the control offers, which is the permit layer's own**
    /// (`Permit.Rung`). A second enum here would be a second opinion about
    /// what the ladder has on it, and the copy in the view file is the one
    /// that does not compile-error when a rung is added.
    typealias Choice = Permit.Rung

    /// **The one build**: a display choice plus a set of pieces becomes a
    /// `Permit`, in the permit layer. This file supplies the words the writer
    /// reads and nothing else about what a rung means (tripwire 44/47 — the
    /// wire vocabulary and the parse are `Permit.swift`'s).
    static func permit(for choice: Choice, pieces: Set<String>) -> Permit {
        Permit.permit(offering: choice, pieces: pieces)
    }

    /// **What an existing permit looks like in this control**, or nil where it
    /// has no shape this build can draw — a role or scope word a later build
    /// invented. A surface meeting nil says so; it must not draw a permit it
    /// cannot represent, because the control would then offer to overwrite a
    /// rung it never showed.
    static func choice(displaying permit: Permit) -> Choice? {
        Permit.rung(of: permit)
    }

    /// The pieces an existing permit names — empty for every permit that is
    /// not about pieces, which is a real state for one of them (*she may write
    /// what she starts*).
    static func pieces(displaying permit: Permit) -> Set<String> {
        Set(permit.wirePieces)
    }

    // MARK: - What the first narrowing does (shared with Task 5's pane)

    /// **What changes about the BOOK the first time anybody in it is anything
    /// less than an author of the whole thing** — the sentence both the
    /// admission sheet and People & Devices show before the writer commits.
    ///
    /// Two facts, and the writer is owed both before they press:
    ///
    /// 1. **Older copies of Maugham stop opening this book.** A build with no
    ///    permit layer cannot judge a line, so it would apply the text this
    ///    book has set aside and re-assert it under its own key. The manifest's
    ///    schema gate is what prevents that, and raising it is what shuts the
    ///    older build out (`DocumentStore.gateOldBuildsOut`).
    /// 2. **A Mac nothing in this book signs for yet starts waiting.** Where
    ///    the book holds an unsigned stream, everything it writes after this
    ///    moment is held on every other machine — until that Mac's first signed
    ///    change syncs here, or, if it signs nothing, until it is sent to the
    ///    Inbox — and nothing it has already written moves, which is the half a
    ///    writer will not assume and must be told. **Both cases, never one**
    ///    (P3c Task 7, Ruling R): it may be a signing Mac whose first seal has
    ///    not synced, so this says what `HeldLines` says about it.
    ///
    /// Pure, with both inputs given rather than looked up, so the same sentence
    /// is decidable with no window and no folder — and so the two callers
    /// cannot say it differently.
    ///
    /// Nil when this is not the book's first narrowing: a book that has been
    /// narrowed before has already paid both costs, and repeating them at every
    /// later change would train the writer to press past the one that matters.
    static func firstNarrowingNotice(
        isTheBooksFirstNarrowing: Bool, holdsAnUnsignedStream: Bool
    ) -> String? {
        guard isTheBooksFirstNarrowing else { return nil }
        var sentence = "This is the first time anyone in this book is anything "
            + "less than an author of the whole of it. Older versions of "
            + "Maugham will no longer open this book."
        if holdsAnUnsignedStream {
            sentence += " And nothing in this book signs for one of the Macs "
                + "writing in it yet: from now on its writing waits on the "
                + "other Macs \u{2014} until "
                + "that Mac\u{2019}s first signed change syncs here, or, if it "
                + "signs nothing, until it is sent to the Inbox. Nothing it has "
                + "already written changes."
        }
        return sentence
    }

    /// What this book's own state says about a narrowing about to be made — the
    /// two inputs `firstNarrowingNotice` takes, gathered together so a surface
    /// asks for them once.
    ///
    /// `holdsAnUnsignedStream` is a fact about FILES (`OpLogStore
    /// .unattributablePositions`), not about this Mac's own enclave: the Mac
    /// that signs nothing is usually somebody else's.
    struct BookNarrowing: Equatable, Sendable {
        /// Has anybody in this book already been given anything less than the
        /// whole of it? (`TrustTable.hasNarrowingPermits`.)
        var alreadyNarrowed: Bool
        /// Does the book hold a stream no key can name?
        var holdsAnUnsignedStream: Bool

        init(alreadyNarrowed: Bool = false, holdsAnUnsignedStream: Bool = false) {
            self.alreadyNarrowed = alreadyNarrowed
            self.holdsAnUnsignedStream = holdsAnUnsignedStream
        }
    }

    /// The notice for a permit about to be written into a book in this state.
    ///
    /// The narrowing question is asked of the permit layer (`Permit.narrows`)
    /// and never by comparing a rung here.
    static func notice(
        forGranting permit: Permit, in book: BookNarrowing
    ) -> String? {
        firstNarrowingNotice(
            isTheBooksFirstNarrowing: permit.narrows && !book.alreadyNarrowed,
            holdsAnUnsignedStream: book.holdsAnUnsignedStream)
    }

    /// **Which acknowledged-loss count a confirmation about THIS permit
    /// carries** (fix round 1, Minor 1) — the same question, asked of the same
    /// place.
    ///
    /// A permit change that narrows takes the book's photograph
    /// (`everyExpectedStream`) as well as the subject's own mark, so what it
    /// decides without is the book's. One that narrows nobody sweeps the
    /// subject's streams alone, and naming a loss under somebody else's
    /// machine would be an over-statement on the one screen that must not make
    /// them.
    ///
    /// The narrowing question is the permit layer's (`Permit.narrows`), asked
    /// here exactly as `notice` asks it and never by comparing a rung.
    static func lostHistory(
        forGranting permit: Permit, subject: Int, book: Int
    ) -> Int {
        permit.narrows ? book : subject
    }
}

// The words the writer reads for each rung — `Permit.Rung.title`,
// `.explanation` and `.picksPieces` — live in MaughamCore's `PermitWords.swift`
// (P3c plan 2, Task 1) so the phone says the same words (tripwire 19).

/// **The control itself** — a rung, and the pieces where the rung needs them.
///
/// It draws a choice and reports it; it builds no permit of its own (the host
/// asks `PermitControl.permit(for:pieces:)`) and it writes nothing. Both hosts
/// give it the same two bindings, so the sheet and the pane cannot drift into
/// asking the question two ways.
struct PermitPicker: View {
    let pieces: [PermitControl.Piece]
    @Binding var choice: PermitControl.Choice
    @Binding var chosenPieces: Set<String>

    /// Named so a test can find the control without pressing it (tripwire 33).
    static let choiceIdentifier = "permitControl.choice"
    static let title = "May write"
    static let piecesTitle = "Pieces"
    /// What the empty piece list means, which is a real state and not an error:
    /// *she may write what she starts*.
    static let noPiecesChosen = "No pieces yet — they can write anything they start."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(Self.title, selection: $choice) {
                ForEach(PermitControl.Choice.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilityLabel(Text(Self.title))
            .accessibilityIdentifier(Self.choiceIdentifier)
            Text(choice.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if choice.picksPieces {
                Text(Self.piecesTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pieces.isEmpty {
                    Text(Self.noPiecesChosen)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(pieces) { piece in
                                Toggle(piece.title, isOn: Binding(
                                    get: { chosenPieces.contains(piece.id) },
                                    set: { on in
                                        if on { chosenPieces.insert(piece.id) }
                                        else { chosenPieces.remove(piece.id) }
                                    }))
                            }
                        }
                        .padding(.leading, 4)
                    }
                    .frame(maxHeight: 120)
                    if chosenPieces.isEmpty {
                        Text(PermitPicker.noPiecesChosen)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
