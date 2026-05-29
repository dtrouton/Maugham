import XCTest
import MaughamCore
@testable import Maugham

final class BuildVariantTests: XCTestCase {
    func test_stableDisplayName() {
        XCTAssertEqual(BuildVariant.stable.displayName, "Maugham")
    }

    func test_devDisplayName() {
        XCTAssertEqual(BuildVariant.dev.displayName, "Maugham Dev")
    }

    func test_stableSupportFolderName() {
        XCTAssertEqual(BuildVariant.stable.supportFolderName, "Maugham")
    }

    func test_devSupportFolderName() {
        XCTAssertEqual(BuildVariant.dev.supportFolderName, "Maugham Dev")
    }

    func test_stableMcpServerKey() {
        XCTAssertEqual(BuildVariant.stable.mcpServerKey, "maugham")
    }

    func test_devMcpServerKey() {
        XCTAssertEqual(BuildVariant.dev.mcpServerKey, "maugham-dev")
    }

    func test_stableUpdaterEnabled() {
        XCTAssertTrue(BuildVariant.stable.updaterEnabled)
    }

    func test_devUpdaterDisabled() {
        XCTAssertFalse(BuildVariant.dev.updaterEnabled)
    }

    func test_stableSocketPathUsesStableFolder() {
        XCTAssertTrue(BuildVariant.stable.mcpSocketPath.hasSuffix("Application Support/Maugham/mcp.sock"))
    }

    func test_devSocketPathUsesDevFolder() {
        XCTAssertTrue(BuildVariant.dev.mcpSocketPath.hasSuffix("Application Support/Maugham Dev/mcp.sock"))
    }

    func test_currentIsDevInTestBuild() {
        XCTAssertEqual(BuildVariant.current, .dev)
    }
}
