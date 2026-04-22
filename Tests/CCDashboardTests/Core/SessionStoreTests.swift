import Foundation
import XCTest
@testable import CCDashboard

final class SessionStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Telemetry.isEnabled = false
    }

    // MARK: - upsertSession 新建

    func testUpsertSessionNewCreatesRunningWithoutAutoAllow() async throws {
        let store = SessionStore()
        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()  // snapshot

        await store.upsertSession(id: "s1", cwd: "/tmp", transcriptPath: nil)

        let event = await iter.next()
        guard case .sessionUpsert(let state) = event else {
            return XCTFail("expected .sessionUpsert, got \(String(describing: event))")
        }
        XCTAssertEqual(state.id, "s1")
        XCTAssertEqual(state.cwd, "/tmp")
        XCTAssertEqual(state.status, .running)
        XCTAssertNil(state.autoAllowUntil)
    }

    // MARK: - upsertSession 同 id:保留 startedAt

    func testUpsertSessionExistingPreservesStartedAt() async throws {
        let store = SessionStore()
        await store.upsertSession(id: "s1", cwd: "/first", transcriptPath: nil)
        let firstList = await store.allSessions()
        let first = try XCTUnwrap(firstList.first)

        try await Task.sleep(nanoseconds: 10_000_000)
        await store.upsertSession(id: "s1", cwd: "/second", transcriptPath: "/tmp/t.jsonl")

        let secondList = await store.allSessions()
        let second = try XCTUnwrap(secondList.first)
        XCTAssertEqual(second.startedAt, first.startedAt)
        XCTAssertEqual(second.cwd, "/second")
        XCTAssertEqual(second.transcriptPath, "/tmp/t.jsonl")
        XCTAssertGreaterThan(second.lastActivityAt, first.lastActivityAt)
    }

    // MARK: - touchSession 未知 id:创建占位

    func testTouchSessionCreatesPlaceholderForUnknownID() async {
        let store = SessionStore()
        await store.touchSession(id: "ghost", cwd: "/tmp")
        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "ghost")
        XCTAssertEqual(sessions.first?.cwd, "/tmp")
    }

    // MARK: - requestApproval miss → 入 pending → resolveApproval 唤醒

    func testRequestApprovalMissEnqueuesAndResolves() async throws {
        let store = SessionStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)

        let request = ApprovalRequest(
            id: "req-1", sessionId: "s1", toolName: "Bash",
            toolInput: ["command": AnyCodable("ls")],
            cwd: "/", createdAt: Date()
        )

        async let decision = store.requestApproval(request)

        let maybeID = await pollForApproval(store: store)
        XCTAssertEqual(maybeID, "req-1")

        await store.resolveApproval(id: "req-1", decision: .allow, reason: nil, trustMinutes: nil)

        let result = await decision
        XCTAssertEqual(result, .allow)

        let afterResolve = await store.allApprovals()
        XCTAssertTrue(afterResolve.isEmpty)
    }

    // MARK: - trustMinutes > 0 后续请求命中 auto-allow

    func testTrustMinutesEnablesSubsequentAutoAllow() async throws {
        let store = SessionStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)

        let req1 = ApprovalRequest(
            id: "req-1", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        async let decision1 = store.requestApproval(req1)
        _ = await pollForApproval(store: store)
        await store.resolveApproval(id: "req-1", decision: .allow, reason: nil, trustMinutes: 10)
        _ = await decision1

        // 第二次 request —— 命中 auto-allow
        let req2 = ApprovalRequest(
            id: "req-2", sessionId: "s1", toolName: "Edit",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        let d2 = await store.requestApproval(req2)
        XCTAssertEqual(d2, .allow)

        let pending = await store.allApprovals()
        XCTAssertTrue(pending.isEmpty, "auto-allow hit 不应入 pending")
    }

    // MARK: - subscribe 首条事件是 snapshot

    func testSubscribeYieldsSnapshotFirst() async throws {
        let store = SessionStore()
        await store.upsertSession(id: "pre-existing", cwd: "/", transcriptPath: nil)

        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()

        guard case .snapshot(let sessions, _) = first else {
            return XCTFail("first event should be .snapshot, got \(String(describing: first))")
        }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "pre-existing")
    }
}
