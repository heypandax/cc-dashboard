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

        // Claude Code 的 PreToolUse hook 在 permission 系统之前触发 —— 用户开了
        // bypassPermissions / acceptEdits 时如果还把请求挂进审批队列,等于强行
        // 覆盖了用户的"自动放行"选择。这里早 return,把决定权还回去。
        if let reason = autoAllowReason(mode: input.permissionMode, toolName: toolName) {
            Log.session.info("auto-allow tool=\(toolName, privacy: .public) reason=\(reason, privacy: .public)")
            return allowOutput(reason: reason)
        }

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

    // MARK: - Stop(单回合完成)
    func stop(_ input: HookInput) async -> HookAckResponse {
        await store.markTurnComplete(sessionID: input.sessionID, cwd: input.cwd)
        return HookAckResponse(ok: true)
    }

    // MARK: - SessionEnd
    func sessionEnd(_ input: HookInput) async -> HookAckResponse {
        await store.markSessionDone(id: input.sessionID)
        return HookAckResponse(ok: true)
    }

    // MARK: - UserPromptSubmit(缓存 prompt 供 Stop 通知使用)
    func userPromptSubmit(_ input: HookInput) async -> HookAckResponse {
        let preview = String((input.prompt ?? "").prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
        Log.session.info("hook user-prompt-submit session=\(input.sessionID, privacy: .public) len=\(input.prompt?.count ?? 0) preview=\"\(preview, privacy: .public)\"")
        guard let prompt = input.prompt, !prompt.isEmpty else {
            return HookAckResponse(ok: true)
        }
        await store.recordUserPrompt(sessionID: input.sessionID, cwd: input.cwd, prompt: prompt)
        return HookAckResponse(ok: true)
    }

    // MARK: - Helpers

    /// 用户在 Claude Code 里开了 auto mode 时,返回一个非 nil 的 reason 表示
    /// 这个工具调用应该立即放行;返回 nil 表示走正常审批流。
    /// - bypassPermissions:全部放行(用户已经声明"全自动")
    /// - acceptEdits:仅 Edit / Write / MultiEdit 放行(Bash 等危险工具仍审)
    static func autoAllowReason(mode: String?, toolName: String) -> String? {
        guard let mode else { return nil }
        switch mode {
        case "bypassPermissions":
            return "Auto-allow (permission_mode=bypassPermissions)"
        case "acceptEdits" where ["Edit", "Write", "MultiEdit"].contains(toolName):
            return "Auto-allow (permission_mode=acceptEdits)"
        default:
            return nil
        }
    }

    private func autoAllowReason(mode: String?, toolName: String) -> String? {
        Self.autoAllowReason(mode: mode, toolName: toolName)
    }

    private func allowOutput(reason: String) -> HookOutput {
        HookOutput(hookSpecificOutput: .init(
            hookEventName: "PreToolUse",
            permissionDecision: "allow",
            permissionDecisionReason: reason
        ))
    }

    private func denyOutput(reason: String) -> HookOutput {
        HookOutput(hookSpecificOutput: .init(
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: reason
        ))
    }
}
