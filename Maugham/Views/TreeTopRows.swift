import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MaughamCore

/// **Where each kind of row stands in the tree** (shell p1 Task 3, spec "The
/// tree"): the Book; Inbox; Canvas; the manuscript; Figures; Research;
/// Palette; Editions; then the existing foot (Trash, Removed Elsewhere).
///
/// Every tree host draws its rows in this order — `BinderView`,
/// `CollectionPiecesPane` and `SceneNavigatorPane` each put up the Book row,
/// `TreeTopRows`, their manuscript, then `BinderTreeSections` (Figures,
/// Research, Palette, Editions). `TreeTopRowsTests` pins the order here and
/// reads it back off each host's source.
enum TreeRowSlot: CaseIterable, Equatable {
    case book, inbox, canvas, manuscript, figures, research, palette, editions

    /// The slots a tree draws: the Inbox only when the project has one, the
    /// Figures only when a figure is not parked, the Editions when there
    /// is an edition to list or one may be added (`TreeEditionRows.drawsSection`).
    static func order(hasInbox: Bool, showsFigures: Bool,
                      showsEditions: Bool) -> [TreeRowSlot] {
        allCases.filter { slot in
            switch slot {
            case .inbox: return hasInbox
            case .figures: return showsFigures
            case .editions: return showsEditions
            case .book, .canvas, .manuscript, .research, .palette: return true
            }
        }
    }
}

/// **The Inbox and Canvas rows** — between the Book row and the manuscript.
///
/// Each is a row and a `.tag`, like the Book row: the tree's `List` selects
/// it, and the selection is a click through `ClickRule` (`BinderTreeSelection`)
/// — tripwire 9's reason a tree row is never an `.onTapGesture`. A selected
/// tag is what lets the open row draw the `List`'s own filled state, which a
/// row whose click was a `Button`'s action could not hold. Inset with the
/// manuscript: every place the project has stands under the Book.
///
/// No per-row work (tripwire 4): `hasInbox` is the host's cached answer, and
/// `hasNewCaptures` reads the inbox store's already-loaded entries.
struct TreeTopRows: View {
    let hasInbox: Bool
    /// **Captures are waiting** (shell p1 Task 6 fix): the Inbox row's one dot,
    /// the signal the deleted picker badge gave for the phone→Mac capture loop.
    var hasNewCaptures: Bool = false
    /// The Canvas row's drop (shell p4 Task 10) — the host's store and state;
    /// nil takes no drop (a host that mounts none).
    var canvasDrop: TreeCanvasRowDrop.Host? = nil

    /// The tree's one "something new arrived" look, the Inbox's and the
    /// Canvas row's alike.
    static let newDotColor = Color.red
    /// The words the dot says to VoiceOver.
    static let newCapturesLabel = "New captures"
    /// The words the Canvas row's dot says: something the tree sent there
    /// waits, selected, for the canvas's next opening.
    static let newOnCanvasLabel = "New on the canvas"

    var body: some View {
        if hasInbox {
            row("Inbox", systemImage: "tray", subject: .inbox, dot: hasNewCaptures)
        }
        if let canvasDrop {
            // The Inbox's "something new" look (red), never the accent
            // "something to resolve" dot (fix round 1).
            row("Canvas", systemImage: "rectangle.on.rectangle.angled", subject: .canvas,
                dot: canvasDrop.state.canvasHasArrivals, dotLabel: Self.newOnCanvasLabel)
                .modifier(TreeCanvasRowDropTarget(host: canvasDrop))
        } else {
            row("Canvas", systemImage: "rectangle.on.rectangle.angled", subject: .canvas)
        }
    }

    private func row(_ title: String, systemImage: String,
                     subject: BinderSubject, dot: Bool = false,
                     dotLabel: String = Self.newCapturesLabel,
                     dotColor: Color = Self.newDotColor) -> some View {
        HStack(spacing: 4) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            if dot {
                Spacer(minLength: 0)
                // One dot, never a number (spec: "A row shows … one dot").
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(dotLabel)
            }
        }
            // The LABEL LEAF, before `.tag` (tripwire 9) — see TreeTravel.swift.
            .treeTravelOnDoubleClick(subject)
            .padding(.leading, ProjectRowLabel.childIndent)
            .tag(TreeRowTag.subject(subject))
            .id(subject)
    }

    /// Whether the Inbox row carries its dot: the inbox holds a capture still
    /// awaiting triage — the same `entries` (new captures only) the deleted
    /// picker badge counted, kept fresh by the same store refreshes. A read of
    /// loaded state, never disk.
    @MainActor
    static func hasNewCaptures(store: ProjectStore) -> Bool {
        hasNewCaptures(inbox: store.documentStore?.inboxStore)
    }

    @MainActor
    static func hasNewCaptures(inbox: InboxStore?) -> Bool {
        !(inbox?.entries.isEmpty ?? true)
    }

    /// Whether the tree draws the Inbox row: the project has a capture
    /// manifest (`BinderTreeSectionsState.projectHasInbox`, cached), the
    /// window's inbox holds a capture, or the Inbox is what is open — a row
    /// that is open is always drawn.
    @MainActor
    static func hasInbox(state: BinderTreeSectionsState, store: ProjectStore,
                         subject: WindowSubject) -> Bool {
        if state.projectHasInbox || subject.open == .inbox { return true }
        guard let inbox = store.documentStore?.inboxStore else { return false }
        return !inbox.entries.isEmpty || !inbox.trashedEntries.isEmpty
    }
}

// MARK: - The row states

/// **What the tree marks besides the `List`'s own selection** (the row last
/// clicked): the open row when it is not that row, and the faces and what is
/// beside when they are neither. Worked out once per tree render at the
/// `List`, read by each row's mark.
struct TreeRowMarks: Equatable {
    var open: BinderSubject?
    var outlined: Set<BinderSubject> = []
}

/// **The pieces in read-through** (`BinderTreeSectionsState.readThrough`),
/// handed to every row at the `List` beside `TreeRowMarks`, under its own key
/// so a click (which moves `TreeRowMarks`) re-renders no row body: a document
/// row draws `ReadThroughMark` by a set lookup (tripwire 4).
private struct ReadThroughPiecesKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    var readThroughPieces: Set<String> {
        get { self[ReadThroughPiecesKey.self] }
        set { self[ReadThroughPiecesKey.self] = newValue }
    }
}

private struct TreeRowMarksKey: EnvironmentKey {
    static let defaultValue = TreeRowMarks()
}

extension EnvironmentValues {
    var treeRowMarks: TreeRowMarks {
        get { self[TreeRowMarksKey.self] }
        set { self[TreeRowMarksKey.self] = newValue }
    }
}

/// **A row's state, drawn on its label leaf**: the open row a soft accent
/// fill, the faces or what is beside an accent outline. The `List`'s own
/// selection is the third, strongest state — the row last clicked. Takes no
/// hits.
struct TreeRowStateMark: ViewModifier {
    let subject: BinderSubject
    @Environment(\.treeRowMarks) private var marks

    func body(content: Content) -> some View {
        content.background {
            if marks.open == subject {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.22))
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if marks.outlined.contains(subject) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Hands every row in a tree its marks — once, at the `List`.
    @MainActor
    func treeRowStates(state: BinderTreeSectionsState,
                       subject: WindowSubject) -> some View {
        let shown = BinderTreeSelection.shown(state.selection, subject: subject,
                                              clickedAt: state.subjectAtLastClick)
        return environment(\.treeRowMarks, TreeRowMarks(
            open: BinderTreeSelection.openMark(shown: shown, subject: subject),
            outlined: BinderTreeSelection.outlined(shown: shown, subject: subject)))
            // The read-through locks: the window's one set, looked up.
            .environment(\.readThroughPieces, state.readThrough)
            // What has something to resolve: the window's one read, looked up.
            .environment(\.resolvePresence, state.presence)
    }
}

// MARK: - The Canvas row's drop (shell p4 Task 10)

/// **A drop on the tree's Canvas row puts it on the canvas** (ADR 0035's
/// capture-to-canvas route): an Inbox capture, a research item (a note, a
/// picture, a palette card, a group) or a Finder file / browser picture —
/// what the canvas itself takes (`CanvasDrop`, `CanvasExternalDrop`), asked by
/// the canvas's own gate (`CanvasEditGate`).
///
/// **Where it lands: loose, clear of the writer's work, never in a region**
/// (`CanvasCapture.Placement.loose`, `CanvasClaudePlacement.looseOrigin`). The
/// row has no drop point, so this is the Send to Canvas command's case, by
/// that command's ruling (§8A.4's amendment) and through its route
/// (`InboxStore.sendToCanvas`, `CanvasCapture.send`): a container the writer
/// did not ask for is friction, and a loose origin outside every region
/// absorbs nothing (tripwire 31 — creation absorbs by centre, and this
/// centre is in no region).
///
/// **How the writer is told where it went:** the card is selected and
/// brought into view now if the canvas is on screen, else on its next
/// opening (`CanvasCapture.show`), and the Canvas row carries one dot until
/// the canvas is next opened (`BinderTreeSectionsState.canvasHasArrivals`).
/// The centre is not taken: the writer dropping from the Inbox is working
/// through the Inbox.
enum TreeCanvasRowDrop {

    /// The store and state a host hands the row.
    struct Host {
        let store: ProjectStore
        let state: BinderTreeSectionsState
        /// What the window has open, at the drop: the row's dot is not set
        /// for a canvas the writer is looking at (`marksArrival`).
        var open: BinderSubject = .project
    }

    /// **The Canvas row's dot, set and cleared by one rule**: something sent
    /// to the canvas is news only while the canvas is not what is open —
    /// set at a drop under that condition, cleared once the canvas opens.
    static func marksArrival(open: BinderSubject) -> Bool { open != .canvas }

    /// What the verdict reads off the project, cached per manifest stamp and
    /// canvas revision (`CanvasCardsRevision`) so a drag entering the row
    /// costs one layout read and one manifest walk per change, not per entry.
    struct Facts {
        let key: Key
        let items: CanvasItemIndex
        let isReadOnly: Bool

        struct Key: Equatable {
            let modified: Date
            let canvas: CanvasCardsRevision
        }
    }

    @MainActor
    static func facts(store: ProjectStore, state: BinderTreeSectionsState) -> Facts {
        let key = Facts.Key(modified: store.manifest.modified,
                            canvas: PieceFoldIndex.key(store: store,
                                                       canvasWrites: state.closedCanvasWrites).canvas)
        if let cached = state.canvasRowFacts, cached.key == key { return cached }
        let fresh = Facts(key: key, items: CanvasItemIndex.over(research: store.manifest.research),
                          isReadOnly: CanvasClaudeWrite.refusal(of: store, projectRoot: store.url) != nil)
        state.canvasRowFacts = fresh
        return fresh
    }

    /// Whether a drag carries a picture the canvas can hold — an image file
    /// or image data. A text file or a PDF is not one: the canvas's ingest
    /// would decline it, so the row refuses it at the hover and the drop.
    static func carriesPictures(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) { return true }
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
        return !hasFiles && pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    /// What a drop on the row would do.
    enum Verdict: Equatable {
        case capture(entryID: String)
        case research(String)
        case files
        case refuse

        var accepts: Bool { self != .refuse }
    }

    /// **The one predicate**: what the row's highlight asks while a drag is
    /// over it, and what its drop performs — the same inputs, read the same
    /// way (the drag pasteboard's types and its string). Pure.
    ///
    /// - A file or a picture: the canvas's external drop (a file always wins
    ///   over text, `ProviderDropRoute`).
    /// - Text: an Inbox capture's prefixed id (`CanvasDrop.payload`), or a
    ///   research id the canvas has a card for (`CanvasItemIndex`, the
    ///   canvas's own refusal of every other id space — a chapter, a figure,
    ///   a to-do).
    /// - A canvas whose layout this build refused takes nothing
    ///   (`CanvasEditGate.accepts`, the canvas's own answer).
    @MainActor
    static func verdict(typeIdentifiers: [String], draggedId: String?,
                        items: CanvasItemIndex, isReadOnly: Bool,
                        carriesPictures: Bool = true) -> Verdict {
        switch ProviderDropRoute.route(typeIdentifiers: typeIdentifiers) {
        case .refuse:
            return .refuse
        case .external:
            guard carriesPictures else { return .refuse }
            return CanvasEditGate.accepts(.external, isReadOnly: isReadOnly) ? .files : .refuse
        case .internalPayload:
            guard let raw = draggedId else { return .refuse }
            switch CanvasDrop.payload(raw) {
            case .capture(let entryID):
                return CanvasEditGate.accepts(.capture, isReadOnly: isReadOnly)
                    ? .capture(entryID: entryID) : .refuse
            case .itemID(let id):
                guard items.entry(of: id) != nil else { return .refuse }
                return CanvasEditGate.accepts(.place, isReadOnly: isReadOnly) ? .research(id) : .refuse
            }
        }
    }

    /// The verdict for the drag in flight, read off the drag pasteboard —
    /// the hover's and the drop's one read.
    @MainActor
    static func verdict(on pasteboard: NSPasteboard, store: ProjectStore,
                        state: BinderTreeSectionsState) -> Verdict {
        let facts = facts(store: store, state: state)
        return verdict(typeIdentifiers: (pasteboard.types ?? []).map(\.rawValue),
                       draggedId: BinderTreeSections.draggedId(on: pasteboard),
                       items: facts.items, isReadOnly: facts.isReadOnly,
                       carriesPictures: carriesPictures(pasteboard))
    }

    /// **The drop itself**: `verdict`'s answer, performed through the Send to
    /// Canvas route. Returns whether it was accepted (a refusal springs the
    /// drag back).
    @MainActor
    static func perform(_ verdict: Verdict, providers: [NSItemProvider], host: Host,
                        report: @escaping (String) -> Void) -> Bool {
        let store = host.store
        let state = host.state
        let open = host.open
        func landed(_ node: CanvasNodeID) {
            CanvasCapture.show(node, in: store)
            if marksArrival(open: open) { state.canvasHasArrivals = true }
        }
        switch verdict {
        case .refuse:
            return false
        case .capture(let entryID):
            guard let inbox = store.documentStore?.inboxStore else { return false }
            Task { @MainActor in
                do {
                    let sent = try await inbox.sendToCanvas(
                        entryID: entryID, projectStore: store, placement: .loose)
                    landed(sent.node)
                } catch { report(error.localizedDescription) }
            }
            return true
        case .research(let id):
            do {
                let sent = try CanvasCapture.send(
                    .item(researchId: id, aspect: pictureAspect(of: id, store: store)),
                    .loose, captureID: id, store: store, projectRoot: store.url)
                landed(sent.node)
            } catch { report(error.localizedDescription) }
            return true
        case .files:
            let accepted = providers.filter { CanvasExternalDrop.accepts($0) }
            guard !accepted.isEmpty else { return false }
            Task { @MainActor in
                do {
                    // Before the copy, or a refused layout strands one (issue #33).
                    try CanvasCapture.refuseUnlessWritable(store: store, projectRoot: store.url)
                    let outcome = await CanvasExternalDrop.ingest(
                        providers: accepted,
                        using: CanvasAssetIngest(
                            file: { try await store.ingestCanvasAsset(fileURL: $0) },
                            image: { try await store.ingestCanvasAsset(image: $0) }))
                    for path in outcome.paths {
                        let sent = try CanvasCapture.send(
                            .picture(path: path, aspect: outcome.aspects[path]), .loose,
                            captureID: path, store: store, projectRoot: store.url,
                            mintsNodeID: true)
                        landed(sent.node)
                    }
                    if let message = outcome.message { report(message) }
                } catch { report(error.localizedDescription) }
            }
            return true
        }
    }

    /// A research picture's shape from its file's header, so its card is
    /// born at its real height (`CanvasDropHandler.pictureAspect`'s read with
    /// no thumbnail cache). Nil for an item with no pixels.
    @MainActor
    private static func pictureAspect(of id: String, store: ProjectStore) -> CGFloat? {
        guard let path = CanvasItemIndex.over(research: store.manifest.research)
                .entry(of: id)?.thumbnailPath,
              let url = try? SafeRelativePath.resolve(path, under: store.url) else { return nil }
        return CanvasThumbnails.headerAspect(of: url)
    }
}

/// The Canvas row as a drop target: its highlight while an accepted drag is
/// over it, nothing over a refused one, and the drop — both asking
/// `TreeCanvasRowDrop.verdict` of the same drag.
struct TreeCanvasRowDropTarget: ViewModifier {
    let host: TreeCanvasRowDrop.Host
    @State private var isTargeted = false
    @State private var hovering: TreeCanvasRowDrop.Verdict = .refuse

    func body(content: Content) -> some View {
        content
            .treeDropHighlight(TreeDropFeedback.into(isTargeted && hovering.accepts))
            // ONE provider drop on the row, the canvas's own shape (#109):
            // a capture, a research id and a file reach the same verdict.
            .onDrop(of: ProviderDropRoute.acceptedTypes, isTargeted: $isTargeted) { providers in
                let verdict = TreeCanvasRowDrop.verdict(on: NSPasteboard(name: .drag),
                                                        store: host.store, state: host.state)
                return TreeCanvasRowDrop.perform(
                    verdict, providers: providers, host: host,
                    report: { host.state.pendingError = $0 })
            }
            // Asked once as the drag arrives, never per frame: the read may
            // look at the canvas's layout file.
            .onChange(of: isTargeted) { _, now in
                hovering = now ? TreeCanvasRowDrop.verdict(on: NSPasteboard(name: .drag),
                                                           store: host.store, state: host.state) : .refuse
            }
    }
}
