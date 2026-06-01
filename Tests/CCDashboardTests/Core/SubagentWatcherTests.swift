import Foundation
import XCTest
@testable import CCDashboard

final class SubagentWatcherTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Telemetry.isEnabled = false
    }

    /// scanOnce 跑真实 fixture 树:完成(end_turn + meta 带 toolUseId)、进行中(无 end_turn +
    /// meta 不带 toolUseId)、截断尾行 —— 不依赖 kqueue 投递时序。
    func testScanOnceBuildsAgentRunsFromFixtures() async throws {
        let anchor = try XCTUnwrap(
            Bundle.module.url(forResource: "sess1", withExtension: "jsonl",
                              subdirectory: "Fixtures/agent_scan"),
            "Fixtures/agent_scan/sess1.jsonl not found in test bundle"
        )
        let store = makeStore()
        let watcher = SubagentWatcher(store: store)
        await watcher.scanOnce(transcriptPath: anchor.path)

        let runs = await store.agentRuns(forSession: "sess1")
        XCTAssertEqual(runs.count, 3)
        let byId = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })

        // 完成态:end_turn 终态记录的 usage 也被累加,model 可读,meta toolUseId 命中
        let done = try XCTUnwrap(byId["done1"])
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.agentType, "Explore")
        XCTAssertEqual(done.description, "survey the codebase")
        XCTAssertEqual(done.toolUseId, "toolu_done1")
        XCTAssertEqual(done.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(done.usage.inputTokens, 220)
        XCTAssertEqual(done.usage.outputTokens, 110)
        XCTAssertEqual(done.usage.cacheCreationTokens, 200)
        XCTAssertEqual(done.usage.cacheReadTokens, 2300)
        XCTAssertNotNil(done.endedAt)
        XCTAssertNotNil(done.estCostUSD)

        // 进行中:无 end_turn → running;meta 不带 toolUseId 的常见 case
        let run = try XCTUnwrap(byId["run1"])
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(run.agentType, "general-purpose")
        XCTAssertNil(run.toolUseId)
        XCTAssertEqual(run.model, "claude-opus-4-8")
        XCTAssertNil(run.endedAt)

        // 截断尾行被跳过,只累加前面完整的 assistant 行
        let trunc = try XCTUnwrap(byId["trunc1"])
        XCTAssertEqual(trunc.status, .running)
        XCTAssertEqual(trunc.usage.inputTokens, 10)
        XCTAssertEqual(trunc.usage.outputTokens, 5)
        XCTAssertEqual(trunc.model, "claude-sonnet-4-6")
    }
}
