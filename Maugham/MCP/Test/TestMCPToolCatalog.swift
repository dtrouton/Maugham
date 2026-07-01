import Foundation

/// Dev-only privileged MCP tools for Claude Code (NOT Claude Desktop). Kept
/// separate from `MCPToolCatalog` so the production catalog, tools/list, and
/// its consistency tests are untouched. Registered only under
/// `#if MAUGHAM_DEV_BUILD` (see MaughamApp.registerTools), so it is absent
/// from the stable binary. Every method is `test_`-prefixed.
public enum TestMCPToolCatalog {
    public static let all: [any MCPTool.Type] = [
        TestPingTool.self
    ]

    @MainActor
    public static func register(router: MCPRouter, registry: ProjectRegistry) {
        for tool in all {
            router.register(method: tool.method) { params in
                try await tool.handle(paramsJSON: params, registry: registry)
            }
        }
    }
}
