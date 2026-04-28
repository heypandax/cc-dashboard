import Foundation
import XCTest
@testable import CCDashboard

/// 用 `TestScheduler` 替换 SessionStore 的 now/delay,deterministic 测试定时器行为。
final class SessionStoreClockTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Telemetry.isEnabled = false
    }

    private func makeStore(sched: TestScheduler, debounceSeconds: Double = 0) -> SessionStore {
        SessionStore(
            aliasStore: AliasStore(defaults: isolatedDefaults()),
            trustStore: TrustStore(defaults: isolatedDefaults()),
            turnCompleteDebounceSeconds: debounceSeconds,
            now: { sched.now },
            delay: { await sched.sleep(nanos: $0) }
        )
    }

    // MARK: - markSessionDone → 10 秒 purge

    func testMarkSessionDoneTriggersPurgeAfter10Seconds() async throws {
        let sched = TestScheduler()
        let store = makeStore(sched: sched)

        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.markSessionDone(id: "s1")
        await waitForScheduledWork()

        let beforeAdvance = await store.allSessions()
        XCTAssertEqual(beforeAdvance.count, 1)
        XCTAssertEqual(beforeAdvance.first?.status, .done)

        sched.advance(bySeconds: 10)
        await waitForScheduledWork()

        let afterAdvance = await store.allSessions()
        XCTAssertTrue(afterAdvance.isEmpty, "session 应在 10 秒 purge")
    }

    // MARK: - 5 秒内 re-upsert 取消 purge

    func testReupsertCancelsPendingPurge() async throws {
        let sched = TestScheduler()
        let store = makeStore(sched: sched)

        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.markSessionDone(id: "s1")
        await waitForScheduledWork()

        sched.advance(bySeconds: 5)
        await waitForScheduledWork()
        await store.upsertSession(id: "s1", cwd: "/new", transcriptPath: nil)

        sched.advance(bySeconds: 10)
        await waitForScheduledWork()

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.cwd, "/new")
        XCTAssertEqual(sessions.first?.status, .running)
    }

    // MARK: - setAutoAllow(2 分钟)过期 timer

    func testAutoAllowExpiresAfterConfiguredMinutes() async throws {
        let sched = TestScheduler()
        let store = makeStore(sched: sched)

        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.setAutoAllow(sessionID: "s1", minutes: 2)
        await waitForScheduledWork()

        sched.advance(bySeconds: 60)
        await waitForScheduledWork()
        var sessions = await store.allSessions()
        XCTAssertNotNil(sessions.first?.autoAllowUntil)

        sched.advance(bySeconds: 60)
        await waitForScheduledWork()
        sessions = await store.allSessions()
        XCTAssertNil(sessions.first?.autoAllowUntil, "auto-allow 应已过期清除")
    }

    // MARK: - auto-allow 命中 / miss 边界

    func testAutoAllowHitBeforeExpiryMissAfter() async throws {
        let sched = TestScheduler()
        let store = makeStore(sched: sched)

        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.setAutoAllow(sessionID: "s1", minutes: 10)
        await waitForScheduledWork()

        sched.advance(bySeconds: 60 * 5)
        let req1 = ApprovalRequest(
            id: "r1", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: sched.now
        )
        let d1 = await store.requestApproval(req1)
        XCTAssertEqual(d1, .allow)

        sched.advance(bySeconds: 60 * 5 + 1)
        await waitForScheduledWork()

        let req2 = ApprovalRequest(
            id: "r2", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: sched.now
        )
        async let d2 = store.requestApproval(req2)
        _ = await pollForApproval(store: store)
        let pending = await store.allApprovals()
        XCTAssertEqual(pending.count, 1, "auto-allow 过期后请求应入 pending")

        await store.resolveApproval(id: "r2", decision: .deny, reason: nil, trustMinutes: nil)
        _ = await d2
    }

    // MARK: - 永久信任不过期:虚拟时钟跳一年仍命中

    func testAutoAllowForeverDoesNotExpire() async throws {
        let sched = TestScheduler()
        let store = makeStore(sched: sched)

        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.setAutoAllowForever(sessionID: "s1")
        await waitForScheduledWork()

        // 跳一年 —— time-boxed window 早就过期了,forever 不该被 expiry task 误清
        sched.advance(bySeconds: 365 * 24 * 60 * 60)
        await waitForScheduledWork()

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.first?.autoAllowForever, true)

        let req = ApprovalRequest(
            id: "r1", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: sched.now
        )
        let d = await store.requestApproval(req)
        XCTAssertEqual(d, .allow)
    }

    // MARK: - turn-complete debounce:静默期满才广播 turnComplete

    func testTurnCompleteDebounceFiresAfterQuietPeriod() async throws {
        let sched = TestScheduler()
        let store = makeStore(sched: sched, debounceSeconds: 2)
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.recordUserPrompt(sessionID: "s1", cwd: "/", prompt: "hi")

        let stream = await store.subscribe()
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()  // snapshot

        await store.markTurnComplete(sessionID: "s1", cwd: nil)
        _ = await iter.next()  // sessionUpsert(.idle) 立即
        await waitForScheduledWork()

        // debounce 还没过 —— 不应有 turnComplete
        sched.advance(bySeconds: 1)
        await waitForScheduledWork()

        // 推过 debounce → 广播
        sched.advance(bySeconds: 2)
        await waitForScheduledWork()

        guard case .turnComplete(_, let prompt) = await iter.next() else {
            return XCTFail("expected .turnComplete after debounce")
        }
        XCTAssertEqual(prompt, "hi")
    }

    // MARK: - turn-complete debounce:期间 PreToolUse 取消上一次的挂起 → 全程仅 fire 一次

    func testTurnCompleteDebounceCancelledByToolUse() async throws {
        let sched = TestScheduler()
        let store = makeStore(sched: sched, debounceSeconds: 2)

        // 先订阅,顺序收集所有事件,最后清点 turnComplete 个数
        let stream = await store.subscribe()
        let collector = TurnCompleteCounter()
        let collectTask = Task {
            for await event in stream {
                if case .turnComplete = event {
                    await collector.bump()
                }
            }
        }
        defer { collectTask.cancel() }

        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)
        await store.recordUserPrompt(sessionID: "s1", cwd: "/", prompt: "p1")

        // 第一次 Stop:进入 debounce 队列
        await store.markTurnComplete(sessionID: "s1", cwd: nil)
        await waitForScheduledWork()

        // 1s 时一笔工具调用 → 取消挂起
        sched.advance(bySeconds: 1)
        await waitForScheduledWork()
        let req = ApprovalRequest(
            id: "r1", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/", createdAt: sched.now
        )
        async let d = store.requestApproval(req)
        await waitForScheduledWork()

        // 跳过 debounce 原本的触发点 —— 若取消生效,这里不应 fire
        sched.advance(bySeconds: 5)
        await waitForScheduledWork()

        // resolve 那笔 pending,清场
        let approvals = await store.allApprovals()
        if let id = approvals.first?.id {
            await store.resolveApproval(id: id, decision: .deny, reason: nil, trustMinutes: nil)
        }
        _ = await d
        await waitForScheduledWork()

        // 二次 Stop —— 让它真 fire
        await store.markTurnComplete(sessionID: "s1", cwd: nil)
        await waitForScheduledWork()
        sched.advance(bySeconds: 3)
        await waitForScheduledWork()

        let count = await collector.value
        XCTAssertEqual(count, 1, "第一次挂起应被工具调用取消,只第二次 Stop 之后 fire 一次")
    }

    /// 让 actor hop + scheduler-registered continuation 有机会跑。
    /// TestScheduler 是虚拟时钟,不能依赖 wall-clock sleep,只 yield。
    private func waitForScheduledWork() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// turnComplete 计数器 —— actor 隔离,跨 Sendable closure 安全。
private actor TurnCompleteCounter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}
