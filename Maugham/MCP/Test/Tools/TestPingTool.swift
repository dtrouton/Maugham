import Foundation
import MaughamCore

/// `test_ping` — cheap readiness probe. Claude Code polls this after
/// relaunching the app to absorb the cold-launch window before asserting.
public enum TestPingTool: MCPTool {
    public struct Result: Codable, Equatable {
        public let ok: Bool
        public let variant: String
        public let version: String
        public let build: String
    }
    public static let method = "test_ping"
    public static let description =
        "Dev-only readiness probe. Returns ok:true plus build variant/version so an automated driver can confirm the intended binary is up before asserting."
    public static let inputSchemaJSON = #"{"type":"object","properties":{}}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let info = Bundle.main.infoDictionary
        let result = Result(
            ok: true,
            variant: BuildVariant.current == .dev ? "dev" : "stable",
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?")
        return try JSONEncoder().encode(result)
    }
}
