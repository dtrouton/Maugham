import Foundation
import MaughamCore

// MARK: - Figures in a window (report plan 6a Task 7)
//
// A window opens a figure through `openFigure`, which hands the figure THIS
// store as its posture door (R-6a-8) and keeps it where the presenter's figure
// arm can reach it. Every render of `figures/<name>.csv` runs through
// `renderFigures`: on the host's load, after every op the open host appends,
// after `createFigure`, and when the presenter reports a figure's stream
// changed (another device's lines). Nothing here reads a CSV back (tripwire 20).

extension DocumentStore {

    /// The session every figure this window opens appends under.
    private static let figureSessionId = UUID().uuidString

    /// **Open a figure in this window** — the one door a window opens a figure
    /// through. The figure's posture door is this store, so its piece's
    /// yields and *Edit Anyway* apply (R-6a-8). Opening an open figure answers
    /// the one already open. The load renders the figure's CSV.
    func openFigure(figureId: String) async throws -> FigureDocument {
        if let open = openFigures[figureId], !open.isClosed { return open }
        let doc = try await FigureDocument.load(
            figureId: figureId, projectURL: projectURL, actor: .author,
            session: Self.figureSessionId, presenter: presenter,
            documentStore: self)
        // Two opens racing: the first to land is the window's.
        if let raced = openFigures[figureId], !raced.isClosed {
            await doc.close()
            return raced
        }
        openFigures[figureId] = doc
        // An open figure answers for its own held lines (`heldLines()`).
        forgetClosedProvenance(ofDocId: figureId)
        await renderFigures(changed: [figureId])
        return doc
    }

    /// **An image figure's file, replaced** (`FigureDocument.setImage` and its
    /// ⌘Z): a copy of `source` takes `destination`'s place in one coordinated
    /// write. The copy is staged in the system's replacement folder on the
    /// destination's volume and swapped in with `replaceItemAt`, so a reader
    /// sees the old picture or the new one, never half of either. A
    /// destination not there yet (a figure's first picture) is a plain
    /// coordinated copy (`executeCopy`).
    func replaceFigureImage(at destination: URL, withCopyOf source: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            return try await executeCopy(from: source, to: destination)
        }
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try fm.copyItem(at: source, to: staged)
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var replaceError: Error?
        coordinator.coordinate(writingItemAt: destination, options: .forReplacing,
                               error: &coordError) { url in
            do { _ = try fm.replaceItemAt(url, withItemAt: staged) } catch { replaceError = error }
        }
        if let coordError { throw coordError }
        if let replaceError { throw replaceError }
    }

    /// Close a figure this window opened: sealed, and no longer reloaded.
    func closeFigure(figureId: String) async {
        guard let doc = openFigures.removeValue(forKey: figureId) else { return }
        // Its held lines stay counted until the next sweep, as a document's do.
        rememberClosedProvenance(of: doc)
        await doc.close()
    }

    /// The open figure for `figureId`, if this window holds one.
    func openFigure(forId figureId: String) -> FigureDocument? {
        openFigures[figureId].flatMap { $0.isClosed ? nil : $0 }
    }

    /// **The open host appended an op** (`FigureDocument.commit`): its render
    /// and every table whose formulas name it follow.
    func figureHostAppended(_ figureId: String) async {
        figureCache.invalidate(figureId: figureId)
        await renderFigures(changed: [figureId])
    }

    /// **Every table figure renders once when a window opens the book**
    /// (ruling R-6a-11), deferred off the open path: an outside edit to a
    /// closed figure's CSV is discarded at the next open, not kept until the
    /// figure next changes. Called once the window's `ProjectStore` is
    /// attached (`ProjectSession.open`).
    func renderEveryTableFigureDeferred() {
        _openFigureRenderTask?.cancel()
        _openFigureRenderTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                  let records = self.projectStore?.manifest.figures else { return }
            await self.renderFigures(changed: Set(records.filter { $0.kind == .table }.map(\.id)))
        }
    }

    /// Test seam: await the deferred open render.
    func awaitOpenFigureRenderForTesting() async {
        await _openFigureRenderTask?.value
    }

    /// **The window is closing** (`close()`): every open figure is closed and
    /// sealed, the map cleared, and any pending or deferred figure pass
    /// cancelled — nothing renders after the presenter is removed.
    func closeFigures() async {
        _openFigureRenderTask?.cancel()
        _openFigureRenderTask = nil
        _figureChangeScheduler?.cancel()
        pendingFigureChanges = []
        let open = Array(openFigures.values)
        openFigures.removeAll()
        for doc in open { await doc.close() }
    }

    // MARK: - The presenter's figure arm

    /// A figure's stream changed on disk. Coalesced: a device arrives as a
    /// burst of files, so the pass runs once after the burst.
    func figureStreamChanged(_ figureId: String) {
        pendingFigureChanges.insert(figureId)
        figureChangeScheduler.schedule(0)
    }

    private var figureChangeScheduler: DebounceScheduler<Int> {
        if let existing = _figureChangeScheduler { return existing }
        let scheduler = DebounceScheduler<Int>(delay: .milliseconds(300)) { [weak self] _ in
            await self?.applyPendingFigureChanges()
        }
        _figureChangeScheduler = scheduler
        return scheduler
    }

    /// Run a pending figure pass now rather than after the debounce — for a
    /// test that has just delivered a presenter callback.
    func flushFigureChangesForTesting() async {
        await _figureChangeScheduler?.flush()
    }

    /// **The figure pass**: each changed figure's cached line is dropped, an
    /// open one re-reads its stream (`FigureDocument.reload`), and they and
    /// their dependants re-render.
    private func applyPendingFigureChanges() async {
        let changed = pendingFigureChanges
        pendingFigureChanges = []
        guard !changed.isEmpty else { return }
        for id in changed {
            figureCache.invalidate(figureId: id)
            guard let open = openFigure(forId: id) else { continue }
            do { try await open.reload() } catch {
                documentLog.error(
                    "figure \(id, privacy: .public) did not re-read after a change on disk: \(error.localizedDescription, privacy: .public)")
            }
        }
        await renderFigures(changed: changed)
    }

    /// **The figure registry changed under an adopted manifest**
    /// (`handleManifestChanged`). A figure's stream is written before its
    /// record (R-6a-9) and the two sync independently, so a stream usually
    /// lands first: its lines are held under `.unregisteredFigure`
    /// (R-6a-12) and it has no render. When the record lands — or a record
    /// changes piece, name, kind or path — each such figure goes through the
    /// figure pass: its cached line dropped, an open host re-read under the
    /// class the record now gives it, and it and its readers re-rendered. A
    /// record that left is re-read too, so an open host stops applying what
    /// its piece allowed.
    func figureRegistryAdopted(from old: [FigureRecord], to new: [FigureRecord]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = Set(after.compactMap { id, record in before[id] == record ? nil : id })
        changed.formUnion(Set(before.keys).subtracting(after.keys))
        guard !changed.isEmpty else { return }
        pendingFigureChanges.formUnion(changed)
        figureChangeScheduler.schedule(0)
    }

    /// **Trust changed** (`invalidateTrust`, R-6a-6): the cache drops every
    /// line, each open figure's store forgets its table, and the open figures
    /// re-read and re-render through the figure pass.
    func figureTrustChanged() {
        figureCache.invalidateAll()
        let open = openFigures.values.filter { !$0.isClosed }
        guard !open.isEmpty else { return }
        for doc in open {
            doc.opStore.invalidateTrust()
            pendingFigureChanges.insert(doc.figureId)
        }
        figureChangeScheduler.schedule(0)
    }

    // MARK: - Rendering

    /// **Render `changed` and every table whose formulas name one of them.**
    ///
    /// The book's tables are assembled into one `Workbook` from the cache
    /// (`FigureWorkbook.assemble`), with each open figure's own state laid
    /// over its read — the host holds the freshest fold. Figures the assembly
    /// could not read (R-6a-7) are logged, one line each, and kept on
    /// `lastUnreadableFigures`; their renders are left as they were. A
    /// failure to write one render is logged and the others still write.
    func renderFigures(changed: Set<String>) async {
        guard let manifest = projectStore?.manifest,
              let records = manifest.figures, !records.isEmpty else { return }
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let registryCache = Document.loadRegistryCache
        let trust: TrustTable
        do {
            trust = try await Task.detached(priority: .userInitiated) {
                try TrustResolution.resolve(
                    projectURL: projectURL, identities: identities, cache: registryCache)
            }.value
        } catch {
            documentLog.error(
                "figures were not rendered: the registry would not read: \(error.localizedDescription, privacy: .public)")
            return
        }
        let assembled = FigureWorkbook.assemble(
            for: manifest, cache: figureCache, projectURL: projectURL,
            trust: trust, pins: FigureRender.noResearchPins)
        lastUnreadableFigures = assembled.unreadable
        for (name, error) in assembled.unreadable {
            documentLog.error(
                "figure \(name, privacy: .public) could not be read for the workbook, so its render and its readers' values may be stale: \(error, privacy: .public)")
        }

        var book = assembled.workbook
        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, doc) in openFigures where !doc.isClosed {
            guard let record = byId[id], record.kind == .table, doc.state.parked == nil else { continue }
            book.setTable(doc.state.table, named: record.name)
        }

        var names = Set<String>()
        for id in changed {
            guard let record = byId[id] else { continue }
            names.insert(record.name)
            names.formUnion(book.tablesReading(record.name))
        }
        // Two records naming one file (two devices made "cash" before either
        // saw the other's) would overwrite each other on every pass: neither
        // renders, and it is said, until a rename separates them (plan 6b).
        var byPath: [String: [FigureRecord]] = [:]
        for record in records { byPath[record.path.lowercased(), default: []].append(record) }
        let shared = Set(byPath.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        let facts = DocumentClass.Facts(manifest)
        for record in records where record.kind == .table && names.contains(record.name) {
            if shared.contains(record.id) {
                documentLog.error(
                    "figure \(record.name, privacy: .public) was not rendered: another figure names the same file, \(record.path, privacy: .public)")
                continue
            }
            // A window closing mid-pass: nothing writes once its presenter is gone.
            guard presenter != nil else { return }
            let state: FigureState
            if let open = openFigure(forId: record.id) {
                state = open.state
            } else {
                // Unreadable figures were listed above; nothing to render.
                guard let read = try? figureCache.state(
                    forFigureId: record.id, in: projectURL, trust: trust, facts: facts)
                else { continue }
                state = read
            }
            do {
                try await FigureRender.render(
                    record: record, state: state, workbook: book, documentStore: self)
            } catch {
                documentLog.error(
                    "figure \(record.name, privacy: .public) did not render: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
