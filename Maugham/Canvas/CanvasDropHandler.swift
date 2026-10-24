import MaughamCore
import SwiftUI

/// `CanvasView`'s drops: one entry point, `handleDrop(providers:at:)`, which
/// `CanvasDropRoute` sends either to a research row or an inbox capture
/// (`handleDrop`) or to a photograph from the Finder or a browser
/// (`handleExternalDrop`) — over bindings to the view's own `camera`,
/// `revision` and `dropError`. Each returns whether the drop was taken; the
/// one modifier that delivers them stays on `CanvasView.body`.
///
/// Built fresh per call by `CanvasView.dropHandler` and never stored; built
/// nowhere else (tripwire 32's surface census). **It holds no sibling
/// helper**: two of its paths finish in a `Task`, and a helper held here
/// would be frozen at build time for that later work (tripwire 57). What the
/// `Task` bodies write after the await, `dropError` and `model.selection`,
/// goes through the binding and the model, so the write lands in live state.
///
/// `subject` is the binder's selection as the drop arrives (the handler is
/// built when the drop's closure runs); with a chapter selected, a drop that
/// lands in no region is wrapped in one bound to it (`CanvasDropWrap`). It
/// never reaches `CanvasEditFocus` or `CanvasLayoutPass` (tripwire 57).
@MainActor
struct CanvasDropHandler {
    let model: CanvasModel
    let subject: CanvasSubject
    let itemIndex: CanvasItemIndex
    let projectRoot: URL
    let captureDrop: CanvasCaptureDrop
    let assetIngest: CanvasAssetIngest
    @Binding var thumbnails: CanvasThumbnails
    @Binding var camera: CanvasCamera
    @Binding var revision: Int
    @Binding var dropError: String?

    // MARK: - Drops

    /// A research row dropped on the canvas (spec §8A.1).
    ///
    /// **This method decides nothing.** `CanvasDrop.decide` is a pure function
    /// over the payload, the scene and the item index, and `CanvasDrop.apply` owns
    /// the undo bracket and the membership — because SwiftUI's drop delivery has
    /// no seam a test can post into, so what a drop *means* has to be answerable
    /// somewhere a test can reach exhaustively. What is left here is the camera
    /// (a view's own state) and the selection, and that this modifier is mounted
    /// at all is pinned by a census rather than by a test.
    ///
    /// **The first payload only, which is the house pattern rather than a
    /// shortcut.** `ResearchRow`'s own `.dropDestination` takes `ids.first`, and
    /// every `.draggable(id)` source in the app sends exactly one — the research
    /// tree's multi-selection is expanded by the *receiver* (`ResearchView`'s
    /// `ResearchSelectionSync.expandedDragIds`) rather than travelling in the
    /// payload, and this receiver deliberately does not expand it: the canvas
    /// cannot see the binder's selection, and inventing a rule from it would be a
    /// second answer to "what did the writer drag". A batch that really does
    /// arrive as several payloads is the external file drop, which is its own
    /// modifier with its own arrangement rule.
    ///
    /// Returns whether anything happened. Since canvas-keyboard-flow Task 1 the
    /// drag itself has already been accepted (`handleDrop(providers:at:)` loads
    /// the string after answering), so an id this canvas has no card for, or a
    /// drop a read-only canvas refuses, does nothing rather than springing back
    /// (ruled).
    ///
    /// **Two id spaces arrive here as of 1C-d Task 12, and `CanvasDrop.payload`
    /// tells them apart before anything else runs** (spec §8A.4). An inbox
    /// capture's ULID and a research item id are not tellable apart, so the inbox
    /// row sends a PREFIXED payload; without the destructuring, `decide` would
    /// look the ULID up in `CanvasItemIndex`, not find it, and refuse the drag
    /// with nothing said. See `CanvasDrop`'s own doc comment for why the prefix
    /// breaks the house's raw-id pattern deliberately.
    func handleDrop(_ payloads: [String], at viewPoint: CGPoint) -> Bool {
        guard let payload = payloads.first else { return false }
        if case .capture(let entryID) = CanvasDrop.payload(payload) {
            // Read-only (issue #44): refused before the send, so no asset is
            // copied and the entry stays new; the drag was already accepted, so
            // nothing happens and the canvas's notice says why.
            guard CanvasEditGate.accepts(.capture, isReadOnly: model.isReadOnly)
            else { return false }
            return handleCaptureDrop(entryID, at: viewPoint)
        }
        switch CanvasDrop.decide(payload: payload,
                                 at: camera.contentPoint(fromView: viewPoint),
                                 in: model.scene, index: itemIndex,
                                 pictureAspect: pictureAspect(ofItem: payload)) {
        case .ignored:
            return false

        case .reveal(let id):
            // Not gated (issue #44): a reveal selects and moves the camera and
            // changes nothing, so it works on a read-only canvas too.
            // The item is already here. Say so by SHOWING it — a drop that
            // silently did nothing is indistinguishable from a broken surface,
            // which is this task's named failure. The card is not moved: that
            // would be a geometry-driven change to something the writer placed.
            //
            // The camera moves even when the card was already on screen, and that
            // is a real cost rather than an oversight: the view has no viewport
            // outside the `Canvas` closure (no `GeometryReader`, by design), so
            // "is it visible already" is not a question it can ask.
            guard let node = model.scene.node(id) else { return false }
            model.selection = .node(id)
            camera.bring(node.origin, toViewPoint: CanvasCamera.revealViewPoint)
            // The selection is read inside the draw closure, where a model value
            // is not in SwiftUI's dependency graph — `handleClick`'s single-click
            // arm bumps for the same reason. `revision` and never `sceneRevision`:
            // nothing structural happened.
            revision += 1
            return true

        case .create(let node):
            guard CanvasEditGate.accepts(.place, isReadOnly: model.isReadOnly)
            else { return false }
            CanvasDrop.apply(node, in: model,
                             wrappingInPiece: CanvasDropWrap.piece(for: subject))
            // Selected, so the right-hand column shows the reference's own arm and
            // the writer can see what landed. Outside the bracket: a snapshot
            // carries the scene and the scrap text, never the selection.
            model.selection = .node(node.id)
            return true
        }
    }

    /// A research item's picture shape, so its card is born at its real height:
    /// the memoised thumbnail's when this session has decoded it, else the
    /// file's header (`CanvasThumbnails.headerAspect`, contained by
    /// `SafeRelativePath` as the decode is). Nil for an item with no pixels.
    private func pictureAspect(ofItem id: String) -> CGFloat? {
        guard let path = itemIndex.entry(of: id)?.thumbnailPath else { return nil }
        if let memo = thumbnails.aspect(path, in: projectRoot) { return memo }
        guard let url = try? SafeRelativePath.resolve(path, under: projectRoot) else { return nil }
        return CanvasThumbnails.headerAspect(of: url)
    }

    /// An inbox capture dropped on the canvas (spec §8A.4) — the **third** caller
    /// of this drop target, beside the research drag and the external file drop.
    ///
    /// **This method decides nothing either.** Everything the send does — reading
    /// the capture, refusing one with nothing in it, ingesting a photograph,
    /// writing the canvas inside one undo bracket and flipping the entry
    /// `.promoted` only after all of it has succeeded — is
    /// `InboxStore.sendToCanvas`, which a test can reach without a window. What is
    /// left here is the drop point, the selection and the alert.
    ///
    /// **The capture lands where it was dropped, and the canvas gains no placement
    /// rule for it** (§8A.4's amendment). That is the whole reason the drag is the
    /// primary route: the writer has already said where.
    ///
    /// **The camera does NOT move**, unlike the command route's `CanvasCapture.show`
    /// — the card arrived under the pointer, so a jump would be to somewhere the
    /// writer is already looking.
    ///
    /// The content point is resolved **before** the await, exactly as the external
    /// drop does it: `camera` can move under a drop that takes a moment (a coast
    /// finishing, a rewind), and the capture belongs where the writer let go of it.
    private func handleCaptureDrop(_ entryID: String, at viewPoint: CGPoint) -> Bool {
        let contentPoint = camera.contentPoint(fromView: viewPoint)
        let piece = CanvasDropWrap.piece(for: subject)
        Task {
            do {
                let id = try await captureDrop.send(entryID, contentPoint, piece)
                // Selected so the right-hand column shows the capture's own
                // inspector arm. Outside the bracket: a snapshot carries the scene
                // and the scrap text, never the selection.
                model.selection = .node(id)
            } catch {
                dropError = error.localizedDescription
            }
        }
        return true
    }

    /// A photograph dropped from the Finder or a browser (spec §8A.1).
    ///
    /// **This method decides nothing either.** Classification is
    /// `DropClassification`'s — the canvas is its fifth adopter and adds no rule
    /// of its own — and everything after it is `CanvasExternalDrop`'s, which is
    /// where a test can reach it. What is left here is the camera, the selection
    /// and the alert, which are the view's own state.
    ///
    /// **The return value is synchronous and the work is not**, which is what the
    /// modifier's signature requires: `accepts` is a pasteboard question with an
    /// immediate answer, so a drag carrying neither a file nor an image is
    /// declined outright and springs back — a refusal the writer can see — while
    /// the ingestion, which reads and writes files, runs in a `Task`.
    ///
    /// The content point is resolved **before** the await: `camera` can move
    /// under a drop that takes a moment (a coast finishing, a rewind), and the
    /// photograph belongs where the writer let go of it.
    func handleExternalDrop(_ providers: [NSItemProvider],
                            at viewPoint: CGPoint) -> Bool {
        // Read-only (issue #44): refused BEFORE `ingest`, which copies into
        // `canvas_assets/` first — a refused drop must strand no copy there.
        guard CanvasEditGate.accepts(.external, isReadOnly: model.isReadOnly)
        else { return false }
        let accepted = providers.filter { CanvasExternalDrop.accepts($0) }
        guard !accepted.isEmpty else { return false }
        let contentPoint = camera.contentPoint(fromView: viewPoint)
        // Read at drop time, before the ingest's await.
        let piece = CanvasDropWrap.piece(for: subject)
        Task {
            let outcome = await CanvasExternalDrop.ingest(providers: accepted,
                                                          using: assetIngest)
            let made = CanvasExternalDrop.apply(paths: outcome.paths,
                                                aspects: outcome.aspects,
                                                at: contentPoint, in: model,
                                                wrappingInPiece: piece)
            // Selected so the right-hand column shows the picture's own inspector
            // arm. Outside the bracket: a snapshot carries the scene and the
            // scrap text, never the selection.
            if let first = made.nodes.first { model.selection = .node(first) }
            dropError = outcome.message
        }
        return true
    }

    /// Every drag dropped on the canvas arrives here, from the canvas's one
    /// `.onDrop` (spec §4). `CanvasDropRoute` decides by type, over every
    /// provider's types, and a file or an image always wins over text.
    ///
    /// **An internal payload is taken before its string is read**, because
    /// the modifier wants its answer now and the string loads asynchronously.
    /// So a payload with an id this canvas has no card for is accepted and
    /// then does nothing, rather than springing back: a cost accepted by
    /// ruling (canvas-keyboard-flow Task 1). The read-only refusal is still
    /// `handleDrop`'s, run when the string arrives.
    ///
    /// The content point is resolved **before** the await and mapped back
    /// through the live camera after it, so the card lands where the writer
    /// let go even if the camera moved meanwhile.
    func handleDrop(providers: [NSItemProvider], at viewPoint: CGPoint) -> Bool {
        let types = providers.flatMap(\.registeredTypeIdentifiers)
        switch CanvasDropRoute.route(typeIdentifiers: types) {
        case .external:
            return handleExternalDrop(providers, at: viewPoint)
        case .refuse:
            return false
        case .internalPayload:
            guard let provider = providers.first else { return false }
            let contentPoint = camera.contentPoint(fromView: viewPoint)
            Task {
                guard let payload = await Self.string(from: provider) else { return }
                _ = handleDrop([payload],
                               at: camera.viewPoint(fromContent: contentPoint))
            }
            return true
        }
    }

    private static func string(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: String.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}
