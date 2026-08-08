import XCTest
@testable import Maugham

/// Contracts for `ClaudeWorldDeriver`, the one-shot `claude -p` that turns a
/// statement's freeform prose into checkable `DerivedClause`/`DerivedRule`
/// values.
///
/// **No network and no real `claude` binary** for every test but one — see
/// the task-3 report for the single live probe. Every test here injects a
/// `cliOverride` pointing at a bash fixture, the same discipline
/// `ClaudeCLISessionTests` uses, but the fixture is simpler: this is a
/// ONE-SHOT `-p --output-format json` call, not a warm stream-json session —
/// read all of stdin once, print one JSON envelope, exit.
@MainActor
final class DeclaredWorldDeriverTests: XCTestCase {

    // MARK: - Fixture

    private enum FakeMode: String {
        /// Answer with a well-formed, bare (unfenced) JSON result.
        case bare
        /// Answer with the same shape, but fenced in ```json and wrapped in
        /// the model's own prose — the spike's "fenced-JSON tolerance still
        /// needed" finding.
        case fenced
        /// Answer with prose that contains no JSON at all.
        case garbage
        /// Answer with a result containing one well-formed entry and one
        /// entry missing a required field.
        case partiallyMalformed
        /// Exit non-zero without answering.
        case dies
        /// Answer with a well-formed envelope far larger than a pipe buffer —
        /// see `test_aLargeDerivationDoesNotDeadlock`.
        case large
    }

    /// How much padding the `.large` fixture carries. A macOS pipe holds 64 KB;
    /// a quarter of a megabyte is decisively past it, so a reader that waits
    /// for termination before reading has to block the writer.
    private let largePaddingBytes = 256 * 1024

    private var tempDir: URL!
    private var counterURL: URL { tempDir.appendingPathComponent("invocations") }
    private var argsURL: URL { tempDir.appendingPathComponent("args") }
    private var stdinURL: URL { tempDir.appendingPathComponent("stdin") }
    /// The `.large` fixture's envelope, written beside the script rather than
    /// carried inside it: a quarter-megabyte base64 literal in a bash source
    /// file is a script no one can read and a diff no one can review.
    private var payloadURL: URL { tempDir.appendingPathComponent("payload.json") }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeclaredWorldDeriverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    /// The "result" text — the model's own answer — for one fixture mode.
    /// Built as plain Swift text (an apostrophe in "a scene's dialogue" would
    /// otherwise fight bash quoting) and carried into the script as base64,
    /// which sidesteps shell-quoting entirely rather than hand-escaping it.
    private func resultText(for mode: FakeMode) -> String {
        switch mode {
        case .bare:
            return #"{"clauses":[{"quote":"Kelly never speaks first.","check":"Kelly never opens a scene with dialogue."}],"rules":[{"subject":"Kelly","quote":"Kelly never speaks first.","constraint":"Kelly must not initiate a scene's dialogue."}]}"#
        case .fenced:
            // A stray brace pair OUTSIDE the fence (a genuine model habit —
            // "quotes look like {this}") makes fence-stripping load-bearing:
            // without it, the widest-brace-span fallback would span from
            // this stray "{" all the way to the real JSON's final "}",
            // producing unparseable text, so a fence-tolerance regression
            // cannot hide behind that fallback saving the test by accident.
            return """
            Sure, here is the derivation (quotes look like {this}):
            ```json
            {"clauses":[{"quote":"Kelly never speaks first.","check":"Kelly never opens a scene with dialogue."}],"rules":[]}
            ```
            Hope that helps!
            """
        case .garbage:
            return "I could not find anything checkable here, sorry."
        case .partiallyMalformed:
            return #"{"clauses":[{"quote":"Good one.","check":"Checks fine."},{"quote":"Missing check."}],"rules":[]}"#
        case .dies:
            return ""
        case .large:
            // One real clause, and a `check` long enough that the envelope
            // cannot fit in a pipe. The padding is inside the JSON rather than
            // printed beside it, so the output is still exactly what the CLI
            // contracts to emit — the deadlock this pins is about VOLUME, not
            // about malformed output.
            let padding = String(repeating: "a very long reading. ",
                                 count: largePaddingBytes / 21)
            return #"{"clauses":[{"quote":"Kelly never speaks first.","check":"\#(padding)"}],"rules":[]}"#
        }
    }

    /// Write an executable bash script that impersonates `claude -p
    /// --output-format json`: read all of stdin, record the invocation and
    /// its argv, print one JSON envelope, exit.
    private func makeFakeCLI(mode: FakeMode) throws -> URL {
        let url = tempDir.appendingPathComponent("fake-claude")

        // Real JSON encoding — not hand-escaped bash literals — so the
        // envelope is correct regardless of what punctuation the fixture
        // text contains.
        let envelope = try JSONSerialization.data(withJSONObject: [
            "is_error": false, "type": "result", "result": resultText(for: mode)
        ])
        let envelopeBase64 = envelope.base64EncodedString()
        if mode == .large { try envelope.write(to: payloadURL, options: .atomic) }

        let script = """
        #!/bin/bash
        COUNTER="\(counterURL.path)"
        ARGS="\(argsURL.path)"
        STDIN="\(stdinURL.path)"
        MODE="\(mode.rawValue)"

        echo "spawn" >> "$COUNTER"
        printf '%s\\n' "$@" > "$ARGS"
        cat > "$STDIN"

        if [ "$MODE" = "dies" ]; then
          exit 3
        fi

        if [ "$MODE" = "large" ]; then
          cat "\(payloadURL.path)"
          exit 0
        fi

        echo '\(envelopeBase64)' | base64 -D
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeDeriver(
        cli: URL?,
        isEnabled: @escaping () -> Bool = { true }
    ) -> ClaudeWorldDeriver {
        ClaudeWorldDeriver(model: "haiku", cliOverride: cli, isEnabled: isEnabled)
    }

    private func lineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    // MARK: - Contracts

    /// Well-formed bare JSON produces a `DerivedWorld` whose `sourceHash` is
    /// `DerivedWorld.sourceHash(of:)` over the EXACT text handed to
    /// `derive` — the one place the gate value is computed (Task 2's
    /// decision, pinned at this call site: the deriver never cleans or
    /// truncates the statement before hashing it).
    func test_wellFormedOutputProducesADerivedWorld() async throws {
        let cli = try makeFakeCLI(mode: .bare)
        let deriver = makeDeriver(cli: cli)
        let statement = "Kelly never speaks first."

        let world = await deriver.derive(statementText: statement)

        let unwrapped = try XCTUnwrap(world)
        XCTAssertEqual(unwrapped.sourceHash, DerivedWorld.sourceHash(of: statement))
        XCTAssertEqual(unwrapped.clauses, [
            DerivedClause(
                quote: "Kelly never speaks first.",
                check: "Kelly never opens a scene with dialogue.")
        ])
        XCTAssertEqual(unwrapped.rules, [
            DerivedRule(
                subject: "Kelly", quote: "Kelly never speaks first.",
                constraint: "Kelly must not initiate a scene's dialogue.")
        ])
        XCTAssertLessThan(
            abs(unwrapped.derivedAt.timeIntervalSinceNow), 5,
            "derivedAt should be stamped around now")
    }

    /// The spike's finding, pinned: a fenced JSON block wrapped in the
    /// model's own prose parses the same as bare JSON.
    func test_fencedJSONAlsoParses() async throws {
        let cli = try makeFakeCLI(mode: .fenced)
        let deriver = makeDeriver(cli: cli)

        let world = await deriver.derive(statementText: "Kelly never speaks first.")

        let unwrapped = try XCTUnwrap(world)
        XCTAssertEqual(unwrapped.clauses.count, 1)
        XCTAssertEqual(unwrapped.clauses.first?.quote, "Kelly never speaks first.")
        XCTAssertTrue(unwrapped.rules.isEmpty)
    }

    /// Output with no JSON in it at all is an honest, non-fatal failure —
    /// never a throw, never a crash.
    func test_garbageProducesNilNeverThrows() async throws {
        let cli = try makeFakeCLI(mode: .garbage)
        let deriver = makeDeriver(cli: cli)

        let world = await deriver.derive(statementText: "Kelly never speaks first.")

        XCTAssertNil(world)
    }

    /// A single malformed entry costs only itself — the same "a bad note
    /// never fails the run" discipline `DiagnosticIngest` uses, applied to
    /// clauses.
    func test_oneMalformedEntryDoesNotFailTheWholeDerivation() async throws {
        let cli = try makeFakeCLI(mode: .partiallyMalformed)
        let deriver = makeDeriver(cli: cli)

        let world = await deriver.derive(statementText: "Kelly never speaks first.")

        let unwrapped = try XCTUnwrap(world)
        XCTAssertEqual(unwrapped.clauses, [
            DerivedClause(quote: "Good one.", check: "Checks fine.")
        ])
    }

    /// A process that dies without answering is the same honest `nil`.
    func test_aDyingProcessProducesNilNeverThrows() async throws {
        let cli = try makeFakeCLI(mode: .dies)
        let deriver = makeDeriver(cli: cli)

        let world = await deriver.derive(statementText: "Kelly never speaks first.")

        XCTAssertNil(world)
    }

    /// No `claude` on the machine is the same ordinary, reportable `nil`.
    func test_missingCLIFailsHonestly() async throws {
        let nowhere = tempDir.appendingPathComponent("no-such-claude")
        let deriver = makeDeriver(cli: nowhere)

        let world = await deriver.derive(statementText: "Kelly never speaks first.")

        XCTAssertNil(world)
        XCTAssertEqual(lineCount(counterURL), 0, "a missing CLI must never be spawned")
    }

    /// The toggle governs derivation exactly as it governs the compiler
    /// (ADR 0028's one toggle) — refused before any spawn.
    func test_theToggleGovernsDerivationToo() async throws {
        let cli = try makeFakeCLI(mode: .bare)
        let deriver = makeDeriver(cli: cli, isEnabled: { false })

        let world = await deriver.derive(statementText: "Kelly never speaks first.")

        XCTAssertNil(world)
        XCTAssertEqual(lineCount(counterURL), 0, "a disabled deriver must not spawn the CLI")
    }

    /// Absence mints nothing: an empty or whitespace-only statement is
    /// nothing to derive, and no tokens are spent deriving nothing.
    func test_anEmptyStatementSpawnsNothing() async throws {
        let cli = try makeFakeCLI(mode: .bare)
        let deriver = makeDeriver(cli: cli)

        let empty = await deriver.derive(statementText: "")
        XCTAssertNil(empty)
        let whitespace = await deriver.derive(statementText: "   \n\t  ")
        XCTAssertNil(whitespace)

        XCTAssertEqual(lineCount(counterURL), 0, "an empty statement must not spawn the CLI")
    }

    /// The membrane: `--tools ""` disables the built-in tools, and no
    /// `--mcp-config` is passed at all — strictly more confined than the
    /// compiler's warm session, which carries an enumerated MCP allowlist.
    /// Derivation needs no tools whatsoever.
    func test_derivationIsMoreConfinedThanTheCompiler() async throws {
        let cli = try makeFakeCLI(mode: .bare)
        let deriver = makeDeriver(cli: cli)

        _ = await deriver.derive(statementText: "Kelly never speaks first.")

        var argv = try String(contentsOf: argsURL, encoding: .utf8)
            .components(separatedBy: "\n")
        if argv.last?.isEmpty == true { argv.removeLast() }

        guard let toolsIndex = argv.firstIndex(of: "--tools") else {
            return XCTFail("--tools must be present in \(argv)")
        }
        XCTAssertTrue(toolsIndex + 1 < argv.count && argv[toolsIndex + 1].isEmpty,
            "--tools must be followed by an empty value, got \(argv)")
        XCTAssertFalse(argv.contains("--mcp-config"),
            "derivation must carry no MCP config at all — it spawns strictly "
            + "less capable than the compiler")
        XCTAssertTrue(argv.contains("-p"))
        XCTAssertEqual(
            argv[argv.firstIndex(of: "--output-format")! + 1], "json",
            "one-shot batch JSON, never stream-json")
        XCTAssertEqual(
            argv[argv.firstIndex(of: "--model")! + 1], "haiku")
    }

    // MARK: - The pipe

    /// **A derivation bigger than a pipe buffer still comes back.**
    ///
    /// The original shape read stdout from the process's `terminationHandler`,
    /// which is a deadlock with a pause button on it: a pipe holds about 64 KB,
    /// so a CLI whose answer is larger blocks on its own `write`, never exits,
    /// never fires the handler — and the continuation waiting on that handler
    /// is never resumed. Not a slow run: a run that never ends, in a `Task` the
    /// orchestrator is awaiting, with `runState` stuck on `.running` for the
    /// life of the window. Reading concurrently with the wait is what keeps the
    /// writer's end of the pipe moving.
    ///
    /// The wait is bounded rather than open, so a regression fails this suite in
    /// half a minute instead of hanging CI until the job's own timeout.
    func test_aLargeDerivationDoesNotDeadlock() async throws {
        let cli = try makeFakeCLI(mode: .large)
        let deriver = makeDeriver(cli: cli)
        let payload = try Data(contentsOf: payloadURL)
        XCTAssertGreaterThan(
            payload.count, 200_000,
            "the fixture must actually exceed a pipe buffer, or this test proves "
            + "nothing about the drain")

        let returned = expectation(description: "the derivation came back")
        let result = Box<DerivedWorld?>(nil)
        Task {
            result.value = await deriver.derive(statementText: "Kelly never speaks first.")
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 30)

        let world = try XCTUnwrap(
            result.value,
            "the CLI answered in full; a nil here means the output was truncated "
            + "rather than drained")
        XCTAssertEqual(world.clauses.count, 1)
        XCTAssertEqual(world.clauses.first?.quote, "Kelly never speaks first.")
        XCTAssertGreaterThan(
            world.clauses.first?.check.count ?? 0, 200_000,
            "…and the whole of it arrived, not the first pipe-full")
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// The prompt and the parser are pinned to the same wire shape — Task 3
    /// owns both sides (unlike the compiler's split between `CompilerPrompt`
    /// and `DiagnosticIngest`), so a reworded prompt cannot drift from what
    /// the parser actually reads.
    func test_derivationSchemaDescriptionNamesTheWireFields() {
        let description = ClaudeWorldDeriver.derivationSchemaDescription
        for field in ["clauses", "rules", "quote", "check", "subject", "constraint"] {
            XCTAssertTrue(description.contains(field), "missing field name: \(field)")
        }
    }

    /// The prompt sent to the CLI carries the writer's statement text and the
    /// schema description — read back off the fixture's captured stdin.
    func test_promptCarriesTheStatementAndTheSchema() async throws {
        let cli = try makeFakeCLI(mode: .bare)
        let deriver = makeDeriver(cli: cli)
        let statement = "Kelly never speaks first, not even to greet someone."

        _ = await deriver.derive(statementText: statement)

        let sentPrompt = try String(contentsOf: stdinURL, encoding: .utf8)
        XCTAssertTrue(sentPrompt.contains(statement))
        XCTAssertTrue(sentPrompt.contains("clauses"))
        XCTAssertTrue(sentPrompt.contains("verbatim"))
    }
}
