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
            "compile",
            "compile_cancel"
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
            "compile",
            "compile_cancel"
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
