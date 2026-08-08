import Foundation

/// One clause that has strained in each of the last
/// `DriftDetector.consecutiveRunsThreshold` runs — a pattern, not a
/// one-off strain the writer already sees in the run register.
struct DriftFinding: Equatable {
    let clauseQuote: String
    let runsStraining: Int
}

/// Reads `DiagnosticsStore.clauseStatusHistory`'s ring and finds clauses
/// straining on a pattern rather than once. Pure and on-demand — the spec's
/// constitution check (§7): "drift is computed from records, never a
/// background process."
enum DriftDetector {
    /// Enough runs in a row that "strains" reads as a pattern rather than
    /// noise — three, chosen to fit inside `DiagnosticsStore.clauseHistoryDepth`
    /// (five) with headroom.
    static let consecutiveRunsThreshold = 3

    /// `history` is oldest→newest, exactly `clauseStatusHistory`'s shape.
    ///
    /// Matched by `clauseQuote`, walking backward from the newest run: a
    /// clause absent from a run (a re-derivation renamed it), one that holds,
    /// or one the delta was silent about all end its streak the same way — an
    /// honest reset, not a special case. A finding reports the streak's full
    /// length, not just the threshold that qualified it.
    static func drift(history: [[DiagnosticIngest.ClauseStatus]]) -> [DriftFinding] {
        guard let mostRecent = history.last else { return [] }

        var findings: [DriftFinding] = []
        var seenQuotes = Set<String>()
        for entry in mostRecent where seenQuotes.insert(entry.clauseQuote).inserted {
            let quote = entry.clauseQuote
            var streak = 0
            for run in history.reversed() {
                guard let match = run.first(where: { $0.clauseQuote == quote }),
                      match.status == "strains"
                else { break }
                streak += 1
            }
            if streak >= consecutiveRunsThreshold {
                findings.append(DriftFinding(clauseQuote: quote, runsStraining: streak))
            }
        }
        return findings
    }
}
