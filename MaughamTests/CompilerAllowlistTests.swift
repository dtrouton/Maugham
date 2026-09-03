import XCTest
@testable import Maugham

final class CompilerAllowlistTests: XCTestCase {

    // MARK: - Contract Tests

    func test_everyEntryNamesACatalogTool() {
        let catalogNames = Set(MCPToolCatalog.all.map { $0.method })

        for entry in CompilerAllowlist.tools {
            // Strip the "mcp__maugham__" prefix
            let prefix = "mcp__maugham__"
            XCTAssertTrue(
                entry.hasPrefix(prefix),
                "Entry '\(entry)' must have prefix '\(prefix)'"
            )

            let toolName = String(entry.dropFirst(prefix.count))
            XCTAssertTrue(
                catalogNames.contains(toolName),
                "Tool name '\(toolName)' (from '\(entry)') not found in MCPToolCatalog.all"
            )
        }
    }

    func test_noWriteToolIsAllowed() {
        let writeTools = Set([
            "add_note",
            "add_comment",
            "add_suggested_change",
            "add_query",
            "add_craft_note",
            "add_canvas_scraps",
            "promote_inbox_entry",
            "move_research_item",
            "link_research",
            "unlink_research",
            "write_translation",
            "write_publish_file",
            "delete_publish_file",
            "set_publish_config",
            "set_piece_style",
            "clear_piece_style",
            "initialize_publish_template",
            "republish",
            "preview_compile",
            "compile",
            "compile_cancel",
            "propose_edition_brief",
            "propose_visual_language"
        ])

        let prefix = "mcp__maugham__"
        let allowedToolNames = Set(
            CompilerAllowlist.tools.map { entry in
                String(entry.dropFirst(prefix.count))
            }
        )

        let intersection = allowedToolNames.intersection(writeTools)
        XCTAssertTrue(
            intersection.isEmpty,
            "Compiler allowlist must not contain write tools. Found: \(intersection.sorted().joined(separator: ", "))"
        )
    }

    func test_theCensusWouldCatchAWrite() {
        // Planted-offender test: a test-local list containing add_note must fail the write predicate.
        let writeTools = Set([
            "add_note",
            "add_comment",
            "add_suggested_change",
            "add_query",
            "add_craft_note",
            "add_canvas_scraps",
            "promote_inbox_entry",
            "move_research_item",
            "link_research",
            "unlink_research",
            "write_translation",
            "write_publish_file",
            "delete_publish_file",
            "set_publish_config",
            "set_piece_style",
            "clear_piece_style",
            "initialize_publish_template",
            "republish",
            "preview_compile",
            "compile",
            "compile_cancel",
            "propose_edition_brief",
            "propose_visual_language"
        ])

        let testList = ["mcp__maugham__add_note"]
        let prefix = "mcp__maugham__"
        let testToolNames = Set(
            testList.map { entry in
                String(entry.dropFirst(prefix.count))
            }
        )

        let intersection = testToolNames.intersection(writeTools)
        XCTAssertFalse(
            intersection.isEmpty,
            "Control test: the planted offender (add_note) should be caught by the write-tools predicate"
        )
    }

    func test_theCompilerCanReachItsDeclaredContext() {
        let prefix = "mcp__maugham__"
        let allowedToolNames = Set(
            CompilerAllowlist.tools.map { entry in
                String(entry.dropFirst(prefix.count))
            }
        )

        let minimumRequired = Set([
            "read_document",
            "read_craft_intent",
            "read_visual_language",
            "read_edition_brief",
            "list_palette_cards",
            "read_palette_card",
            "list_research",
            "list_canvas",
            "search_text",
            "get_outline",
            "get_metadata"
        ])

        for tool in minimumRequired {
            XCTAssertTrue(
                allowedToolNames.contains(tool),
                "Compiler allowlist must contain required tool: '\(tool)'"
            )
        }
    }

    // MARK: - The answer is the WRITER's (M2 Task 10)

    /// **Only the writer's own hand puts words into a statement.**
    ///
    /// Task 10 gives an answered diagnostic a route into the piece's intent —
    /// through `RulingPerformer.rule`, driven by a writer typing into a field.
    /// The compiler's Claude reads that intent every run (`read_craft_intent`,
    /// `read_visual_language`) and must never be able to write it: a model that
    /// could edit the standard it is judged against can quietly move the
    /// standard until nothing it wrote is ever flagged again. That is the
    /// planning plane's line (`Maugham/MCP/AREA.md` tripwire 4) arriving on the
    /// surface M2 built.
    ///
    /// **Asserted twice over, because the allowlist is the weaker half.** The
    /// allowlist restricts the compiler's own spawned session; the CATALOG is
    /// what any MCP client — Claude Desktop, Claude Code, a peer — can reach.
    /// A statement-writing tool that exists but is merely absent from this
    /// allowlist would be a write path for every OTHER client, so the catalog
    /// is checked too.
    func test_noStatementWritingToolExistsAnywhereClaudeCanReach() {
        let offenders = Self.statementWriters(in: CompilerAllowlist.tools.map {
            String($0.dropFirst("mcp__maugham__".count))
        })
        XCTAssertTrue(
            offenders.isEmpty,
            "the compiler must not be able to write the intent it is judged against. "
            + "Found in the allowlist: \(offenders.sorted().joined(separator: ", "))")

        // `{ $0.method }` rather than `\.method`: `MCPToolCatalog.all` is an
        // array of existentials, and a key path over one crashes SILGen on
        // this toolchain (Xcode 26.6). The rest of this file already spells it
        // this way.
        let inCatalog = Self.statementWriters(in: MCPToolCatalog.all.map { $0.method })
        XCTAssertTrue(
            inCatalog.isEmpty,
            "no statement-writing tool may exist in the catalog at all \u{2014} an "
            + "allowlist omission would still leave the write reachable by every "
            + "other MCP client. Found: \(inCatalog.sorted().joined(separator: ", "))")
    }

    /// The control. Without it the census above passes for a predicate that
    /// matches nothing at all, and a real statement writer would ship green.
    ///
    /// **Widened in P5**: `edition_brief` and `visual_language` are subjects
    /// too (a hypothetical `write_edition_brief` was NOT caught before), and a
    /// `propose_` prefix on any statement subject other than the two
    /// proposable ones is caught — `propose_craft_intent` is a write wearing
    /// a proposal's name, while `propose_edition_brief` ships and stages only.
    func test_theStatementCensusWouldCatchAWriteToIntent() {
        let planted = ["read_craft_intent", "write_craft_intent", "list_projects",
                       "write_edition_brief", "set_visual_language",
                       "propose_craft_intent", "propose_edition_brief", "propose_visual_language",
                       "propose_statement"]
        XCTAssertEqual(
            Self.statementWriters(in: planted),
            ["write_craft_intent", "write_edition_brief", "set_visual_language",
             "propose_craft_intent", "propose_statement"],
            "the predicate must catch a hypothetical statement writer \u{2014} and must "
            + "NOT catch the READERS beside it, nor the two proposal tools, which stage "
            + "a draft the writer adopts")
    }

    /// A tool name that would put words into a statement.
    ///
    /// Names rather than a list of known-bad spellings: the risk is a tool that
    /// does not exist yet. The subjects are the statement kinds
    /// (`Statement.Kind`) plus `statement` itself; the verbs are the write
    /// verbs. A `propose_` tool is a write unless its subject is one of the
    /// two `ProposableStatement` cases — the proposal is staged, never written.
    static func statementWriters(in names: [String]) -> Set<String> {
        let subjects = ["craft_intent", "visual_language", "edition_brief", "statement", "intent"]
        let verbs = ["write_", "add_", "set_", "append_", "update_", "edit_", "delete_"]
        let proposable = ["propose_edition_brief", "propose_visual_language"]
        var found: Set<String> = []
        for name in names {
            let namesAStatement = subjects.contains { name.contains($0) }
            let isAWrite = verbs.contains { name.hasPrefix($0) }
            let isAForeignProposal = name.hasPrefix("propose_") && !proposable.contains(name)
            if namesAStatement && (isAWrite || isAForeignProposal) { found.insert(name) }
        }
        return found
    }

    // MARK: - Argument Format Test

    func test_cliArgumentsReturnsCorrectFormat() {
        let args = CompilerAllowlist.cliArguments()

        XCTAssertEqual(args.count, 2, "cliArguments() should return exactly 2 elements")
        XCTAssertEqual(args[0], "--allowedTools", "First element should be '--allowedTools'")
        XCTAssertFalse(args[1].isEmpty, "Second element (joined tools) should not be empty")

        // Verify the joined argument contains expected separators and formats
        let joinedArg = args[1]
        XCTAssertTrue(
            joinedArg.contains(","),
            "Joined argument should use comma-separated format"
        )
    }
}
