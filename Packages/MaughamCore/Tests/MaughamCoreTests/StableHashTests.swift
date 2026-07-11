import XCTest
@testable import MaughamCore

/// Tests for `StableHash` — the cross-launch-stable FNV-1a hash helper.
///
/// The key invariant: the pinned expected values below are FIXED constants
/// computed from the FNV-1a spec. If `String.hashValue` were used instead,
/// these tests would fail on every run because `hashValue` is process-
/// seed-randomised (Swift SE-0206). The fact that these tests can even be
/// written with hard-coded expected values is the proof of stability.
final class StableHashTests: XCTestCase {

    // MARK: - 64-bit FNV-1a pinned values

    /// Known-answer test: pin the 64-bit output for a set of representative
    /// strings so any future regression (wrong constants, wrong algorithm)
    /// immediately fails here rather than silently orphaning op logs.
    func test_fnv1a64Hex_pinnedKnownAnswers() {
        // Values computed once via the FNV-1a spec and hardcoded here.
        // "hello" → FNV-1a 64-bit = 0xa430d84680aabd0b
        XCTAssertEqual(StableHash.fnv1a64Hex("hello"), "a430d84680aabd0b")
        // Filename-like strings representative of what resolveDocId uses:
        XCTAssertEqual(StableHash.fnv1a64Hex("chapter-one.md"), "b5de4cc4ff0c9322")
        XCTAssertEqual(StableHash.fnv1a64Hex("manuscript/chapter-one.md"), "f5a57e05371c70d1")
    }

    /// Empty string must produce the FNV-1a 64-bit offset basis (no bytes XORed).
    func test_fnv1a64Hex_emptyString_isOffsetBasis() {
        // FNV-1a 64-bit offset basis = 0xcbf29ce484222325 (no iterations run)
        XCTAssertEqual(StableHash.fnv1a64Hex(""), "cbf29ce484222325")
    }

    /// Two different strings must not collide (sanity; not a proof of general
    /// collision resistance, just guards against trivially broken implementations).
    func test_fnv1a64Hex_distinctInputs_giveDistinctOutputs() {
        let a = StableHash.fnv1a64Hex("chapter-one.md")
        let b = StableHash.fnv1a64Hex("chapter-two.md")
        XCTAssertNotEqual(a, b)
    }

    /// The output is exactly 16 lowercase hex characters (64 bits = 16 nibbles).
    func test_fnv1a64Hex_outputLength_is16() {
        XCTAssertEqual(StableHash.fnv1a64Hex("anything").count, 16)
        XCTAssertEqual(StableHash.fnv1a64Hex("").count, 16)
    }

    // MARK: - 32-bit FNV-1a (package-internal, used by DeviceSlug)

    /// Pin the 32-bit value for "hello" to lock down DeviceSlug's delegate path.
    /// Also verifies that DeviceSlug still produces the same output it did before
    /// its private implementation was removed (the constant is the same).
    func test_fnv1a32Hex_pinnedKnownAnswer() {
        // "hello" → FNV-1a 32-bit = 0x4f9f2cab
        XCTAssertEqual(StableHash.fnv1a32Hex("hello"), "4f9f2cab")
    }

    // MARK: - DeviceSlug delegation smoke test

    /// DeviceSlug must produce the same output before and after delegating its
    /// private FNV-1a impl to StableHash. Pin one known output to catch any
    /// regression in the delegation path.
    func test_deviceSlug_delegatesToStableHash_stableOutput() {
        // The suffix is StableHash.fnv1a32Hex("Denvers-Mac.local") = "4ae99f35"
        let slug = DeviceSlug.make(from: "Denvers-Mac.local")
        XCTAssertTrue(slug.raw.hasSuffix("-4ae99f35"),
            "DeviceSlug.make must produce a stable suffix via StableHash.fnv1a32Hex; got: \(slug.raw)")
    }
}
