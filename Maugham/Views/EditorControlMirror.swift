import SwiftUI
import MaughamCore

/// **The editor's membrane, decided from the posture** — pure, so both
/// directions are pinned without a window (`ReviewModeMembraneTests`).
///
/// - `lockEditing` is the hard floor: the posture refuses `.writeText`, or the
///   iCloud share is read-only (an OS-level lock that claims no role).
/// - `isReviewMode` is forced on where the posture refuses the text — a
///   reviewer's Mac opens in review mode, so the selection toolbar offers
///   annotation. The writer's own refusal is per piece: read-through
///   (`EditorControl.readThroughDocIds`), never a window-wide flag.
///
/// Keyed on `allows(.writeText)`, never on `isRestricted` (controller ruling
/// E): an author of some pieces inside her own piece is restricted (she may
/// not start a piece) and may type every word of it. `Posture.settling` refuses
/// `.writeText`, so it LOCKS: a verb appearing a frame late is fine, one
/// appearing that must not is not. `nil` is no manuscript document in the
/// editor: nothing to lock.
enum EditorControlMirror {
    struct Membrane: Equatable {
        let lockEditing: Bool
        let isReviewMode: Bool
        /// The share input on its own, for the figure grid's gate
        /// (`FigureGridGate`), which answers to the figure's posture and
        /// never to the text's.
        var shareIsReadOnly: Bool = false
    }

    static func membrane(posture: Posture?, shareIsReadOnly: Bool) -> Membrane {
        let mayWrite = posture?.allows(.writeText) ?? true
        return Membrane(
            lockEditing: !mayWrite || shareIsReadOnly,
            isReviewMode: !mayWrite,
            shareIsReadOnly: shareIsReadOnly)
    }
}

/// **Whether the Insert menu's items are enabled** (plan 3a Task 4) — the
/// window's answer to "may the key window's editor take an inserted report
/// element?", published to the menu bar as `FocusedValues.mayInsertReportElement`.
/// Pure, so every refusal is pinned without a window (`InsertCommandTests`).
///
/// The editor's membrane refuses on its own all the same (defence in depth):
/// a disabled item is what the writer sees, the membrane is what holds.
enum InsertMenuGate {
    /// True only when all of these hold:
    /// - the centre shows the bare editor — `.editor(altitude: nil, cover: nil)`.
    ///   Altitude, the canvas, a research subject, a Collection reference and
    ///   every cover (Publish's problems and translation round draw over a
    ///   chapter too) hide the text the insert would land in;
    /// - the editor holds a manuscript document (`posture` non-nil) whose
    ///   format takes report elements (`format`, not a screenplay);
    /// - its posture `allows(.writeText)`, and the iCloud share is writable;
    /// - the open piece is not in read-through, nor read in a translation;
    /// - no table grid is expanded in the editor (`FigureGridPresence`,
    ///   report plan 7c Task 9): the grid has the keys, and the writer folds
    ///   it before inserting into the text.
    static func isEnabled(posture: Posture?, format: DocumentFormat?,
                          readThrough: Bool, shareIsReadOnly: Bool,
                          isReadingTranslation: Bool, gridHoldsTheKeys: Bool,
                          route: CentreRoute?) -> Bool {
        guard !gridHoldsTheKeys, ProjectWindow.manuscriptIsVisible(route: route),
              let posture, let format, !format.isScreenplay else { return false }
        return posture.allows(.writeText) && !shareIsReadOnly
            && !readThrough && !isReadingTranslation
    }
}

/// Mirrors posture + appearance changes from ProjectWindow-owned sources into
/// the `EditorControl` model (ADR 0017). A modifier for `ProjectWindow.body`'s
/// type-check ceiling.
struct EditorControlMirrorModifier: ViewModifier {
    /// Computed in `ProjectWindow`'s body from the drawing posture door, so a
    /// selection change AND a `postureEpoch` bump both arrive here as a change
    /// of this value.
    let membrane: EditorControlMirror.Membrane
    /// The same door's answer, whole, for the margin card's dispositions —
    /// mirrored beside the membrane rather than folded into it, because the
    /// membrane is the pinned lock decision and nothing more.
    let posture: Posture?
    /// Whether the Insert menu's items are enabled (`InsertMenuGate`), published
    /// to the menu bar beside the membrane it shadows — the window publishes it
    /// here because this modifier already carries the window's editor posture.
    let mayInsertReportElement: Bool
    let effectiveTypography: TypographySettings
    /// The session's pieces in read-through (`ReadThroughStore.pieceIds`).
    let readThroughPieces: Set<String>
    /// Those whose checkpoint was not saved (`piecesLackingCheckpoint`).
    let readThroughLackingCheckpoint: Set<String>
    @Binding var editorControl: EditorControl
    @Environment(UserPreferences.self) private var userPreferences

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.mayInsertReportElement, mayInsertReportElement)
            .onChange(of: membrane) { _, membrane in
                editorControl.isReviewMode = membrane.isReviewMode
                editorControl.lockEditing = membrane.lockEditing
                editorControl.shareIsReadOnly = membrane.shareIsReadOnly
            }
            .onChange(of: posture) { _, posture in editorControl.posture = posture }
            .onChange(of: readThroughPieces) { _, pieces in editorControl.readThroughDocIds = pieces }
            .onChange(of: readThroughLackingCheckpoint) { _, pieces in
                editorControl.readThroughLackingCheckpoint = pieces
            }
            .onChange(of: userPreferences.theme) { _, t in editorControl.theme = t }
            .onChange(of: effectiveTypography) { _, t in editorControl.typography = t }
            .onChange(of: userPreferences.typewriterScroll) { _, v in
                editorControl.typewriterScroll = v
            }
            .onChange(of: userPreferences.sentenceFocus) { _, v in
                editorControl.sentenceFocus = v
            }
            .onChange(of: userPreferences.paragraphFocus) { _, v in
                editorControl.paragraphFocus = v
            }
            .onAppear {
                // Seed the model from current sources (onChange only fires on
                // transitions, not on first render).
                editorControl.isReviewMode = membrane.isReviewMode
                editorControl.lockEditing = membrane.lockEditing
                editorControl.shareIsReadOnly = membrane.shareIsReadOnly
                editorControl.posture = posture
                editorControl.readThroughDocIds = readThroughPieces
                editorControl.readThroughLackingCheckpoint = readThroughLackingCheckpoint
                editorControl.theme = userPreferences.theme
                editorControl.typography = effectiveTypography
                editorControl.typewriterScroll = userPreferences.typewriterScroll
                editorControl.sentenceFocus = userPreferences.sentenceFocus
                editorControl.paragraphFocus = userPreferences.paragraphFocus
                // Not mirrored here: `referenceIndexVersion` and
                // `figureCardVersion` are written by `EditorHost`, which owns
                // the index and the cards (report plan 7a Task 4).
            }
    }
}

// MARK: - View ▸ Margin (shell p5 Task 2)

/// **What the margin's marks are keyed on** — they are built once per
/// change of this, never per keystroke or per draw (tripwire 4): the open
/// piece's `annotationsVersion` (which also moves when a seal arriving
/// changes whose a note is, with no new op), the sidecar's version, the
/// setting, To resolve's selection, and what hides or yields the marks.
struct MarginKey: Equatable {
    let docId: String?
    let annotationsVersion: Int
    let diagnosticsVersion: Int
    let setting: MarginSetting
    let selection: Set<ResolveSource>
    let focusMode: Bool
    let readingTranslation: Bool
    let reviewRender: Bool
    let localName: String
}

/// **The margin's window wiring** (shell p5 Task 2): View ▸ Margin's setting
/// published to the menu bar and written to `UIState` on its event; the
/// open piece's marks built into `EditorControl.margin`, one way; a mark's
/// click answered by To resolve. A modifier for `ProjectWindow.body`'s
/// type-check ceiling.
struct MarginMirrorModifier: ViewModifier {
    let window: NSWindow?
    let documentStore: DocumentStore?
    let structure: [StructureItem]
    /// The window's subject: read for the open piece, and a click moves the
    /// faces to it (fix round 1, M5).
    @Binding var subject: WindowSubject
    let diagnostics: DiagnosticsStore?
    /// To resolve's selection per piece, as its own list last published it
    /// (`ResolvePane.onSelectionShown`, `ProjectWindow.recordingSelection`);
    /// a piece with none is everything (fix round 1, M6).
    let resolveSelections: [String: Set<ResolveSource>]
    let isNoChromeOn: Bool
    @Binding var editorControl: EditorControl
    @Binding var showInspector: Bool
    @Binding var position: RightColumnPosition
    @Binding var resolveRequest: ResolveRequest?
    @Environment(UserPreferences.self) private var userPreferences

    /// The open piece, where the editor holds a manuscript: never a
    /// reference piece, never the Book or research.
    private var docId: String? {
        guard let id = subject.open.itemID, let item = TreeWalk.find(id: id, in: structure),
              EditorHost.loadsAsAManuscript(item) else { return nil }
        return id
    }

    private var setting: MarginSetting { Self.publishedSetting(documentStore) }

    private var key: MarginKey {
        Self.key(document: docId.flatMap { documentStore?.document(forDocId: $0) },
                 diagnosticsVersion: diagnostics?.version ?? 0, setting: setting,
                 selection: docId.flatMap { resolveSelections[$0] } ?? [],
                 focusMode: isNoChromeOn, control: editorControl,
                 localName: userPreferences.collaboratorDisplayName)
    }

    /// **What the menu's check marks read** (published as `\.marginSetting`):
    /// the project's remembered setting.
    @MainActor
    static func publishedSetting(_ documentStore: DocumentStore?) -> MarginSetting {
        documentStore?.uiState.marginSetting ?? .off
    }

    /// **View ▸ Margin's receiver** (fix round 1, I1): the chosen setting,
    /// written to the project's `UIState`.
    @MainActor
    static func receiveSetting(_ userInfo: [AnyHashable: Any]?, documentStore: DocumentStore?) {
        guard let chosen = MaughamEvent.marginSetting(of: userInfo) else { return }
        documentStore?.updateUIState { $0.marginSetting = chosen }
    }

    /// **A mark's click, as the window answers it** (fix round 1, M5): the
    /// faces go to the open piece (the line over the prose's rule,
    /// `RightColumnContent.facesForTheStrip`), so the column never opens on
    /// a figure's or an edition's list; then To resolve shows, holding the
    /// request.
    struct ParagraphJump: Equatable {
        let subject: WindowSubject
        let jump: ProjectWindow.StrainJump
    }

    static func paragraphJump(_ userInfo: [AnyHashable: Any]?, subject: WindowSubject,
                              structure: [StructureItem]) -> ParagraphJump? {
        guard let asked = MaughamEvent.paragraphInResolve(of: userInfo) else { return nil }
        return ParagraphJump(
            subject: RightColumnContent.facesForTheStrip(subject, structure: structure),
            jump: ProjectWindow.strainJump(.showParagraph(
                docId: asked.docId, paragraphId: asked.paragraphId,
                annotationId: MaughamEvent.marginAnnotationId(of: userInfo))))
    }

    /// **The key, from what the window holds** — read in the modifier's body,
    /// so a move of any part re-runs the build. `annotationsVersion` moves
    /// with a new note and with a re-read that changed whose a note is.
    @MainActor
    static func key(document: Document?, diagnosticsVersion: Int, setting: MarginSetting,
                    selection: Set<ResolveSource>, focusMode: Bool, control: EditorControl,
                    localName: String) -> MarginKey {
        MarginKey(
            docId: document?.docId, annotationsVersion: document?.annotationsVersion ?? 0,
            diagnosticsVersion: diagnosticsVersion, setting: setting,
            selection: selection, focusMode: focusMode,
            readingTranslation: control.translationLanguage != nil,
            reviewRender: control.reviewRenders(docId: document?.docId),
            localName: localName)
    }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.marginSetting, Self.publishedSetting(documentStore))
            .onKeyWindowCommand(.maughamSetMargin, window: window) { note in
                Self.receiveSetting(note.userInfo, documentStore: documentStore)
            }
            .onKeyWindowCommand(.maughamShowParagraphInResolve, window: window) { note in
                guard let answer = Self.paragraphJump(note.userInfo, subject: subject,
                                                      structure: structure) else { return }
                if answer.subject != subject { subject = answer.subject }
                showInspector = answer.jump.showInspector
                position = answer.jump.position
                resolveRequest = answer.jump.request
            }
            // The sidecar for the open piece, so its strains can tick with
            // the right column hidden.
            .task(id: MarginSidecarKey(docId: docId, flagged: setting == .everythingFlagged)) {
                guard setting == .everythingFlagged, let docId else { return }
                diagnostics?.load(docId: docId)
            }
            .onChange(of: key, initial: true) { _, key in
                editorControl.margin = Self.marks(
                    key: key, document: key.docId.flatMap { documentStore?.document(forDocId: $0) },
                    diagnostics: diagnostics)
            }
    }

    private struct MarginSidecarKey: Equatable {
        let docId: String?
        let flagged: Bool
    }

    /// **The marks for `key`**, from the open piece's own `Document` and the
    /// sidecar To resolve reads (`DiagnosticsStore.live`) — no walk, no
    /// second manuscript `Document`.
    @MainActor
    static func marks(key: MarginKey, document: Document?,
                      diagnostics: DiagnosticsStore?) -> MarginMarks {
        guard let document, key.setting != .off else { return .none }
        // A note whose paragraph left the text marks nothing (fix round 2).
        let present = Set(document.sequence)
        let notes = document.annotations(filter: AnnotationFilter(statuses: [.open]))
            .filter { $0.paragraphId.map(present.contains) ?? true }
        var items = notes.map { ResolveItem.note(ProjectAnnotation(docId: document.docId, annotation: $0)) }
        if key.setting == .everythingFlagged, let diagnostics {
            let paragraphs = document.paragraphs
            items += diagnostics.live(docId: document.docId) { paragraphs[$0] }
                .filter { $0.kind == .conformanceStrain }
                .map { ResolveItem.finding(docId: document.docId, $0) }
        }
        return MarginMarks.of(
            setting: key.setting, notes: notes, owner: document.noteOwner, items: items,
            selection: key.selection, localName: key.localName, focusMode: key.focusMode,
            readingTranslation: key.readingTranslation, reviewRenderIsOn: key.reviewRender)
    }
}

struct FocusedMarginSettingKey: FocusedValueKey { typealias Value = MarginSetting }
extension FocusedValues {
    /// The key window's margin setting, for View ▸ Margin's check marks.
    var marginSetting: MarginSetting? {
        get { self[FocusedMarginSettingKey.self] }
        set { self[FocusedMarginSettingKey.self] = newValue }
    }
}

/// **View ▸ Margin ▸ Off / My Notes / Everything Flagged** (shell p5 Task
/// 2): three checked items, no key, disabled with no project window.
struct FocusedMarginItems: View {
    @FocusedValue(\.marginSetting) private var current

    var body: some View {
        Menu(MarginSetting.menuTitle) {
            ForEach(MarginSetting.allCases, id: \.self) { setting in
                Toggle(setting.title, isOn: Binding(
                    get: { MarginMarks.isChecked(setting, current: current) },
                    set: { _ in MaughamEvent.postMarginSetting(setting) }))
            }
        }
        .disabled(current == nil)
    }
}
