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
        let host = try await hostForFigure(figureId)
        keptFigureOpens.insert(figureId)
        return host
    }

    /// **One act on a figure through its host** — the one this window holds
    /// open, or one opened for the act and closed after it. The host is
    /// closed only when the last loan ends and nobody asked to keep it open
    /// (`openFigure(figureId:)`) meanwhile: who opened it is held across the
    /// awaits, never sampled before them.
    func withFigureHost<T>(
        _ figureId: String, _ act: (FigureDocument) async throws -> T
    ) async throws -> T {
        figureHostLoans[figureId, default: 0] += 1
        let result: T
        do {
            result = try await act(try await hostForFigure(figureId))
        } catch {
            await endFigureHostLoan(figureId)
            throw error
        }
        await endFigureHostLoan(figureId)
        return result
    }

    private func endFigureHostLoan(_ figureId: String) async {
        let left = (figureHostLoans[figureId] ?? 1) - 1
        figureHostLoans[figureId] = left > 0 ? left : nil
        if left <= 0, !keptFigureOpens.contains(figureId) {
            await closeFigure(figureId: figureId)
        }
    }

    /// The open host for `figureId`, or a newly loaded one.
    private func hostForFigure(_ figureId: String) async throws -> FigureDocument {
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
    /// coordinated copy (`executeCopy`). A `destination` that is not one plain
    /// file in this book's `figures/` throws `.unsafeProjectPath` (tripwire 58).
    func replaceFigureImage(at destination: URL, withCopyOf source: URL) async throws {
        // Only ever one plain file inside this book's `figures/` (tripwire
        // 58): a caller's URL that is anywhere else is refused, not written.
        do {
            let inside = try SafeRelativePath.resolveFile(
                named: destination.lastPathComponent,
                in: ProjectStore.figuresFolder, under: projectURL)
            guard inside.standardizedFileURL.path == destination.standardizedFileURL.path else {
                throw SafeRelativePath.PathError.escapesRoot(destination.path)
            }
        } catch let error as SafeRelativePath.PathError {
            throw ProjectStoreError.unsafeProjectPath(
                relativePath: destination.path, reason: error.localizedDescription)
        }
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

    /// **A figure's file, moved to a new name in `figures/`** — a rename's
    /// file half (`ProjectStore.renameFigure`, `FigureDocument.renameImageFile`),
    /// through the typed mover (tripwire 14). Both URLs are the caller's,
    /// already checked as plain files in `figures/` (tripwire 58). A move
    /// that only changes the name's case goes through a temporary name, so a
    /// case-insensitive disk renames it rather than finding it already there.
    func moveFigureFile(from source: URL, to destination: URL) async throws {
        try await relocateUserContent(affectedPaths: []) {
            guard source.path.lowercased() == destination.path.lowercased() else {
                return try await coordinatedMove(from: source, to: destination)
            }
            let step = source.deletingLastPathComponent()
                .appendingPathComponent(".rename-\(UUID().uuidString)") // local-path: minted here, a step on the way
            try await coordinatedMove(from: source, to: step)
            do { try await coordinatedMove(from: step, to: destination) } catch {
                try? await coordinatedMove(from: step, to: source)
                throw error
            }
        }
    }

    /// Close a figure this window opened: sealed, and no longer reloaded.
    func closeFigure(figureId: String) async {
        keptFigureOpens.remove(figureId)
        guard let doc = openFigures.removeValue(forKey: figureId) else { return }
        // Its held lines stay counted until the next sweep, as a document's do.
        rememberClosedProvenance(of: doc)
        await doc.close()
    }

    /// A window's figure cards start hearing this store's figure triggers.
    func attachFigureCardCache(_ cache: FigureCardCache) {
        figureCardCaches.add(cache)
    }

    /// A window's figure cards stop hearing them; every other window's keep on.
    func detachFigureCardCache(_ cache: FigureCardCache) {
        figureCardCaches.remove(cache)
    }

    /// Every attached window's figure cards refill (final review I1).
    func invalidateFigureCards() {
        for cache in figureCardCaches.allObjects { cache.invalidate() }
    }

    /// The open figure for `figureId`, if this window holds one.
    func openFigure(forId figureId: String) -> FigureDocument? {
        openFigures[figureId].flatMap { $0.isClosed ? nil : $0 }
    }

    /// **The open host appended an op** (`FigureDocument.commit`): its render
    /// and every table whose formulas name it follow.
    func figureHostAppended(_ figureId: String) async {
        figureCache.invalidate(figureId: figureId)
        invalidateFigureCards()
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
        keptFigureOpens.removeAll()
        figureHostLoans.removeAll()
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
        invalidateFigureCards()
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
    ///
    /// **A closed figure's held lines are re-counted too** (residual N-2):
    /// while unlisted, a closed pass skips its stream, so a stranger's lines
    /// in a figure whose stream arrived first were not counted for People &
    /// Devices. Each record that arrived or changed is queued for one closed
    /// pass, which skips any figure that is open. (A record that left needs
    /// none: the closed map stops counting what the manifest no longer lists.)
    func figureRegistryAdopted(from old: [FigureRecord], to new: [FigureRecord]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let arrivedOrChanged = Set(after.compactMap { id, record in before[id] == record ? nil : id })
        let changed = arrivedOrChanged.union(Set(before.keys).subtracting(after.keys))
        guard !changed.isEmpty else { return }
        pendingFigureChanges.formUnion(changed)
        figureChangeScheduler.schedule(0)
        if !arrivedOrChanged.isEmpty {
            closedReclassifyPending.formUnion(arrivedOrChanged)
            reclassifyPendingClosedDocuments()
        }
    }

    /// **Trust changed** (`invalidateTrust`, R-6a-6): the cache drops every
    /// line, each open figure's store forgets its table, and the open figures
    /// re-read and re-render through the figure pass.
    func figureTrustChanged() {
        figureCache.invalidateAll()
        invalidateFigureCards()
        let open = openFigures.values.filter { !$0.isClosed }
        guard !open.isEmpty else { return }
        for doc in open {
            doc.opStore.invalidateTrust()
            pendingFigureChanges.insert(doc.figureId)
        }
        figureChangeScheduler.schedule(0)
    }

    // MARK: - Reading the book's figures

    /// The trust table figure reads judge lines by, resolved off the main actor.
    private func figureTrust() async throws -> TrustTable {
        figureTrustResolutions += 1
        let projectURL = self.projectURL
        let identities = Document.loadIdentities
        let registryCache = Document.loadRegistryCache
        return try await Task.detached(priority: .userInitiated) {
            try TrustResolution.resolve(
                projectURL: projectURL, identities: identities, cache: registryCache)
        }.value
    }

    /// **The book's figures as one workbook, freshest first**: every table
    /// figure read through the cache (`FigureWorkbook.assemble`) with each open
    /// host's fold laid over its read (`FigureWorkbook.overlay`) — its table,
    /// its pins and its parked status. Throws when the registry will not read.
    func assembledFigures() async throws -> FigureWorkbook? {
        guard let manifest = projectStore?.manifest else { return nil }
        let trust = try await figureTrust()
        return assembledFigures(manifest: manifest, trust: trust)
    }

    private func assembledFigures(manifest: ProjectManifest, trust: TrustTable) -> FigureWorkbook {
        var assembled = FigureWorkbook.assemble(
            for: manifest, cache: figureCache, projectURL: projectURL, trust: trust)
        let tableIds = Set((manifest.figures ?? []).filter { $0.kind == .table }.map(\.id))
        for (id, doc) in openFigures where !doc.isClosed && tableIds.contains(id) {
            assembled.overlay(doc.state, id: id)
        }
        return assembled
    }

    /// **The names a Research CSV's formulas resolve through** (report plan 6b
    /// Task 6): `FormulaNames(records:tables:research:)` over every figure with
    /// its table — an open host's fold laid over its read — and the Research
    /// tables. Throws when the registry will not read.
    func formulaNamesForUse() async throws -> FormulaNames {
        guard let manifest = projectStore?.manifest, let assembled = try await assembledFigures() else { return .empty }
        return FormulaNames(
            records: manifest.figures ?? [], tables: assembled.workbook.tables, research: manifest.research)
    }

    /// **Every source figure `state`'s pins read, as it stands now** (spec
    /// §4.3, report plan 6b Task 9): each Research table its formulas name,
    /// read through `ProjectStore.pinSourceRead` (absent when the item or its
    /// file is gone), and each figure they read that is parked in Research,
    /// with its park, its parked table and values, and its working copy read
    /// the same way (nil when the copy is gone), and every table for a range's
    /// shape. Throws when the registry or a parked figure's stream will not read.
    /// Costly (an assembly, trust, every source file): never from a view body
    /// or per frame — a surface caches what it derives on the host.
    func pinSources(for state: FigureState) async throws -> PinSources {
        guard let manifest = projectStore?.manifest, projectStore != nil else { return PinSources() }
        let trust = try await figureTrust()
        return try await pinSources(
            for: state, manifest: manifest, trust: trust,
            assembled: assembledFigures(manifest: manifest, trust: trust))
    }

    /// `pinSources(for:)` over a caller's own trust table and assembly — one
    /// fill of the window's figure cards asks every pinned figure's sources
    /// over ONE resolution and ONE assembly (`figureCardInputs`).
    private func pinSources(
        for state: FigureState, manifest: ProjectManifest, trust: TrustTable,
        assembled: FigureWorkbook
    ) async throws -> PinSources {
        guard let projectStore else { return PinSources() }
        let book = assembled.workbook
        let parkedTables = assembled.parked.reduce(into: [String: FigureTable]()) { out, id in
            if let table = book.tables[id] { out[id] = table }
        }
        let read = Set(FigurePins.reads(of: state.table, parked: parkedTables, tables: book.tables)
            .values.flatMap { $0.map(\.source) })
        let names = FormulaNames(records: manifest.figures ?? [], tables: book.tables, research: manifest.research)
        let facts = DocumentClass.Facts(manifest)
        var sources = PinSources(tables: book.tables)
        for source in read.sorted() {
            if let table = parkedTables[source] {
                let parkedState = try openFigure(forId: source)?.state
                    ?? figureCache.state(forFigureId: source, in: projectURL, trust: trust, facts: facts)
                guard let parking = parkedState.parked else { continue }
                sources.parked[source] = PinSources.Parked(
                    parking: parking, table: table,
                    parkedValues: PinSourceRead(hash: parking.hash, table: table, book: book, as: source),
                    copy: await projectStore.pinSourceRead(workingCopyOf: parking, book: book, names: names))
            } else if let now = await projectStore.pinSourceRead(researchItemId: source, book: book, names: names) {
                sources.research[source] = now
            }
        }
        return sources
    }

    /// **The current park cycle of each of `sources` parked now** (report
    /// plan 6c Task 2): one assembly's `FigureWorkbook.parkCycles`, an open
    /// host's park laid over its read — what a figure restore's pins are
    /// judged by (`FigurePinChoice.isLive`), whether or not a formula reads
    /// the source. Empty for no sources. Throws when the registry will not read.
    func parkCycles(of sources: Set<String>) async throws -> [String: String] {
        guard !sources.isEmpty, let assembled = try await assembledFigures() else { return [:] }
        return assembled.parkCycles.filter { sources.contains($0.key) }
    }

    /// **The entry pins `state`'s formula cells take** (spec §4.3; report plan
    /// 6b final review I-1) — the ONE helper every path that lands a formula
    /// asks: a cell typed (`FigureDocument.setCell`), a figure made by *Use in
    /// document* (`ProjectStore.createFigureStream`) and the cells a return
    /// brings back (`ProjectStore.bringBack`). Each formula cell in `cells`
    /// (every one, when nil) that names a Research table and holds no pin on
    /// what it reads takes one (`FigurePins.entry(state:cells:sources:at:)`).
    /// Nothing is gathered when no such cell names Research
    /// (`FigurePins.readsResearch`, a syntactic test). Throws when the sources
    /// will not read (`pinSources(for:)`); the caller then lands the formula
    /// unpinned, which `FigurePins.status` reports as `unpinned`.
    func entryPins(for state: FigureState, cells: Set<CellKey>? = nil) async throws -> [PinWrite] {
        let readsResearch = state.table.cells.contains { key, cell in
            guard cells?.contains(key) ?? true, case .formula(let f) = cell.content else { return false }
            return FigurePins.readsResearch(f)
        }
        guard readsResearch else { return [] }
        let sources = try await pinSources(for: state)
        return FigurePins.entry(state: state, cells: cells, sources: sources, at: Date())
    }

    /// **The CSV `record` renders to from its op state, parked or not** —
    /// what a removed table's Trash entry carries when its render is not on
    /// disk (final review I-3): `FigureRender.csv` over the open host's state,
    /// else the cache's read, with the park lifted so a parked table renders
    /// its parked values. Nil for a picture, or when the registry or the
    /// stream will not read.
    func figureRenderText(for record: FigureRecord) async -> String? {
        guard record.kind == .table, let manifest = projectStore?.manifest,
              let trust = try? await figureTrust() else { return nil }
        var state: FigureState
        if let open = openFigure(forId: record.id) {
            state = open.state
        } else {
            guard let read = try? figureCache.state(
                forFigureId: record.id, in: projectURL, trust: trust, facts: DocumentClass.Facts(manifest))
            else { return nil }
            state = read
        }
        state.parked = nil
        return FigureRender.csv(
            record: record, state: state, workbook: assembledFigures(manifest: manifest, trust: trust).workbook)
    }

    /// **Is figure `figureId` parked in Research?** Asked of its open host,
    /// else its stream (the registry resolved only then), whatever its kind.
    /// False for an id the registry does not list. Throws when the stream or
    /// the registry will not read: a parked figure can't be told apart.
    func figureIsParked(_ figureId: String) async throws -> Bool {
        guard let manifest = projectStore?.manifest,
              manifest.figures?.contains(where: { $0.id == figureId }) == true else { return false }
        if let open = openFigure(forId: figureId) { return open.state.parked != nil }
        let trust = try await figureTrust()
        let state = try figureCache.state(
            forFigureId: figureId, in: projectURL, trust: trust, facts: DocumentClass.Facts(manifest))
        return state.parked != nil
    }

    // MARK: - The window's figure cards

    /// **What one fill of the window's figure cards reads** (report plan 7a
    /// Task 3, `FigureCardCache`): every registered figure's state — an open
    /// host's fold, else the figure cache's read — the book assembled as one
    /// workbook for their values, which of them hold a pin whose source has
    /// changed, and the book's locale. Opens no host and reads no
    /// `figures/<name>.csv` (tripwire 20). Nil once the window has closed, or when
    /// the registry will not read (logged); a figure whose stream will not
    /// read is left out. Costly (trust, an assembly, each pinned figure's
    /// sources): never per keystroke.
    func figureCardInputs() async -> FigureCardInputs? {
        guard presenter != nil, let projectStore else { return nil }
        guard !(projectStore.manifest.figures ?? []).isEmpty else {
            return FigureCardInputs(records: [], states: [:], workbook: nil, pinChanged: [],
                                    locale: TableLocale(languageTag: nil))
        }
        let locale = TableLocale(languageTag: await projectStore.bookLanguageTag())
        let trust: TrustTable
        do { trust = try await figureTrust() } catch {
            documentLog.error(
                "figure cards were not filled: the registry would not read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // The window may have closed, or the registry moved, across the awaits.
        guard presenter != nil, let manifest = self.projectStore?.manifest else { return nil }
        let records = manifest.figures ?? []
        let assembled = assembledFigures(manifest: manifest, trust: trust)
        let facts = DocumentClass.Facts(manifest)
        var states: [String: FigureState] = [:]
        for record in records where states[record.id] == nil {
            if let open = openFigure(forId: record.id) {
                states[record.id] = open.state
            } else if let read = try? figureCache.state(
                forFigureId: record.id, in: projectURL, trust: trust, facts: facts) {
                states[record.id] = read
            }
        }
        var pinChanged = Set<String>()
        for (id, state) in states where !state.pins.isEmpty {
            let sources: PinSources
            do {
                sources = try await pinSources(
                    for: state, manifest: manifest, trust: trust, assembled: assembled)
            } catch {
                // Its card shows no changed-source flag until a fill reads them.
                documentLog.error(
                    "figure \(id, privacy: .public): its card's Research sources did not read: \(error.localizedDescription, privacy: .public)")
                continue
            }
            let statuses = FigurePins.status(of: state, sources: sources).values
            if statuses.contains(where: { if case .sourceChanged = $0 { true } else { false } }) {
                pinChanged.insert(id)
            }
        }
        guard presenter != nil else { return nil }
        return FigureCardInputs(records: records, states: states, workbook: assembled.workbook,
                                pinChanged: pinChanged, locale: locale)
    }

    // MARK: - Rendering

    /// **Render `changed` and every table whose formulas name one of them.**
    ///
    /// The book's tables are assembled into one `Workbook` from the cache
    /// (`FigureWorkbook.assemble`), with each open figure's own state laid
    /// over its read (`assembledFigures`) — the host holds the freshest
    /// fold, a parked one's too (its readers keep its parked values, R-D2, or
    /// their own pins on it), and research refs read each reader's pins.
    /// The parked set it leaves is kept on `lastParkedFigures`. Figures the assembly
    /// could not read (R-6a-7) are logged, one line each, and kept on
    /// `lastUnreadableFigures`; their renders are left as they were. A
    /// failure to write one render is logged and the others still write.
    func renderFigures(changed: Set<String>) async {
        guard let manifest = projectStore?.manifest,
              let records = manifest.figures, !records.isEmpty else {
            // No figures: nothing parked or unreadable is left to say.
            lastParkedFigures = []
            lastUnreadableFigures = []
            return
        }
        let projectURL = self.projectURL
        let trust: TrustTable
        do {
            trust = try await figureTrust()
        } catch {
            documentLog.error(
                "figures were not rendered: the registry would not read: \(error.localizedDescription, privacy: .public)")
            // Nothing was assembled, so the last pass's lists no longer hold.
            lastParkedFigures = []
            lastUnreadableFigures = []
            return
        }
        let assembled = assembledFigures(manifest: manifest, trust: trust)
        lastUnreadableFigures = assembled.unreadable
        for (name, error) in assembled.unreadable {
            documentLog.error(
                "figure \(name, privacy: .public) could not be read for the workbook, so its render and its readers' values may be stale: \(error, privacy: .public)")
        }

        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        lastParkedFigures = assembled.parked
        let book = assembled.workbook

        // A changed figure the registry no longer lists (removed here or
        // elsewhere) renders nothing, but its readers do.
        var due = Set<String>()
        for id in changed {
            if byId[id] != nil { due.insert(id) }
            due.formUnion(book.tablesReading(id))
        }
        // Two records naming one file (two devices made "cash" before either
        // saw the other's) would overwrite each other on every pass: neither
        // renders, and it is said, until a rename separates them
        // (`ProjectStore.renameFigure`, which then renders both).
        var byPath: [String: [FigureRecord]] = [:]
        for record in records { byPath[record.path.lowercased(), default: []].append(record) }
        let shared = Set(byPath.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        let facts = DocumentClass.Facts(manifest)
        for record in records where record.kind == .table && due.contains(record.id) {
            if shared.contains(record.id) {
                documentLog.error(
                    "figure \(record.name, privacy: .public) was not rendered: another figure names the same file, \(record.path, privacy: .public); rename one of them to render both")
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

/// **One fill's worth of the book's figures** (`DocumentStore.figureCardInputs()`),
/// plain values for `FigureCardCache` to build its cards from.
struct FigureCardInputs {
    /// The registry as read (`manifest.figures`).
    var records: [FigureRecord]
    /// Each readable figure's state, by id; an unreadable one is absent.
    var states: [String: FigureState]
    /// The book's tables evaluated together, keyed by figure id; nil with no figures.
    var workbook: Workbook?
    /// The figures holding a pin whose source has changed (`PinStatus.sourceChanged`).
    var pinChanged: Set<String>
    var locale: TableLocale
}
