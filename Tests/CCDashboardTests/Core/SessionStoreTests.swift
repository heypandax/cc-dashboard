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

    // MARK: - setAutoAllow 排空同 session 的 pending 审批

    func testSetAutoAllowResolvesAlreadyPendingApprovals() async throws {
        let store = SessionStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)

        // 两笔 pending(来自同一 session)在信任开窗之前已排队
        let req1 = ApprovalRequest(
            id: "req-a", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        let req2 = ApprovalRequest(
            id: "req-b", sessionId: "s1", toolName: "Edit",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        async let d1 = store.requestApproval(req1)
        async let d2 = store.requestApproval(req2)
        _ = await pollForApproval(store: store)
        // 等两笔都入队
        while await store.allApprovals().count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // 开 10 分钟信任窗,同 session 那两笔必须被 allow 放行
        await store.setAutoAllow(sessionID: "s1", minutes: 10)
        let r1 = await d1
        let r2 = await d2
        XCTAssertEqual(r1, .allow)
        XCTAssertEqual(r2, .allow)

        let stillPending = await store.allApprovals()
        XCTAssertTrue(stillPending.isEmpty, "信任开窗后不应还有同 session 的 pending")
    }

    func testSetAutoAllowDoesNotTouchOtherSessionsApprovals() async throws {
        let store = SessionStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.upsertSession(id: "s2", cwd: "/", transcriptPath: nil)

        let reqOther = ApprovalRequest(
            id: "req-other", sessionId: "s2", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        async let decisionOther = store.requestApproval(reqOther)
        _ = await pollForApproval(store: store)

        await store.setAutoAllow(sessionID: "s1", minutes: 10)

        let pending = await store.allApprovals()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.sessionId, "s2", "另一个 session 的 pending 不应受影响")

        // cleanup
        await store.resolveApproval(id: "req-other", decision: .deny, reason: nil, trustMinutes: nil)
        _ = await decisionOther
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

    // MARK: - Alias: 新 session 自动套用已存 alias

    func testUpsertAutoAppliesStoredAlias() async throws {
        let defaults = isolatedDefaults()
        let aliasStore = AliasStore(defaults: defaults)
        aliasStore.set(cwd: "/repo", alias: "My Project")

        let store = SessionStore(aliasStore: aliasStore)
        await store.upsertSession(id: "s1", cwd: "/repo", transcriptPath: nil)

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.first?.alias, "My Project")
    }

    // MARK: - Alias: setSessionAlias 既写盘又广播,且顺序为 upsert 先、aliasChanged 后

    func testSetSessionAliasBroadcastsInOrderAndPersists() async throws {
        let defaults = isolatedDefaults()
        let aliasStore = AliasStore(defaults: defaults)
        let store = SessionStore(aliasStore: aliasStore)

        await store.upsertSession(id: "s1", cwd: "/repo", transcriptPath: nil)

        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()   // snapshot

        await store.setSessionAlias(cwd: "/repo", alias: "Renamed")

        guard case .sessionUpsert(let s) = await iter.next() else {
            return XCTFail("expected .sessionUpsert first")
        }
        XCTAssertEqual(s.alias, "Renamed")

        guard case .sessionAliasChanged(let sid, let alias) = await iter.next() else {
            return XCTFail("expected .sessionAliasChanged second")
        }
        XCTAssertEqual(sid, "s1")
        XCTAssertEqual(alias, "Renamed")

        XCTAssertEqual(aliasStore.get(cwd: "/repo"), "Renamed")
    }

    // MARK: - Alias: 同 cwd 下多 session 一并更新

    func testSetSessionAliasUpdatesAllSessionsSharingCwd() async throws {
        let defaults = isolatedDefaults()
        let store = SessionStore(aliasStore: AliasStore(defaults: defaults))

        await store.upsertSession(id: "s1", cwd: "/repo", transcriptPath: nil)
        await store.upsertSession(id: "s2", cwd: "/repo", transcriptPath: nil)

        await store.setSessionAlias(cwd: "/repo", alias: "Shared")

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.alias == "Shared" })
    }

    // MARK: - Alias: 清空(空串 / nil 都走同一条语义)→ aliasChanged payload 为 nil

    func testClearAliasEmitsNilInEvent() async throws {
        let defaults = isolatedDefaults()
        let aliasStore = AliasStore(defaults: defaults)
        aliasStore.set(cwd: "/repo", alias: "to-be-cleared")

        let store = SessionStore(aliasStore: aliasStore)
        await store.upsertSession(id: "s1", cwd: "/repo", transcriptPath: nil)

        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()   // snapshot

        // 空串也应该清空
        await store.setSessionAlias(cwd: "/repo", alias: "")

        _ = await iter.next()   // sessionUpsert
        guard case .sessionAliasChanged(_, let alias) = await iter.next() else {
            return XCTFail("expected .sessionAliasChanged")
        }
        XCTAssertNil(alias)
        XCTAssertNil(aliasStore.get(cwd: "/repo"))
    }

    // MARK: - Alias: setSessionAliasById 路径找得到 cwd

    func testSetSessionAliasByIdResolvesCwd() async throws {
        let defaults = isolatedDefaults()
        let aliasStore = AliasStore(defaults: defaults)
        let store = SessionStore(aliasStore: aliasStore)

        await store.upsertSession(id: "s1", cwd: "/resolved", transcriptPath: nil)
        await store.setSessionAliasById(sessionID: "s1", alias: "by id")

        XCTAssertEqual(aliasStore.get(cwd: "/resolved"), "by id")
        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.first?.alias, "by id")
    }

    // MARK: - Alias: setSessionAliasById 对 unknown session id 静默

    func testSetSessionAliasByIdIgnoresUnknownSession() async throws {
        let defaults = isolatedDefaults()
        let aliasStore = AliasStore(defaults: defaults)
        let store = SessionStore(aliasStore: aliasStore)

        await store.setSessionAliasById(sessionID: "does-not-exist", alias: "oops")

        XCTAssertTrue(aliasStore.load().isEmpty, "unknown sessionId 不应触发任何写入")
    }

    // MARK: - 辅助

    private func isolatedDefaults() -> UserDefaults {
        let name = "test.store.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }
}
