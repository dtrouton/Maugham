// MaughamTests/OpLog/BurstSchedulerTests.swift
import XCTest
@testable import Maugham

@MainActor
final class BurstSchedulerTests: XCTestCase {
    func test_recordActivity_doesNotFireBeforeIdleThreshold() async throws {
        let exp = expectation(description: "should not fire")
        exp.isInverted = true
        let s = BurstScheduler(idle: .milliseconds(200), max: .seconds(10)) {
            exp.fulfill()
        }
        s.recordActivity()
        await fulfillment(of: [exp], timeout: 0.1)
    }

    func test_recordActivity_firesAfterIdleThreshold() async throws {
        let exp = expectation(description: "fires on idle")
        let s = BurstScheduler(idle: .milliseconds(100), max: .seconds(10)) {
            exp.fulfill()
        }
        s.recordActivity()
        await fulfillment(of: [exp], timeout: 1)
    }

    func test_continuousActivity_firesAtMaxDuration() async throws {
        let exp = expectation(description: "fires on max")
        let s = BurstScheduler(idle: .seconds(60), max: .milliseconds(300)) {
            exp.fulfill()
        }
        for _ in 0..<10 {
            s.recordActivity()
            try await Task.sleep(for: .milliseconds(50))
        }
        await fulfillment(of: [exp], timeout: 1)
    }

    func test_forceFlush_firesImmediately() async throws {
        let exp = expectation(description: "fires on force")
        let s = BurstScheduler(idle: .seconds(60), max: .seconds(60)) {
            exp.fulfill()
        }
        s.recordActivity()
        s.forceFlush()
        await fulfillment(of: [exp], timeout: 0.5)
    }
}
