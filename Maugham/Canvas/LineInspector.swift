import SwiftUI

/// One line, in the inspector: the name the writer gives it, and nothing else.
///
/// **A field in the right-hand column, and not a sheet.** The region's label is
/// edited here; a line's belongs in the same place, for the same reasons — no
/// modal to dismiss, the same discovery path, and the selected thing described
/// where the writer is already looking. It also puts the edit on the correct
/// side of tripwire 32.
///
/// **There is no kind, no vocabulary and no validation, and there must not be**
/// (spec §5, §9). Kinopio shipped author-typed connections for years and removed
/// them in April 2026 because they confused every first-time user observed. What
/// is left is an untyped edge with an optional free-text name — a line costs
/// nothing to draw and nothing to be wrong about, which is what thinking needs.
/// `[[wiki-links]]` remain the durable relationship layer, reached deliberately
/// through promotion.
///
/// **Every commit goes through `CanvasModel.mutateFromInspector`, never
/// `mutate`** (tripwire 32). This view is in the window's other column and the
/// canvas may be holding "Edit Scrap" open the whole time the writer is in it —
/// `CanvasView.commitActiveEdit` runs from `handleClick`, which only fires for
/// clicks on the canvas, and a double-click never reassigns `selection`. Nested,
/// the commit takes no snapshot at depth 2 and registers nothing at depth 1, so
/// **the name is on no undo step at all**: the open gesture's baseline predates
/// it, the writer's next keystroke carries it into a step called "Edit Scrap",
/// and a ⌘Z aimed at a sentence takes the line's name with it.
/// `CanvasUndo.mutateFromOutsideTheCanvas` has the mechanism at length.
///
/// **Every commit also checks that the value actually moved**, exactly as
/// `RegionInspector.commitLabel` does. The field commits on focus loss as well
/// as on ⌘↩, so the no-op commit is the common case rather than the rare one.
/// `CanvasUndo.endGesture` already declines to register an unchanged gesture, so
/// what the guard buys is the rest of it: no snapshot, no queued disk write, and
/// no redraw of the canvas.
///
/// **If a thing has an inspector, its inspector can delete it — unless deletion
/// through the inspector was ruled against, which is the scrap's own case.** A
/// region could be removed from this pane or with ⌫ from the moment 1C-b
/// shipped; a line arriving with only the key would have made two arms of ONE
/// `RegionInspectorPane` offer different affordances for the same act — and ⌫
/// needs `CanvasEventNSView` to hold first responder, so a writer who has just
/// typed a name into the field above would have to click back onto the canvas
/// before they could delete the thing they were editing. **A scrap gained an
/// inspector too, in 1C-c2 (`ScrapInspector`), and it deliberately has no
/// Delete button** — ⌫ stays the only route to deleting a scrap, which is a
/// standing ADR 0026 consequence and Denver's ruling, not the gap this
/// paragraph used to say it was: adding one there for symmetry with this pane
/// would be a design change wearing a tidy-up's clothes, not a fourth spelling
/// of the rule above.
///
/// **Tripwire 16 does not apply.** That rule is about an inline rename
/// `TextField` that *appears* inside a `List(selection:)` row and has to win a
/// focus race against the list's own focus pass. This field is always present in
/// a static form.
struct LineInspector: View {

    let model: CanvasModel
    let lineID: CanvasLineID

    /// What the writer has typed but not yet committed. Local, so one name is
    /// one undo step rather than one per keystroke.
    @State private var draftLabel = ""
    @FocusState private var labelFocused: Bool

    private var line: CanvasLine? { model.scene.line(lineID) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draftLabel, prompt: Text("Unlabelled"))
                    .focused($labelFocused)
                    .onSubmit { commitLabel(draftLabel) }
            } header: {
                Text("Line")
            } footer: {
                Text("A line says these two cards have something to do with each "
                     + "other. What that is, is yours to say — or to leave unsaid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Promote…") {
                    // The SAME command the menu item and ⌘⇧↩ post, so the
                    // button and the keystroke cannot drift into behaving
                    // differently. A closure of our own would be a second path.
                    //
                    // Safe from this column, and the reason is worth knowing:
                    // a `.keyWindow` post made from inside a SHEET is dropped,
                    // because the sheet's own window holds key status (the
                    // v0.24.0 "enter does nothing" bug, `TranslationReviewModifier`).
                    // This button is in the project window itself.
                    MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
                }
                Text("A line becomes a [[wiki-link]] once both of its cards have "
                     + "been promoted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Delete Line", role: .destructive) { deleteLine() }
                Text("Both cards stay on the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { draftLabel = line?.label ?? "" }
        // The selection moved to a different line while this view kept its
        // identity — without the re-seed the new line opens showing the old one's
        // name, and the first focus loss renames it to that.
        //
        // The commit above it is belt and braces against an ordering this view
        // does not control, and it commits to `old` because by the time this runs
        // `lineID` is already the line the writer moved TO. Committing twice is
        // free — the second is a no-op. `RegionInspector` carries the same pair
        // for the same reason.
        .onChange(of: lineID) { old, _ in
            commitLabel(draftLabel, to: old)
            draftLabel = line?.label ?? ""
        }
        // The model's label changed under us: a ⌘Z, or a change arriving from
        // anywhere else. Skipped while the field has focus, or the re-seed would
        // fight the writer mid-word.
        .onChange(of: line?.label) { _, new in
            guard !labelFocused else { return }
            draftLabel = new ?? ""
        }
        .onChange(of: labelFocused) { _, focused in
            if !focused { commitLabel(draftLabel) }
        }
    }

    // MARK: - Commits

    /// **Whitespace is no label, not a label made of spaces.** Stored, one draws
    /// an empty pill on the line for the rest of the canvas's life: visible,
    /// unreadable, and removable only by finding the field again and clearing it
    /// a second time.
    ///
    /// `static` and pure so the rule is reachable from a test that does not host
    /// SwiftUI, which is the only place a view's private normalisation ever gets
    /// looked at.
    static func normalise(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func commitLabel(_ new: String) {
        commitLabel(new, to: lineID)
    }

    /// Named explicitly, because the one caller that needs it is committing a
    /// name to the line the writer typed it into *after* `lineID` has already
    /// moved on to the next one.
    ///
    /// The bump is the structural counter's: the canvas draws this label from
    /// inside a `Canvas` draw closure, where a model value is not in SwiftUI's
    /// dependency graph, and the writer never touched the canvas — so no `@State`
    /// over there moved and nothing else would get the redraw.
    func commitLabel(_ new: String, to target: CanvasLineID) {
        let label = Self.normalise(new)
        guard let line = model.scene.line(target), line.label != label else { return }
        model.mutateFromInspector(label == nil ? "Clear Line Label" : "Label Line") {
            $0.updateLine(target) { $0.label = label }
        }
        model.bumpSceneRevision()
    }

    /// The same rule ⌫ follows: the line goes and both cards stay. The mirror of
    /// `RegionInspector.deleteRegion`, and no `isInGesture` refusal like
    /// `CanvasView.deleteSelection`'s — that guard exists because a KEY can reach
    /// the event view mid-drag, and this button cannot be clicked while the mouse
    /// is down on the canvas. `mutateFromInspector` covers the gesture that *can*
    /// be open here.
    ///
    /// **Clearing the selection is not tidiness.** It names a line that is no
    /// longer in the scene, and every reader resolves it — `CanvasModel
    /// .selectedLine` above all, which is what decides whether this view is on
    /// screen at all. Left dangling, the writer deletes a line and keeps looking
    /// at its empty inspector.
    func deleteLine() {
        guard model.scene.line(lineID) != nil else { return }
        model.mutateFromInspector("Delete Line") { $0.removeLine(lineID) }
        model.selection = nil
        model.bumpSceneRevision()
    }
}
