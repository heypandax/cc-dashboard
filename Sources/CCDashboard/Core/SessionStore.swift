import Foundation

/// 并发安全的状态中心。hook handlers 在 non-isolated 执行器上跑,UI 在 MainActor,通过这个 actor 串行化访问。
actor SessionStore {
    private var sessions: [String: SessionState] = [:]
    private var pendingApprovals: [String: ApprovalRequest] = [:]
    private var pendingContinuations: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var eventStreams: [UUID: AsyncStream<DashboardEvent>.Continuation] = [:]
    private var autoAllowExpireTasks: [String: Task<Void, Never>] = [:]
    private var purgeTasks: [String: Task<Void, Never>] = [:]
    /// 最近一次用户在该 session 提交的 prompt 文本。Stop hook 触发的 turn-complete 通知
    /// 拿这里取(Stop payload 自己不带 prompt)。session purge 时清。不广播,不上传。
    private var lastPrompts: [String: String] = [:]
    /// turn-complete 防抖任务。Stop 触发后调度,debounce 内任何 PreToolUse / UserPromptSubmit
    /// 都会取消重置,只在"真正安静"时才广播 turn-complete。详见 `markTurnComplete`。
    private var pendingTurnCompleteTasks: [String: Task<Void, Never>] = [:]
    private let turnCompleteDebounceNanos: UInt64

    /// 测试可注入的时间源与延迟函数。生产走默认值 —— `Date()` 和 `Task.sleep(nanoseconds:)`。
    /// 为什么不是 `Clock.sleep(for:)` / `Task.sleep(for:)`:见 fffadbc 的 crash fix,
    /// 后者在 macOS 26 cooperative pool 上触发 swift_task_dealloc abort。不要换。
    private let now: @Sendable () -> Date
    private let delay: @Sendable (UInt64) async -> Void
    private let aliasStore: AliasStore
    private let trustStore: TrustStore
    /// 启动时从 TrustStore 一次性加载,upsertSession 命中新 session 时按需套用。
    /// 过期的 time-boxed 项在 init 阶段就丢,顺手清掉持久层。
    private var pendingTrustsByCwd: [String: PersistedTrust.Mode] = [:]

    init(
        aliasStore: AliasStore = AliasStore(),
        trustStore: TrustStore = TrustStore(),
        turnCompleteDebounceSeconds: Double = 2.0,
        now: @Sendable @escaping () -> Date = { Date() },
        delay: @Sendable @escaping (UInt64) async -> Void = { nanos in
            try? await Task.sleep(nanoseconds: nanos)
        }
    ) {
        self.aliasStore = aliasStore
        self.trustStore = trustStore
        self.turnCompleteDebounceNanos = UInt64(max(0, turnCompleteDebounceSeconds) * 1_000_000_000)
        self.now = now
        self.delay = delay

        // 启动时:loadAll → 用注入的 now() 过滤过期 → 过期项清出持久层 → 剩下的等 upsertSession 套用
        let nowDate = now()
        for (cwd, entry) in trustStore.loadAll() {
            switch entry.mode {
            case .forever:
                pendingTrustsByCwd[cwd] = .forever
            case .until(let when):
                if when > nowDate {
                    pendingTrustsByCwd[cwd] = .until(when)
                } else {
                    trustStore.clear(cwd: cwd)
                }
            }
        }
    }

    // MARK: Session lifecycle

    func upsertSession(id: String, cwd: String, transcriptPath: String?) {
        let resolvedAlias = aliasStore.get(cwd: cwd)
        if var existing = sessions[id] {
            existing.cwd = cwd
            existing.lastActivityAt = now()
            existing.status = .running
            if let transcriptPath { existing.transcriptPath = transcriptPath }
            existing.alias = resolvedAlias   // cwd 可能在 update 时变,alias 跟着走
            sessions[id] = existing
            broadcast(.sessionUpsert(existing))

            // touchSession(UserPromptSubmit / Notification) 可能在 upsertSession 之前先建了
            // 一个无信任占位 → 这里补查持久层,让"app 重启后第一次 prompt 进 hook"也能自动恢复。
            if !existing.hasActiveTrust(now: now()) {
                applyPendingTrust(sessionID: id, cwd: cwd)
            }
        } else {
            let state = SessionState(
                id: id,
                cwd: cwd,
                status: .running,
                startedAt: now(),
                lastActivityAt: now(),
                transcriptPath: transcriptPath,
                lastTool: nil,
                lastNotification: nil,
                autoAllowUntil: nil,
                alias: resolvedAlias
            )
            sessions[id] = state
            broadcast(.sessionUpsert(state))
            Log.session.notice("new session=\(id, privacy: .public) cwd=\(cwd, privacy: .public)")
            applyPendingTrust(sessionID: id, cwd: cwd)
        }
    }

    /// 若 cwd 有持久化信任 → 走标准 setAutoAllow* 路径(广播 / 调度 expiry / 重写持久层都自洽)。
    /// time-boxed 用"剩余整分钟"近似,精度损失最多 60s,UX 可接受。
    private func applyPendingTrust(sessionID: String, cwd: String) {
        guard let mode = pendingTrustsByCwd[cwd] else { return }
        switch mode {
        case .forever:
            Log.autoAllow.notice("restore forever session=\(sessionID, privacy: .public) cwd=\(cwd, privacy: .public)")
            setAutoAllowForever(sessionID: sessionID)
        case .until(let when):
            let remaining = max(1, Int(ceil(when.timeIntervalSince(now()) / 60)))
            Log.autoAllow.notice("restore time-boxed session=\(sessionID, privacy: .public) cwd=\(cwd, privacy: .public) minutes=\(remaining)")
            setAutoAllow(sessionID: sessionID, minutes: remaining)
        }
    }

    func touchSession(id: String, cwd: String? = nil, status: SessionStatus? = nil, tool: String? = nil, notification: String? = nil) {
        var s = sessions[id] ?? SessionState(
            id: id,
            cwd: cwd ?? "",
            status: .running,
            startedAt: now(),
            lastActivityAt: now(),
            transcriptPath: nil,
            lastTool: nil,
            lastNotification: nil,
            autoAllowUntil: nil,
            alias: aliasStore.get(cwd: cwd ?? "")
        )
        if let cwd { s.cwd = cwd }
        if let status { s.status = status }
        if let tool { s.lastTool = tool }
        if let notification { s.lastNotification = notification }
        s.lastActivityAt = now()
        sessions[id] = s
        broadcast(.sessionUpsert(s))
    }

    func markSessionDone(id: String) {
        guard var s = sessions[id] else { return }
        // SessionEnd 比 turn-complete 优先级低 —— 整会话退出就别再弹"这个回合结束"。
        cancelPendingTurnComplete(sessionID: id)
        s.status = .done
        s.lastActivityAt = now()
        sessions[id] = s
        broadcast(.sessionUpsert(s))
        broadcast(.sessionFinished(s))

        // 10 秒后移除,给 UI 时间展示完成状态
        purgeTasks[id]?.cancel()
        purgeTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.delay(10 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.purgeSession(id: id)
        }
    }

    private func purgeSession(id: String) {
        purgeTasks.removeValue(forKey: id)
        guard sessions[id]?.status == .done else { return }
        sessions.removeValue(forKey: id)
        lastPrompts.removeValue(forKey: id)
        cancelPendingTurnComplete(sessionID: id)
        broadcast(.sessionRemove(id))
    }

    /// UserPromptSubmit hook —— 缓存 prompt 文本,Stop 时取出来塞进 turn-complete 通知。
    /// 同时把 session 设回 .running(用户刚提交,agent 即将处理)。
    /// 还要取消上一回合可能挂起的 turn-complete 通知 —— 用户已经开始下一句,旧的"完成提醒"过期了。
    func recordUserPrompt(sessionID: String, cwd: String?, prompt: String) {
        cancelPendingTurnComplete(sessionID: sessionID)
        lastPrompts[sessionID] = prompt
        touchSession(id: sessionID, cwd: cwd, status: .running)
        Log.session.info("user-prompt session=\(sessionID, privacy: .public) len=\(prompt.count)")
    }

    /// Stop hook —— 一个对话回合"看起来"完成。状态立即设 .idle 让 UI 反应,但 turn-complete
    /// 事件做防抖:Claude Code 文档没明确说 Stop 只 fire 一次(实证上 agentic 续写 / extended
    /// thinking / 工具间歇 都可能引起多次或过早 fire)。debounce 内若再来一笔 PreToolUse、
    /// 新 UserPromptSubmit、或下一次 Stop,都会取消挂起的广播,只在"真安静一段时间"才弹。
    ///
    /// debounce=0(测试默认)或 prompt=nil 时立即广播 + 不调度 task,行为等同旧版 / 跳过本次。
    /// session 保留(下个回合复用),不调度 purge。
    func markTurnComplete(sessionID: String, cwd: String?) {
        touchSession(id: sessionID, cwd: cwd, status: .idle)
        guard sessions[sessionID] != nil else { return }
        Log.session.info("turn-complete schedule session=\(sessionID, privacy: .public) debounce-ns=\(self.turnCompleteDebounceNanos)")

        if turnCompleteDebounceNanos == 0 {
            fireTurnComplete(sessionID: sessionID)
            return
        }

        pendingTurnCompleteTasks[sessionID]?.cancel()
        pendingTurnCompleteTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.delay(self.turnCompleteDebounceNanos)
            guard !Task.isCancelled else { return }
            await self.fireTurnComplete(sessionID: sessionID)
        }
    }

    /// 真正广播 turn-complete 事件。消费 lastPrompts(防止下次无 prompt 的 Stop 误用旧 prompt)。
    /// 由 markTurnComplete 直接调(debounce=0)或 debounce task 在静默期满后调。
    private func fireTurnComplete(sessionID: String) {
        pendingTurnCompleteTasks.removeValue(forKey: sessionID)
        guard let s = sessions[sessionID] else { return }
        let p = lastPrompts.removeValue(forKey: sessionID)
        Log.session.info("turn-complete fire session=\(sessionID, privacy: .public) has-prompt=\(p != nil) len=\(p?.count ?? 0)")
        broadcast(.turnComplete(session: s, prompt: p))
    }

    /// agent "又活了" —— PreToolUse 或新 UserPromptSubmit 期间调用,把挂起的 turn-complete 收回。
    private func cancelPendingTurnComplete(sessionID: String) {
        pendingTurnCompleteTasks[sessionID]?.cancel()
        pendingTurnCompleteTasks.removeValue(forKey: sessionID)
    }

    func allSessions() -> [SessionState] {
        Array(sessions.values).sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Approval

    /// 挂起等待 UI 决策,永远不自动 deny。若 app 卡死或被 Quit,hook wrapper 的 curl 超时会触发 `ask` fallback,
    /// 走 Claude Code 原生 TUI 弹窗,不阻断使用。
    /// 若该 session 已被永久信任、或在未过期的 auto-allow window 内,直接返回 `.allow`,不挂起、不广播审批请求。
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        // 工具调用进来 = agent 还在工作 → 取消任何挂起的 turn-complete 通知,等真稳定再弹。
        cancelPendingTurnComplete(sessionID: request.sessionId)

        if let s = sessions[request.sessionId], s.hasActiveTrust(now: now()) {
            touchSession(id: request.sessionId, cwd: request.cwd, status: .running, tool: request.toolName)
            Log.autoAllow.info("hit session=\(request.sessionId, privacy: .public) tool=\(request.toolName, privacy: .public) forever=\(s.autoAllowForever)")
            return .allow
        }

        let missReason = sessions[request.sessionId]?.autoAllowUntil == nil ? "not-set" : "expired"
        Log.autoAllow.info("miss session=\(request.sessionId, privacy: .public) tool=\(request.toolName, privacy: .public) reason=\(missReason, privacy: .public)")

        pendingApprovals[request.id] = request
        touchSession(id: request.sessionId, cwd: request.cwd, status: .waitingApproval, tool: request.toolName)
        broadcast(.approvalAdd(request))

        return await withCheckedContinuation { cont in
            pendingContinuations[request.id] = cont
        }
    }

    func resolveApproval(id: String, decision: ApprovalDecision, reason: String? = nil, trustMinutes: Int? = nil, trustForever: Bool = false) {
        let sessionID = pendingApprovals[id]?.sessionId
        guard let cont = pendingContinuations.removeValue(forKey: id) else { return }
        pendingApprovals.removeValue(forKey: id)
        cont.resume(returning: decision)
        broadcast(.approvalResolve(id))
        if let sessionID {
            touchSession(id: sessionID, status: .running)
        }
        if decision == .allow, let sid = sessionID {
            if trustForever {
                setAutoAllowForever(sessionID: sid)
            } else if let minutes = trustMinutes, minutes > 0 {
                setAutoAllow(sessionID: sid, minutes: minutes)
            }
        }
    }

    // MARK: Auto-allow grants

    func setAutoAllow(sessionID: String, minutes: Int) {
        guard minutes > 0 else { return }
        let until = now().addingTimeInterval(TimeInterval(minutes * 60))
        guard var s = sessions[sessionID] else {
            Log.autoAllow.error("set dropped: session=\(sessionID, privacy: .public) not found")
            return
        }
        s.autoAllowUntil = until
        // 显式 time-boxed grant 覆盖 forever —— 用户最后一次操作为准
        s.autoAllowForever = false
        sessions[sessionID] = s
        broadcast(.sessionUpsert(s))
        broadcast(.autoAllowSet(sessionId: sessionID, until: until))
        Log.autoAllow.notice("set session=\(sessionID, privacy: .public) minutes=\(minutes) until=\(until.timeIntervalSince1970)")
        // producer 直接上报 authoritative minutes —— 不从 Dashboard 端反推 until→minutes(可能 off-by-one)
        Telemetry.track(.autoAllowSet, [.minutes: minutes])

        // 持久化 —— cwd 维度,下次重启或同 cwd 新 session 自动套用。
        // 空 cwd 保护在 TrustStore 内部完成。同时更新内存里的 pendingTrustsByCwd
        // 避免 set→clear→set 的快速重复操作里启动时 cache 旧值。
        trustStore.setUntil(cwd: s.cwd, until: until, savedAt: now())
        pendingTrustsByCwd[s.cwd] = .until(until)

        drainPendingApprovals(forSession: sessionID)

        autoAllowExpireTasks[sessionID]?.cancel()
        autoAllowExpireTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.delay(UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.clearAutoAllow(sessionID: sessionID, reason: "expired")
        }
    }

    /// 永久信任。和 setAutoAllow 共享 drain pending + broadcast 语义,但不调度 expiry。
    /// 同时清空已存在的 time-boxed 窗口,避免到期 task 误触 `clearAutoAllow` 把 forever 一起抹掉。
    func setAutoAllowForever(sessionID: String) {
        guard var s = sessions[sessionID] else {
            Log.autoAllow.error("set forever dropped: session=\(sessionID, privacy: .public) not found")
            return
        }
        // 取消可能挂着的 time-boxed expiry —— 否则它将来 fire 会误清掉 forever
        autoAllowExpireTasks[sessionID]?.cancel()
        autoAllowExpireTasks.removeValue(forKey: sessionID)

        s.autoAllowForever = true
        s.autoAllowUntil = nil
        sessions[sessionID] = s
        broadcast(.sessionUpsert(s))
        broadcast(.autoAllowForeverSet(sessionId: sessionID))
        Log.autoAllow.notice("set forever session=\(sessionID, privacy: .public)")
        Telemetry.track(.autoAllowForeverSet)

        trustStore.setForever(cwd: s.cwd, savedAt: now())
        pendingTrustsByCwd[s.cwd] = .forever

        drainPendingApprovals(forSession: sessionID)
    }

    /// "开窗之前"这一刻还挂着的同 session pending 审批,和窗口内未来的调用同等对待 —— 一并 allow。
    /// 不 resume 的话用户会体验到"我已经点了信任,为啥卡着那笔还要手动同意一次"。
    private func drainPendingApprovals(forSession sessionID: String) {
        let drained = pendingApprovals.filter { $0.value.sessionId == sessionID }.keys
        for id in drained {
            guard let cont = pendingContinuations.removeValue(forKey: id) else { continue }
            pendingApprovals.removeValue(forKey: id)
            cont.resume(returning: .allow)
            broadcast(.approvalResolve(id))
        }
        if !drained.isEmpty {
            touchSession(id: sessionID, status: .running)
            Log.autoAllow.notice("drained \(drained.count) pending approval(s) session=\(sessionID, privacy: .public)")
        }
    }

    func clearAutoAllow(sessionID: String, reason: String = "manual") {
        autoAllowExpireTasks[sessionID]?.cancel()
        autoAllowExpireTasks.removeValue(forKey: sessionID)
        guard var s = sessions[sessionID], (s.autoAllowUntil != nil || s.autoAllowForever) else { return }
        Log.autoAllow.notice("clear session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public) forever=\(s.autoAllowForever)")
        s.autoAllowUntil = nil
        s.autoAllowForever = false
        sessions[sessionID] = s
        broadcast(.sessionUpsert(s))
        broadcast(.autoAllowCleared(sessionId: sessionID))

        // 用户主动取消、或时间窗到期 —— 都从持久层清掉。下次重启 / 新 session 不再恢复。
        trustStore.clear(cwd: s.cwd)
        pendingTrustsByCwd.removeValue(forKey: s.cwd)
    }

    func allApprovals() -> [ApprovalRequest] {
        Array(pendingApprovals.values).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Alias

    /// 按 cwd 存 alias。同一 cwd 下所有 session 一并更新 —— cwd-binding 的语义,
    /// 换言之:重命名"这个项目",不是重命名"这个 pid"。
    /// alias 为 nil 或空串 → 清除。AliasStore 内部做 trim / 截长。
    func setSessionAlias(cwd: String, alias: String?) {
        guard !cwd.isEmpty else { return }
        aliasStore.set(cwd: cwd, alias: alias)
        let resolved = aliasStore.get(cwd: cwd)   // 让 trim / empty→nil 的规范化在 AliasStore 收敛

        for (id, var s) in sessions where s.cwd == cwd {
            s.alias = resolved
            sessions[id] = s
            broadcast(.sessionUpsert(s))
            broadcast(.sessionAliasChanged(sessionId: id, alias: resolved))
        }
        Telemetry.track(.sessionRenamed, [.cleared: resolved == nil ? 1 : 0])
    }

    /// HTTP / UI 层入口:给 sessionId,内部查到 cwd 再走 cwd-binding 语义。
    /// session 已 purge(10s grace 过了)→ 静默 no-op。
    func setSessionAliasById(sessionID: String, alias: String?) {
        guard let cwd = sessions[sessionID]?.cwd else { return }
        setSessionAlias(cwd: cwd, alias: alias)
    }

    // MARK: Event stream (WebSocket subscribers)

    func subscribe() -> AsyncStream<DashboardEvent> {
        let (stream, continuation) = AsyncStream<DashboardEvent>.makeStream()
        let id = UUID()
        eventStreams[id] = continuation

        let snapshot = DashboardEvent.snapshot(
            sessions: Array(sessions.values).sorted { $0.startedAt > $1.startedAt },
            approvals: Array(pendingApprovals.values).sorted { $0.createdAt < $1.createdAt }
        )
        continuation.yield(snapshot)

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.unsubscribe(id: id)
            }
        }

        return stream
    }

    private func unsubscribe(id: UUID) {
        eventStreams.removeValue(forKey: id)
    }

    private func broadcast(_ event: DashboardEvent) {
        for cont in eventStreams.values {
            cont.yield(event)
        }
    }
}
