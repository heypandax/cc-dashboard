import Foundation

// MARK: - Session

enum SessionStatus: String, Codable, Sendable {
    case running
    case waitingApproval = "waiting_approval"
    case idle
    case done
    case error
}

struct SessionState: Codable, Sendable, Identifiable {
    let id: String            // session_id from hook
    var cwd: String
    var status: SessionStatus
    var startedAt: Date
    var lastActivityAt: Date
    var transcriptPath: String?
    var lastTool: String?
    var lastNotification: String?
    var autoAllowUntil: Date?
    /// 永久信任标记。和 `autoAllowUntil` 互斥(set 任一会清空另一项),`hasActiveTrust(now:)`
    /// 两者 OR。生命周期同 in-memory state —— 进程重启即清空,与现有安全模型一致。
    var autoAllowForever: Bool = false
    /// 用户自定义显示名。持久化源是 AliasStore(按 cwd),这里的字段只是广播/查询时的投影。
    var alias: String?
    /// 父会话当前的 permission_mode。每个 hook payload 都带(HookInput.permissionMode),
    /// 之前收到却没落库;Agent Hub 头部要展示。默认 nil 且必须排在 alias 之后 ——
    /// 否则 SessionState(...) 的位置参数构造点(含测试)会断。
    var permissionMode: String? = nil
}

extension SessionState {
    /// 单一信任判定 —— forever 或未过期 time-boxed window 都算命中。actor 侧和 UI 侧共用,避免双字段
    /// 检查在多处重复(曾经在 4 个文件里漂移过)。
    func hasActiveTrust(now: Date) -> Bool {
        if autoAllowForever { return true }
        if let until = autoAllowUntil, until > now { return true }
        return false
    }
}

// MARK: - Approval

struct ApprovalRequest: Codable, Sendable, Identifiable {
    let id: String            // server-generated UUID
    let sessionId: String
    let toolName: String
    let toolInput: [String: AnyCodable]
    let cwd: String
    let createdAt: Date

    /// 单行摘要:优先 command,其次 file_path,兜底工具名。用于通知 body 和菜单栏卡片副标题。
    var summaryLine: String {
        if let cmd = toolInput["command"] { return cmd.display }
        if let path = toolInput["file_path"] { return path.display }
        return String(localized: "Tool: \(toolName)")
    }
}

enum ApprovalDecision: String, Codable, Sendable {
    case allow
    case deny
    case ask
}

struct DecisionRequest: Codable, Sendable {
    let decision: ApprovalDecision
    let reason: String?
    let trustMinutes: Int?
    let trustForever: Bool?
}

struct TrustRequest: Codable, Sendable {
    let minutes: Int
}

// MARK: - Agent runs (subagent tree)

/// 子 agent 执行状态。spawning = hook 已报派生但磁盘文件还没出现;running = 子转录在追加;
/// done = 末条 assistant 记录 stop_reason==end_turn;error = 会话结束时仍未完成。
enum AgentRunStatus: String, Codable, Sendable {
    case spawning
    case running
    case done
    case error
}

/// 单个 agent 的 token 累计。只取转录 usage 里 4 个扁平字段 —— 嵌套的 cache_creation /
/// server_tool_use / iterations 是噪声,忽略。
struct TokenUsage: Codable, Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }

    static func + (l: TokenUsage, r: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: l.inputTokens + r.inputTokens,
            outputTokens: l.outputTokens + r.outputTokens,
            cacheCreationTokens: l.cacheCreationTokens + r.cacheCreationTokens,
            cacheReadTokens: l.cacheReadTokens + r.cacheReadTokens
        )
    }
}

/// 子 agent 的一次工具调用(从子转录的 tool_use 记录提取)。summary 是 command/file_path/url 等摘要 ——
/// 本机展示用,和审批卡一样含命令 / 路径,绝不进 Telemetry。
struct AgentToolCall: Codable, Sendable, Equatable, Identifiable {
    let id: String        // tool_use id(toolu_…),去重 / ForEach
    let name: String      // Read / Bash / Edit / …
    let summary: String   // command / file_path / url …(可空)
    let at: Date?
}

/// 主会话派生的一个 subagent 的运行视图。`id` 是 Claude Code 的 agentId(子转录文件名内嵌)。
/// spawning 阶段还没有真实 agentId —— 先用 synthetic id 占位,watcher 见到文件后按
/// (agentType, description) 对齐替换(见 SessionStore.upsertAgentRun)。
/// `prompt` 只有 PreToolUse hook 拿得到 —— 本机 UI / 本地 /ws 可展示,绝不进 Telemetry。
struct AgentRun: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let sessionId: String
    var toolUseId: String?
    var agentType: String
    var description: String
    var prompt: String?
    var model: String?
    var status: AgentRunStatus
    var startedAt: Date
    var endedAt: Date?
    var usage: TokenUsage
    var estCostUSD: Double?
    var toolCalls: [AgentToolCall] = []
}

// MARK: - Hook IO

struct HookInput: Codable, Sendable {
    let sessionID: String
    let cwd: String?
    let hookEventName: String?
    let transcriptPath: String?
    let permissionMode: String?
    let toolName: String?
    let toolInput: [String: AnyCodable]?
    /// UserPromptSubmit hook payload 顶层字段。其他 hook 不带,缺省 nil。
    let prompt: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case transcriptPath = "transcript_path"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case prompt
    }
}

struct HookSpecificOutput: Codable, Sendable {
    let hookEventName: String
    let permissionDecision: String
    let permissionDecisionReason: String?
}

struct HookOutput: Codable, Sendable {
    let hookSpecificOutput: HookSpecificOutput
}

// MARK: - AnyCodable helper for arbitrary tool_input JSON

struct AnyCodable: Codable, Sendable {
    let value: Sendable

    init(_ value: Sendable) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull() }
        else if let b = try? c.decode(Bool.self) { self.value = b }
        else if let i = try? c.decode(Int.self) { self.value = i }
        else if let d = try? c.decode(Double.self) { self.value = d }
        else if let s = try? c.decode(String.self) { self.value = s }
        else if let a = try? c.decode([AnyCodable].self) { self.value = a }
        else if let o = try? c.decode([String: AnyCodable].self) { self.value = o }
        else { self.value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [AnyCodable]: try c.encode(a)
        case let o as [String: AnyCodable]: try c.encode(o)
        default: try c.encodeNil()
        }
    }

    var display: String {
        switch value {
        case let s as String: return s
        case let o as [String: AnyCodable]:
            if let cmd = o["command"]?.value as? String { return cmd }
            if let path = o["file_path"]?.value as? String { return path }
            return String(describing: o.mapValues { $0.display })
        default: return String(describing: value)
        }
    }
}

// MARK: - WebSocket broadcast events (tagged-union JSON for JS frontend)

enum DashboardEvent: Sendable {
    case sessionUpsert(SessionState)
    case sessionRemove(String)
    case sessionFinished(SessionState)
    /// 单次对话回合完成 —— Stop hook 触发。`prompt` 是当前回合用户提交的内容(可能 nil,
    /// 例如 hook 重放 / Claude 内部自驱动 turn / SessionStart 后立刻 Stop)。供通知层展示。
    case turnComplete(session: SessionState, prompt: String?)
    case approvalAdd(ApprovalRequest)
    case approvalResolve(String)
    case autoAllowSet(sessionId: String, until: Date)
    case autoAllowForeverSet(sessionId: String)
    case autoAllowCleared(sessionId: String)
    case sessionAliasChanged(sessionId: String, alias: String?)
    case snapshot(sessions: [SessionState], approvals: [ApprovalRequest])
    /// 子 agent 运行 upsert —— spawn / 进度 / 完成统一走这条,前端按 AgentRun.id 覆盖。
    case agentRunUpsert(AgentRun)
    /// 某 session 的全部 agent 运行快照 —— subscribe 首帧逐 session 补发,重连不丢历史。
    case agentRunsSnapshot(sessionId: String, runs: [AgentRun])
}

extension DashboardEvent: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, session, sessionId, approval, approvalId, sessions, approvals, until, alias, prompt, agentRun, runs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionUpsert(let s):
            try c.encode("session_upsert", forKey: .type)
            try c.encode(s, forKey: .session)
        case .sessionRemove(let id):
            try c.encode("session_remove", forKey: .type)
            try c.encode(id, forKey: .sessionId)
        case .sessionFinished(let s):
            try c.encode("session_finished", forKey: .type)
            try c.encode(s, forKey: .session)
        case .turnComplete(let s, let prompt):
            try c.encode("turn_complete", forKey: .type)
            try c.encode(s, forKey: .session)
            try c.encodeIfPresent(prompt, forKey: .prompt)
        case .approvalAdd(let a):
            try c.encode("approval_add", forKey: .type)
            try c.encode(a, forKey: .approval)
        case .approvalResolve(let id):
            try c.encode("approval_resolve", forKey: .type)
            try c.encode(id, forKey: .approvalId)
        case .autoAllowSet(let sid, let until):
            try c.encode("auto_allow_set", forKey: .type)
            try c.encode(sid, forKey: .sessionId)
            try c.encode(until, forKey: .until)
        case .autoAllowForeverSet(let sid):
            try c.encode("auto_allow_forever_set", forKey: .type)
            try c.encode(sid, forKey: .sessionId)
        case .autoAllowCleared(let sid):
            try c.encode("auto_allow_cleared", forKey: .type)
            try c.encode(sid, forKey: .sessionId)
        case .sessionAliasChanged(let sid, let alias):
            try c.encode("session_alias_changed", forKey: .type)
            try c.encode(sid, forKey: .sessionId)
            try c.encodeIfPresent(alias, forKey: .alias)
        case .snapshot(let sessions, let approvals):
            try c.encode("snapshot", forKey: .type)
            try c.encode(sessions, forKey: .sessions)
            try c.encode(approvals, forKey: .approvals)
        case .agentRunUpsert(let run):
            try c.encode("agent_run_upsert", forKey: .type)
            try c.encode(run, forKey: .agentRun)
        case .agentRunsSnapshot(let sid, let runs):
            try c.encode("agent_runs_snapshot", forKey: .type)
            try c.encode(sid, forKey: .sessionId)
            try c.encode(runs, forKey: .runs)
        }
    }
}
