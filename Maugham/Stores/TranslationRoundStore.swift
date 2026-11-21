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
        load(language: language).nextNumber
    }

    /// Newest first.
    func rounds(language: String) -> [TranslationRound] {
        load(language: language).rounds.reversed()
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
        let ledger = load(language: language)
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
        let ledger = load(language: language)
        var byPiece = ledger.latestByPiece
        for round in ledger.rounds where Self.isFinished(round) {
            if let kept = byPiece[round.docId], kept.number >= round.number { continue }
            byPiece[round.docId] = round
        }
        return byPiece
    }

    /// Notes per round over the last five, oldest first — the desk's trend.
    func trend(language: String) -> [Int] {
        Array(load(language: language).rounds.suffix(5)).map(\.noteCount)
    }

    /// Notes per round for one piece's rounds still in the ring, oldest first.
    func trend(language: String, docId: String) -> [Int] {
        load(language: language).rounds.filter { $0.docId == docId }.map(\.noteCount)
    }

    /// Append one round, advance the number past it, trim the ring. A
    /// finished round also becomes its piece's latest; a cancelled one goes
    /// to the ring only.
    func append(_ round: TranslationRound) throws {
        var ledger = load(language: round.language)
        ledger.rounds.append(round)
        if Self.isFinished(round) {
            ledger.latestByPiece[round.docId] = round
        }
        ledger.nextNumber = max(ledger.nextNumber, round.number + 1)
        if ledger.rounds.count > Self.ringSize {
            ledger.rounds.removeFirst(ledger.rounds.count - Self.ringSize)
        }
        try write(ledger, language: round.language)
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

    /// Rewrite one round the report's verbs changed (a departure dismissed, a
    /// proposal adopted or skipped). Never mints a number and never moves one.
    /// Writes through to every place the round is kept — the ring, and its
    /// piece's latest — so a round aged out of the ring is still found when it
    /// is its piece's latest.
    func update(_ round: TranslationRound) throws {
        var ledger = load(language: round.language)
        var found = false
        if let index = ledger.rounds.firstIndex(where: { $0.number == round.number }) {
            ledger.rounds[index] = round
            found = true
        }
        if ledger.latestByPiece[round.docId]?.number == round.number {
            ledger.latestByPiece[round.docId] = round
            found = true
        }
        guard found else { throw UpdateError.roundGone(number: round.number) }
        try write(ledger, language: round.language)
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
