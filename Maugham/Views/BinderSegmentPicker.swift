import SwiftUI
import MaughamCore

/// The binder's segmented picker. One implementation shared by
/// `BinderPaneToggle` and `CollectionBinderPaneToggle`: the two toggles differ
/// only in which pane each segment routes to, never in which segments are
/// offered, and a second copy of this derivation is how the two would drift
/// apart (the right pane's badge-offset literal drifted exactly this way).
struct BinderSegmentPicker: View {
    @Binding var segment: BinderSegment
    /// The window's working mode. Decides the persona-owned part of the list —
    /// see `Persona.binderSegments(for:)`.
    let persona: Persona
    let projectType: ProjectType
    let hasTrash: Bool
    let findActive: Bool

    /// Segments this picker shows, in order: the persona's own list, then the
    /// two runtime-gated ones. Trash and Find are persona-INDEPENDENT — they
    /// are transient states rather than surfaces, so a writer mid-search keeps
    /// the Find segment in every mode.
    ///
    /// `selected`, when supplied and not already present, is **appended**.
    /// Personas are lenses, not gates: several paths force a binder segment
    /// outside the current persona's list (wiki-link navigation, the MCP note
    /// banner, a restored `UIState`), and without the append the picker renders
    /// with nothing highlighted while the pane below shows the right content —
    /// the defect the right pane shipped and had to fix
    /// (`DetailPaneToggle.visibleSegments(including:)`). Appending rather than
    /// inserting keeps the persona's own ordering stable.
    static func visibleSegments(persona: Persona,
                                projectType: ProjectType,
                                hasTrash: Bool,
                                findActive: Bool,
                                including selected: BinderSegment? = nil) -> [BinderSegment] {
        var segments = persona.binderSegments(for: projectType)
        // `.trash`/`.find` are the two transient segments — see
        // `BinderSegment.isTransient`, the single source shared with
        // `PersonaModifier.applyPersonaChange`'s `keepBinder` whitelist so
        // the two cannot disagree.
        if hasTrash, BinderSegment.trash.isTransient { segments.append(.trash) }
        if findActive, BinderSegment.find.isTransient { segments.append(.find) }
        if let selected, !segments.contains(selected) { segments.append(selected) }
        return segments
    }

    /// The one list this picker renders — labels and ordering both derive from
    /// it, so they cannot disagree.
    private var pickerSegments: [BinderSegment] {
        Self.visibleSegments(persona: persona,
                             projectType: projectType,
                             hasTrash: hasTrash,
                             findActive: findActive,
                             including: segment)
    }

    /// UNIFORM CHILDREN — every segment is an `Image`, never a mix.
    ///
    /// The `if let symbol { Image } else { Text }` this replaces put an
    /// `_ConditionalContent` inside the `ForEach`. Its branch is cached per
    /// position and the segmented `Picker` updates its `NSSegmentedControl` in
    /// place, so the first persona change that reshaped the list left stale
    /// branches on the wrong indices: `Pieces | 🎨Research | 🎨`, and in Review
    /// (which offers no Palette) a palette icon sitting on the Research
    /// segment. That is how the palette wall became unreachable — the writer
    /// clicked the palette and got Research (2026-07-25 smoke, defect C).
    ///
    /// Anything that varies per segment must therefore stay INSIDE one child
    /// expression. If a future segment wants a text label, every segment gets
    /// a text label — see `BinderSegment.pickerSymbolName` for why that is not
    /// affordable in a 240pt column today.
    ///
    /// **A picker exists only where a real choice exists** (shell-finish stage
    /// 1, spec §9): `pickerSegments.count <= 1` renders nothing — no bar, no
    /// divider, no reserved height, so the tree's header sits exactly where
    /// it would if this view were never mounted. The `Divider()` beneath the
    /// segmented control is folded in HERE rather than left for each caller
    /// to place — a divider left behind by a caller after its picker goes
    /// empty is the strip's ghost, a 1pt residue of the very bar the rule
    /// exists to remove. Fix round 1 of shell-finish stage 1 task 2 caught
    /// exactly that: the picker alone rendered nothing, but both
    /// `BinderPaneToggle` and `CollectionBinderPaneToggle` still called
    /// `Divider()` unconditionally right after it. Folding bar and divider
    /// together into one `if` is the one spelling of "is there a real
    /// choice" — the two callers now call this view and place nothing of
    /// their own beside it, so a third caller cannot forget the divider
    /// either.
    ///
    /// Everything — the `Picker`'s padding AND the `Divider()` — lives
    /// INSIDE the `if`, so a choiceless mount produces the implicit
    /// `EmptyView` with nothing wrapping it; anything hoisted outside the
    /// condition would reserve space even with zero content, which is the
    /// "empty bar" this exists to avoid.
    var body: some View {
        if pickerSegments.count > 1 {
            VStack(spacing: 0) {
                Picker("Binder", selection: $segment) {
                    ForEach(pickerSegments, id: \.self) { seg in
                        Image(systemName: seg.pickerSymbolName)
                            .tag(seg)
                            .help(seg.displayName(for: projectType))
                            .accessibilityLabel(seg.displayName(for: projectType))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
        }
    }
}
