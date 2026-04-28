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

    /// `bypassPermissions` 模式下用户已经在 Claude Code 端声明"全自动",cc-dashboard
    /// 应该立即放行而不是把请求挂进审批队列。否则会出现"开了 auto mode 还要点 Allow"
    /// 的体验割裂。
    func testPreToolUseBypassPermissionsAutoAllowsWithoutQueueing() async {
        let store = makeStore()
        let handlers = HookHandlers(store: store)

        let input = HookInput(
            sessionID: "s-bypass", cwd: "/tmp",
            hookEventName: "PreToolUse", transcriptPath: nil,
            permissionMode: "bypassPermissions", toolName: "Bash",
            toolInput: ["command": AnyCodable("rm -rf /tmp/x")],
            prompt: nil
        )
        let output = await handlers.preToolUse(input)

        XCTAssertEqual(output.hookSpecificOutput.permissionDecision, "allow")
        XCTAssertTrue(output.hookSpecificOutput.permissionDecisionReason?.contains("bypassPermissions") == true)

        let pending = await store.allApprovals()
        XCTAssertTrue(pending.isEmpty, "auto-allow 不应进入审批队列")
    }

    /// `acceptEdits` 模式只对 Edit / Write / MultiEdit 自动放行(跟 Claude Code
    /// 自身的 acceptEdits 语义对齐),其余工具仍走正常审批。
    func testPreToolUseAcceptEditsAutoAllowsOnlyWriteTools() async {
        let store = makeStore()
        let handlers = HookHandlers(store: store)

        let editInput = HookInput(
            sessionID: "s-ae-edit", cwd: "/tmp",
            hookEventName: "PreToolUse", transcriptPath: nil,
            permissionMode: "acceptEdits", toolName: "Edit",
            toolInput: ["file_path": AnyCodable("/tmp/a.txt")],
            prompt: nil
        )
        let editOutput = await handlers.preToolUse(editInput)
        XCTAssertEqual(editOutput.hookSpecificOutput.permissionDecision, "allow")

        let pendingAfterEdit = await store.allApprovals()
        XCTAssertTrue(pendingAfterEdit.isEmpty, "Edit 在 acceptEdits 下不应入队")

        // Bash 即便在 acceptEdits 下也应被审 —— 注意这里要用独立 session,否则
        // 已经被 upsert 进去的 s-ae-edit 会污染断言;另外 requestApproval 是阻塞的,
        // 所以包成 Task 看队列是否真的入了即可。
        let bashInput = HookInput(
            sessionID: "s-ae-bash", cwd: "/tmp",
            hookEventName: "PreToolUse", transcriptPath: nil,
            permissionMode: "acceptEdits", toolName: "Bash",
            toolInput: ["command": AnyCodable("ls")],
            prompt: nil
        )
        let bashTask = Task { _ = await handlers.preToolUse(bashInput) }
        let approvalID = await pollForApproval(store: store)
        XCTAssertNotNil(approvalID, "Bash 即便在 acceptEdits 下也应入审批队列")

        // 清理:resolve 一下让 hookTask 退出
        if let id = approvalID {
            await store.resolveApproval(id: id, decision: .allow, reason: nil, trustMinutes: nil)
        }
        _ = await bashTask.value
    }

    /// `default` / nil 模式下行为不变,正常入队。一行覆盖回归。
    func testAutoAllowReasonHelperPureLogic() {
        XCTAssertEqual(HookHandlers.autoAllowReason(mode: "bypassPermissions", toolName: "Bash"),
                       "Auto-allow (permission_mode=bypassPermissions)")
        XCTAssertEqual(HookHandlers.autoAllowReason(mode: "acceptEdits", toolName: "MultiEdit"),
                       "Auto-allow (permission_mode=acceptEdits)")
        XCTAssertNil(HookHandlers.autoAllowReason(mode: "acceptEdits", toolName: "Bash"))
        XCTAssertNil(HookHandlers.autoAllowReason(mode: "default", toolName: "Edit"))
        XCTAssertNil(HookHandlers.autoAllowReason(mode: nil, toolName: "Edit"))
        XCTAssertNil(HookHandlers.autoAllowReason(mode: "plan", toolName: "Edit"))
    }
}
