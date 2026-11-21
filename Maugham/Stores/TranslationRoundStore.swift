import Foundation
import MaughamCore
import os

private let roundLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "TranslationRounds")

/// **The ring of rounds** (spec §7): `.maugham/translations/rounds/<lang>.json`,
/// one file per language holding the last `ringSize` rounds and the next
/// number. Derived — losing it costs a report and restarts numbering, never
/// words. Not per-device (tripwire 17 is about concurrent APPENDS to one file;
/// this is a whole-file rewrite by the one pipeline the gate allows), and
/// `.maugham/translations/` already classifies as `unknownSidecar` in
/// `MaughamSidecarPath`, so no presenter route changes.
struct TranslationRoundStore {

    static let ringSize = 10

    /// The file's whole content. `nextNumber` outlives the ring so a number
    /// trimmed out of it is never minted twice.
    struct Ledger: Codable, Equatable {
        var nextNumber: Int = 1
        /// Oldest first on disk; readers below reverse it.
        var rounds: [TranslationRound] = []
        /// **Each piece's latest FINISHED round, keyed by docId** (shell plan 4
        /// Task 2). The ring is per language, so a whole-book run of twelve
        /// chapters ages out two chapters' letters; this map keeps every
        /// chapter's, beside the ring rather than instead of it. A cancelled
        /// round never lands here (`isFinished`).
        var latestByPiece: [String: TranslationRound] = [:]

        init(nextNumber: Int = 1, rounds: [TranslationRound] = [],
             latestByPiece: [String: TranslationRound] = [:]) {
            self.nextNumber = nextNumber
            self.rounds = rounds
            self.latestByPiece = latestByPiece
        }

        private enum CodingKeys: String, CodingKey { case nextNumber, rounds, latestByPiece }

        /// Hand-written for `latestByPiece` alone: a ledger written before the
        /// map existed reads with an empty one (tripwire 11: no migration).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nextNumber = try c.decode(Int.self, forKey: .nextNumber)
            rounds = try c.decode([TranslationRound].self, forKey: .rounds)
            latestByPiece = try c.decodeIfPresent(
                [String: TranslationRound].self, forKey: .latestByPiece) ?? [:]
        }
    }

    /// A round that ran to an end and was not cancelled — a failed round is
    /// finished (its report says where it stopped); a cancelled one is not.
    static func isFinished(_ round: TranslationRound) -> Bool {
        round.endedAt != nil && !round.wasCancelled
    }

    let projectURL: URL

    init(projectURL: URL) { self.projectURL = projectURL }

    static func directoryURL(in projectURL: URL) -> URL {
        TranslationStore.directoryURL(in: projectURL).appendingPathComponent("rounds")
    }

    static func fileURL(language: String, in projectURL: URL) -> URL {
        directoryURL(in: projectURL).appendingPathComponent("\(language.lowercased()).json")
    }

    func nextNumber(language: String) -> Int {
        reading(language) { $0.nextNumber }
    }

    /// Newest first.
    func rounds(language: String) -> [TranslationRound] {
        reading(language) { $0.rounds.reversed() }
    }

    /// The newest round for `(language, docId)`, or for the language when
    /// `docId` is nil.
    func latest(language: String, docId: String?) -> TranslationRound? {
        rounds(language: language).first { docId == nil || $0.docId == docId }
    }

    /// The newest finished round for `(language, docId)`, whether or not the
    /// ring still holds it. The map answers; a ledger written before the map
    /// existed falls back to the ring, and the higher number wins (numbers
    /// rise per language, so it is the newer).
    func latestFinished(language: String, docId: String) -> TranslationRound? {
        let ledger = reading(language) { $0 }
        let kept = ledger.latestByPiece[docId]
        let ringed = ledger.rounds.last { $0.docId == docId && Self.isFinished($0) }
        switch (kept, ringed) {
        case (let kept?, let ringed?): return ringed.number > kept.number ? ringed : kept
        case (let kept?, nil): return kept
        case (nil, let ringed): return ringed
        }
    }

    /// Every piece's newest finished round in `language`, keyed by docId —
    /// `latestFinished` for the whole book in one read.
    func latestFinishedByPiece(language: String) -> [String: TranslationRound] {
        let ledger = reading(language) { $0 }
        var byPiece = ledger.latestByPiece
        for round in ledger.rounds where Self.isFinished(round) {
            if let kept = byPiece[round.docId], kept.number >= round.number { continue }
            byPiece[round.docId] = round
        }
        return byPiece
    }

    /// **`latestFinishedByPiece` and `trendsByPiece` from ONE decode** —
    /// what an edition's Status reads (shell p4 Task 6 fix round 2, N5: the
    /// ledger is megabytes at book size, and the two calls decoded it twice).
    func latestFinishedAndTrendsByPiece(language: String)
    -> (latest: [String: TranslationRound], trends: [String: [Int]]) {
        let ledger = reading(language) { $0 }
        var byPiece = ledger.latestByPiece
        for round in ledger.rounds where Self.isFinished(round) {
            if let kept = byPiece[round.docId], kept.number >= round.number { continue }
            byPiece[round.docId] = round
        }
        let trends = ledger.rounds.reduce(into: [String: [Int]]()) {
            $0[$1.docId, default: []].append($1.noteCount)
        }
        return (byPiece, trends)
    }

    /// Notes per round over the last five, oldest first — the desk's trend.
    func trend(language: String) -> [Int] {
        reading(language) { Array($0.rounds.suffix(5)).map(\.noteCount) }
    }

    /// Notes per round for one piece's rounds still in the ring, oldest first.
    func trend(language: String, docId: String) -> [Int] {
        reading(language) { $0.rounds.filter { $0.docId == docId }.map(\.noteCount) }
    }

    /// `trend(language:docId:)` for every piece in one read, keyed by docId —
    /// what an edition's Status asks (shell p4 Task 5), never once per row.
    func trendsByPiece(language: String) -> [String: [Int]] {
        reading(language) { ledger in
            ledger.rounds.reduce(into: [:]) { $0[$1.docId, default: []].append($1.noteCount) }
        }
    }

    /// Append one round, advance the number past it, trim the ring. A
    /// finished round also becomes its piece's latest; a cancelled one goes
    /// to the ring only.
    func append(_ round: TranslationRound) throws {
        try changing(round.language) { ledger in Self.appending(round, to: &ledger) }
    }

    /// **Append, in order, without holding the caller** (shell p4 Task 6 fix
    /// round 3): the pipeline's save, enqueued on the project's ledger queue
    /// behind every write already pressed, so the main actor never waits on a
    /// book-sized decode. A read asked after it (the next round's number, a
    /// list re-read on the round-ended post) is queued after it and sees it.
    func appendInOrder(_ round: TranslationRound, onFailure: @escaping @Sendable (Error) -> Void) {
        let store = self
        Self.queue(for: projectURL).async {
            do { try store.changingOnQueue(round.language) { Self.appending(round, to: &$0) } } catch {
                onFailure(error)
            }
        }
    }

    private static func appending(_ round: TranslationRound, to ledger: inout Ledger) {
        ledger.rounds.append(round)
        if isFinished(round) {
            ledger.latestByPiece[round.docId] = round
        }
        ledger.nextNumber = max(ledger.nextNumber, round.number + 1)
        if ledger.rounds.count > ringSize {
            ledger.rounds.removeFirst(ledger.rounds.count - ringSize)
        }
    }

    enum UpdateError: LocalizedError {
        case roundGone(number: Int)
        var errorDescription: String? {
            switch self {
            case .roundGone(let number):
                return "Round \(number) is no longer in the ledger \u{2014} it has aged out of the last \(TranslationRoundStore.ringSize) and is not its piece's latest."
            }
        }
    }

    /// **The round as the ledger holds it NOW**, by number and piece — the
    /// copy a verb must decide over, never the one a surface was holding
    /// (shell p4 Task 6 fix round, review C1). Its piece's latest when it is
    /// one, else the ring's.
    func record(language: String, docId: String, number: Int) -> TranslationRound? {
        reading(language) { Self.record(in: $0, docId: docId, number: number) }
    }

    private static func record(in ledger: Ledger, docId: String, number: Int) -> TranslationRound? {
        if let kept = ledger.latestByPiece[docId], kept.number == number { return kept }
        return ledger.rounds.last { $0.number == number && $0.docId == docId }
    }

    /// **Change one round in place: a read-modify-write of the CURRENT
    /// record** (shell p4 Task 6 fix round, review C1). The report's and To
    /// resolve's verbs (a departure dismissed or ruled, a glossary proposal
    /// adopted or skipped) flip one field of the record as the ledger holds
    /// it at the write — never a whole value a surface was holding, so a
    /// second verb pressed over a stale copy cannot undo the first. Applied
    /// to every place the round is kept (the ring, and its piece's latest),
    /// never mints a number and never moves one. Returns the round as
    /// written; `change` may throw to refuse, and then nothing is written.
    @discardableResult
    func mutate(language: String, docId: String, number: Int,
                _ change: (inout TranslationRound) throws -> Void) throws -> TranslationRound {
        try changing(language) { try Self.mutating(&$0, docId: docId, number: number, change) }
    }

    /// **`mutate`, in the order it was asked, off the caller's actor** (fix
    /// round 3): enqueued on the project's ledger queue at the call — a
    /// verb pressed before another is written before it — and awaited.
    func mutateInOrder(language: String, docId: String, number: Int,
                       _ change: @escaping @Sendable (inout TranslationRound) throws -> Void)
    async throws -> TranslationRound {
        let store = self
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue(for: projectURL).async {
                continuation.resume(with: Result {
                    try store.changingOnQueue(language) {
                        try Self.mutating(&$0, docId: docId, number: number, change)
                    }
                })
            }
        }
    }

    /// `record`, in order behind every write already asked, off the caller.
    func recordInOrder(language: String, docId: String, number: Int) async -> TranslationRound? {
        let store = self
        return await withCheckedContinuation { continuation in
            Self.queue(for: projectURL).async {
                continuation.resume(returning: Self.record(in: store.load(language: language),
                                                           docId: docId, number: number))
            }
        }
    }

    private static func mutating(_ ledger: inout Ledger, docId: String, number: Int,
                                 _ change: (inout TranslationRound) throws -> Void) throws -> TranslationRound {
        var written: TranslationRound?
        // Number AND piece: two Macs can mint one number in one language for
        // different chapters before either sees the other's file.
        if let index = ledger.rounds.firstIndex(where: { $0.number == number && $0.docId == docId }) {
            try change(&ledger.rounds[index])
            written = ledger.rounds[index]
        }
        if var kept = ledger.latestByPiece[docId], kept.number == number {
            try change(&kept)
            ledger.latestByPiece[docId] = kept
            written = kept
        }
        guard let written else { throw UpdateError.roundGone(number: number) }
        return written
    }

    // MARK: - One writer at a time (shell p4 Task 6 fix round 3)

    /// **Every read and every read-modify-write of a project's round ledger
    /// goes through ONE serial queue per project** — the struct is made
    /// freely, so the queue lives in a table keyed by the project's folder,
    /// shared by every `TranslationRoundStore` for that project. A verb, the
    /// pipeline's append and an MCP read therefore never interleave a load
    /// with another's write: no change is dropped, and the queue's FIFO
    /// keeps writes in the order they were asked. `load` and `write` are
    /// called from `reading`, `changingOnQueue` and `recordInOrder` only
    /// (`TranslationRoundStoreTests.test_theLedgerIsReadAndWrittenThroughTheQueueOnly`).
    private static let queuesLock = NSLock()
    nonisolated(unsafe) private static var queues: [String: DispatchQueue] = [:]

    static func queue(for projectURL: URL) -> DispatchQueue {
        let key = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
        queuesLock.lock()
        defer { queuesLock.unlock() }
        if let queue = queues[key] { return queue }
        let queue = DispatchQueue(label: "maugham.translation-rounds")
        queues[key] = queue
        return queue
    }

    /// Test seam: called on the queue between a write's load and its write
    /// — where an unserialised writer would let another in.
    nonisolated(unsafe) static var betweenLoadAndWrite: ((URL) -> Void)?

    private func reading<T>(_ language: String, _ body: (Ledger) -> T) -> T {
        Self.queue(for: projectURL).sync { body(load(language: language)) }
    }

    private func changing<T>(_ language: String, _ body: (inout Ledger) throws -> T) throws -> T {
        try Self.queue(for: projectURL).sync { try changingOnQueue(language, body) }
    }

    /// The one load-change-write; on the project's queue only.
    private func changingOnQueue<T>(_ language: String, _ body: (inout Ledger) throws -> T) throws -> T {
        var ledger = load(language: language)
        let result = try body(&ledger)
        Self.betweenLoadAndWrite?(projectURL)
        try write(ledger, language: language)
        return result
    }

    /// A missing or undecodable file is an empty ledger, logged — the ring is
    /// derived, and a round that cannot be written because last month's could
    /// not be read is the wrong trade.
    private func load(language: String) -> Ledger {
        let url = Self.fileURL(language: language, in: projectURL)
        guard let data = try? Data(contentsOf: url) else { return Ledger() }  // adr-0018-ok: reads a derived .maugham/translations/rounds/ ledger the pipeline itself wrote, not manuscript text
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Ledger.self, from: data)
        } catch {
            roundLog.error("round ledger for \(language, privacy: .public) is unreadable and will be replaced: \(error, privacy: .public)")
            return Ledger()
        }
    }

    private func write(_ ledger: Ledger, language: String) throws {
        try FileManager.default.createDirectory(
            at: Self.directoryURL(in: projectURL), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ledger).write(
            to: Self.fileURL(language: language, in: projectURL), options: .atomic)
    }
}
