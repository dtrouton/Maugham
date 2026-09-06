import XCTest
@testable import Maugham

/// `StatementPane.userFacingMessage` is what Adopt/Discard show the writer on
/// failure — see the fix note on the function itself. Windowless: it is a
/// pure function of an error, with no view to mount.
///
/// The case this pins: `(error as? CustomStringConvertible)` off the `any
/// Error` a `catch` hands you triggers a compiler warning claiming the cast
/// "always succeeds" (fired at both call sites this function replaced) — but
/// that claim is WRONG at runtime for a plain Swift error type that does not
/// actually conform (`PlainLocalizedError`/`BareError` below); the naive fix
/// of an unconditional `as` cast to silence the warning is a real regression
/// (verified with a standalone `swift` script: it does not trap, it bridges
/// through `__SwiftNativeNSError` and shows a case dump instead of falling
/// back to `localizedDescription`). `userFacingMessage` casts through `Any`
/// first, which keeps the real dynamic-cast behavior and drops only the
/// (incorrect) warning.
final class StatementPaneUserFacingMessageTests: XCTestCase {

    /// A `CustomStringConvertible` error — its own `description` wins.
    private struct DescribedError: Error, CustomStringConvertible {
        var description: String { "a described failure" }
    }

    /// A plain `LocalizedError` with NO `CustomStringConvertible` conformance
    /// of its own — this is the case the old `as?` off `any Error` silently
    /// mishandled (it never actually returned nil, so this fell straight
    /// through to a case dump rather than `errorDescription`).
    private enum PlainLocalizedError: Error, LocalizedError {
        case diskFull
        var errorDescription: String? { "The project could not be saved: disk full" }
    }

    /// A bare `Error` with no `CustomStringConvertible` and no
    /// `LocalizedError` — `localizedDescription`'s own generic fallback text.
    private enum BareError: Error {
        case somethingWentWrong
    }

    func test_customStringConvertibleError_showsItsOwnDescription() {
        XCTAssertEqual(StatementPane.userFacingMessage(DescribedError()), "a described failure")
    }

    func test_plainLocalizedError_showsErrorDescription_notACaseDump() {
        let message = StatementPane.userFacingMessage(PlainLocalizedError.diskFull)
        XCTAssertEqual(message, "The project could not be saved: disk full")
        XCTAssertFalse(message.contains("PlainLocalizedError"),
                        "must never show the raw case name — that's the regression this guards")
    }

    /// `NSError` genuinely, natively conforms to `CustomStringConvertible`
    /// (bridged from `NSObject`'s `description`) — verified with a standalone
    /// `swift` script against both the direct `any Error` cast and this
    /// `Any`-mediated one before writing this test, since it is easy to
    /// *assume* "localized description" here and be wrong. Both the ORIGINAL
    /// pre-branch code and this fix take the `.description` branch for a real
    /// `NSError`, and `NSError.description` is its verbose domain/code/
    /// userInfo dump, NOT `localizedDescription` — that mismatch predates
    /// this branch and is not something this fix changes or is meant to fix.
    func test_nsError_takesItsOwnGenuineCustomStringConvertibleConformance() {
        let nsError = NSError(domain: "MaughamTest", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "a wrapped NSError failure"])
        XCTAssertEqual(StatementPane.userFacingMessage(nsError), nsError.description,
                        "a real NSError conforms to CustomStringConvertible on its own — " +
                        "this must match the protocol's own branch, not localizedDescription")
        XCTAssertNotEqual(nsError.description, nsError.localizedDescription,
                           "documents the pre-existing quirk this test relies on: they differ")
    }

    func test_bareErrorWithNeitherConformance_fallsBackToLocalizedDescription() {
        let message = StatementPane.userFacingMessage(BareError.somethingWentWrong)
        XCTAssertEqual(message, BareError.somethingWentWrong.localizedDescription)
    }
}
