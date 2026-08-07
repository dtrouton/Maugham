import Foundation

/// Turns a statement's freeform prose into checkable clauses and rules.
/// `nil` is an honest, non-fatal failure — a missing CLI, a disabled toggle,
/// or output that could not be read, all reported the same way a background
/// convenience should report them: quietly.
protocol WorldDeriver: AnyObject {
    @MainActor func derive(statementText: String) async -> DerivedWorld?
}

/// The one-shot `claude -p` behind `WorldDeriver`.
///
/// **Strictly more confined than `ClaudeCLISession`.** That is a warm
/// `stream-json` session carrying an enumerated MCP allowlist (spec §3.4);
/// this is one `-p --output-format json` process per derivation, with no
/// `--mcp-config` at all and `--tools ""` — derivation reads prose and
/// writes JSON, and needs no tool, warm or cold, to do either.
/// `test_derivationIsMoreConfinedThanTheCompiler` pins both halves of that
/// membrane.
///
/// **The prompt and the parser are pinned to one wire shape here.** Unlike
/// the compiler's M2 split (`CompilerPrompt.outputSchemaDescription` sent by
/// one type, read by `DiagnosticIngest`), `derivationSchemaDescription` is
/// sent AND read by this same type — a rewording that drops a field name
/// breaks `test_derivationSchemaDescriptionNamesTheWireFields` before it can
/// silently desync prompt from parser.
///
/// **`sourceHash` is stamped here, not by the caller.** `DerivedWorld`'s
/// field is non-optional, so something has to compute it before a value can
/// exist at all — and the only thing that knows the EXACT string handed to
/// the CLI (this method never cleans or truncates it) is this method itself.
/// `DerivedWorld.sourceHash(of:)` is called exactly once, over
/// `statementText` as given. A caller storing the result (Task 4) reads
/// `world.sourceHash` rather than recomputing it — recomputing would risk a
/// second spelling of "the text this reading was made from" that could
/// disagree with the first.
@MainActor
final class ClaudeWorldDeriver: WorldDeriver {

    private let model: String
    private let cliOverride: URL?
    private let isEnabled: () -> Bool

    /// Resolved once and reused — see `ClaudeCLISession.resolvedCLI`, the
    /// same reasoning: locating the CLI can cost a login shell, and only a
    /// SUCCESS is worth remembering.
    private var resolvedCLI: URL?

    init(model: String, cliOverride: URL?, isEnabled: @escaping () -> Bool) {
        self.model = model
        self.cliOverride = cliOverride
        self.isEnabled = isEnabled
    }

    /// The wire shape sent to the CLI and read back from it. Verbatim
    /// quoting and "do not invent standards" are the spike's measured
    /// findings (`docs/superpowers/notes/2026-08-07-second-draft-spike.md`);
    /// `what_pulls` has no analogue here — this schema has no strains to
    /// qualify, unlike the compiler's conformance section.
    static let derivationSchemaDescription: String = """
        Output ONLY a JSON object and nothing else — no prose before or \
        after it:
        {"clauses":[{"quote":<string>,"check":<string>}],"rules":[{\
        "subject":<string>,"quote":<string>,"constraint":<string>}]}
        Each quote is the writer's own words, copied verbatim from the \
        statement below — never paraphrased. A clause is a checkable thing \
        the prose should do; a rule is a constraint on a named subject \
        (a character, a place, an object). Derive only what is genuinely \
        checkable against prose. Do not invent standards the writer did \
        not state.
        """

    func derive(statementText: String) async -> DerivedWorld? {
        // Absence mints nothing: no spawn, no tokens spent deriving nothing.
        let trimmed = statementText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // The toggle is enforced here, not at the UI — before any spawn,
        // every time, mirroring ClaudeCLISession.send's discipline.
        guard isEnabled() else { return nil }

        guard let cli = await resolveCLI() else { return nil }

        guard let envelope = await Self.runOneShot(
            cli: cli, arguments: Self.arguments(model: model),
            input: Self.prompt(statementText: statementText))
        else { return nil }

        guard let resultText = Self.extractResultText(fromEnvelope: envelope),
              let parsed = Self.parse(resultText: resultText)
        else { return nil }

        return DerivedWorld(
            sourceHash: DerivedWorld.sourceHash(of: statementText),
            clauses: parsed.clauses,
            rules: parsed.rules,
            derivedAt: Date())
    }

    // MARK: - Locating the CLI

    private func resolveCLI() async -> URL? {
        if let resolvedCLI { return resolvedCLI }
        if let cliOverride {
            guard FileManager.default.isExecutableFile(atPath: cliOverride.path) else {
                return nil
            }
            resolvedCLI = cliOverride
            return cliOverride
        }
        let found = await Task.detached(priority: .userInitiated) {
            ClaudeCLISession.locateCLI()
        }.value
        if let found { resolvedCLI = found }
        return found
    }

    // MARK: - Spawn

    /// `-p --output-format json`: one batch JSON envelope, never
    /// `stream-json`. No `--mcp-config` at all — the flag that grants MCP
    /// tools is simply absent, not merely empty — and `--tools ""` empties
    /// the built-in set (Read/Glob/Grep would otherwise reach any file in
    /// the working directory even under an enumerated allowlist; see
    /// `ClaudeCLISession.arguments`'s doc for the flag's own history).
    static func arguments(model: String) -> [String] {
        ["-p", "--output-format", "json", "--model", model, "--tools", ""]
    }

    /// The prompt handed to the CLI on stdin: the schema, then the writer's
    /// statement verbatim. A pure function of its input, like
    /// `CompilerPrompt`, so it is testable without a subprocess.
    static func prompt(statementText: String) -> String {
        """
        You are the derivation layer of a writing tool. Read the writer's \
        freeform intent statement below and derive its checkable structure.

        \(derivationSchemaDescription)

        Writer's intent statement:
        ---
        \(statementText)
        ---
        """
    }

    /// Run one subprocess to completion off the main actor and return its
    /// raw stdout, or `nil` if it could not be spawned. Deliberately a free
    /// function rather than a method: the termination-handler closure must
    /// not capture `self` (a MainActor instance) from a non-isolated
    /// callback, the same discipline `TectonicInvoker.compile` uses for its
    /// own one-shot subprocess.
    private static func runOneShot(
        cli: URL, arguments: [String], input: String
    ) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { _ in
                let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                _ = try? stderr.fileHandleForReading.readToEnd()
                cont.resume(returning: String(data: outData ?? Data(), encoding: .utf8))
            }

            do {
                try process.run()
            } catch {
                cont.resume(returning: nil)
                return
            }
            // Written after `run()`: the pipe's write end must exist before
            // anything is written to it, and closing signals EOF so a CLI
            // reading stdin to completion (text input format) does not hang
            // waiting for more.
            if let data = input.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            try? stdin.fileHandleForWriting.close()
        }
    }

    // MARK: - Reading the result

    /// `--output-format json` wraps the model's answer in one envelope
    /// object; `result` is the field that carries it.
    private static func extractResultText(fromEnvelope text: String) -> String? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any],
              let result = object["result"] as? String,
              !result.isEmpty
        else { return nil }
        return result
    }

    /// Parse the model's answer into clauses and rules. Never throws: output
    /// that cannot be read at all returns `nil` (an honest, non-fatal
    /// failure); one malformed entry inside otherwise-good JSON costs only
    /// itself, the same "a bad note never fails the run" discipline
    /// `DiagnosticIngest.parse` uses.
    static func parse(resultText: String) -> (clauses: [DerivedClause], rules: [DerivedRule])? {
        guard let object = jsonObject(in: resultText) else { return nil }

        let clauses = (object["clauses"] as? [Any] ?? []).compactMap { entry -> DerivedClause? in
            guard let item = entry as? [String: Any],
                  let quote = nonEmptyString(item["quote"]),
                  let check = nonEmptyString(item["check"])
            else { return nil }
            return DerivedClause(quote: quote, check: check)
        }

        let rules = (object["rules"] as? [Any] ?? []).compactMap { entry -> DerivedRule? in
            guard let item = entry as? [String: Any],
                  let subject = nonEmptyString(item["subject"]),
                  let quote = nonEmptyString(item["quote"]),
                  let constraint = nonEmptyString(item["constraint"])
            else { return nil }
            return DerivedRule(subject: subject, quote: quote, constraint: constraint)
        }

        return (clauses, rules)
    }

    // MARK: - JSON extraction (DiagnosticIngest's approach, this schema's keys)

    /// The first candidate that parses as an object carrying `clauses` or
    /// `rules` wins: fenced blocks first, then the whole text, then the
    /// widest brace-to-brace span — `DiagnosticIngest.jsonObject`'s
    /// approach, reproduced here rather than shared, because the two types
    /// disagree on which keys make a dictionary "ours".
    private static func jsonObject(in text: String) -> [String: Any]? {
        var candidates = fencedBlocks(in: text)
        candidates.append(text)
        if let span = widestBraceSpan(in: text) { candidates.append(span) }

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary["clauses"] != nil || dictionary["rules"] != nil
            else { continue }
            return dictionary
        }
        return nil
    }

    private static func fencedBlocks(in text: String) -> [String] {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return [] }
        return stride(from: 1, to: parts.count, by: 2).map { index -> String in
            let block = parts[index]
            guard let newline = block.firstIndex(of: "\n") else { return block }
            let firstLine = block[block.startIndex..<newline]
            let isLanguageTag = !firstLine.contains("{")
                && firstLine.trimmingCharacters(in: .whitespaces).count <= 12
            return isLanguageTag ? String(block[block.index(after: newline)...]) : block
        }
    }

    private static func widestBraceSpan(in text: String) -> String? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open < close
        else { return nil }
        return String(text[open...close])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
