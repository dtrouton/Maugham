import XCTest
import MaughamCore
@testable import Maugham

final class TaskOpRoundTripTests: XCTestCase {

    private static let testDate: Date = {
        let f = ISO8601DateFormatter()
        return f.date(from: "2026-05-23T18:00:00Z")!
    }()

    func test_taskCreateOp_roundTrip() throws {
        let prov = Op.Provenance(
            taskId: "op_2026-05-23T18:00:00.000Z_abcd",
            taskBody: "revise act 2",
            taskPriority: 1.0,
            taskKind: "pane_created")
        let op = Op(
            opId: "op_2026-05-23T18:00:00.000Z_abcd",
            docId: "doc_test",
            at: Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: .taskCreate,
            changes: [],
            sequence: nil,
            provenance: prov)
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(Op.self, from: data)
        XCTAssertEqual(decoded.kind, .taskCreate)
        XCTAssertEqual(decoded.provenance?.taskId, "op_2026-05-23T18:00:00.000Z_abcd")
        XCTAssertEqual(decoded.provenance?.taskBody, "revise act 2")
        XCTAssertEqual(decoded.provenance?.taskPriority, 1.0)
        XCTAssertEqual(decoded.provenance?.taskKind, "pane_created")
    }

    func test_taskStatusChangeOp_roundTrip() throws {
        let prov = Op.Provenance(
            taskId: "op_2026-05-23T18:00:00.000Z_abcd",
            taskStatus: "done")
        let op = Op(
            opId: "op_2026-05-23T18:01:00.000Z_bcde",
            docId: "doc_test",
            at: Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: .taskStatusChange,
            changes: [],
            sequence: nil,
            provenance: prov)
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(Op.self, from: data)
        XCTAssertEqual(decoded.kind, .taskStatusChange)
        XCTAssertEqual(decoded.provenance?.taskId, "op_2026-05-23T18:00:00.000Z_abcd")
        XCTAssertEqual(decoded.provenance?.taskStatus, "done")
        XCTAssertNil(decoded.provenance?.taskBody)
    }

    func test_taskPriorityChangeOp_roundTrip() throws {
        let prov = Op.Provenance(
            taskId: "op_2026-05-23T18:00:00.000Z_abcd",
            taskPriority: 2.5)
        let op = Op(
            opId: "op_2026-05-23T18:02:00.000Z_cdef",
            docId: "doc_test",
            at: Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: .taskPriorityChange,
            changes: [],
            sequence: nil,
            provenance: prov)
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(Op.self, from: data)
        XCTAssertEqual(decoded.kind, .taskPriorityChange)
        XCTAssertEqual(decoded.provenance?.taskId, "op_2026-05-23T18:00:00.000Z_abcd")
        XCTAssertEqual(decoded.provenance?.taskPriority, 2.5)
    }

    func test_taskParentChangeOp_roundTrip() throws {
        let prov = Op.Provenance(
            taskId: "op_2026-05-23T18:00:00.000Z_abcd",
            taskParentId: "op_2026-05-23T17:00:00.000Z_efgh")
        let op = Op(
            opId: "op_2026-05-23T18:03:00.000Z_defg",
            docId: "doc_test",
            at: Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: .taskParentChange,
            changes: [],
            sequence: nil,
            provenance: prov)
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(Op.self, from: data)
        XCTAssertEqual(decoded.kind, .taskParentChange)
        XCTAssertEqual(decoded.provenance?.taskId, "op_2026-05-23T18:00:00.000Z_abcd")
        XCTAssertEqual(decoded.provenance?.taskParentId, "op_2026-05-23T17:00:00.000Z_efgh")
    }

    func test_taskBodyEditOp_roundTrip() throws {
        let prov = Op.Provenance(
            taskId: "op_2026-05-23T18:00:00.000Z_abcd",
            taskBody: "new text for the task")
        let op = Op(
            opId: "op_2026-05-23T18:04:00.000Z_efgh",
            docId: "doc_test",
            at: Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: .taskBodyEdit,
            changes: [],
            sequence: nil,
            provenance: prov)
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(Op.self, from: data)
        XCTAssertEqual(decoded.kind, .taskBodyEdit)
        XCTAssertEqual(decoded.provenance?.taskId, "op_2026-05-23T18:00:00.000Z_abcd")
        XCTAssertEqual(decoded.provenance?.taskBody, "new text for the task")
    }

    func test_taskArchiveOp_roundTrip() throws {
        let prov = Op.Provenance(
            taskId: "op_2026-05-23T18:00:00.000Z_abcd")
        let op = Op(
            opId: "op_2026-05-23T18:05:00.000Z_fghi",
            docId: "doc_test",
            at: Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: .taskArchive,
            changes: [],
            sequence: nil,
            provenance: prov)
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(Op.self, from: data)
        XCTAssertEqual(decoded.kind, .taskArchive)
        XCTAssertEqual(decoded.provenance?.taskId, "op_2026-05-23T18:00:00.000Z_abcd")
        XCTAssertNil(decoded.provenance?.taskBody)
        XCTAssertNil(decoded.provenance?.taskStatus)
    }

    func test_provenanceTaskFields_absentFromNonTaskOp() throws {
        // A regular typing burst op should have nil task fields after round-trip.
        let op = Op(
            opId: "op_2026-05-23T18:06:00.000Z_ghij",
            docId: "doc_test",
            at: Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: .typingBurst,
            changes: [],
            sequence: nil,
            provenance: Op.Provenance(sessionId: "test-session"))
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(Op.self, from: data)
        XCTAssertNil(decoded.provenance?.taskId)
        XCTAssertNil(decoded.provenance?.taskBody)
        XCTAssertNil(decoded.provenance?.taskStatus)
        XCTAssertNil(decoded.provenance?.taskPriority)
        XCTAssertNil(decoded.provenance?.taskParentId)
        XCTAssertNil(decoded.provenance?.taskKind)
    }

    func test_snakeCaseCodingKeys_inJSON() throws {
        // Verify the snake_case encoding is correct on disk.
        let prov = Op.Provenance(
            taskId: "task-id-value",
            taskBody: "body-value",
            taskStatus: "open",
            taskPriority: 3.0,
            taskParentId: "parent-id",
            taskKind: "pane_created")
        let op = Op(
            opId: "op_test",
            docId: "doc_test",
            at: Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: .taskCreate,
            changes: [],
            sequence: nil,
            provenance: prov)
        let data = try JSONEncoder().encode(op)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"task_id\""))
        XCTAssertTrue(json.contains("\"task_body\""))
        XCTAssertTrue(json.contains("\"task_status\""))
        XCTAssertTrue(json.contains("\"task_priority\""))
        XCTAssertTrue(json.contains("\"task_parent_id\""))
        XCTAssertTrue(json.contains("\"task_kind\""))
    }
}
