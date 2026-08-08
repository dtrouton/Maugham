import SwiftUI
import MaughamCore
import AppKit
import os

/// Subsystem from the running bundle id so dev/stable logs separate without
/// hardcoding "com.maugham" (tripwire 13 spirit).
private let _binderTreeSectionsLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "BinderTreeSections")

/// **The Research and Palette sections at the foot of every binder tree**
/// (shell-finish stage-2a Task 4, spec §3).
///
/// The milestone gives every persona ONE left column, so research and palette
/// stop being panes the writer switches to and become furniture at the foot of
/// whichever tree the project type puts up. There are three of those hosts —
/// `BinderView`, `CollectionPiecesPane`, `SceneNavigatorPane` — and a writer
/// must not be able to tell which one they are looking at from the sections'
/// behaviour.
///
/// **So the sections are one implementation, mounted three times, rather than
/// one per host.** The plan's contract says "each host fills ONE
/// `ResearchTreeActions` bundle"; there is one bundle in the app, built here,
/// which is that contract's stronger form. Three copies of ~150 lines of store
/// wiring is precisely the shape CLAUDE.md means by *a copy drifts* — and stage
/// 2b deletes `ResearchView` and `CollectionResearchPane`, which is far cheaper
/// against one implementation than three.
///
/// **Mounting takes two touchpoints, and the second is not optional.** The rows
/// go inside the host's `List`; the presentations they need — the Add Link
/// sheet, the error alert, the palette-card load, the deferred rename commit —
/// go OUTSIDE it via `.binderTreeSections(store:state:)`, which is where
/// `CollectionResearchPane` puts the same two modifiers and for the same
/// reason: a sheet attached to a row inside a lazy list is presented from a view
/// the list may unmount. Forgetting the modifier is a live defect that no row
/// count would catch, so `TripwireGrepTests` censuses the pairing.
struct BinderTreeSections: View {
    @Bindable var store: ProjectStore
    @Bindable var state: BinderTreeSectionsState
    @Binding var selectedSubject: BinderSubject?

    var body: some View {
        researchSection
        paletteSection
    }

    // MARK: - Research

    private var researchSection: some View {
        Section {
            let roots = TreeSectionDerivation.sharedResearchRoots(
                research: store.manifest.research,
                projectType: store.manifest.type)
            if roots.isEmpty {
                placeholder("No research yet.")
            } else {
                ForEach(roots) { item in
                    ResearchTreeNode(
                        item: item,
                        renamingItemId: $state.renamingItemId,
                        findParentId: { findParentId(of: $0) },
                        actions: actions,
                        // The one difference from the old panes: their `List`s
                        // select over `Set<String>` and tag bare ids; the tree's
                        // selection is the WINDOW's subject.
                        tagFor: { BinderSubject.research($0.id) })
                }
            }
        } header: {
            sectionHeader("Research") {
                Button("New Note") { actions.newNote(nil) }
                Button("New Group") { actions.newGroup(nil) }
                Button("Add File…") { actions.addFile(nil) }
                Button("Add Link…") { actions.addLink(nil) }
            }
        }
    }

    // MARK: - Palette

    /// Palette rows are FLAT and carry no tree of their own: a card is a
    /// research `.document` under `research/palette/`, and the group holding
    /// them is the section. They are tagged `.research(card.id)` because
    /// `PaletteCard.id` **is** the research item's id — a `.paletteCard` subject
    /// case would be a second name for one id (plan constraint).
    ///
    /// The cards come from `state.cards`, loaded once per manifest change by
    /// `.binderTreeSections(store:state:)` — tripwire 4: a row that reads its
    /// own card off disk turns a binder click into N file reads.
    private var paletteSection: some View {
        Section {
            if state.cards.isEmpty {
                placeholder("No cards yet.")
            } else {
                ForEach(state.cards) { card in
                    Label(card.title,
                          systemImage: PaletteCardTile.kindSymbol(for: card.kind))
                        .tag(BinderSubject.research(card.id))
                }
            }
        } header: {
            // The group's LIVE title, not the convention's: the writer can
            // rename it, and the header that names it must follow.
            sectionHeader(store.paletteGroupDisplayTitle) {
                ForEach(PaletteCard.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue.capitalized) { addCard(kind: kind) }
                }
            }
        }
    }

    // MARK: - Shared row shapes

    /// A section header: its name, its `+` menu, and the SAME verbs on
    /// right-click.
    ///
    /// **Both, from one closure.** The `+` button is the shape both old panes
    /// use and is the discoverable one; the context menu is what a writer who
    /// right-clicks a header expects, and without it the click falls through to
    /// the binder's root menu and offers *New Document* under a heading that
    /// says Research.
    private func sectionHeader<Menu: View>(
        _ title: String, @ViewBuilder menu: @escaping () -> Menu
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            SwiftUI.Menu(content: menu) {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .contextMenu(menuItems: menu)
    }

    /// The one row an empty section shows.
    ///
    /// **It is a row rather than a section-level affordance because a drop on an
    /// empty `Section` never fires** — SwiftUI gives it no live drop region
    /// (`CollectionResearchPane.swift`'s measured lesson). Task 7 makes this the
    /// full-width target; until then its destination REFUSES, so a note dragged
    /// here is returned to where it came from rather than accepted and dropped
    /// on the floor.
    ///
    /// **It carries no `.tag`, and that is why the trees' selection binding
    /// refuses a `nil` write** (`BinderTreeSelection`). An untagged row is
    /// selected anyway and writes `nil` through the binding — measured on
    /// `BinderView`'s old empty-state row, macOS 26.5 — which would blank the
    /// centre column every time a writer clicked "No research yet."
    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { ids, _ in
                refuseDrop("empty section placeholder", payload: ids.first)
                return false
            }
    }

    // MARK: - Actions

    /// The one `ResearchTreeActions` bundle in the app's binder trees, wired to
    /// the same `ProjectStore` APIs `ResearchView` and `CollectionResearchPane`
    /// call.
    ///
    /// **Scope is shared, always.** A tree's Research section is the project's
    /// shared research in every project type; a collection piece's own research
    /// is Task 6's fold under the piece row, and creating from this header must
    /// not silently land there. `addResearchTextNote(parentId: nil)` is exactly
    /// what `createResearchNote(scope: .shared)` routes to, so the two surfaces
    /// cannot disagree.
    private var actions: ResearchTreeActions {
        ResearchTreeActions(
            rename: { id, newTitle in
                perform { try await store.updateResearchItem(id: id, title: newTitle) }
            },
            internalDrop: { draggedId, _, target in
                refuseDrop("research row \(target.id)", payload: draggedId)
            },
            externalDrop: { _, _, target in
                refuseDrop("research row \(target.id)", payload: nil)
            },
            newNote: { parentId in
                create { try await store.addResearchTextNote(
                    parentId: parentId, title: "Untitled Note") }
            },
            newGroup: { parentId in
                create { try await store.addResearchItem(
                    parentId: parentId, title: "Untitled Group", kind: nil) }
            },
            addFile: { parentId in addFile(parentId: parentId) },
            addLink: { parentId in
                state.addLinkParentId = parentId
                state.showingAddLinkSheet = true
            },
            duplicate: { id in
                create { try await store.duplicateResearchItem(id: id) }
            },
            delete: { id in
                perform { try await store.deleteResearchItem(id: id) }
            },
            // **2a is single-select** (plan constraint): the tree's selection is
            // the window's one subject, so the acting set for a row is that row.
            // Multiselect survives in the old panes until 2b, which carries it.
            selectionForRow: { [$0] },
            moveTargets: { ids in
                ResearchSelectionSync.moveTargets(forIds: ids, manifest: store.manifest)
            },
            move: { ids, target in
                perform { try await store.moveResearchItems(ids: ids, to: target) }
            },
            deleteMany: { ids in
                perform { try await store.deleteResearchItems(ids: ids) }
            })
    }

    private func addFile(parentId: String?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        perform { _ = try await store.importResearchFiles(urls, toParentId: parentId) }
    }

    private func addCard(kind: PaletteCard.Kind) {
        create { try await store.addPaletteCard(
            title: "New \(kind.rawValue)", kind: kind) }
    }

    /// Runs a store mutation, surfacing any failure in the alert the host
    /// attaches. Nothing here repairs the subject on a delete — the window's own
    /// sweep does that (`SubjectValidationModifier`, Task 2), and a second rule
    /// beside it is how the two come to disagree.
    private func perform(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await work() }
            catch { state.pendingError = error.localizedDescription }
        }
    }

    /// Runs a store mutation that MAKES something, and points the window at it.
    ///
    /// **Creating from a header selects the new thing**, which is the whole
    /// reason these verbs live on the tree rather than in a menu somewhere: the
    /// writer asked for a note, so the note is what the window is now about. The
    /// rename is deferred rather than set here — the row does not exist until
    /// the manifest change arrives, and `pendingRenameId` is committed by the
    /// host's `.onChange` when it does (the shape both old panes use).
    private func create(_ work: @escaping () async throws -> ResearchItem) {
        Task { @MainActor in
            do {
                let item = try await work()
                selectedSubject = .research(item.id)
                state.pendingRenameId = item.id
            } catch {
                state.pendingError = error.localizedDescription
            }
        }
    }

    /// **Task 7's placeholder, and it refuses out loud.**
    ///
    /// `ResearchTreeActions`' drop closures return `Void`, and `ResearchRow`'s
    /// own `.dropDestination` returns `true` unconditionally — so a stub that
    /// simply did nothing would tell the writer the drop was ACCEPTED and then
    /// discard it, which is the silent-no-op shape the publishing-namespace
    /// finding says to fail loudly on. The only channel a `Void` closure has is
    /// the log, so it uses it; the placeholder rows, whose destinations return a
    /// value, refuse properly by returning `false`.
    private func refuseDrop(_ target: String, payload: String?) {
        _binderTreeSectionsLog.warning(
            "binder tree refused a drop on \(target, privacy: .public) with payload \(payload ?? "external", privacy: .public) — routing lands in stage-2a Task 7")
    }

    private func findParentId(of childId: String) -> String? {
        store.findResearchParentId(of: childId, in: store.manifest.research, parent: nil)
    }
}

// MARK: - State

/// The sections' mutable state, owned by the HOST rather than by the sections
/// themselves, because the presentations that read it are attached outside the
/// host's `List` while the rows that write it are inside one.
///
/// A reference type rather than a pile of `@Binding`s so that adding a piece of
/// state does not re-thread three call sites — and so the pairing a host has to
/// get right is one value in two places rather than five.
@MainActor
@Observable
final class BinderTreeSectionsState {
    /// The row currently showing its inline-rename `TextField` (tripwire 16 —
    /// `ResearchRow` owns the focus dance; nothing here touches it).
    var renamingItemId: String?
    /// A row that should go into rename mode as soon as it EXISTS. A freshly
    /// created item is not in the manifest the current body pass rendered, so
    /// setting `renamingItemId` directly names a row nobody drew.
    var pendingRenameId: String?
    var pendingError: String?
    var showingAddLinkSheet: Bool = false
    /// Which group the Add Link sheet's result belongs in; `nil` is the shared
    /// root.
    var addLinkParentId: String?
    /// Palette cards, parsed from disk once per manifest change (tripwire 4).
    var cards: [PaletteCard] = []

    init() {}
}

// MARK: - The host's half

extension View {
    /// The presentations `BinderTreeSections` needs, attached OUTSIDE the
    /// host's `List`. Every host that mounts the sections must also attach this
    /// — see `BinderTreeSections` for why the pairing is split, and
    /// `TripwireGrepTests` for the census that keeps a host from having one half
    /// without the other.
    func binderTreeSections(store: ProjectStore,
                            state: BinderTreeSectionsState) -> some View {
        modifier(BinderTreeSectionsPresentations(store: store, state: state))
    }
}

private struct BinderTreeSectionsPresentations: ViewModifier {
    @Bindable var store: ProjectStore
    @Bindable var state: BinderTreeSectionsState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.showingAddLinkSheet) {
                AddResearchLinkSheet(
                    onAdd: { title, url in
                        let parentId = state.addLinkParentId
                        state.showingAddLinkSheet = false
                        Task { @MainActor in
                            do {
                                _ = try await store.addResearchLink(
                                    parentId: parentId, title: title, url: url)
                            } catch {
                                state.pendingError = error.localizedDescription
                            }
                        }
                    },
                    onCancel: { state.showingAddLinkSheet = false })
            }
            .alert(state.pendingError ?? "",
                   isPresented: Binding(
                    get: { state.pendingError != nil },
                    set: { if !$0 { state.pendingError = nil } })) {
                Button("OK", role: .cancel) {}
            }
            // One load per manifest change, never per row (tripwire 4).
            .task(id: store.manifest.modified) {
                state.cards = store.loadPaletteCards()
            }
            // The deferred rename, committed when the row it names exists. Both
            // triggers are needed and either alone is incomplete: the manifest
            // may arrive after the request, or the request after the manifest.
            .onChange(of: store.manifest.research) { _, _ in commitPendingRename() }
            .onChange(of: state.pendingRenameId) { _, _ in commitPendingRename() }
    }

    private func commitPendingRename() {
        guard let id = state.pendingRenameId,
              TreeWalk.contains(id: id, in: store.manifest.research) else { return }
        state.renamingItemId = id
        state.pendingRenameId = nil
    }
}

// MARK: - Selection

/// What a binder tree's `List` selection means for the window's subject.
///
/// **One rule, three trees.** Every tree now holds untagged rows — the empty
/// sections' placeholders — and an untagged row does not decline to be
/// selected: it is selected and the `List` writes `nil` through the binding
/// (measured on `BinderView`'s old empty-state message row, macOS 26.5). A
/// `nil` subject blanks the centre column, so without this a writer clicking
/// "No research yet." would lose the editor.
///
/// `SceneNavigatorPane` already reached this conclusion for its untagged
/// slugline rows and has a projection of its own; it calls this for the case
/// the two share rather than spelling it a second time.
enum BinderTreeSelection {

    /// The subject after the `List` writes `written`. Anything the tree tags is
    /// a subject; a `nil` leaves the subject exactly where it was.
    static func subject(_ current: BinderSubject?,
                        whenListWrites written: BinderSubject?) -> BinderSubject? {
        switch written {
        case .project, .item, .research: return written
        case .none: return current
        }
    }

    /// `subject` as a `List(selection:)` binding: reads the window's subject
    /// straight through (a tree highlights whichever of its rows the window is
    /// about, and nothing when it draws no row for it), writes through the rule.
    static func binding(_ subject: Binding<BinderSubject?>) -> Binding<BinderSubject?> {
        Binding(
            get: { subject.wrappedValue },
            set: { written in
                subject.wrappedValue = Self.subject(
                    subject.wrappedValue, whenListWrites: written)
            })
    }
}
