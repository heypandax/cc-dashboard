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
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
        await store.touchSession(id: "ghost", cwd: "/tmp")
        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "ghost")
        XCTAssertEqual(sessions.first?.cwd, "/tmp")
    }

    // MARK: - requestApproval miss → 入 pending → resolveApproval 唤醒

    func testRequestApprovalMissEnqueuesAndResolves() async throws {
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
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

    // MARK: - 信任持久化:setAutoAllowForever 写盘,新进程下新 session 进同 cwd 自动套上

    func testTrustForeverPersistsAndRestoresOnNewSession() async throws {
        let sharedDefaults = isolatedDefaults()
        let store1 = SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: TrustStore(defaults: sharedDefaults)
        )
        await store1.upsertSession(id: "s1", cwd: "/proj-x", transcriptPath: nil)
        await store1.setAutoAllowForever(sessionID: "s1")

        // 模拟"重启"—— 拿同一 UserDefaults 起一个新 SessionStore
        let store2 = SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: TrustStore(defaults: sharedDefaults)
        )
        await store2.upsertSession(id: "s2-fresh", cwd: "/proj-x", transcriptPath: nil)

        let sessions = await store2.allSessions()
        let restored = try XCTUnwrap(sessions.first { $0.id == "s2-fresh" })
        XCTAssertTrue(restored.autoAllowForever, "新 session 进同 cwd 应自动套上 forever 信任")
    }

    // MARK: - 信任持久化:time-boxed 未过期 → 新 session 拿到剩余时长

    func testTrustTimeBoxedPersistsAndRestoresWithRemaining() async throws {
        let sharedDefaults = isolatedDefaults()
        let store1 = SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: TrustStore(defaults: sharedDefaults)
        )
        await store1.upsertSession(id: "s1", cwd: "/proj-y", transcriptPath: nil)
        await store1.setAutoAllow(sessionID: "s1", minutes: 30)

        let store2 = SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: TrustStore(defaults: sharedDefaults)
        )
        await store2.upsertSession(id: "s2-fresh", cwd: "/proj-y", transcriptPath: nil)

        let sessions = await store2.allSessions()
        let restored = try XCTUnwrap(sessions.first { $0.id == "s2-fresh" })
        XCTAssertNotNil(restored.autoAllowUntil, "新 session 应继承 time-boxed 信任")
        XCTAssertFalse(restored.autoAllowForever)
    }

    // MARK: - 信任持久化:已过期 time-boxed → 不恢复 + 清持久层

    func testTrustTimeBoxedExpiredOnLoadIsDropped() async throws {
        let sharedDefaults = isolatedDefaults()
        let trustStore = TrustStore(defaults: sharedDefaults)
        // 直接写一条已过期的条目
        trustStore.setUntil(cwd: "/proj-old", until: Date(timeIntervalSinceNow: -3600))

        let store = SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: trustStore
        )
        await store.upsertSession(id: "s1", cwd: "/proj-old", transcriptPath: nil)

        let sessions = await store.allSessions()
        let s = try XCTUnwrap(sessions.first)
        XCTAssertNil(s.autoAllowUntil, "过期条目不应恢复")
        XCTAssertFalse(s.autoAllowForever)

        // 持久层也应被 GC
        XCTAssertNil(trustStore.loadAll()["/proj-old"], "init 阶段应顺手清掉过期条目")
    }

    // MARK: - 信任持久化:touchSession 先于 upsertSession 创建占位时,upsertSession 仍能恢复信任

    func testTrustForeverRestoredEvenWhenTouchSessionPreemptsUpsert() async throws {
        let sharedDefaults = isolatedDefaults()
        // 第一次:set forever 写盘
        let store1 = SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: TrustStore(defaults: sharedDefaults),
            turnCompleteDebounceSeconds: 0
        )
        await store1.upsertSession(id: "old-session", cwd: "/proj-race", transcriptPath: nil)
        await store1.setAutoAllowForever(sessionID: "old-session")

        // 模拟"重启 + Claude 已有 session 抢先发了 UserPromptSubmit / Notification"
        // —— UserPromptSubmit handler 内部走 touchSession 建占位,此时还没 upsertSession。
        let store2 = SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: TrustStore(defaults: sharedDefaults),
            turnCompleteDebounceSeconds: 0
        )
        await store2.recordUserPrompt(sessionID: "running-sid", cwd: "/proj-race", prompt: "go")
        // 此时 sessions["running-sid"] 是占位,无信任
        let beforeUpsert = await store2.allSessions().first { $0.id == "running-sid" }
        XCTAssertNotNil(beforeUpsert)
        XCTAssertFalse(beforeUpsert?.autoAllowForever ?? true)

        // PreToolUse 才到 → upsertSession 应补查持久层
        await store2.upsertSession(id: "running-sid", cwd: "/proj-race", transcriptPath: nil)

        let afterUpsert = await store2.allSessions().first { $0.id == "running-sid" }
        XCTAssertEqual(afterUpsert?.autoAllowForever, true, "occupant 占位后 upsertSession 仍应补恢复信任")
    }

    // MARK: - 信任持久化:clearAutoAllow 同步清持久层

    func testClearAutoAllowAlsoClearsPersistence() async throws {
        let sharedDefaults = isolatedDefaults()
        let trustStore = TrustStore(defaults: sharedDefaults)
        let store = SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: trustStore
        )
        await store.upsertSession(id: "s1", cwd: "/proj-z", transcriptPath: nil)
        await store.setAutoAllowForever(sessionID: "s1")
        XCTAssertNotNil(trustStore.loadAll()["/proj-z"])

        await store.clearAutoAllow(sessionID: "s1")
        XCTAssertNil(trustStore.loadAll()["/proj-z"], "用户取消信任应同时清持久层")
    }

    // MARK: - turn-complete:Stop 广播带最近 prompt

    func testMarkTurnCompleteBroadcastsRecordedPrompt() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()  // snapshot

        await store.recordUserPrompt(sessionID: "s1", cwd: "/", prompt: "do the thing")
        // recordUserPrompt 内部 touchSession,先消耗那条 sessionUpsert
        _ = await iter.next()

        await store.markTurnComplete(sessionID: "s1", cwd: nil)

        // markTurnComplete 先 touchSession(.idle) → sessionUpsert,再广播 turnComplete
        guard case .sessionUpsert(let s) = await iter.next() else {
            return XCTFail("expected .sessionUpsert first")
        }
        XCTAssertEqual(s.status, .idle)

        guard case .turnComplete(let tcSession, let prompt) = await iter.next() else {
            return XCTFail("expected .turnComplete second")
        }
        XCTAssertEqual(tcSession.id, "s1")
        XCTAssertEqual(prompt, "do the thing")
    }

    // MARK: - turn-complete:无 prompt 时 prompt=nil

    func testMarkTurnCompleteWithoutRecordedPromptYieldsNil() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()  // snapshot(已含 s1)—— upsert 在 subscribe 之前触发,不进 stream

        await store.markTurnComplete(sessionID: "s1", cwd: nil)
        _ = await iter.next()  // sessionUpsert(.idle)
        guard case .turnComplete(_, let prompt) = await iter.next() else {
            return XCTFail("expected .turnComplete")
        }
        XCTAssertNil(prompt)
    }

    // MARK: - turn-complete:消费后 prompt 被清,下次 Stop 无 prompt 时不复用

    func testMarkTurnCompleteClearsPromptAfterBroadcast() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.recordUserPrompt(sessionID: "s1", cwd: "/", prompt: "first")

        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()  // snapshot

        // 第一次 Stop —— 带上 prompt
        await store.markTurnComplete(sessionID: "s1", cwd: nil)
        _ = await iter.next()  // sessionUpsert
        guard case .turnComplete(_, let p1) = await iter.next() else {
            return XCTFail("expected first .turnComplete")
        }
        XCTAssertEqual(p1, "first")

        // 第二次 Stop(没新 prompt)—— 不复用旧的
        await store.markTurnComplete(sessionID: "s1", cwd: nil)
        _ = await iter.next()  // sessionUpsert
        guard case .turnComplete(_, let p2) = await iter.next() else {
            return XCTFail("expected second .turnComplete")
        }
        XCTAssertNil(p2, "消费后 prompt 应被清,下次 Stop 不应该看到旧 prompt")
    }

    // MARK: - turn-complete:多次 prompt,Stop 取最新

    func testRecordUserPromptLatestWins() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)

        await store.recordUserPrompt(sessionID: "s1", cwd: "/", prompt: "first")
        await store.recordUserPrompt(sessionID: "s1", cwd: "/", prompt: "second")

        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()  // snapshot

        await store.markTurnComplete(sessionID: "s1", cwd: nil)
        _ = await iter.next()  // sessionUpsert
        guard case .turnComplete(_, let prompt) = await iter.next() else {
            return XCTFail("expected .turnComplete")
        }
        XCTAssertEqual(prompt, "second")
    }

    // MARK: - 永久信任:set forever 排空同 session 的 pending 审批

    func testSetAutoAllowForeverDrainsPendingApprovals() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)

        let req = ApprovalRequest(
            id: "req-f", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        async let decision = store.requestApproval(req)
        _ = await pollForApproval(store: store)

        await store.setAutoAllowForever(sessionID: "s1")
        let r = await decision
        XCTAssertEqual(r, .allow)

        let stillPending = await store.allApprovals()
        XCTAssertTrue(stillPending.isEmpty)
    }

    // MARK: - 永久信任:后续请求命中 auto-allow

    func testTrustForeverEnablesSubsequentAutoAllow() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.setAutoAllowForever(sessionID: "s1")

        let req = ApprovalRequest(
            id: "req-x", sessionId: "s1", toolName: "Edit",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        let d = await store.requestApproval(req)
        XCTAssertEqual(d, .allow)

        let pending = await store.allApprovals()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - 永久信任:resolveApproval(trustForever: true) 触发设置

    func testResolveApprovalWithTrustForeverSetsFlag() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)

        let req = ApprovalRequest(
            id: "req-rf", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        async let decision = store.requestApproval(req)
        _ = await pollForApproval(store: store)

        await store.resolveApproval(id: "req-rf", decision: .allow, reason: nil, trustMinutes: nil, trustForever: true)
        _ = await decision

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.first?.autoAllowForever, true)
        XCTAssertNil(sessions.first?.autoAllowUntil)
    }

    // MARK: - 永久信任:clearAutoAllow 清掉 forever 标志

    func testClearAutoAllowClearsForeverFlag() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.setAutoAllowForever(sessionID: "s1")

        await store.clearAutoAllow(sessionID: "s1")

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.first?.autoAllowForever, false)
        XCTAssertNil(sessions.first?.autoAllowUntil)

        // 再来一笔请求应入 pending
        let req = ApprovalRequest(
            id: "req-after", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: Date()
        )
        async let d = store.requestApproval(req)
        _ = await pollForApproval(store: store)
        let pending = await store.allApprovals()
        XCTAssertEqual(pending.count, 1)
        await store.resolveApproval(id: "req-after", decision: .deny, reason: nil, trustMinutes: nil)
        _ = await d
    }

    // MARK: - 永久信任 vs. time-boxed:互相覆盖

    func testSetAutoAllowForeverClearsTimeBoxed() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.setAutoAllow(sessionID: "s1", minutes: 30)

        await store.setAutoAllowForever(sessionID: "s1")

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.first?.autoAllowForever, true)
        XCTAssertNil(sessions.first?.autoAllowUntil, "forever 设置后 time-boxed window 应清空")
    }

    func testSetAutoAllowClearsForever() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.setAutoAllowForever(sessionID: "s1")

        await store.setAutoAllow(sessionID: "s1", minutes: 5)

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.first?.autoAllowForever, false, "显式 time-boxed grant 应覆盖 forever")
        XCTAssertNotNil(sessions.first?.autoAllowUntil)
    }

    // MARK: - 永久信任:广播 .autoAllowForeverSet 事件

    func testSetAutoAllowForeverBroadcastsEvent() async throws {
        let store = makeStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)

        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()  // snapshot

        await store.setAutoAllowForever(sessionID: "s1")

        // 第一条:sessionUpsert(state.autoAllowForever == true)
        guard case .sessionUpsert(let s) = await iter.next() else {
            return XCTFail("expected .sessionUpsert first")
        }
        XCTAssertTrue(s.autoAllowForever)

        // 第二条:autoAllowForeverSet(sessionId)
        guard case .autoAllowForeverSet(let sid) = await iter.next() else {
            return XCTFail("expected .autoAllowForeverSet second")
        }
        XCTAssertEqual(sid, "s1")
    }

    // MARK: - trustMinutes > 0 后续请求命中 auto-allow

    func testTrustMinutesEnablesSubsequentAutoAllow() async throws {
        let store = makeStore()
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
        let store = makeStore()
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
