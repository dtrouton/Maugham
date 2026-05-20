import XCTest
import CoreGraphics
@testable import Maugham

final class RewindDensityTests: XCTestCase {
    /// Build N typing-burst ticks evenly spaced over time.
    private func ticks(_ n: Int, kinds: [OpKind]? = nil) -> [RewindTickLayout.RawTick] {
        (0..<n).map { i in
            RewindTickLayout.RawTick(
                opId: "op\(i)",
                at: Date(timeIntervalSince1970: TimeInterval(i)),
                kind: kinds?[i] ?? .typingBurst)
        }
    }

    func test_decimateTicks_underWidth_returnsAll() {
        let raw = ticks(50)
        let laid = RewindTickLayout.decimate(ticks: raw, width: 1000)
        XCTAssertEqual(laid.count, 50)
    }

    func test_decimateTicks_overWidth_collapsesAdjacent() {
        // 1000 ticks in 600px — many will collapse (rule: at most one
        // tick per pixel, except checkpoints always drawn).
        let raw = ticks(1000)
        let laid = RewindTickLayout.decimate(ticks: raw, width: 600)
        XCTAssertLessThanOrEqual(laid.count, 600)
        // First and last should always be present.
        XCTAssertEqual(laid.first?.opId, "op0")
        XCTAssertEqual(laid.last?.opId, "op999")
    }

    func test_decimateTicks_checkpointsAlwaysVisible() {
        // 1000 ticks where every 100th is a checkpoint.
        var kinds: [OpKind] = []
        for i in 0..<1000 {
            kinds.append(i % 100 == 0 ? .checkpoint : .typingBurst)
        }
        let raw = ticks(1000, kinds: kinds)
        let laid = RewindTickLayout.decimate(ticks: raw, width: 200)
        // Width is 200px — typing-burst ticks collapse heavily,
        // but all 10 checkpoint ticks must still appear.
        let checkpointsInOutput = laid.filter { $0.kind == .checkpoint }
        XCTAssertEqual(checkpointsInOutput.count, 10,
                       "Checkpoint ticks must survive density collapse")
    }
}
