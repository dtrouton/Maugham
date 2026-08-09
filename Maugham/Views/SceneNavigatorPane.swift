import SwiftUI
import MaughamCore

/// The Scenes segment — a screenplay's binder.
///
/// A screenplay is ONE `.fountain` (the Phase 3d invariant), so this pane is a
/// slugline navigator inside a single file: clicking a slugline scrolls the
/// editor rather than opening anything, which is why those rows are `Button`s
/// and carry no selection.
///
/// **Above them it is a binder like any other** — the project row, then the
/// project's documents, which for a screenplay is the one script. Those two rows
/// select; the sluglines beneath them navigate. It listed only the *insides* of
/// the script for a slice, with no row for the script itself, and that made the
/// project row a one-way door on every screenplay with no sluglines yet: see
/// `scriptRow`.
///
/// **It carries the project row** (persona shell spec §3.3).
/// `BinderSegment.documentHome(for: .screenplay)` is
/// `.scenes` and no persona offers a screenplay the `.manuscript` segment, so
/// `BinderView` — the row's other non-collection home — is never mounted for a
/// screenplay at all: without a row here `BinderSubject.project` is
/// **unconstructible in a screenplay**, and since slice 1 deleted
/// `StatementPane`'s `[Chapter | Project]` switch that means project-scope Intent
/// is unreachable. It can hide the writer's own prose, not just a blank pane:
/// `legacyCraftIntentByScope` adopts a pre-M1A whole-script craft-intent note
/// into `.project` scope, gated on schema version and never on project type.
struct SceneNavigatorPane: View {
    /// The project, for the Research and Palette sections at the foot of the
    /// tree (stage-2a Task 4). Every persona gets one left column, so those
    /// sections are furniture in all three trees — and this pane is the one that
    /// had no store of its own, because sluglines are parsed from a script it is
    /// handed. Required rather than optional on purpose: an optional would let a
    /// call site ship a screenplay whose writer can reach no research at all,
    /// silently.
    @Bindable var store: ProjectStore
    let script: FountainScript?
    /// Shown on the head row.
    let projectTitle: String
    /// The window's subject. This pane writes it in exactly two places — the
    /// List's selection (the project row and the script row), and the restore in
    /// `sceneRow` — and both go through the static rules below.
    @Binding var selectedSubject: BinderSubject?
    /// The single document the sluglines live in — the subject of the script
    /// row, and what a scene click restores the subject to when the project row
    /// is holding it. `nil` only if the screenplay has no document at all, in
    /// which case there is no script row and a scene click has nothing to
    /// restore to, so the subject is left alone.
    let documentID: String?
    /// Called with the line range location when the user clicks a scene.
    let onSelect: (Int) -> Void

    /// The Research and Palette sections' own state (stage-2a Task 4). Owned
    /// here because their presentations hang off this pane, outside the `List`.
    @State private var treeState = BinderTreeSectionsState()

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
        // project and script rows in it that would mean a brand-new screenplay
        // has no subject it can be given at all — neither the project, exactly
        // when project-scope intent is what a writer reaches for first, nor the
        // script, which is the only way back off it. So it is an OVERLAY, the shape
        // `BinderView` and `CollectionPiecesPane` both landed on, and
        // `SceneNavigatorProjectRowTests` hit-tests it here rather than
        // inheriting the measurement: this empty state is neither of theirs.
        List(selection: listSelection) {
            projectRow
            scriptRow
            ForEach(Array(summaries.enumerated()), id: \.offset) { _, summary in
                // Inset under the two header rows above: a slugline is a place
                // INSIDE the script, and the indent is what says so without a
                // disclosure triangle the writer cannot collapse anyway.
                sceneRow(for: summary)
                    .padding(.leading, ProjectRowLabel.childIndent)
            }
            // Below the sluglines — furniture at the foot of the column
            // (stage-2a Task 4). A screenplay's writer reaches the same research
            // and the same palette as everyone else's; before this the Scenes
            // segment was the only tree with no way to either.
            BinderTreeSections(store: store, state: treeState,
                               selectedSubject: $selectedSubject)
        }
        .listStyle(.sidebar)
        .overlay {
            if summaries.isEmpty { emptyState }
        }
        .binderTreeSections(store: store, state: treeState,
                            selectedSubject: $selectedSubject)
    }

    /// The row at the head of the navigator naming the project itself.
    ///
    /// **A row and a `.tag`**, like the project row in `BinderView` and
    /// `CollectionPiecesPane` — tripwire 9 is why it is not a `Button` and not an
    /// `.onTapGesture` inside `List(.sidebar)`. The slugline rows below are
    /// Buttons because they navigate and select nothing; `scriptRow`, between
    /// the two, is a row and a `.tag` for the same reason this one is.
    private var projectRow: some View {
        ProjectRowLabel(title: projectTitle)
            .tag(BinderSubject.project)
    }

    /// The row naming the script itself — the screenplay's one document, sitting
    /// between the project row and the sluglines (smoke, 2026-08-01).
    ///
    /// **Why it exists.** Without it this is the only binder in the app that
    /// lists the *insides* of a document and never the document. That reads as a
    /// stylistic difference until a screenplay has no sluglines yet — which is
    /// every new one — and then it is a one-way door: selecting the project row
    /// blanks the centre column, and the escape the pane was built with is a
    /// *scene* click, which does not exist when there are no scenes. With this
    /// row the navigator is shaped like every other binder — the project, then
    /// the project's documents, with sluglines as detail beneath the one
    /// document — and because a screenplay always has exactly one script, the
    /// escape can never be missing the way a scene row can.
    ///
    /// **Why it says "Script" and not the document's title.** The rest of the
    /// app draws a document row with its `StructureItem.title`, and the first
    /// instinct is to do that here. Two facts rule it out. The title a
    /// screenplay's document actually carries is `"Scene 1"`
    /// (`ProjectFactory.createScreenplayProject`), which sitting one row above
    /// real sluglines reads as a third scene — the exact confusion this row is
    /// meant to end. And it is not a default the writer can move off:
    /// `ProjectStore.renameStructureItem` has one caller, `BinderView.rename`,
    /// and `BinderView` is never mounted for a screenplay
    /// (`BinderSegment.documentHome(for: .screenplay)` is `.scenes`), so from
    /// inside the app that title is permanent. So the row names the *kind* of
    /// thing, which a screenplay can do and no other project type can: there is
    /// exactly one script (the Phase 3d invariant). A fixed noun also guarantees
    /// the two head rows can never read the same, which a title cannot — a
    /// document titled after its project would put "The Long Walk" directly
    /// under "The Long Walk", and two adjacent rows naming the same thing would
    /// be worse than the bug this fixes.
    @ViewBuilder
    private var scriptRow: some View {
        if let documentID {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("Script")
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .tag(BinderSubject.item(documentID))
        }
    }

    /// The List's selection, PROJECTED — the pane's whole answer to having two
    /// selectable rows in a list of unselectable ones.
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
    /// So the binding is a projection rather than the state itself, and it now
    /// distinguishes **three** writes rather than two: `.project` and the
    /// script's own `.item(documentID)` are this pane's rows and move the
    /// subject; everything else — `nil` from an untagged scene row, or an item
    /// this pane does not draw — leaves it exactly where it was. The scene rows'
    /// own Button is still the authoritative signal for what a scene click
    /// means, through `subject(_:whenNavigatingTo:)`. Ordering between the two
    /// does not matter, which is the point — there is no flag and no guard here
    /// (tripwire 2), just a value that ignores writes it has no meaning for.
    ///
    /// **It selects a SET as of stage-2b Task 3**, like the other two trees, and
    /// the pane's own rules do the same job one element at a time. Each is used
    /// as a MAP rather than a test: `listSelection(for:)` sends a subject to the
    /// row this pane shows for it, and `subject(_:whenListWrites:documentID:)`
    /// — asked from no subject at all — sends a written row to the signal it
    /// carries. A foreign document is the one input either drops, which is
    /// exactly the refusal that made this pane's list a projection in the first
    /// place. There is no second predicate beside them to fall out of step.
    private var listSelection: Binding<Set<BinderSubject>> {
        Binding(
            get: {
                Set(BinderTreeSelection
                    .shown(treeState.selection, subject: selectedSubject)
                    .compactMap { Self.listSelection(for: $0, documentID: documentID) })
            },
            set: { written in
                let mine = Set(written.compactMap {
                    Self.subject(nil, whenListWrites: $0, documentID: documentID)
                })
                let next = BinderTreeSelection.resolved(
                    written: mine, stored: treeState.selection,
                    subject: selectedSubject,
                    structure: store.manifest.structure,
                    research: store.manifest.research,
                    // One row written is still this pane's own rule, unchanged
                    // — including the `nil` an untagged slugline writes.
                    single: { Self.subject($0, whenListWrites: $1,
                                           documentID: documentID) })
                treeState.selection = next.selection
                selectedSubject = next.subject
            })
    }

    /// Which of this pane's rows shows as selected, given the window's subject.
    /// Pure and static so it can be asked over every subject rather than the one
    /// a mounted test happens to drive.
    ///
    /// A subject naming some *other* document selects nothing: the pane draws no
    /// row for it, and claiming a row it does not have would highlight the
    /// script while the window was about something else.
    ///
    /// A **research** subject passes straight through (stage-2a Task 4): the
    /// Research and Palette sections at the foot of this list draw rows that
    /// mean one. It needs none of the document case's care — a research id this
    /// tree happens not to draw simply highlights nothing, where a foreign
    /// document id would have highlighted the script.
    static func listSelection(for subject: BinderSubject?,
                              documentID: String?) -> BinderSubject? {
        switch subject {
        case .project: return .project
        case .item(let id): return id == documentID ? .item(id) : nil
        case .research(let id): return .research(id)
        case .none: return nil
        }
    }

    /// What the subject becomes when the List writes through the projection.
    /// This pane's own rows move it; a `nil` — from an untagged scene row or an
    /// untagged section placeholder — and an item this pane draws no row for
    /// leave the window's subject alone.
    ///
    /// **The `nil` rule is not spelled here**: it is `BinderTreeSelection`'s,
    /// shared with the other two trees, which grew untagged rows of their own in
    /// stage-2a Task 4. Only the foreign-document refusal is this pane's, and it
    /// is the one thing about this list the others do not have.
    static func subject(_ current: BinderSubject?,
                        whenListWrites written: BinderSubject?,
                        documentID: String?) -> BinderSubject? {
        switch written {
        case .item(let id):
            return id == documentID ? .item(id) : current
        case .project, .research, .none:
            return BinderTreeSelection.subject(current, whenListWrites: written)
        }
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
    ///
    /// **A research subject is reclaimed, exactly like the project** (stage-2a
    /// Task 4's ruling; Task 1 deferred it to the task that gave this pane
    /// research rows, which is this one). The two are the same case in the only
    /// way that matters here: neither has an editor in the centre column, so the
    /// `maughamNavigateToScene` post that follows this call reaches no
    /// coordinator and the writer's click on a slugline does nothing they can
    /// see. `.item` is left alone for the opposite reason — an editor IS
    /// mounted, and re-writing the same value would churn its reload triggers.
    static func subject(_ current: BinderSubject?,
                        whenNavigatingTo documentID: String?) -> BinderSubject? {
        switch current {
        case .item: return current
        case .project, .research, .none:
            return documentID.map(BinderSubject.item) ?? current
        }
    }

    /// Shown when the script has no sluglines — an overlay on the list rather
    /// than a replacement for it (see `body`). Tripwire 15: the full-frame chain
    /// is what stops SwiftUI sizing this to its intrinsic content.
    ///
    /// **The copy names the first step.** It used to read "Type INT. or EXT. to
    /// add one", which assumes an editor is already on screen — and the state a
    /// writer most often reads this in is the one where it is not: subject on
    /// the project, centre column blank, nothing to type into. Now it points at
    /// the row that puts the editor there.
    private var emptyState: some View {
        VStack {
            Text("No scenes yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open the script, then type INT. or EXT.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
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
