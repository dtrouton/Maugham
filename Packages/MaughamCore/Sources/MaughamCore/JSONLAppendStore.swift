// Maugham/OpLog/JSONLAppendStore.swift
import Foundation
import os

/// Diagnostic channel for the one thing a verified READ can fail at without the
/// read itself failing: the forensic record of what it set aside. The record is
/// how the writer LEARNS that something wrote into their history; it is never
/// how the read proceeds. Mirrors `OpLogStore`'s stance on the same write.
private let appendStoreLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "JSONLAppendStore")

/// NSFileCoordinator-coordinated append-only JSONL store. Generic over
/// any Codable element; ISO8601-with-fractional-seconds Date coding is
/// the default since that's what every existing store uses.
///
/// Two configurable knobs:
///   - `dedupKey`: if non-nil, load() drops duplicates by this key,
///     keeping first occurrence. (OpLogStore uses `\.opId`.)
///   - `sortedBy`: if non-nil, load() sorts by this comparator.
///     (OpLogStore uses { $0.opId < $1.opId }.)
@MainActor
public final class JSONLAppendStore<Element: Codable & Sendable> {
    public let fileURL: URL
    public let presenter: NSFilePresenter?
    private let dedupKey: ((Element) -> String)?
    private let sortedBy: ((Element, Element) -> Bool)?
    /// Non-nil for the op log and the inbox: every append chains onto the file's
    /// verified head, and anything this device did not write is set aside first.
    /// Nil for every other store — publications, checkpoints — which keeps the
    /// plain append it has always had. NOT tasks: a project-scope task op is an
    /// `Op` appended through `OpLogStore` into `__project__.jsonl`, so it is
    /// chained like any other op.
    public let chain: ChainPolicy?

    public init(
        fileURL: URL,
        presenter: NSFilePresenter? = nil,
        dedupKey: ((Element) -> String)? = nil,
        sortedBy: ((Element, Element) -> Bool)? = nil,
        chain: ChainPolicy? = nil
    ) {
        self.fileURL = fileURL
        self.presenter = presenter
        self.dedupKey = dedupKey
        self.sortedBy = sortedBy
        self.chain = chain
    }

    public func load() async throws -> [Element] {
        parseDiagnosed(bytes: try readBytes()).elements
    }

    /// Like `load()`, but also reports lines that failed to decode (previously
    /// dropped silently). Use this where corruption must be surfaced.
    public func loadDiagnosed() async throws -> (elements: [Element], diagnostics: ParseDiagnostics) {
        parseDiagnosed(bytes: try readBytes())
    }

    /// Like `load()`, but an UNREADABLE-yet-present file THROWS instead of
    /// reading as empty. `readBytes` swallows the coordinated read's failure
    /// (`try? Data(contentsOf:)`), so every lenient consumer presents an
    /// unreadable file as an empty list — RULING-7's forbidden shape
    /// ("unreadable is never presented as empty"), fixed for the inbox at
    /// M8-IN-012. `load()` keeps the lenient contract its remaining consumers
    /// (publications, tasks) currently rely on; a register residual records
    /// that they should each decide deliberately. The op log went strict with
    /// RULING-54's first slice (M9-OL-001) and checkpoints followed
    /// (M9-OL-007: unreadable files are NAMED in `CheckpointLoad`).
    public func loadStrict() async throws -> [Element] {
        parseDiagnosed(bytes: try readBytesStrict()).elements
    }

    /// The strict twin of `loadDiagnosed` (RULING-54): unreadable-yet-present
    /// throws; absent is still empty.
    public func loadDiagnosedStrict() async throws -> (elements: [Element], diagnostics: ParseDiagnostics) {
        parseDiagnosed(bytes: try readBytesStrict())
    }

    /// The strict read a CHAINED store owes its reader: unreadable-yet-present
    /// throws, seal lines never reach the element decoder, every line is
    /// classified against this device's own word before any of it is applied,
    /// and whatever the walk held back is recorded where the writer can find
    /// it. With no chain policy it is exactly `loadDiagnosedStrict`.
    ///
    /// This is the READ half of the chain, and it is deliberately generic: the
    /// op log's tail, the inbox's manifest and (Task 8) the annotation stream
    /// are the same three steps over different elements — verify the bytes, set
    /// aside what broke, hand the KEPT bytes to the parser. One implementation,
    /// so a second stream cannot grow a second opinion about what a broken
    /// chain means.
    ///
    /// It writes NOTHING to this device's memory. Adopting a head is the op
    /// log's own decision (`OpLogStore.classifyTail`'s adopt rule), made where
    /// the provenance that justifies it is in hand.
    public func loadVerifiedStrict() async throws -> (elements: [Element], diagnostics: ParseDiagnostics) {
        let bytes = try readBytesStrict()
        guard let chain else { return parseDiagnosed(bytes: bytes) }
        let fileKey = OpLogDeviceState.fileKey(fileURL)
        let walked = OpLogChain.verify(
            bytes: bytes,
            trusted: { chain.trustedFingerprints.contains($0) },
            rememberedHead: chain.state.head(for: fileKey))
        // The same absent-head decision the op log's own reader and this
        // store's chained WRITE make — one rule for every chained stream, so
        // the inbox and the annotation log cannot grow an opinion of their own
        // about what a missing remembered head means.
        let (verification, _) = OpLogChain.resolveAbsentHead(
            walked,
            rememberedHead: chain.state.head(for: fileKey),
            previousHead: chain.state.previousHead(for: fileKey))
        let parsed = Self.parse(
            bytes: Self.applied(verification, whole: bytes),
            dedupKey: dedupKey, sortedBy: sortedBy)
        let read = (elements: parsed.elements, diagnostics: parsed.diagnostics,
                    verification: verification)
        do {
            try Self.setAside(
                read.verification, from: fileURL,
                docId: chain.docId, in: chain.projectURL)
        } catch {
            appendStoreLog.error("""
                Could not record set-aside lines from \
                \(self.fileURL.lastPathComponent, privacy: .public): \
                \(String(describing: error), privacy: .public).
                """)
        }
        return (read.elements, read.diagnostics)
    }

    /// Verify, keep, parse — the pure middle of every chained read, callable on
    /// bytes that arrived any way at all (a coordinated read, a decompressed
    /// segment, a synchronous load). Nonisolated so the synchronous op-log
    /// reader can call it without an actor hop.
    nonisolated static func verifiedParse(
        bytes: Data,
        trusted: (String) -> Bool,
        rememberedHead: String?,
        dedupKey: ((Element) -> String)? = nil,
        sortedBy: ((Element, Element) -> Bool)? = nil
    ) -> (elements: [Element], diagnostics: ParseDiagnostics,
          verification: OpLogChain.Verification) {
        let verification = OpLogChain.verify(
            bytes: bytes, trusted: trusted, rememberedHead: rememberedHead)
        let parsed = parse(
            bytes: applied(verification, whole: bytes),
            dedupKey: dedupKey, sortedBy: sortedBy)
        return (parsed.elements, parsed.diagnostics, verification)
    }

    /// The bytes a verification KEPT — the whole input when it quarantined
    /// nothing, and otherwise the applied lines rebuilt in file order.
    ///
    /// One spelling for the reader (which hands them to the parser) and the
    /// chained writer (which writes them back over the file), because the two
    /// disagreeing about what "kept" means would leave a load applying lines a
    /// rewrite had already deleted.
    nonisolated static func applied(
        _ verification: OpLogChain.Verification, whole: Data
    ) -> Data {
        guard !verification.quarantined.isEmpty else { return whole }
        var out = Data()
        for line in verification.lines where line.state != .quarantined {
            out.append(line.bytes)
            out.append(0x0A)
        }
        return out
    }

    /// Record the lines a walk held back, in the writer's own words for why.
    /// Answers nil — writing nothing — when the walk held nothing back.
    ///
    /// Every caller that sets lines aside goes through here: the chained
    /// append, the verified read, and the op log's own load. The REASON is
    /// derived from the break rather than passed in, so no caller can file the
    /// same event under different words.
    @discardableResult
    nonisolated static func setAside(
        _ verification: OpLogChain.Verification,
        from fileURL: URL, docId: String, in projectURL: URL
    ) throws -> QuarantineRecord? {
        guard !verification.quarantined.isEmpty else { return nil }
        return try OpLogQuarantine.setAsideLines(
            verification.quarantined, from: fileURL, docId: docId,
            reason: quarantineReason(verification.breakReason), in: projectURL)
    }

    /// The strict twin of `readBytes`: absent is still empty, unreadable throws.
    private func readBytesStrict() throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Data() }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var readErr: Error?
        var bytes: Data?
        coord.coordinate(readingItemAt: fileURL, options: [], error: &coordErr) { ru in
            do { bytes = try Data(contentsOf: ru) }  // adr-0018-ok: append-store (op-log / inbox JSONL) bytes — the log IS the source of truth (ADR 0018)
            catch { readErr = error }
        }
        if let coordErr { throw coordErr }
        if let readErr { throw readErr }
        return bytes ?? Data()
    }

    /// Coordinated read of the whole file; empty Data if the file is absent.
    private func readBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Data() }
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var bytes: Data?
        coord.coordinate(readingItemAt: fileURL, options: [], error: &coordErr) { ru in
            bytes = try? Data(contentsOf: ru)  // adr-0018-ok: append-store (op-log / inbox JSONL) bytes — the log IS the source of truth (ADR 0018)
        }
        if let coordErr { throw coordErr }
        return bytes ?? Data()
    }

    public func append(_ element: Element) async throws {
        try await appendBatch([element])
    }

    /// Every element in `elements` in ONE write — chained, when there is a
    /// policy, as N lines each naming the one before it, so a batch is a run of
    /// the chain rather than a gap in it.
    ///
    /// The batch is the unit a caller means: `write_translation` files a
    /// paragraph set, the Translation Review pane purges a set of orphans, and
    /// either one either lands whole or does not land. Writing them one
    /// `append` at a time would coordinate N times, re-verify the tail N times,
    /// and leave a partial run behind the first failure — the very thing
    /// `TranslationStore.appendBatch` was extracted to prevent.
    ///
    /// An empty batch writes nothing and is not an error: a caller that built
    /// no records has nothing to say, and minting a file for it is exactly the
    /// phantom `TranslationStore`'s tombstone rule refuses.
    public func appendBatch(_ elements: [Element]) async throws {
        guard !elements.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var encoded: [Data] = []
        encoded.reserveCapacity(elements.count)
        for element in elements { encoded.append(Data(try encode(element).utf8)) }
        if let chain {
            try chainedAppend(elementJSONs: encoded, chain: chain)
            return
        }
        var out = Data()
        for line in encoded {
            out.append(line)
            out.append(0x0A)
        }
        try plainAppend(out)
    }

    /// Appends one seal line over this file's current head, signed by the
    /// policy's identity, and answers whether it wrote one.
    ///
    /// It answers **false** — appending nothing and throwing nothing — in the
    /// three cases that are conditions rather than failures: no chain policy at
    /// all, an identity with no key (spec §4.1: such a device writes chained
    /// lines that nothing seals, and that is a state, not an error), and a file
    /// with no unsealed line since its last seal (there is nothing new to
    /// commit to).
    ///
    /// It goes through the SAME chained path an op does, so a foreign line
    /// sitting in the tail is set aside before the seal commits to a head that
    /// includes it. One implementation for the op log and the inbox.
    @discardableResult
    public func appendSeal(at date: Date = Date()) async throws -> Bool {
        guard let chain, chain.identity.canSign else { return false }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        return try chainedAppend(elementJSONs: [], chain: chain, sealAt: date)
    }

    // MARK: - The chained write

    /// The whole chained append, inside ONE coordinated write.
    ///
    /// Order, and why each step is where it is:
    ///
    /// 1. **Read the tail** off the coordinated URL itself — never a nested
    ///    coordination, which would deadlock on the write we already hold.
    /// 2. **Verify** against this device's remembered head. `trusted` is this
    ///    device's own fingerprints and nothing else — all four of its actors
    ///    since P1b, one for a store built with a single identity: P1 has no
    ///    registry, and a seal from anyone else is history rather than this
    ///    device's word.
    /// 3. **Set aside** whatever the verifier quarantined, then rewrite the
    ///    kept bytes. Quarantined lines are always a suffix (the walk stops at
    ///    the first break and quarantines everything after it), so "kept" is a
    ///    prefix and the rewrite is a truncation. Rewriting a file another
    ///    writer might be appending to would be reckless; this one has exactly
    ///    one writer by ADR 0012, the same argument `sealTailIfNeeded` makes.
    /// 4. **Chain onto the verified head**, or onto `OpLogChain.genesis` when
    ///    the file is empty — never nil, because a first line with no `prev` is
    ///    indistinguishable from a pre-P1 legacy line and no seal would ever
    ///    settle it.
    /// 5. **Remember the new head BEFORE writing the line.** A crash between
    ///    the two leaves a remembered head that no line hashes to, which the
    ///    load path treats as the adopt case. The other order would leave a
    ///    line the device wrote sitting after the head it remembers — its own
    ///    last op, quarantined as a stranger's.
    @discardableResult
    private func chainedAppend(
        elementJSONs: [Data], chain: ChainPolicy, sealAt: Date? = nil
    ) throws -> Bool {
        let fileKey = OpLogDeviceState.fileKey(fileURL)
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var thrown: Error?
        var wrote = false

        coord.coordinate(writingItemAt: fileURL, options: [], error: &coordErr) { wu in
            do {
                let existing = (try? Data(contentsOf: wu)) ?? Data()  // adr-0018-ok: append-store (op-log / inbox JSONL) bytes — the log IS the source of truth (ADR 0018)
                let walked = OpLogChain.verify(
                    bytes: existing,
                    trusted: { chain.trustedFingerprints.contains($0) },
                    rememberedHead: chain.state.head(for: fileKey))
                // The same decision the READ makes about a remembered head that
                // is nowhere in the file, from the same function. If the two
                // disagreed, a load that held a forged tail back would be
                // followed by an append that chained onto it, stranding the
                // writer's own new ops after a break for good.
                let (verification, _) = OpLogChain.resolveAbsentHead(
                    walked,
                    rememberedHead: chain.state.head(for: fileKey),
                    previousHead: chain.state.previousHead(for: fileKey))

                if !verification.quarantined.isEmpty {
                    try Self.setAside(
                        verification, from: wu,
                        docId: chain.docId, in: chain.projectURL)
                    try Self.applied(verification, whole: existing)
                        .write(to: wu, options: .atomic)
                }

                // Each line chains onto the one before it, so the running
                // head advances WITHIN the batch — N lines are N links, not N
                // siblings of one head, which would leave every line after the
                // first breaking the chain on the next read.
                var prev = verification.head ?? OpLogChain.genesis
                var out = Data()
                if elementJSONs.isEmpty {
                    guard let sealAt, verification.head != nil,
                          verification.lines.contains(where: { $0.state == .unsealed })
                    else { return }
                    let line = try OpLogChain.Seal.line(
                        head: prev, identity: chain.identity, at: sealAt)
                    prev = OpLogChain.lineHash(line)
                    out.append(line)
                    out.append(0x0A)
                } else {
                    for elementJSON in elementJSONs {
                        let line = OpLogChain.chainedLine(elementJSON: elementJSON, prev: prev)
                        prev = OpLogChain.lineHash(line)
                        out.append(line)
                        out.append(0x0A)
                    }
                }

                // Persist-before-write, over the head the WHOLE batch leaves:
                // a crash mid-write leaves a remembered head no line hashes to,
                // which is the adopt case, never a line this device wrote
                // sitting after the head it remembers.
                chain.state.remember(head: prev, for: fileKey, root: chain.projectURL)

                if FileManager.default.fileExists(atPath: wu.path) {
                    let h = try FileHandle(forWritingTo: wu)
                    try h.seekToEnd()
                    try h.write(contentsOf: out)
                    try h.close()
                } else {
                    try out.write(to: wu, options: .atomic)
                }
                wrote = true
            } catch { thrown = error }
        }
        if let coordErr { throw coordErr }
        if let thrown { throw thrown }
        return wrote
    }

    /// The writer's own words for why a line was set aside. Two reasons, not
    /// five: a line that chains correctly but arrived after the head this
    /// device remembers, and one that has no `prev` at all after the chain
    /// began, both mean something else wrote into this file. Everything else is
    /// the chain itself failing to hold together.
    nonisolated static func quarantineReason(_ reason: OpLogChain.BreakReason?) -> String {
        switch reason {
        case .afterRememberedHead, .unchainedAfterChain:
            return "written by something that is not Maugham"
        default:
            return "the history's chain is broken"
        }
    }

    private func plainAppend(_ line: Data) throws {
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(writingItemAt: fileURL, options: [], error: &coordErr) { wu in
            do {
                if FileManager.default.fileExists(atPath: wu.path) {
                    let h = try FileHandle(forWritingTo: wu)
                    try h.seekToEnd()
                    try h.write(contentsOf: line)
                    try h.close()
                } else {
                    try line.write(to: wu, options: .atomic)
                }
            } catch { writeErr = error }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    private func encode(_ element: Element) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = Self.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(element)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseDiagnosed(bytes: Data) -> (elements: [Element], diagnostics: ParseDiagnostics) {
        Self.parse(bytes: bytes, dedupKey: dedupKey, sortedBy: sortedBy)
    }

    /// Parse raw JSONL bytes — the SAME parser the file-backed load uses,
    /// callable on bytes that arrived another way (a decompressed sealed
    /// segment, ADR 0016). Nonisolated + static so the synchronous readers
    /// (`OpLogStore.loadSyncMerged`) can call it.
    nonisolated static func parse(
        bytes: Data,
        dedupKey: ((Element) -> String)? = nil,
        sortedBy: ((Element, Element) -> Bool)? = nil
    ) -> (elements: [Element], diagnostics: ParseDiagnostics) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = Self.dateDecoding
        var elements: [Element] = []
        var seen = Set<String>()
        var skipped: [ParseDiagnostics.SkippedLine] = []
        var offset = 0
        for lineBytes in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let lineLen = lineBytes.count
            defer { offset += lineLen + 1 }  // +1 for the consumed newline
            if lineBytes.isEmpty { continue }  // blank line: not corruption
            let data = Data(lineBytes)
            // A seal is a line of its own kind, not an element — it belongs to
            // the chain, and `OpLogChain` is the only thing that reads one. It
            // is filtered HERE, in the one parser every reader shares (tails,
            // decompressed segments, the inbox), so no reader can be written
            // that hands a seal to an element decoder and then reports the
            // file as damaged because it would not decode.
            if OpLogChain.isSealLine(data) { continue }
            guard let element = try? dec.decode(Element.self, from: data) else {
                let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                skipped.append(.init(byteOffset: offset, raw: raw))
                continue
            }
            if let key = dedupKey?(element), !seen.insert(key).inserted { continue }
            elements.append(element)
        }
        if let sortedBy { elements.sort(by: sortedBy) }
        return (elements, ParseDiagnostics(skipped: skipped))
    }

    // === Shared ISO8601-with-fractional-seconds Date coding ===

    // Computed property returning a fresh instance per call keeps this
    // nonisolated without the (unsafe) baggage on a class-typed stored property.
    // These stores are not on the hot path so the allocation cost is negligible.
    nonisolated private static var iso8601Formatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    nonisolated public static var dateEncoding: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso8601Formatter.string(from: date))
        }
    }

    nonisolated public static var dateDecoding: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            // Accept fractional-second and whole-second ISO8601 strings.
            if let d = iso8601Formatter.date(from: s) { return d }
            if let d = ISO8601DateFormatter().date(from: s) { return d }
            // Backward-compat for CheckpointStore data written via secondsSince1970.
            if let epoch = Double(s) { return Date(timeIntervalSince1970: epoch) }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unrecognised date: \(s)")
        }
    }
}
