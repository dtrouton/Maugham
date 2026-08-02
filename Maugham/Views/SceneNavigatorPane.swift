import SwiftUI
import MaughamCore

/// The Scenes segment — a screenplay's binder.
///
/// A screenplay is ONE `.fountain` (the Phase 3d invariant), so this pane is not
/// a tree of documents: it is a slugline navigator inside a single file, and
/// clicking a row scrolls the editor rather than opening anything. That is why
/// its rows are `Button`s and carry no selection.
///
/// **It also carries the project row** (persona shell spec §3.3), and it is the
/// only one of the three surfaces that does where that row is not simply another
/// row of the same kind. `BinderSegment.documentHome(for: .screenplay)` is
/// `.scenes` and no persona offers a screenplay the `.manuscript` segment, so
/// `BinderView` — the row's other non-collection home — is never mounted for a
/// screenplay at all: without a row here `BinderSubject.project` is
/// **unconstructible in a screenplay**, and since slice 1 deleted
/// `StatementPane`'s `[Chapter | Project]` switch that means project-scope Intent
/// is unreachable. It can hide the writer's own prose, not just a blank pane:
/// `legacyCraftIntentByScope` adopts a pre-M1A whole-script craft-intent note
/// into `.project` scope, gated on schema version and never on project type.
struct SceneNavigatorPane: View {
    let script: FountainScript?
    /// Shown on the head row.
    let projectTitle: String
    /// The window's subject. This pane writes it in exactly two places — the
    /// head row's selection, and the restore in `sceneRow` — and both go through
    /// the static rules below.
    @Binding var selectedSubject: BinderSubject?
    /// The single document the sluglines live in — what a scene click restores
    /// the subject to when the project row is holding it. `nil` only if the
    /// screenplay has no document at all, in which case a scene click cannot
    /// have come from anywhere and the subject is left alone.
    let documentID: String?
    /// Called with the line range location when the user clicks a scene.
    let onSelect: (Int) -> Void

    var body: some View {
        // Compute every scene's page number + length in ONE O(document) pass,
        // here, instead of two O(document) walks per row per render (tripwire
        // 4). With N scenes this turns O(N × document) per render into
        // O(document). The rows read pre-computed values only.
        let summaries = script?.sceneSummaries() ?? []
        // One `List`, always — including when the script has no sluglines yet,
        // which is what EVERY new screenplay opens on (`createScreenplayProject`
        // writes an empty `.fountain`) and stays on until the writer types their
        // first INT./EXT. The empty state used to REPLACE this list; with the
        // project row in it that would mean a brand-new screenplay has no
        // subject it can be given at all — exactly when project-scope intent is
        // what a writer reaches for first. So it is an OVERLAY, the shape
        // `BinderView` and `CollectionPiecesPane` both landed on, and
        // `SceneNavigatorProjectRowTests` hit-tests it here rather than
        // inheriting the measurement: this empty state is neither of theirs.
        List(selection: headRowSelection) {
            projectRow
            ForEach(Array(summaries.enumerated()), id: \.offset) { _, summary in
                sceneRow(for: summary)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if summaries.isEmpty { emptyState }
        }
    }

    /// The row at the head of the navigator naming the screenplay itself.
    ///
    /// **A row and a `.tag`**, like the other two — tripwire 9 is why it is not a
    /// `Button` and not an `.onTapGesture` inside `List(.sidebar)`, even though
    /// every row below it is a Button. Those are navigation, and their click
    /// does not select anything.
    private var projectRow: some View {
        ProjectRowLabel(title: projectTitle)
            .tag(BinderSubject.project)
    }

    /// The head row's selection, PROJECTED — the pane's whole answer to having
    /// one selectable row in a list of unselectable ones.
    ///
    /// A scene row carries no `.tag`, and an untagged row does not decline to be
    /// selected: it is selected and the List writes `nil` through the binding
    /// (measured on `BinderView`'s empty-state row, macOS 26.5, where a
    /// `.selectionDisabled()` message row was selected anyway). Handing
    /// `$selectedSubject` to this List directly would therefore make every scene
    /// click ALSO deselect the window's subject, racing the row's own Button —
    /// and `nil` blanks the centre column, so the writer would click a slugline
    /// and lose the editor.
    ///
    /// So the binding is a projection rather than the state itself: it shows
    /// `.project` only when the subject is the project, and it accepts only
    /// `.project` back. The scene rows' own Button is the authoritative signal
    /// for what a scene click means, and it runs through
    /// `subject(_:whenNavigatingTo:)`. Ordering between the two does not matter,
    /// which is the point — there is no flag and no guard here (tripwire 2), just
    /// a value that ignores writes it has no meaning for.
    private var headRowSelection: Binding<BinderSubject?> {
        Binding(
            get: { Self.headRowSelection(for: selectedSubject) },
            set: { written in
                selectedSubject = Self.subject(selectedSubject, whenListWrites: written)
            })
    }

    /// What the head row shows as selected, given the window's subject.
    /// Pure and static so it can be asked over every subject rather than the one
    /// a mounted test happens to drive.
    static func headRowSelection(for subject: BinderSubject?) -> BinderSubject? {
        subject == .project ? .project : nil
    }

    /// What the subject becomes when the List writes through the projection.
    /// Only `.project` moves it; a `nil` from an untagged scene row leaves the
    /// window's subject exactly where it was.
    static func subject(_ current: BinderSubject?,
                        whenListWrites written: BinderSubject?) -> BinderSubject? {
        written == .project ? .project : current
    }

    /// What the subject becomes when the writer clicks a slugline.
    ///
    /// **A scene click means "I am working on the script"**, so it takes the
    /// subject off the project and back onto the document. Without this the
    /// project row would be a trap: the head row blanks the centre column (the
    /// project is not a document, so `EditorHost` has nothing to bind), and a
    /// click on a scene would have nothing to scroll and no way back except the
    /// binder segment picker.
    ///
    /// A subject that already names an item is left ALONE — the navigator does
    /// not know better than the window which document is open, and re-writing the
    /// same value on every scene click would churn the editor's reload triggers.
    ///
    /// **Known edge, stated rather than hidden:** on the click that restores the
    /// document, the editor is mounting for the first time, so the
    /// `maughamNavigateToScene` post that follows reaches no coordinator and the
    /// scroll is lost — the writer lands in the script, at wherever it was, not
    /// at that slugline. A second click gets it. It is not fixed here with a
    /// delayed re-post: that would jump a writer BACK to scene A if they clicked
    /// A then B quickly, which is worse than a first click that under-delivers.
    /// Fixing it properly means the coordinator holding a pending navigation
    /// across its own mount, which is an editor change, not a binder one.
    static func subject(_ current: BinderSubject?,
                        whenNavigatingTo documentID: String?) -> BinderSubject? {
        switch current {
        case .item: return current
        case .project, .none: return documentID.map(BinderSubject.item) ?? current
        }
    }

    /// Shown when the script has no sluglines — an overlay on the list rather
    /// than a replacement for it (see `body`). Tripwire 15: the full-frame chain
    /// is what stops SwiftUI sizing this to its intrinsic content.
    private var emptyState: some View {
        VStack {
            Text("No scenes yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Type INT. or EXT. to add one.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sceneRow(for summary: FountainScript.SceneSummary) -> some View {
        Button {
            // Order: the subject first, then the scroll. The editor has to be
            // the thing on screen before there is anything to scroll.
            selectedSubject = Self.subject(
                selectedSubject, whenNavigatingTo: documentID)
            onSelect(summary.line.range.location)
        } label: {
            HStack(spacing: 8) {
                Text(summary.line.content)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Self.rowCaption(for: summary))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Returns the compact "p1 · ¼" trailing caption from pre-computed scene
    /// metrics. Empty length info collapses to just "p\(page)". Format is
    /// pixel-identical to the prior per-scene version.
    static func rowCaption(for summary: FountainScript.SceneSummary) -> String {
        let length = formatPagesCompact(summary.length)
        if length.isEmpty {
            return "p\(summary.pageNumber)"
        }
        return "p\(summary.pageNumber) · \(length)"
    }

    /// Formats fractional pages compactly: "0" hidden as "—", "0.25" as "¼p",
    /// "0.5" as "½p", "0.75" as "¾p", whole numbers as "1p" / "2p", and
    /// mixed as "1¼p" / "2½p" using nearest quarter rounding.
    static func formatPages(_ pages: Double) -> String {
        if pages <= 0 { return "—" }
        let quarters = (pages * 4).rounded()
        let whole = Int(quarters / 4)
        let frac = Int(quarters.truncatingRemainder(dividingBy: 4))
        let fracGlyph: String
        switch frac {
        case 0: fracGlyph = ""
        case 1: fracGlyph = "¼"
        case 2: fracGlyph = "½"
        case 3: fracGlyph = "¾"
        default: fracGlyph = ""
        }
        if whole == 0 && frac == 0 {
            // Tiny scene that rounds below ¼ — show "<¼p"
            return "<¼p"
        }
        if whole == 0 {
            return "\(fracGlyph)p"
        }
        return "\(whole)\(fracGlyph)p"
    }

    /// Compact form of `formatPages` for inline display next to the page
    /// number. Drops the trailing "p" since the prefix already implies pages.
    /// Returns "" for ≤0; "¼", "½", "¾", "1" / "1¼" / "2½" otherwise.
    static func formatPagesCompact(_ pages: Double) -> String {
        if pages <= 0 { return "" }
        let quarters = (pages * 4).rounded()
        let whole = Int(quarters / 4)
        let frac = Int(quarters.truncatingRemainder(dividingBy: 4))
        let fracGlyph: String
        switch frac {
        case 1: fracGlyph = "¼"
        case 2: fracGlyph = "½"
        case 3: fracGlyph = "¾"
        default: fracGlyph = ""
        }
        if whole == 0 && frac == 0 { return "<¼" }
        if whole == 0 { return fracGlyph }
        return "\(whole)\(fracGlyph)"
    }
}
