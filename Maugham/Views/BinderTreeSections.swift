import SwiftUI
import MaughamCore
import AppKit
import os
import UniformTypeIdentifiers

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
/// 2b Task 7 deleted `ResearchView` and `CollectionResearchPane`, which was far
/// cheaper against one implementation than three.
///
/// **Mounting takes two touchpoints, and the second is not optional.** The rows
/// go inside the host's `List`; the presentations they need — the Add Link
/// sheet, the error alert, the palette-card load, the deferred rename commit —
/// go OUTSIDE it via `.binderTreeSections(store:state:selectedSubject:)`, which
/// is where the deleted `CollectionResearchPane` put the same two modifiers, for
/// the same reason: a sheet attached to a row inside a lazy list is presented from a view
/// the list may unmount. Forgetting the modifier is a live defect that no row
/// count would catch, so `TripwireGrepTests` censuses the pairing.
struct BinderTreeSections: View {
    @Bindable var store: ProjectStore
    @Bindable var state: BinderTreeSectionsState
    @Binding var selectedSubject: BinderSubject?
    /// Whether the Palette header's "Open Wall" affordance is live — false in
    /// Plan, where the centre column is the canvas and the wall taking it over
    /// there is stage 3's call (shell-finish stage 2b Task 5). Derived by the
    /// caller from `persona != .plan` today; Task 6 re-bases the segment-shaped
    /// predicates this file already reads onto `Persona` directly, and this one
    /// can fold into that pass then.
    ///
    /// Defaulted so the mounted-tree fixtures across `BinderPieceFoldTests`,
    /// `BinderTreeSectionsTests`, `BinderTreeMultiselectMountTests` and
    /// `BinderTreeDropRoutingTests` — none of which are about the wall's door —
    /// keep compiling unchanged.
    var canOpenPaletteWall: Bool = true
    /// Opens the palette wall in the centre column — `ProjectWindow`'s
    /// `showsPaletteWall = true` (stage 2b Task 5). Defaulted for the same
    /// reason `canOpenPaletteWall` is.
    var onOpenPaletteWall: () -> Void = {}

    var body: some View {
        researchSection
        paletteSection
    }

    // MARK: - Research

    private var researchSection: some View {
        // **`isExpanded:` since stage-3a Task 4** — see
        // `BinderTreeSectionsState.researchSectionExpanded`. What the writer
        // clicks is unchanged; what is new is that the reveal can open a section
        // the writer closed, which is what made **Open** and **Show** able to
        // point at a row nothing was drawing.
        Section(isExpanded: $state.researchSectionExpanded) {
            let roots = TreeSectionDerivation.sharedResearchRoots(
                research: store.manifest.research,
                projectType: store.manifest.type)
            if roots.isEmpty {
                placeholder("No research yet.", onDrop: { ids in
                    sharedSectionDrop(ids)
                }, onExternalDrop: { providers in
                    sharedSectionExternalDrop(providers)
                })
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
                        tagFor: { BinderSubject.research($0.id) },
                        // The section's groups open out of the shared state, so
                        // `reveal` can open the ones between a revealed item and
                        // the root. The piece folds pass nothing and keep
                        // SwiftUI's own — see `ResearchTreeNode.expandedGroups`.
                        expandedGroups: $state.expandedResearchGroups)
                }
            }
        } header: {
            sectionHeader("Research") {
                Button("New Note") { actions.newNote(nil) }
                Button("New Group") { actions.newGroup(nil) }
                Button("Add File…") { actions.addFile(nil) }
                Button("Add Link…") { actions.addLink(nil) }
            }
            // **The header is the section's drop target when the section has
            // rows** (Task 7). The placeholder below is the target when it has
            // none, and a `Section` gets no live drop region of its own — so
            // without this there would be no way to drag a note OUT of a
            // chapter's fold in a novel at all: a novel's linked note is a
            // shared item that is already showing in this very section, so the
            // empty-section placeholder can never be on screen while a fold
            // has something in it.
            .dropDestination(for: String.self) { ids, _ -> Bool in
                return sharedSectionDrop(ids)
            }
            // **The string destination FIRST, the provider drop after it**
            // (stage-2b Task 4), and the order is a shipped bug rather than a
            // style question: `.onDrop(of:)` claims the drag session on hover,
            // before any payload is examined, so mounted first it leaves the
            // destination behind it dead — an internal drag onto this header
            // would do nothing at all, silently, while a Finder file still
            // landed. Both instances of that were found by a writer and neither
            // by a test; `TripwireGrepTests` censuses the ordering, and this
            // file is now one of its members.
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                return sharedSectionExternalDrop(providers)
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
    /// `.binderTreeSections(store:state:selectedSubject:)` — tripwire 4: a row
    /// that reads its own card off disk turns a binder click into N file reads.
    private var paletteSection: some View {
        // Its twin above carries why this takes a binding.
        Section(isExpanded: $state.paletteSectionExpanded) {
            if state.cards.isEmpty {
                // The palette's placeholder refuses: a card is MADE (the
                // header's `+` menu), never dragged into being, and the
                // section's rows are not drop targets either.
                placeholder("No cards yet.", onDrop: { ids in
                    refuseDrop("palette placeholder", payload: ids.first,
                               reason: .notAResearchTarget)
                }, onExternalDrop: { _ in
                    // A card is MADE, from the header's `+` menu — and that
                    // goes for a Finder file too: a dropped image is research,
                    // and a card is a written thing with an image on it.
                    refuseDrop("palette placeholder", payload: nil,
                               reason: .notAResearchTarget)
                })
            } else {
                ForEach(state.cards) { card in
                    Label(card.title,
                          systemImage: PaletteCardTile.kindSymbol(for: card.kind))
                        .tag(BinderSubject.research(card.id))
                        .contentShape(Rectangle())
                        // **A card is dragged by its BARE id** (final review's
                        // I2). That is the canvas's own drop contract — the
                        // canvas reads a research id and derives its node id
                        // from it — and it is what `ResearchRow` sends, so a
                        // card and a note are the same payload to every reader.
                        // The Inbox's prefixed payload is the exception and
                        // says so at its own site.
                        .draggable(card.id) {
                            Text(card.title)
                                .padding(6)
                                .background(.regularMaterial,
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                        .contextMenu { paletteRowMenu(for: card) }
                }
            }
        } header: {
            paletteSectionHeader
        }
    }

    /// **What a writer can do to a card from the tree** (stage 2b final
    /// review's I2).
    ///
    /// Every management verb the palette had lived on `ResearchView`'s rows and
    /// died with that pane in Task 7: the capability census enumerated the PANE's
    /// affordances and missed that 2a's palette rows were already bare `Label`s,
    /// so there was nothing on the tree for the deletion to take away and nothing
    /// to notice. A card could be made and edited and never removed.
    ///
    /// **Duplicate and Delete, through the same bundle the research rows use** —
    /// a card is an ordinary research `.document` under `research/palette/`, so
    /// `duplicateResearchItem`/`deleteResearchItem(s)` are its verbs too and no
    /// new store API exists here.
    ///
    /// **Rename is deliberately absent, and so is Move to.** A card's title is
    /// the card's own H1 — `PaletteCardEditor` owns it, and
    /// `updatePaletteCard` routes a title change through the typed mover so the
    /// file, its `_assets/` folder and its refs move together. An inline rename
    /// in the tree would write the manifest title alone and leave the card's
    /// own heading behind. Move to would take the card OUT of the palette group,
    /// which is what makes it a card at all.
    @ViewBuilder
    private func paletteRowMenu(for card: PaletteCard) -> some View {
        // The whole selection when this row is inside one — the research rows'
        // rule, asked rather than re-spelled, so ⌘-clicking two cards and
        // deleting offers the same verb it does one section up.
        let acting = actions.selectionForRow(card.id)
        if acting.count > 1 {
            Button("Delete \(acting.count) Items", role: .destructive) {
                actions.deleteMany(acting)
            }
        } else {
            Button("Duplicate") { actions.duplicate(card.id) }
            Button("Delete", role: .destructive) { actions.delete(card.id) }
        }
    }

    /// The Palette section's own header: its live title, its `+` creation
    /// menu, and — since stage 2b Task 5 — the wall's own door. `.palette`
    /// dies with the strip in Task 7; this button is what survives it, so a
    /// writer can still reach the wall of images once the segment picker that
    /// used to carry it is gone.
    ///
    /// **A button of its own rather than folded into the `+` menu**, per the
    /// task's contract: opening the wall is not a creation verb, and burying
    /// it inside "New Swatch / New Photo / New Note" would read as one more
    /// kind of card rather than a door to all of them. Mirrored onto the
    /// header's own context menu for the writer who right-clicks instead of
    /// hunting for the icon — `sectionHeader`'s shape, one arm wider.
    ///
    /// **Disabled rather than hidden in Plan.** Plan's centre column is the
    /// canvas; the wall taking it over there is stage 3's call. A hidden
    /// button reads as "no door here", where a disabled one with a tooltip
    /// says what is actually true — the door exists, this room just does not
    /// open into it yet.
    private var paletteSectionHeader: some View {
        HStack {
            Text(store.paletteGroupDisplayTitle)
            Spacer()
            openWallButton
            SwiftUI.Menu(content: paletteCreationMenu) {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open Wall", action: onOpenPaletteWall)
                .disabled(!canOpenPaletteWall)
            Divider()
            paletteCreationMenu()
        }
    }

    @ViewBuilder
    private func paletteCreationMenu() -> some View {
        ForEach(PaletteCard.Kind.allCases, id: \.self) { kind in
            Button(kind.rawValue.capitalized) { addCard(kind: kind) }
        }
    }

    /// **The target is the frame, not the glyph** (Denver's smoke, 2026-08-10).
    ///
    /// A bare `Image` inside a `Button(.plain)` hit-tests the box it draws in and
    /// nothing more. Measured on this SDK with real mouse events through a
    /// mounted tree: the live region was **13×10pt in the middle of a 19pt header
    /// row**, so a click on the icon's own top or bottom edge did nothing at all
    /// — not the door, and not the section's own disclosure either; the header's
    /// `.contentShape(Rectangle())` swallowed it. The writer's reading was that
    /// only the icon's top half worked.
    ///
    /// **Not a regression from the `isExpanded:` conversion**, which is where it
    /// was first looked for: a plain `Section` header carrying the identical
    /// button measures the identical 10pt band (`PaletteWallDoorHitAreaTests`'
    /// control). The door has always been this small; stage 3a only changed what
    /// was around it.
    ///
    /// **21×15 is the `+` menu's own size**, read off the mounted window rather
    /// than chosen: `SwiftUI.Menu` mounts a real `SwiftUIPopupButton` `NSView`
    /// that is live across its whole frame, which is why the `+` beside this
    /// button never had the defect. Matching it makes the row's two accessories
    /// one size, and leaves the header's height exactly where it was.
    ///
    /// It is a match rather than a ceiling, and the difference was measured: the
    /// 19pt header row absorbs a 19pt child without moving, and only grows at
    /// around 30. So there is real headroom here if the door ever wants more —
    /// what there is no headroom for is the two accessories disagreeing, since
    /// they sit a few points apart on one row in every tree in the app.
    ///
    /// `.contentShape` is the half that does the work: without it the frame is
    /// layout only and the glyph is still all that answers a click.
    private var openWallButton: some View {
        Button(action: onOpenPaletteWall) {
            Image(systemName: "rectangle.grid.2x2")
                .frame(width: 21, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpenPaletteWall)
        .help(canOpenPaletteWall
              ? "Open the Palette wall"
              : "The Palette wall isn't available in Plan — Plan's centre "
                + "column is the canvas.")
        .accessibilityLabel("Open Wall")
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
    /// (`CollectionResearchPane.swift`'s measured lesson). Since Task 7 it is
    /// the Research section's full-width drop target — its `onDrop` is the
    /// section's, and the Palette's placeholder passes a refusal instead, since
    /// a card is made and never dragged into being.
    ///
    /// **It carries no `.tag`, and that is why the trees' selection binding
    /// refuses a `nil` write** (`BinderTreeSelection`). An untagged row is
    /// selected anyway and writes `nil` through the binding — measured on
    /// `BinderView`'s old empty-state row, macOS 26.5 — which would blank the
    /// centre column every time a writer clicked "No research yet."
    private func placeholder(
        _ text: String, onDrop: @escaping ([String]) -> Bool,
        onExternalDrop: @escaping ([NSItemProvider]) -> Bool
    ) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // **`-> Bool` and an explicit `return`, both deliberately** (fix
            // round 2). Written without them, this closure bound to a
            // Void-returning `dropDestination` overload, so `refuseDrop`'s
            // `false` went nowhere and the placeholder accepted the drag and
            // discarded it — the round-1 defect again, one layer out, and the
            // compiler said so in a warning nobody read
            // (`result of call to 'refuseDrop(_:payload:)' is unused`). The
            // annotated result type is what forces the Bool overload; the
            // `return` is what makes a future reader see the value matters.
            .dropDestination(for: String.self) { ids, _ -> Bool in
                return onDrop(ids)
            }
            // The section's other drop kind, mounted AFTER the string one for
            // the reason the header's is — see there. An empty Research section
            // is exactly where a writer drags their first file, and until Task
            // 4 the only surface that would take it was a pane about to be
            // deleted.
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                return onExternalDrop(providers)
            }
    }

    // MARK: - Actions

    /// The tree's verbs. See `BinderTreeVerbs` — they are a value rather than
    /// something this view owns, because `BinderPieceFold` needs the same ones
    /// and reaching into a `View` for them would make every fold look like a
    /// fourth section host to `TripwireGrepTests`' pairing census.
    var verbs: BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state, selectedSubject: $selectedSubject)
    }

    /// The one `ResearchTreeActions` bundle in the app's binder trees.
    ///
    /// Not `private`: `BinderTreeSectionsTests` asks this bundle directly
    /// whether it accepts a drop. The drop verbs are the one thing here that a
    /// mounted test cannot drive — a real drag session is not synthesisable —
    /// so the refusal is asserted at the value the row actually returns.
    var actions: ResearchTreeActions { verbs.bundle }

    private func addCard(kind: PaletteCard.Kind) {
        verbs.create { try await store.addPaletteCard(
            title: "New \(kind.rawValue)", kind: kind) }
    }

    private func refuseDrop(_ target: String, payload: String?,
                            reason: TreeDropIntent.Reason? = nil) -> Bool {
        verbs.refuseDrop(target, payload: payload, reason: reason)
    }

    /// The Research section as a drop target — mounted twice, on its header and
    /// on the placeholder an empty section shows, because those are the two
    /// times exactly one of them is on screen.
    ///
    /// Not `private`: `BinderTreeSectionsTests` asks the section directly what
    /// a drop on it does, for the reason the drop verbs are reachable at all —
    /// a real drag session is not synthesisable headless.
    func sharedSectionDrop(_ ids: [String]) -> Bool {
        guard let id = ids.first else { return false }
        return verbs.routeSharedSectionDrop(draggedId: id)
    }

    /// The same two targets, for a Finder file or a browser bitmap (stage-2b
    /// Task 4). The section IS the shared root, so this is the plain import —
    /// and it is reachable for the same reason `sharedSectionDrop` is.
    func sharedSectionExternalDrop(_ providers: [NSItemProvider]) -> Bool {
        verbs.routeExternalDrop(providers: providers, position: .middle,
                                target: .sharedSection)
    }

    private func findParentId(of childId: String) -> String? {
        verbs.findParentId(of: childId)
    }

    /// What the Add Link sheet does with its answer — **a creation verb like any
    /// other here, so it points the window at what it made** (fix round 1).
    ///
    /// A `static` taking the binding rather than a closure inside the sheet,
    /// because the sheet's completion is not reachable from a test: the modifier
    /// is private, a `ViewModifier`'s body cannot be driven headless, and there
    /// is no synthesisable path from "the writer typed a URL and pressed Add" to
    /// this code. It shipped discarding the created link, and nothing could have
    /// caught that — this is the smallest shape that makes the write assertable
    /// (`BinderTreeSectionsTests.test_addLinkPointsTheWindowAtTheLinkItMade`).
    ///
    /// Deliberately sets no `pendingRenameId`: the sheet already asked for the
    /// title, and both old panes leave a new link out of rename mode for that
    /// reason.
    static func addLink(
        title: String, url: String, parentId: String?,
        store: ProjectStore, state: BinderTreeSectionsState,
        selectedSubject: Binding<BinderSubject?>
    ) async {
        do {
            let link = try await store.addResearchLink(
                parentId: parentId, title: title, url: url)
            selectedSubject.wrappedValue = .research(link.id)
        } catch {
            state.pendingError = error.localizedDescription
        }
    }
}

// MARK: - The verbs

/// **The binder trees' research verbs, as a value.**
///
/// Every row in a tree's Research section — and, since Task 6, every row in a
/// piece's fold — acts through one `ResearchTreeActions` bundle wired to one
/// set of `ProjectStore` calls. Three copies of that wiring is exactly the
/// shape CLAUDE.md means by *a copy drifts*.
///
/// **Why it is not a computed property on `BinderTreeSections`, where it
/// started.** `BinderPieceFold` needs the same bundle, and the only way to ask
/// a view for it is to construct the view — which put a `BinderTreeSections(`
/// call in a file that mounts no section, and that is precisely the token
/// `TripwireGrepTests.test_everyBinderTreeMountsBothHalvesOfTheSections` reads
/// as *a host mounting rows without their presentations*. The census was right
/// and the shape was wrong: verbs are a value, mounting is a view, and now the
/// two cannot be confused for one another.
///
/// **Scope is shared, always, here.** A tree's Research section is the
/// project's shared research in every project type; a collection piece's own
/// research is the fold under its piece row, and creating from a section header
/// must not silently land there. `addResearchTextNote(parentId: nil)` is
/// exactly what `createResearchNote(scope: .shared)` routes to, so the two
/// surfaces cannot disagree. `BinderPieceFold` re-routes the one verb for which
/// that default is wrong — see its `actions`.
@MainActor
struct BinderTreeVerbs {
    let store: ProjectStore
    let state: BinderTreeSectionsState
    @Binding var selectedSubject: BinderSubject?

    var bundle: ResearchTreeActions {
        ResearchTreeActions(
            rename: { id, newTitle in
                perform { try await store.updateResearchItem(id: id, title: newTitle) }
            },
            // **The tree's rows route by scope** (Task 7): what a drop MEANS is
            // `TreeDropIntent.classify`, what it DOES is `BinderTreeDrops`.
            // `inFoldOf: nil` — these are the shared section's rows;
            // `BinderPieceFold` re-routes this one verb with its document, for
            // the same reason it re-routes `newNote`.
            internalDrop: { draggedId, position, target in
                routeResearchRowDrop(draggedId: draggedId, position: position,
                                     target: target, inFoldOf: nil)
            },
            // **Routed since stage-2b Task 4**, and this is where 2a's one
            // declared gap closed. A Finder file dropped on a research row has
            // to land in a SCOPE, and the piece-root case looked like it had no
            // store API — `importResearchFiles(toParentId:)` reads `nil` as the
            // shared root, so a file dropped on a row at a Collection piece's
            // root would have imported to shared research silently. The rule
            // that fills it is `TreeDropIntent.container(ofRow:)`, which
            // already answers *"what does beside this row mean"* with a typed
            // scope; `importPieceResearchFiles` is the verb for its `.piece`
            // arm, and this is that store call's first caller outside the pane
            // stage 2b deletes. `inFoldOf` has its mirror here too —
            // `BinderPieceFold` re-routes this verb with its document.
            externalDrop: { providers, position, target in
                routeExternalDrop(providers: providers, position: position,
                                  target: .researchRow(target.id))
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
            // **The whole selection when the row is inside one** (stage-2b Task
            // 3). 2a's `{ [$0] }` was the tree's one concession to being
            // single-select, and the batch verbs the old panes carry — "Delete N
            // Items", a multi "Move to ▸", a batch drag — are all built on this
            // one closure, so widening it is what carries them across.
            selectionForRow: { rowId in actingIds(forRow: rowId) },
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

    /// **What a verb aimed at `rowId` acts on** — the tree's whole selection
    /// when that row is in it, else the row alone (stage-2b Task 3).
    ///
    /// It reads the SHOWN selection rather than the stored one, which matters
    /// the moment the subject moved without a click: a note created from a
    /// section header collapses the tree onto itself, and a menu built from the
    /// stored set would still offer "Delete 3 Items" over rows the tree has
    /// stopped highlighting. One projection, both readers.
    ///
    /// Not `private`: `BinderTreeDrops` is a file over and a batch DRAG carries
    /// the same ids a batch menu verb does — a drag that moved only the row
    /// under the cursor while three were highlighted is the same defect wearing
    /// a different gesture.
    func actingIds(forRow rowId: String) -> [String] {
        BinderTreeSelection.actingResearchIds(
            forRow: rowId,
            selection: BinderTreeSelection.shown(state.selection,
                                                 subject: selectedSubject),
            research: store.manifest.research)
    }

    private func addFile(parentId: String?) {
        let panel = Self.makeAddFilePanel()
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        perform { _ = try await store.importResearchFiles(urls, toParentId: parentId) }
    }

    /// **The Add File panel, and it takes folders** (stage-2b Task 4).
    ///
    /// `importResearchFiles` has always imported a folder as a group with its
    /// contents recursively under it, and `ResearchView`'s panel has always
    /// allowed one. Stage 2a's tree wrote `canChooseDirectories = false` with
    /// nothing said about it — an unflagged narrowing, harmless only for as
    /// long as the pane it copied from was still there to ask. Stage 2b deletes
    /// that pane, so the narrowing would have shipped as a capability the app
    /// simply lost.
    ///
    /// A factory rather than four lines inside `addFile` because `runModal()`
    /// is not drivable from a test: the panel's configuration is assertable,
    /// the modal it runs is not.
    static func makeAddFilePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        return panel
    }

    /// Runs a store mutation, surfacing any failure in the alert the host
    /// attaches. Nothing here repairs the subject on a delete — the window's own
    /// sweep does that (`SubjectValidationModifier`, Task 2), and a second rule
    /// beside it is how the two come to disagree.
    ///
    /// Not `private`: `BinderTreeDrops` — the peer extension that performs what
    /// `TreeDropIntent` decided — is a file over, and a store failure it causes
    /// (the mover refusing to take a role-bearing item across scopes, a group
    /// into its own descendant) has to reach the same alert every other verb's
    /// does. A second error channel is how two surfaces come to disagree about
    /// whether anything went wrong.
    func perform(_ work: @escaping () async throws -> Void) {
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
    ///
    /// Not `private`: `BinderPieceFold` re-routes exactly one creation verb
    /// (Task 6) and calls this for the rest of what creating means, so the
    /// tree's headers and its folds cannot come to disagree about what happens
    /// after something is made.
    func create(_ work: @escaping () async throws -> ResearchItem) {
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

    /// **A refused drop, said out loud.** The drag bounces back to where the
    /// writer took it from and the log says why (`reason`, since Task 7 —
    /// before it every refusal was the same sentence about unbuilt routing).
    ///
    /// This shipped wrong once and the fix is worth recording. The first version
    /// returned `Void` and only logged, on the reasoning that a `Void` closure
    /// has no other channel — but `ResearchRow`'s `.dropDestination` was
    /// returning `true` unconditionally, so "accepted" was a property of the row
    /// rather than of the handler: a note dragged onto a populated research row
    /// animated home as accepted and was then silently discarded. That is the
    /// exact silent-no-op the publishing-namespace finding says to fail loudly
    /// on. The drop closures now return `Bool` all the way down, so the row
    /// returns the handler's answer and the compiler asks every caller
    /// (fix round 1).
    ///
    /// Returns `false`, always, and says why in the log.
    func refuseDrop(_ target: String, payload: String?,
                    reason: TreeDropIntent.Reason? = nil) -> Bool {
        _binderTreeSectionsLog.warning(
            "binder tree refused a drop on \(target, privacy: .public) with payload \(payload ?? "external", privacy: .public): \(reason?.explanation ?? "no route", privacy: .public)")
        return false
    }

    func findParentId(of childId: String) -> String? {
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
    /// **The tree's `List` selection** (stage-2b Task 3) — every row of it, not
    /// just the sections': the whole tree is one `List`, and one selection is
    /// what a `List` has.
    ///
    /// It lives on the sections' state rather than in each host because that is
    /// where the verbs can already reach it. `BinderTreeVerbs` is handed this
    /// object, and *what a right-click acts on* is a verb's question
    /// (`selectionForRow`) — a selection held privately by each of the three
    /// hosts would have to be threaded back down to the bundle through three
    /// call sites and `BinderPieceFold`, and the copy that drifts is the one
    /// nobody has to keep in step.
    ///
    /// The window's subject is DERIVED from this and never stored twice — see
    /// `BinderTreeSelection`.
    var selection: Set<BinderSubject> = []

    /// **Whether the Research section is open** (stage-3a Task 4), and its
    /// Palette twin below it.
    ///
    /// Until this task the tree's expansion state did not exist anywhere: both
    /// `Section`s and every research group took the no-binding initialisers, so
    /// SwiftUI held the flags privately and nothing outside a mouse click could
    /// move them. `ProjectWindow.openResearchItem` recorded that as its one
    /// declared gap — it could point the window at a note and not make the note's
    /// row visible.
    ///
    /// It lives here for `selection`'s reason exactly, and the reason is stronger
    /// for this one: the value has FOUR writers — the two `Section`s the writer
    /// clicks, the reveal, and the window that calls it — and three of them are
    /// in different files from the fourth. `true` is what SwiftUI drew before
    /// this existed, so a fresh window looks the same as it always did.
    var researchSectionExpanded: Bool = true
    var paletteSectionExpanded: Bool = true
    /// **The research groups that are OPEN**, by id — never the closed ones.
    ///
    /// A set of open ids makes the empty set mean "everything closed", which is
    /// what a binding-less `DisclosureGroup` already did, so converting the rows
    /// changed nothing a writer sees. The inverse spelling would have had to
    /// enumerate every group in the manifest to say the same thing, and would
    /// have to be swept as groups come and go — this one lets a stale id sit
    /// harmlessly, exactly as `selection` does and for the same reason (a row
    /// nothing draws reads nothing).
    var expandedResearchGroups: Set<String> = []

    /// **Open whatever it takes for `itemId`'s row to be on screen** — the
    /// section that holds it and every group between it and the root.
    ///
    /// The window's two forced entries call this beside their subject write:
    /// **Open** on a promoted card and **Show** on Claude's banner both name an
    /// item the writer is not necessarily looking at, and selecting a row inside
    /// a closed section highlights nothing. Everything else in the tree is
    /// already visible when it is clicked, which is why this is a call at two
    /// sites rather than an observer of the subject (a subject can also arrive
    /// from a restore, and a restore may not move the writer's tree).
    ///
    /// **It only ever opens.** A reveal is an addition to what is visible; a
    /// writer's other open groups are none of its business.
    ///
    /// The ancestor walk is `TreeWalk`'s — a group is an ancestor when it
    /// CONTAINS the item, which is `ResearchSelectionSync.moveTargets`' own
    /// spelling of the same question. No tree-walking code of its own lives here.
    func reveal(_ itemId: String, research: [ResearchItem]) {
        // An id no tree holds names no row. Opening the Research section on it
        // anyway would move the writer's tree for a Show banner naming a note
        // that has since been deleted.
        guard TreeWalk.contains(id: itemId, in: research) else { return }
        // A card is a research item under the palette group — but the Palette
        // section draws its cards FLAT, so the group is not an ancestor anything
        // shows. Role-first, through the one lookup `sharedResearchRoots` filters
        // with, so the two cannot disagree about what the palette group is.
        if let palette = PaletteLookup.paletteGroup(in: research),
           palette.id == itemId
            || TreeWalk.contains(id: itemId, in: palette.children ?? []) {
            paletteSectionExpanded = true
            return
        }
        researchSectionExpanded = true
        for group in TreeWalk.collect(in: research, where: { $0.type == .group })
        where TreeWalk.contains(id: itemId, in: group.children ?? []) {
            expandedResearchGroups.insert(group.id)
        }
    }

    init() {}
}

// MARK: - The host's half

extension View {
    /// The presentations `BinderTreeSections` needs, attached OUTSIDE the
    /// host's `List`. Every host that mounts the sections must also attach this
    /// — see `BinderTreeSections` for why the pairing is split, and
    /// `TripwireGrepTests` for the census that keeps a host from having one half
    /// without the other.
    ///
    /// It takes the subject binding as well as the state, because one of the
    /// presentations MAKES something: the Add Link sheet is a creation verb that
    /// happens to need a sheet, and creating from the tree selects the new thing
    /// like every other creation verb here (fix round 1).
    func binderTreeSections(store: ProjectStore,
                            state: BinderTreeSectionsState,
                            selectedSubject: Binding<BinderSubject?>) -> some View {
        modifier(BinderTreeSectionsPresentations(
            store: store, state: state, selectedSubject: selectedSubject))
    }
}

private struct BinderTreeSectionsPresentations: ViewModifier {
    @Bindable var store: ProjectStore
    @Bindable var state: BinderTreeSectionsState
    @Binding var selectedSubject: BinderSubject?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.showingAddLinkSheet) {
                AddResearchLinkSheet(
                    // **The new link becomes the subject** — creating from the
                    // tree selects the new thing, and a link is a creation verb
                    // like New Note and New Card. It shipped discarding the
                    // result, which made Add Link the one verb here that left
                    // the window pointed somewhere else (fix round 1); both old
                    // panes already select their new link, so it was a
                    // regression against the surfaces this one replaces.
                    //
                    // No `pendingRenameId`, deliberately, and this is where it
                    // differs from New Note: the sheet already asked for the
                    // title, so opening a rename field on top of the answer
                    // would be asking twice. Same reasoning as the old panes'.
                    onAdd: { title, url in
                        let parentId = state.addLinkParentId
                        state.showingAddLinkSheet = false
                        Task { @MainActor in
                            await BinderTreeSections.addLink(
                                title: title, url: url, parentId: parentId,
                                store: store, state: state,
                                selectedSubject: $selectedSubject)
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
            // **⌘V lands in shared research** (stage-2b Task 4) — the table is
            // `ResearchPasteImporter`'s, which is `ResearchView`'s moved, and
            // whether this window's paste is research's at all is
            // `TreePasteRouting`'s. Mounted here rather than in each host for
            // the reason every other presentation is: three copies of the same
            // wiring is the shape that drifts, and this modifier is what all
            // three trees already attach.
            .onPasteCommand(of: ResearchPasteImporter.acceptedTypeIdentifiers) { items in
                guard TreePasteRouting.acceptsPaste(subject: selectedSubject) else {
                    return
                }
                Task { @MainActor in
                    await ResearchPasteImporter(
                        store: store,
                        reportError: { state.pendingError = $0 }).paste(items)
                }
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

    // MARK: - More than one row (stage-2b Task 3)

    /// **The tree selects a SET, and the window's subject is derived from it.**
    ///
    /// Stage 2b Task 7 deleted `ResearchView` and `CollectionResearchPane`,
    /// which were the only surfaces in the app that could act on more than one
    /// note at a time — a "Delete 3 Items", a multi "Move to ▸", a batch drag. Those
    /// capabilities do not survive their panes unless the tree learns them, and
    /// the tree cannot learn them while its `List` selects one value.
    ///
    /// **The subject is derived, never a second state.** There is no flag and no
    /// `.onChange` reconciling the two (tripwire 2 — a flag-based loop guard
    /// between two mirrors of the same thing leaked in exactly this shape in
    /// Phase 3d): `shown` projects the stored set through the subject on the way
    /// out, `resolved` derives the subject from the set on the way in, and both
    /// are pure.
    ///
    /// **A write of one row never reaches the anchor rule.** `resolved` sends it
    /// straight to `subject(_:whenListWrites:)` — the function stage 2a shipped,
    /// unchanged — so single-click behaviour is what it was, structurally rather
    /// than by argument, and 2a's mounted selection tests are this task's
    /// regression net without a line changed in them.
    ///
    /// **There is no sweep here, deliberately.** A deleted note leaves its id in
    /// the stored set, and nothing needs to chase it: the two places the set is
    /// *read for meaning* — `ordered` and `actingResearchIds` — are built by
    /// walking the live manifest, so a ghost cannot come out of either. A stale
    /// id highlights no row (the `List` draws none for it) and reaches no plural
    /// store verb. A second sweep beside `SubjectValidationModifier`'s would be
    /// a second rule about what a dead id means, and the two would be free to
    /// disagree.
    static func shown(_ stored: Set<BinderSubject>,
                      subject: BinderSubject?) -> Set<BinderSubject> {
        guard let subject else { return [] }
        // A subject the set does not hold arrived from somewhere other than a
        // click — a creation, a restore, a navigation from another column — and
        // it collapses the tree onto itself.
        return stored.contains(subject) ? stored : [subject]
    }

    /// The selection and the subject after the `List` writes `written`.
    ///
    /// - Parameter single: the surface's own one-row rule. It defaults to this
    ///   type's, and `SceneNavigatorPane` passes its own — that pane refuses an
    ///   item it draws no row for, which is the one thing about its list the
    ///   other two trees do not have. Handing the rule in keeps the count-of-one
    ///   case each surface's own and the anchor case shared, rather than forking
    ///   the whole projection.
    static func resolved(
        written: Set<BinderSubject>,
        stored: Set<BinderSubject>,
        subject: BinderSubject?,
        structure: [StructureItem],
        research: [ResearchItem],
        single: (BinderSubject?, BinderSubject?) -> BinderSubject? = {
            BinderTreeSelection.subject($0, whenListWrites: $1)
        }
    ) -> (selection: Set<BinderSubject>, subject: BinderSubject?) {
        guard written.count > 1 else {
            let next = single(subject, written.first)
            // ACCEPTED — the surface's rule gave back the row that was written,
            // so the tree holds that row and nothing else: a plain click
            // replaces a selection, it does not add to one.
            if let next, next == written.first { return ([next], next) }
            // REFUSED — an untagged placeholder's empty write, or a document
            // this surface draws no row for. Nothing moves, and that includes
            // the selection: emptying it would take the writer's whole
            // multi-selection away on a click at "No research yet."
            return (stored, next)
        }
        // The anchor survives a set it is still in, so ⌘-clicking a second note
        // does not move the editor off the first.
        if let anchor = subject, written.contains(anchor) { return (written, anchor) }
        // Otherwise the first of what is left, in the order the TREE draws —
        // never `Set.first`, which is whatever hashing yields today.
        return (written,
                ordered(written, structure: structure, research: research).first
                    ?? subject)
    }

    /// A selection in the order the tree draws it: the project row, then the
    /// structure in tree order, then research — and nothing else, because it is
    /// built by walking those two trees. That is what prunes a dead id.
    static func ordered(_ selection: Set<BinderSubject>,
                        structure: [StructureItem],
                        research: [ResearchItem]) -> [BinderSubject] {
        var out: [BinderSubject] = []
        if selection.contains(.project) { out.append(.project) }
        out += TreeWalk.collect(in: structure, where: { selection.contains(.item($0.id)) })
            .map { BinderSubject.item($0.id) }
        // The research half is `ResearchSelectionSync`'s, called rather than
        // restated — it is the ordering the two research panes have always used
        // and the one their batch verbs were built on.
        out += ResearchSelectionSync.orderedSelection(
            Set(selection.compactMap(\.researchID)), in: research)
            .map(BinderSubject.research)
        return out
    }

    /// **The ids a research row's verbs act on**: the whole selection when the
    /// row is inside one, else that row alone — `ResearchSelectionSync`'s
    /// shipped `expandedDragIds`, which is what both old panes' "Delete N
    /// Items", multi "Move to ▸" and batch drag are built on.
    ///
    /// **Only a homogeneous research selection batches.** Structure has no
    /// plural verbs — no batch delete, no batch move — so a set holding the
    /// project row or a chapter degrades every research verb to the row it was
    /// aimed at rather than inventing one for the manuscript.
    static func actingResearchIds(forRow rowId: String,
                                  selection: Set<BinderSubject>,
                                  research: [ResearchItem]) -> [String] {
        guard selection.count > 1,
              selection.allSatisfy({ $0.researchID != nil }) else { return [rowId] }
        return ResearchSelectionSync.expandedDragIds(
            draggedId: rowId,
            selection: Set(selection.compactMap(\.researchID)),
            in: research)
    }

    /// The tree's `List(selection:)` binding, for the two hosts whose rows are
    /// all their own. `SceneNavigatorPane` builds its own out of the same parts
    /// — see its `listSelection`.
    @MainActor
    static func binding(subject: Binding<BinderSubject?>,
                        state: BinderTreeSectionsState,
                        store: ProjectStore) -> Binding<Set<BinderSubject>> {
        Binding(
            get: { shown(state.selection, subject: subject.wrappedValue) },
            set: { written in
                let next = resolved(
                    written: written, stored: state.selection,
                    subject: subject.wrappedValue,
                    structure: store.manifest.structure,
                    research: store.manifest.research)
                state.selection = next.selection
                subject.wrappedValue = next.subject
            })
    }
}
