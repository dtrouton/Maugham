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

    /// Notes per round over the last five, oldest first — the desk's trend.
    func trend(language: String) -> [Int] {
        Array(load(language: language).rounds.suffix(5)).map(\.noteCount)
    }

    /// Append one finished round, advance the number past it, trim the ring.
    func append(_ round: TranslationRound) throws {
        var ledger = load(language: round.language)
        ledger.rounds.append(round)
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
                return "Round \(number) is no longer in the ledger \u{2014} it has aged out of the last \(TranslationRoundStore.ringSize)."
            }
        }
    }

    /// Rewrite one round the report's verbs changed (a departure dismissed, a
    /// proposal adopted or skipped). Never mints a number and never moves one.
    func update(_ round: TranslationRound) throws {
        var ledger = load(language: round.language)
        guard let index = ledger.rounds.firstIndex(where: { $0.number == round.number }) else {
            throw UpdateError.roundGone(number: round.number)
        }
        ledger.rounds[index] = round
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
