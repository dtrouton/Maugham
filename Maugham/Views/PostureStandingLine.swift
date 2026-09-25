import SwiftUI
import MaughamCore

/// **Why the words in front of her are not hers to change** (signed op log
/// P3c Task 3, spec §8) — the editor's standing line.
///
/// The membrane refuses a keystroke silently (`EditorEditPolicy`); this is the
/// sentence that says why, over the editor, for as long as it is true. One
/// sentence per `Posture.Reason`, and NOTHING where there is no reason — an
/// author inside her own words, and `Posture.settling`, whose answer is still
/// on its way and so has nothing to name (a lock the writer can see the reason
/// for a frame late is fine; a reason that is not yet true is not).
///
/// Keyed on `reason`, never on `isRestricted` (controller ruling E): a posture
/// can be restricted (a pieces author may not dispose of notes in the piece she
/// started, ruling F) with nothing to say about the words she is looking at,
/// and it can offer every writing verb with something to say (Option A's
/// `.waitingToBeClaimed`, P3c plan 2).
///
/// The pure half (`line`, the sentences) is pinned in
/// `PostureStandingLineTests`; the view below draws it and presses one verb,
/// the root's **Edit Anyway** (plan ruling R2), through the door.
enum PostureStandingLine {

    /// What the line says, for which document.
    struct Line: Equatable {
        enum Kind: Equatable {
            /// A reviewer (or a narrowed actor): notes, never the text.
            case reviewer
            /// An author of some pieces, outside them.
            case notYourPiece(title: String)
            /// The root, yielding on somebody else's piece.
            case yielding(to: String)
            /// A permit this build cannot read.
            case cannotJudge
            /// **Her own words, in a piece she started that nobody has said
            /// is hers yet** (P3c plan 2, Option A). Not a refusal — she
            /// writes — and it names who would end the wait.
            case waitingToBeClaimed
        }

        /// Why the words are not hers, or nil where they are and the line is
        /// here only for `keptInHistory`.
        let kind: Kind?
        /// The document the line is about — what Edit Anyway lifts.
        let docId: String
        /// **Some of what she wrote here is kept in History** (controller
        /// ruling K): this document holds set-aside or held lines in this
        /// device's OWN files. Decided from the count and never from the
        /// reason — a reviewer's own earlier prose, and a promoted author's
        /// lines from while she was demoted, are both still there.
        var keptInHistory: Bool = false

        /// Only the root's cooperative yield can be lifted from here; every
        /// other reason is a permit, and a permit is the root's to change.
        var offersEditAnyway: Bool {
            if case .yielding? = kind { return true }
            return false
        }

        /// The sentence. `root` is the label of the root this Mac is on, when
        /// it has been read; the reviewer's sentence names it.
        func sentence(root: String?) -> String? {
            guard let kind else { return nil }
            switch kind {
            case .reviewer:
                let whom = root ?? "the book’s author"
                return "You’re reviewing this book — your notes reach \(whom); "
                    + "the text is theirs."
            case .notYourPiece(let title):
                return "“\(title)” isn’t one of your pieces — you can leave notes."
            case .yielding(let name):
                return "This is \(name)’s piece."
            case .cannotJudge:
                return "This Mac can’t read the permission it was given — "
                    + "update Maugham to write here."
            case .waitingToBeClaimed:
                return Document.waitingToBeToldItIsYours(root: root)
            }
        }
    }

    /// The line for `posture` over the document `docId` titled `title`, or nil
    /// where the posture names no reason AND none of this device's own lines
    /// is kept in History. `ownLinesKeptInHistory` is the document's stored
    /// count (`Document.ownLinesKeptInHistory`), zero where it is not open.
    static func line(
        for posture: Posture, title: String, docId: String,
        ownLinesKeptInHistory: Int = 0
    ) -> Line? {
        let kind: Line.Kind?
        switch posture.reason {
        case nil: kind = nil
        case .reviewer: kind = .reviewer
        case .notYourPiece: kind = .notYourPiece(title: title)
        case .yielding(let name): kind = .yielding(to: name)
        case .cannotJudge: kind = .cannotJudge
        // P3c plan 2, Option A: not a refusal — her words are offered — and
        // the line says who would end the wait. It goes the moment the root
        // answers *Theirs*: the permit change re-stamps and bumps the epoch,
        // and her posture then carries no reason at all.
        case .waitingToBeClaimed: kind = .waitingToBeClaimed
        }
        let kept = ownLinesKeptInHistory > 0
        guard kind != nil || kept else { return nil }
        return Line(kind: kind, docId: docId, keptInHistory: kept)
    }

    /// The clause for `Line.keptInHistory`; the view pairs it with a History
    /// link.
    static let keptInHistoryClause = "Some of what you wrote here is kept in History."

    /// **⇧⌘S over text this Mac may not change** (plan ruling R5): said in
    /// place of the label sheet. ⌘S itself says nothing — it flashes, and
    /// writes nothing.
    static let checkpointRefusal =
        "This text isn’t yours to change, so a checkpoint here would mark nothing of yours."

    /// The label of the root this device is on — read OFF the main actor, the
    /// one registry read the line makes, and only for the two sentences that
    /// name it (the reviewer's, and Option A's *waiting to be told it is
    /// yours*). Nil where the registry does not read or names no root; the
    /// sentence then says *the book's author*. The same read as the pane's
    /// waiting sentence (`Document.rootLabel(in:identities:cache:)`), so the
    /// line over her editor and the placeholder in front of an unopened piece
    /// cannot name two different roots.
    @MainActor
    static func rootLabel(projectURL: URL) async -> String? {
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        return await Task.detached(priority: .utility) { () -> String? in
            Document.rootLabel(in: projectURL, identities: identities, cache: cache)
        }.value
    }

    /// Does this line's sentence name the root? The view reads the label only
    /// where it does.
    static func namesTheRoot(_ kind: Line.Kind?) -> Bool {
        switch kind {
        case .reviewer?, .waitingToBeClaimed?: return true
        default: return false
        }
    }
}

/// The thin view: one line in the status footer's register, over the editor.
struct PostureStandingLineView: View {
    let line: PostureStandingLine.Line
    let documentStore: DocumentStore

    @State private var rootLabel: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .regular))
            // No `fixedSize(vertical:)`: this is a top inset on the writing
            // column, and an unbreakable height there grows the split view
            // (`ViewOnlyShareNotice`'s measured reason).
            if let sentence = line.sentence(root: rootLabel) {
                Text(sentence)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if line.keptInHistory {
                Text(PostureStandingLine.keptInHistoryClause)
                    .lineLimit(2)
                Button("History") {
                    MaughamEvent.postDetailSegment(.history)
                }
                .buttonStyle(.link)
            }
            if line.offersEditAnyway {
                Button("Edit Anyway") {
                    documentStore.overrideYield(docId: line.docId)
                }
                .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .task(id: RootReadKey(kind: line.kind, epoch: documentStore.postureEpoch)) {
            guard PostureStandingLine.namesTheRoot(line.kind) else { return }
            rootLabel = await PostureStandingLine.rootLabel(
                projectURL: documentStore.projectURL)
        }
    }

    private struct RootReadKey: Equatable {
        let kind: PostureStandingLine.Line.Kind?
        let epoch: Int
    }
}
