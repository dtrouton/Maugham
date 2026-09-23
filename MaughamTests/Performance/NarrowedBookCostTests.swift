import XCTest
@testable import Maugham
@testable import MaughamCore

/// **What a narrowed book costs** (signed op log P3b Task 10; the whole-branch
/// review's W5, inherited).
///
/// P3a measured the ORDINARY book — which is what every existing book becomes
/// — and could not measure the narrowed one, because nothing P3a shipped
/// created a permit event. P3b does: the admission sheet's rung, People &
/// Devices' Change…, and the unsigned photograph every narrowing verb takes.
/// So the number P3b inherited (`Document.load` 23.8 → 39.2 ms, medians of 7,
/// one reviewer) is re-measured here against a book that was narrowed through
/// the production verbs, and a THIRD shape is added that P3a had no name for:
/// a narrowed book holding a long stream this register can name no key for,
/// which is the file the photograph is about and the one every load now walks
/// and judges.
///
/// **Env-gated and kept**, `OpLogGrowthBaselineTests`' rule and for its reason:
/// it is heavy, it is a measurement rather than an assertion, and a number
/// nobody can re-take is a number nobody can check. Run it with:
///
///     TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 xcodebuild -project Maugham.xcodeproj \
///       -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
///       -only-testing:MaughamTests/NarrowedBookCostTests
///
/// **The four measures are P3a's four**, so the two runs are about the same
/// things: the annotations walk, the board's aggregation over it,
/// `Document.load` of the heaviest piece, and `TranslationStore.loadMerged`.
/// Each is a median of seven.
///
/// **The absolute numbers are not P3a's.** That probe was thrown away
/// (it was never committed), and this fixture is a real novel project built by
/// `ProjectFactory` with bursts written into one piece, not the 30-document
/// growth fixture. What is comparable — and what the ADR and `AREA.md` state —
/// is the DELTA between the shapes, measured here on one machine in one run.
///
/// Nothing is asserted about a duration. A machine that is busy would fail
/// such an assertion and teach nobody anything (`OpLogGrowthBaselineTests`
/// made the same choice); the run PRINTS, the report records, and the two
/// documents quote it.
@MainActor
final class NarrowedBookCostTests: XCTestCase {

    /// How many typing bursts go into the measured piece. Enough that
    /// `Document.load` is doing real work — P3a's headline was a 1,001-op
    /// document — and small enough that three shapes build in a minute.
    private static let bursts = 300

    /// How many chained lines the unsigned stream carries in shape 3. A Mac
    /// with no enclave that has been in the book for a while.
    private static let unsignedLines = 400

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        PieceWriterFixture.reset()
        temp.cleanup()
        temp = nil
    }

    /// What was installed in the register before the measurement.
    private enum Shape: String, CaseIterable {
        /// Somebody admitted, nobody narrowed — P2b's own book, and the shape
        /// W1 restored every exit for.
        case admissionsOnly = "admissions only"
        /// One reviewer: the first narrowing, its event, and the photograph
        /// that comes with it.
        case oneReviewer = "one reviewer"
        /// The same, over a book holding a long stream no key can name — the
        /// door's own subject.
        case oneReviewerAndAnUnsignedStream = "one reviewer + an unsigned stream"
    }

    func test_whatANarrowedBookCosts() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")

        var rows: [(Shape, [String: Double])] = []
        for shape in Shape.allCases {
            rows.append((shape, try await measure(shape)))
        }

        let columns = ["annotations walk", "aggregation", "Document.load",
                       "loadMerged"]
        var table = "=== P3b Task 10 \u{2014} what a narrowed book costs "
            + "(medians of 7, ms; \(Self.bursts) bursts, "
            + "\(Self.unsignedLines) unsigned lines) ===\n"
        table += "shape".padding(toLength: 36, withPad: " ", startingAt: 0)
            + columns.map { $0.padding(toLength: 20, withPad: " ", startingAt: 0) }
                .joined() + "\n"
        for (shape, numbers) in rows {
            table += shape.rawValue.padding(toLength: 36, withPad: " ", startingAt: 0)
                + columns.map {
                    String(format: "%.2f", numbers[$0] ?? -1)
                        .padding(toLength: 20, withPad: " ", startingAt: 0)
                }.joined() + "\n"
        }

        // **Attached, not only printed.** `xcodebuild`'s own log does not
        // carry a test's stdout and the host is sandboxed, so a `print` and a
        // file in the host's temp directory are both unreadable afterwards —
        // and a measurement nobody can read back is a measurement nobody can
        // check, which is the whole reason this suite is KEPT rather than
        // thrown away like P3a's probe was. Pull it with:
        //
        //   xcrun xcresulttool export attachments \
        //     --path <bundle>.xcresult --output-path <dir>
        let attachment = XCTAttachment(string: table)
        attachment.name = "narrowed-book-cost.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\n" + table)
    }

    // MARK: - One shape, measured

    private func measure(_ shape: Shape) async throws -> [String: Double] {
        let book = try await buildBook(shape)
        defer { PieceWriterFixture.reset() }
        let piece = book.pieceIDs[0]
        let url = try XCTUnwrap(pieceURL(book, piece))

        // **A fresh store per iteration for the two walks.** Both are cached
        // behind a key that stats every closed document's op-log files, so a
        // second call on one store measures the cache and not the walk — and
        // the walk is what an app launch does.
        let walk = try await median(7) {
            let store = try await ProjectStore.load(from: book.url)
            _ = store.listAnnotationsAcrossProject()
        }
        let aggregation = try await median(7) {
            let store = try await ProjectStore.load(from: book.url)
            _ = store.openNotesSummaries()
        }
        let load = try await median(7) {
            let doc = try await Document.load(
                url: url, device: "cost-measure", session: "m", presenter: nil,
                burstIdle: .seconds(3600), burstMax: .seconds(3600))
            await doc.close()
        }
        let merged = try await median(7) {
            _ = try TranslationStore.loadMerged(
                forDocId: piece, language: "es", in: book.url)
        }
        return ["annotations walk": walk, "aggregation": aggregation,
                "Document.load": load, "loadMerged": merged]
    }

    /// A piece's file on disk, off the manifest's own `path`.
    private func pieceURL(
        _ book: PieceWriterFixture.Book, _ pieceID: String
    ) -> URL? {
        TreeWalk.collect(in: book.store.manifest.structure, where: { $0.id == pieceID })
            .first?.path
            .map { book.url.appendingPathComponent($0) }
    }

    private func median(
        _ times: Int, _ body: () async throws -> Void
    ) async rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<times {
            let clock = ContinuousClock()
            let start = clock.now
            try await body()
            let elapsed = clock.now - start
            samples.append(
                Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15)
        }
        return samples.sorted()[times / 2]
    }

    // MARK: - The three books

    private func buildBook(_ shape: Shape) async throws -> PieceWriterFixture.Book {
        let book = try await PieceWriterFixture.oneAuthor(
            named: "cost-\(shape.rawValue.prefix(4))", in: temp.url)
        try await writeBursts(into: book)
        let sam = DeviceIdentity.softwareForTesting()
        _ = try await book.documentStore.admit(
            device: sam.fingerprint, label: "Sam", ownName: "Sam\u{2019}s Mac")
        switch shape {
        case .admissionsOnly:
            break
        case .oneReviewer:
            _ = try await book.documentStore.changePermit(
                everyRecordOf: sam.fingerprint, to: .reviewer)
        case .oneReviewerAndAnUnsignedStream:
            // Written BEFORE the narrowing, so the photograph is taken over a
            // stream that is really there — which is the walk the third shape
            // exists to price.
            try writeUnsignedStream(into: book)
            _ = try await book.documentStore.changePermit(
                everyRecordOf: sam.fingerprint, to: .reviewer)
        }
        return book
    }

    /// Bursts into the first piece, through the ordinary editing path, so the
    /// op log is the shape a writer's own afternoon leaves behind.
    private func writeBursts(into book: PieceWriterFixture.Book) async throws {
        let url = try XCTUnwrap(pieceURL(book, book.pieceIDs[0]))
        let doc = try await Document.load(
            url: url, device: "cost-measure", session: "build", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        for burst in 0..<Self.bursts {
            if doc.sequence.isEmpty {
                _ = doc.insertParagraph(after: nil, text: "opening \(burst)")
            } else {
                let id = doc.sequence[burst % doc.sequence.count]
                doc.setParagraph(
                    id: id, text: (doc.paragraph(id: id) ?? "") + " w\(burst)")
            }
            if burst % 20 == 19 {
                _ = doc.insertParagraph(
                    after: doc.sequence.last, text: "paragraph \(burst)")
            }
            try await doc.flushBurstNow()
        }
        await doc.close()
    }

    /// A chained, never-sealed op-log file under a slug no device record
    /// names — a Mac with no Secure Enclave, which is exactly what the
    /// unsigned door is about.
    private func writeUnsignedStream(into book: PieceWriterFixture.Book) throws {
        let piece = book.pieceIDs[0]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        var bytes = Data()
        var head = OpLogChain.genesis
        for index in 0..<Self.unsignedLines {
            let op = Op(
                opId: String(format: "01K5Q8ZJ3M%014d", index), docId: piece,
                at: Date(timeIntervalSince1970: 1_000 + Double(index)),
                device: "author-ghostmac", session: "ghost", kind: .typingBurst,
                changes: [.init(paragraphId: "aaaa", prior: nil,
                                next: "ghost \(index)")],
                sequence: ["aaaa"])
            let line = OpLogChain.chainedLine(
                elementJSON: try encoder.encode(op), prev: head)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        try bytes.write(
            to: OpLogStore.opLogFileURL(
                forDocId: piece,
                deviceSlug: DeviceSlug.unsafeForTesting("ghostmac-0badf00d"),
                in: book.url),
            options: .atomic)
    }
}
