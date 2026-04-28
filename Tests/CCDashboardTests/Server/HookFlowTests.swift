import Foundation
import XCTest
@testable import CCDashboard

/// 阻塞审批流 —— 不走 HTTP,直接测 `HookHandlers`。
///
/// 为什么不用 HummingbirdTesting 的 `.live` client:它内部一个 `TestClient` 用单 channel
/// + CircularBuffer 串行化所有请求(见 HummingbirdTesting/TestClient.swift 的 queue),
/// 并发 `execute()` 会互相 block,导致 pre-tool-use(挂起) + decision(发不出去) 死锁。
/// 阻塞语义在 actor 层已经完整表达,handler 层测试足够覆盖。
final class HookFlowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Telemetry.isEnabled = false
    }

    func testPreToolUseBlocksUntilDecision() async throws {
        let store = makeStore()
        let handlers = HookHandlers(store: store)

        let input = HookInput(
            sessionID: "s-block", cwd: "/tmp",
            hookEventName: "PreToolUse", transcriptPath: nil,
            permissionMode: nil, toolName: "Bash",
            toolInput: ["command": AnyCodable("ls")],
            prompt: nil
        )

        let hookTask = Task { () -> String in
            let output = await handlers.preToolUse(input)
            return output.hookSpecificOutput.permissionDecision
        }

        let maybeID = await pollForApproval(store: store)
        let approvalID = try XCTUnwrap(maybeID, "pending approval 没在 3s 内入队")

        await store.resolveApproval(id: approvalID, decision: .allow, reason: nil, trustMinutes: nil)

        let decision = await hookTask.value
        XCTAssertEqual(decision, "allow")

        let after = await store.allApprovals()
        XCTAssertTrue(after.isEmpty, "resolve 后 pending 应清空")
    }

    func testPreToolUseMissingToolNameDenies() async {
        let store = makeStore()
        let handlers = HookHandlers(store: store)

        let input = HookInput(
            sessionID: "s-invalid", cwd: "/tmp",
            hookEventName: "PreToolUse", transcriptPath: nil,
            permissionMode: nil, toolName: nil, toolInput: nil,
            prompt: nil
        )
        let output = await handlers.preToolUse(input)

        XCTAssertEqual(output.hookSpecificOutput.permissionDecision, "deny")
        XCTAssertEqual(output.hookSpecificOutput.permissionDecisionReason, "missing tool_name")
    }
}
