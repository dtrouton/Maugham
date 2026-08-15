import SwiftUI
import MaughamCore

/// **Review's centre column: the pieces × passes board** (M3 P1, routed in
/// Task 6 and filled in Task 7).
///
/// One row per node of the manuscript (`ReviewBoardRows`, which keeps the
/// groups), one column per `ProjectManifest.effectiveReviewPasses` entry, and a
/// chip at every intersection saying where that piece stands on that pass. It
/// is the layer between the corkboard — which says what the project IS — and
/// the compiled book, which says what it will look like: this one says what is
/// left to do to it.
///
/// **It takes values, never the store** (tripwire 4). The pane's whole input is
/// a title, a structure array and a pass list, all read off `manifest` at the
/// one mount site in `ProjectWindow.manuscriptEditor`. Nothing on the body path
/// can reach a `Document`, the disk, or a word-count cache, so a board of two
/// hundred rows costs two hundred dictionary lookups and no I/O — and the whole
/// surface is mountable in a test with no project on disk at all, which is what
/// `ReviewBoardPaneTests` does.
///
/// **The chips are `Button`s and they now do the two things a reviewer wants of
/// a cell** (Task 8). A CLICK opens that piece through that pass —
/// `onNavigate(pieceId, passId)`, whose payload is the chip's OWN identity,
/// taken from the row and column it was drawn in and never read back out of any
/// selection state. A right-click offers the four states
/// (`ReviewBoardChipVerbs`), and choosing one calls `onSetState`.
///
/// **Both are closures, and neither of them decides anything.** The pane still
/// holds no store (tripwire 4, and `ReviewBoardPaneTests`' census): what a
/// navigation MEANS — which subject the window takes, which pass it remembers —
/// belongs to the mount in `ProjectWindow.manuscriptEditor`, and so does the
/// `ProjectStore.setPassState` call. What the board knows is which cell was
/// pressed. In particular nothing here writes the window's PERSONA: the board is
/// a surface Review shows, never a thing that decides Review is showing
/// (`ReviewBoardRoutingTests.test_theBoardsOwnFileWritesNoPersona`).
///
/// **A reference row offers neither** — no chips, so no click and no verbs. Its
/// passes live in the project it points at, and a control here would be a
/// decision made in the wrong window.
///
/// Nothing about pass ORDER is offered here: the board says where each piece
/// stands, and the advisory nudge about which pass to run next is the queue
/// pane's (M3 P2).
///
/// **Two scrolling axes, neither of them the window's.** A project with a dozen
/// passes is wider than the column, so the whole grid sits in a horizontal
/// `ScrollView` and the rows inside it in a vertical one; the pane itself never
/// grows past the column it is given. It is a `ScrollView` + `LazyVStack` and
/// not a `List` on purpose: a `List` mounts an `NSTableView`, and the board's
/// structural reading in `ReviewBoardRoutingTests.boardScroller` — a scroll
/// view holding neither a table nor the writer's text — is what Task 6's whole
/// routing suite hangs on. A lazy stack also keeps the row views cheap on a
/// long manuscript without the table's row-reuse contract.
struct ReviewBoardPane: View {
    let title: String
    let structure: [StructureItem]
    let passes: [ReviewPass]
    /// A chip was clicked: `(pieceId, passId)`, the cell's own identity.
    let onNavigate: (String, String) -> Void
    /// A chip's menu ruled on a pass: `(pieceId, passId, state)`. `nil` is
    /// untouched — the store verb removes the key rather than storing a fourth
    /// state, exactly as `PassLadder.onSet` does.
    let onSetState: (String, String, PassState?) -> Void

    /// The menu behind every chip, over this pane's own `onSetState`. Built per
    /// access like `BinderView.treeVerbs`: it is one closure in a wrapper and
    /// nothing in it is state.
    private var verbs: ReviewBoardChipVerbs {
        ReviewBoardChipVerbs(onSetState: onSetState)
    }

    // MARK: - Metrics

    /// The narrowest the piece column is allowed to get. Below this the board
    /// scrolls horizontally rather than squeezing titles to nothing — chapter
    /// names are how a reviewer finds the row they mean.
    static let minimumTitleColumnWidth: CGFloat = 200
    /// One pass column. Wide enough for a short pass name ("Copyedit") to sit
    /// over its chips without truncating at the usual sizes.
    static let passColumnWidth: CGFloat = 92
    private static let horizontalPadding: CGFloat = 10
    private static let groupIndent: CGFloat = 14
    private static let pieceRowHeight: CGFloat = 30
    /// The reference row is deliberately shorter than a piece row: it carries
    /// no chips and no decision, and its thinness is what says so at a glance.
    private static let referenceRowHeight: CGFloat = 22

    /// The width the grid wants: the narrowest usable piece column plus every
    /// pass column. Wider than the pane means the pane scrolls; narrower means
    /// the slack goes to the piece column (see `board`).
    static func intrinsicWidth(passCount: Int) -> CGFloat {
        minimumTitleColumnWidth + CGFloat(passCount) * passColumnWidth
    }

    private func titleColumnWidth(in width: CGFloat) -> CGFloat {
        max(Self.minimumTitleColumnWidth,
            width - CGFloat(passes.count) * Self.passColumnWidth)
    }

    // MARK: - Body

    var body: some View {
        let rows = ReviewBoardRows.derive(structure: structure)
        return VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to review yet", systemImage: "checklist")
                } description: {
                    Text("Add chapters or pieces and their review passes appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                board(rows: rows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
        .padding(8)
    }

    /// The grid. `GeometryReader` is here for one reason: the content is as
    /// wide as the grid needs OR as wide as the column, whichever is greater —
    /// so a narrow column scrolls and a wide one hands its slack to the piece
    /// titles instead of leaving a gutter of dead space beside the chips.
    private func board(rows: [ReviewBoardRows.Row]) -> some View {
        GeometryReader { proxy in
            let width = max(Self.intrinsicWidth(passCount: passes.count),
                            proxy.size.width)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeaders(width: width)
                    Divider()
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                rowView(row, width: width)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columnHeaders(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Piece")
                .padding(.horizontal, Self.horizontalPadding)
                .frame(width: titleColumnWidth(in: width), alignment: .leading)
            ForEach(passes) { pass in
                Text(pass.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.passColumnWidth)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func rowView(_ row: ReviewBoardRows.Row, width: CGFloat) -> some View {
        switch row.kind {
        case .group(let depth):
            groupRow(row.item, depth: depth, width: width)
        case .piece:
            pieceRow(row.item, width: width)
        case .reference:
            referenceRow(row.item, width: width)
        }
    }

    private func groupRow(_ item: StructureItem, depth: Int, width: CGFloat) -> some View {
        Text(item.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.leading, Self.horizontalPadding + Self.groupIndent * CGFloat(depth))
            .padding(.trailing, Self.horizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .frame(width: width, alignment: .leading)
    }

    private func pieceRow(_ item: StructureItem, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(width: titleColumnWidth(in: width), alignment: .leading)
            ForEach(passes) { pass in
                chip(item: item, pass: pass)
                    .frame(width: Self.passColumnWidth)
            }
        }
        .frame(width: width, height: Self.pieceRowHeight, alignment: .leading)
    }

    /// A Collection piece that IS another project. Thin, chip-less, and it says
    /// why: this manifest does not hold that project's pass states, so a row of
    /// controls here would be a decision made in the wrong window.
    private func referenceRow(_ item: StructureItem, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.forward.app")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            Text(item.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("reviewed in its own project")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(width: width, height: Self.referenceRowHeight, alignment: .leading)
    }

    /// One cell. **The two ids the verbs and the click carry are the ones this
    /// call was drawn with** — `item.id` from the row, `pass.id` from the
    /// column — so a chip cannot act on whatever the window happens to have
    /// selected. That is T3's rule about a payload, and on a grid it is not
    /// theoretical: every chip on the board is looking at a different piece from
    /// the one the subject names.
    private func chip(item: StructureItem, pass: ReviewPass) -> some View {
        let state = item.passStates?[pass.id]
        return Button {
            onNavigate(item.id, pass.id)
        } label: {
            Image(systemName: ReviewBoardChip.symbol(for: state))
                .imageScale(.large)
                .foregroundStyle(StatusSwatch.color(for: ReviewBoardChip.status(for: state)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ReviewBoardChip.label(piece: item.title, pass: pass, state: state))
        .accessibilityLabel(ReviewBoardChip.label(piece: item.title, pass: pass, state: state))
        .contextMenu {
            ForEach(verbs.chipMenuItems(for: item.id, passId: pass.id, current: state)) { verb in
                Button {
                    verb.perform()
                } label: {
                    // The current state is checkmarked. A `Label` rather than a
                    // `Toggle`: the four verbs are a choice among states, and a
                    // menu of toggles reads as four independent switches.
                    if verb.isCurrent {
                        Label(verb.title, systemImage: "checkmark")
                    } else {
                        Text(verb.title)
                    }
                }
            }
        }
    }
}

/// **The four things a reviewer can say about one cell** (M3 P1 Task 8) — the
/// chip's right-click menu, as values.
///
/// **Exposed, and a value type, because `.contextMenu` is headless-unreachable.**
/// SwiftUI builds that `NSMenu` on the right-click itself, so a test can neither
/// see the items nor press one (`BinderView.linkResearchVerb`'s discipline, and
/// `PlanTreeStructureCreationTests`' note on this SDK). The menu's whole truth
/// table therefore lives in `chipMenuItems(for:passId:current:)`, which
/// `ReviewBoardPaneTests` drives directly: the alternative is a menu asserted
/// nowhere, which is how a verb that writes the wrong cell ships green.
///
/// The verbs are the ladder's four — `PassLadder`'s own titles, read rather than
/// restated, so the writer sets a state by one name in the Inspector and the
/// board's menu calls it the same thing.
struct ReviewBoardChipVerbs {
    /// `(pieceId, passId, state)` — the pane's own closure, forwarded. Nothing
    /// here calls a store: which channel a write goes through is the mount's
    /// decision (tripwire 4).
    let onSetState: (String, String, PassState?) -> Void

    /// One menu item: what it says, whether it is where the piece stands now,
    /// and what pressing it does.
    struct ChipVerb: Identifiable {
        /// The state this verb sets. `nil` is untouched — the store verb
        /// removes the key.
        let state: PassState?
        let title: String
        /// Whether this is the state the cell is in. Exactly one verb carries
        /// it, or none — see `chipMenuItems`.
        let isCurrent: Bool
        let perform: () -> Void

        var id: String { title }
    }

    /// The states a writer can choose, in the ladder's order — untouched first,
    /// because clearing a pass is a real ruling and burying it under the three
    /// positive ones makes it look like an absence.
    static let offeredStates: [PassState?] = [nil, .inProgress, .done, .skipped]

    /// The menu for the cell `(piece, passId)`, currently standing at `current`.
    ///
    /// **`.unknown` shows all four UNCHECKED, and that is the honest reading.**
    /// A state written by a newer build is not one of these four, so checkmarking
    /// any of them would claim the piece stands somewhere it does not. The chip
    /// still DRAWS the unknown (its own glyph and its raw value, `ReviewBoardChip`),
    /// so what the writer sees is "the board knows something I cannot set from
    /// here" — and choosing one of the four replaces it, which is the only thing
    /// this build can honestly offer. `PassLadder`'s picker keeps a fifth row for
    /// the raw value instead, because a `Picker`'s selection must match a tag or
    /// it renders blank; a menu of verbs has no such constraint, and a verb that
    /// re-set the unknown value would be a control whose only effect is to look
    /// like one.
    func chipMenuItems(for piece: String, passId: String,
                       current: PassState?) -> [ChipVerb] {
        Self.offeredStates.map { state in
            ChipVerb(
                state: state,
                title: ReviewBoardChip.stateTitle(for: state),
                isCurrent: state == current,
                perform: { onSetState(piece, passId, state) })
        }
    }
}

/// **What one cell of the board looks like** (M3 P1 Task 7) — the glyph, the
/// colour and the words for a single `(piece, pass)` state.
///
/// Split out of the pane's body so the truth table is assertable without
/// mounting anything, and kept in one place so the chip, its tooltip and its
/// VoiceOver label can never disagree about what a cell says.
enum ReviewBoardChip {

    /// **The chip's colour is the projection, applied to one cell.**
    ///
    /// Not a second switch over `PassState`: this asks `ReviewStatus.derived`
    /// what it would say about a project with exactly this one pass in exactly
    /// this state, which is precisely what the chip means. So the board's
    /// colours cannot drift from the status dots in the tree, the corkboard and
    /// the inspector — the rules for `.skipped` (complete), `.unknown` (touched
    /// but never complete) and untouched (draft) are read from the one place
    /// that owns them rather than restated here, where a copy would go stale
    /// the first time a case is added.
    static func status(for state: PassState?) -> ReviewStatus {
        ReviewStatus.derived(
            passStates: state.map { [oneCellPassID: $0] },
            passes: [ReviewPass(id: oneCellPassID, name: "")],
            legacyStatus: nil)
    }

    private static let oneCellPassID = "cell"

    /// **No `default:`** — a fifth `PassState` must be given a glyph here
    /// rather than silently inheriting another state's.
    static func symbol(for state: PassState?) -> String {
        switch state {
        case .none: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        // A state a newer build wrote and this one cannot read: it is honestly
        // a question mark, never a blank cell that would read as untouched.
        case .unknown: return "questionmark.circle"
        }
    }

    /// The state in words, in the SAME spelling the inspector's ladder offers
    /// — `PassLadder`'s own titles, because the writer sets a state by one name
    /// and must not read it back under another.
    static func stateTitle(for state: PassState?) -> String {
        switch state {
        case .none: return PassLadder.untouchedTitle
        case .inProgress: return PassLadder.inProgressTitle
        case .done: return PassLadder.doneTitle
        case .skipped: return PassLadder.skipTitle
        case .unknown(let raw): return raw
        }
    }

    /// The chip's tooltip and its VoiceOver label. A chip is a glyph in a grid,
    /// so on its own it says nothing aloud: the label names the piece and the
    /// pass as well as the state, because a reviewer arrowing through the board
    /// needs to know which cell they are in.
    static func label(piece: String, pass: ReviewPass, state: PassState?) -> String {
        "\(piece) — \(pass.name): \(stateTitle(for: state))"
    }
}
