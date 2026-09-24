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
/// Keyed on `reason`, never on `isRestricted` (controller ruling E): an author
/// of some pieces inside her own piece is restricted — she may not start a
/// piece — and there is nothing to say about the words she is looking at.
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
        }

        let kind: Kind
        /// The document the line is about — what Edit Anyway lifts.
        let docId: String

        /// Only the root's cooperative yield can be lifted from here; every
        /// other reason is a permit, and a permit is the root's to change.
        var offersEditAnyway: Bool {
            if case .yielding = kind { return true }
            return false
        }

        /// The sentence. `root` is the label of the root this Mac is on, when
        /// it has been read; the reviewer's sentence names it.
        func sentence(root: String?) -> String {
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
            }
        }
    }

    /// The line for `posture` over the document `docId` titled `title`, or nil
    /// where the posture names no reason.
    static func line(for posture: Posture, title: String, docId: String) -> Line? {
        guard let reason = posture.reason else { return nil }
        let kind: Line.Kind
        switch reason {
        case .reviewer: kind = .reviewer
        case .notYourPiece: kind = .notYourPiece(title: title)
        case .yielding(let name): kind = .yielding(to: name)
        case .cannotJudge: kind = .cannotJudge
        }
        return Line(kind: kind, docId: docId)
    }

    /// **⇧⌘S over text this Mac may not change** (plan ruling R5): said in
    /// place of the label sheet. ⌘S itself says nothing — it flashes, and
    /// writes nothing.
    static let checkpointRefusal =
        "This text isn’t yours to change, so a checkpoint here would mark nothing of yours."

    /// The label of the root this device is on — read OFF the main actor, the
    /// one registry read the line makes, and only for the reviewer's sentence.
    /// Nil where the registry does not read or names no root; the sentence
    /// then says *the book's author*.
    @MainActor
    static func rootLabel(projectURL: URL) async -> String? {
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        return await Task.detached(priority: .utility) { () -> String? in
            guard let verified = try? TrustResolution.resolveVerified(
                projectURL: projectURL, identities: identities, cache: cache),
                  let root = verified.table.myRoot
            else { return nil }
            return verified.registry.person(root)?.label
        }.value
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
            Text(line.sentence(root: rootLabel))
                .lineLimit(2)
                .truncationMode(.middle)
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
            guard case .reviewer = line.kind else { return }
            rootLabel = await PostureStandingLine.rootLabel(
                projectURL: documentStore.projectURL)
        }
    }

    private struct RootReadKey: Equatable {
        let kind: PostureStandingLine.Line.Kind
        let epoch: Int
    }
}
