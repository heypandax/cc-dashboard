import Foundation

/// 并发安全的状态中心。hook handlers 在 non-isolated 执行器上跑,UI 在 MainActor,通过这个 actor 串行化访问。
actor SessionStore {
    private var sessions: [String: SessionState] = [:]
    private var pendingApprovals: [String: ApprovalRequest] = [:]
    private var pendingContinuations: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var eventStreams: [UUID: AsyncStream<DashboardEvent>.Continuation] = [:]
    private var autoAllowExpireTasks: [String: Task<Void, Never>] = [:]
    private var purgeTasks: [String: Task<Void, Never>] = [:]

    /// 测试可注入的时间源与延迟函数。生产走默认值 —— `Date()` 和 `Task.sleep(nanoseconds:)`。
    /// 为什么不是 `Clock.sleep(for:)` / `Task.sleep(for:)`:见 fffadbc 的 crash fix,
    /// 后者在 macOS 26 cooperative pool 上触发 swift_task_dealloc abort。不要换。
    private let now: @Sendable () -> Date
    private let delay: @Sendable (UInt64) async -> Void
    private let aliasStore: AliasStore

    init(
        aliasStore: AliasStore = AliasStore(),
        now: @Sendable @escaping () -> Date = { Date() },
        delay: @Sendable @escaping (UInt64) async -> Void = { nanos in
            try? await Task.sleep(nanoseconds: nanos)
        }
    ) {
        self.aliasStore = aliasStore
        self.now = now
        self.delay = delay
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
            // 新建 session 时 autoAllowUntil 必然 nil —— 诊断"进程重启后 auto-allow 失效"的关键痕迹
            Log.session.notice("new session=\(id, privacy: .public) cwd=\(cwd, privacy: .public)")
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
        broadcast(.sessionRemove(id))
    }

    func allSessions() -> [SessionState] {
        Array(sessions.values).sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Approval

    /// 挂起等待 UI 决策,永远不自动 deny。若 app 卡死或被 Quit,hook wrapper 的 curl 超时会触发 `ask` fallback,
    /// 走 Claude Code 原生 TUI 弹窗,不阻断使用。
    /// 若该 session 有未过期的 auto-allow grant,直接返回 `.allow`,不挂起、不广播审批请求。
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        if let until = sessions[request.sessionId]?.autoAllowUntil, until > now() {
            touchSession(id: request.sessionId, cwd: request.cwd, status: .running, tool: request.toolName)
            Log.autoAllow.info("hit session=\(request.sessionId, privacy: .public) tool=\(request.toolName, privacy: .public)")
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

    func resolveApproval(id: String, decision: ApprovalDecision, reason: String? = nil, trustMinutes: Int? = nil) {
        let sessionID = pendingApprovals[id]?.sessionId
        guard let cont = pendingContinuations.removeValue(forKey: id) else { return }
        pendingApprovals.removeValue(forKey: id)
        cont.resume(returning: decision)
        broadcast(.approvalResolve(id))
        if let sessionID {
            touchSession(id: sessionID, status: .running)
        }
        if decision == .allow, let minutes = trustMinutes, minutes > 0, let sid = sessionID {
            setAutoAllow(sessionID: sid, minutes: minutes)
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
        sessions[sessionID] = s
        broadcast(.sessionUpsert(s))
        broadcast(.autoAllowSet(sessionId: sessionID, until: until))
        Log.autoAllow.notice("set session=\(sessionID, privacy: .public) minutes=\(minutes) until=\(until.timeIntervalSince1970)")
        // producer 直接上报 authoritative minutes —— 不从 Dashboard 端反推 until→minutes(可能 off-by-one)
        Telemetry.track(.autoAllowSet, [.minutes: minutes])

        // "开窗之前"这一刻还挂着的同 session pending 审批,和窗口内未来的调用同等对待 —— 一并 allow。
        // 不 resume 的话用户会体验到"我已经点了信任,为啥卡着那笔还要手动同意一次"。
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

        autoAllowExpireTasks[sessionID]?.cancel()
        autoAllowExpireTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.delay(UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.clearAutoAllow(sessionID: sessionID, reason: "expired")
        }
    }

    func clearAutoAllow(sessionID: String, reason: String = "manual") {
        autoAllowExpireTasks[sessionID]?.cancel()
        autoAllowExpireTasks.removeValue(forKey: sessionID)
        guard var s = sessions[sessionID], s.autoAllowUntil != nil else { return }
        Log.autoAllow.notice("clear session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")
        s.autoAllowUntil = nil
        sessions[sessionID] = s
        broadcast(.sessionUpsert(s))
        broadcast(.autoAllowCleared(sessionId: sessionID))
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
