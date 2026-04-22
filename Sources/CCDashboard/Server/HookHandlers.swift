import Foundation

struct HookHandlers: Sendable {
    let store: SessionStore

    // MARK: - SessionStart
    func sessionStart(_ input: HookInput) async -> HookAckResponse {
        await store.upsertSession(
            id: input.sessionID,
            cwd: input.cwd ?? "",
            transcriptPath: input.transcriptPath
        )
        return HookAckResponse(ok: true)
    }

    // MARK: - PreToolUse(关键:阻塞等待 UI 决策)
    func preToolUse(_ input: HookInput) async -> HookOutput {
        guard let toolName = input.toolName else {
            return denyOutput(reason: "missing tool_name")
        }

        // 确保 session 存在(防止 SessionStart hook 没触发的情况)
        await store.upsertSession(
            id: input.sessionID,
            cwd: input.cwd ?? "",
            transcriptPath: input.transcriptPath
        )

        let request = ApprovalRequest(
            id: UUID().uuidString,
            sessionId: input.sessionID,
            toolName: toolName,
            toolInput: input.toolInput ?? [:],
            cwd: input.cwd ?? "",
            createdAt: Date()
        )

        let decision = await store.requestApproval(request)

        let reason: String
        switch decision {
        case .allow: reason = "Approved via cc-dashboard"
        case .deny: reason = "Denied via cc-dashboard"
        case .ask: reason = "Delegated to interactive prompt"
        }

        return HookOutput(hookSpecificOutput: .init(
            hookEventName: "PreToolUse",
            permissionDecision: decision.rawValue,
            permissionDecisionReason: reason
        ))
    }

    // MARK: - Notification
    func notification(_ input: HookInput) async -> HookAckResponse {
        await store.touchSession(
            id: input.sessionID,
            cwd: input.cwd,
            notification: "notification"
        )
        return HookAckResponse(ok: true)
    }

    // MARK: - Stop
    func stop(_ input: HookInput) async -> HookAckResponse {
        await store.touchSession(id: input.sessionID, status: .idle)
        return HookAckResponse(ok: true)
    }

    // MARK: - SessionEnd
    func sessionEnd(_ input: HookInput) async -> HookAckResponse {
        await store.markSessionDone(id: input.sessionID)
        return HookAckResponse(ok: true)
    }

    // MARK: - Helpers
    private func denyOutput(reason: String) -> HookOutput {
        HookOutput(hookSpecificOutput: .init(
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: reason
        ))
    }
}
