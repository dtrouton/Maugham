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

    var body: some View {
        Picker("Binder", selection: $segment) {
            ForEach(pickerSegments, id: \.self) { seg in
                if let symbol = seg.pickerSymbolName {
                    Image(systemName: symbol)
                        .tag(seg)
                        .help(seg.displayName(for: projectType))
                } else {
                    Text(seg.displayName(for: projectType)).tag(seg)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
