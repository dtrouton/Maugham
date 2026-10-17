import XCTest
@testable import Maugham

final class MCPErrorTests: XCTestCase {
    /// #47: `localizedDescription` must be the error's own sentence, not
    /// Foundation's "The operation couldn't be completed…".
    func test_anMCPErrorsLocalizedDescriptionIsItsMessage() {
        XCTAssertEqual(MCPError.invalidArgument("x").localizedDescription,
                       MCPError.invalidArgument("x").message)
        XCTAssertEqual(MCPError.projectNotOpen.localizedDescription,
                       "That project isn't open in Maugham.")
    }
}
