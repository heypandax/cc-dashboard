import AppKit
import Foundation
import Observation
import SwiftUI

/// UI ViewModel。桥接 actor 状态到 SwiftUI。MainActor 保证所有 UI 读写都在主线程。
@Observable
@MainActor
final class Dashboard {
    let store: SessionStore
    private let server: DashboardHTTPServer
    private let notifier = Notifier()

    var sessions: [SessionState] = []
    var approvals: [ApprovalRequest] = []
    var serverError: String?

    init() {
        let store = SessionStore()
        self.store = store
        self.server = DashboardHTTPServer(store: store)

        let srv = server
        Task.detached {
            // 无论 server return 还是 throw 都视作异常 —— 我们期望它一直跑。
            let reason: String
            do {
                try await srv.run()
                reason = "server exited unexpectedly"
            } catch {
                reason = "server error: \(error)"
                Telemetry.recordError(error, phase: "http_server")
            }
            await MainActor.run {
                print("[cc-dashboard] \(reason), quitting app")
                NSApplication.shared.terminate(nil)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.notifier.requestAuthorization()
        }

        // 首次启动静默安装 Claude Code hooks(已装 → 只同步脚本,不改 settings.json)
        Task.detached(priority: .utility) {
            HooksInstaller.installIfNeeded()
        }

        Task { [weak self] in
            guard let self else { return }
            let stream = await self.store.subscribe()
            for await event in stream {
                self.apply(event: event)
            }
        }
    }

    func apply(event: DashboardEvent) {
        switch event {
        case .snapshot(let s, let a):
            self.sessions = s
            self.approvals = a
        case .sessionUpsert(let s):
            if let idx = sessions.firstIndex(where: { $0.id == s.id }) {
                sessions[idx] = s
            } else {
                sessions.insert(s, at: 0)
            }
        case .sessionRemove(let id):
            withAnimation(.easeOut(duration: 0.25)) {
                sessions.removeAll { $0.id == id }
            }
        case .sessionFinished:
            break  // 整会话退出本身不弹横幅 —— 噪音。需要"完成感"通知请走 .turnComplete(每回合一条)。
        case .turnComplete(let s, let prompt):
            notifier.notifyTurnComplete(s, prompt: prompt)
        case .approvalAdd(let a):
            withAnimation(.easeIn(duration: 0.2)) {
                approvals.append(a)
            }
            notifier.notifyApproval(a)
            Telemetry.track(.approvalShown, approvalParams(a))
        case .approvalResolve(let id):
            withAnimation(.easeOut(duration: 0.2)) {
                approvals.removeAll { $0.id == id }
            }
        case .autoAllowSet:
            break  // 埋点由 SessionStore 在 setAutoAllow 处上报(有 authoritative minutes);
                   // session 的 autoAllowUntil 字段已通过 sessionUpsert 同步,UI 自动 react。
        case .autoAllowForeverSet:
            break  // 同上 —— forever 标志走 sessionUpsert,埋点在 store 侧。
        case .autoAllowCleared:
            break
        case .sessionAliasChanged:
            break  // alias 已随 sessionUpsert 更新。这个 case 留作 test 断言锚点 + 未来 UI flash 挂钩。
        }
    }

    func decide(approvalID: String, decision: ApprovalDecision, trustMinutes: Int? = nil, customTrust: Bool = false, trustForever: Bool = false) {
        // store.resolveApproval 是幂等的 —— UI entry 已消失也继续调(比如快速双击)
        if let a = approvals.first(where: { $0.id == approvalID }) {
            Telemetry.track(.approvalDecided, approvalParams(a).merging([
                .decision:     decision.rawValue,
                .trustMinutes: trustMinutes ?? 0,
                .customTrust:  customTrust ? 1 : 0,
                .trustForever: trustForever ? 1 : 0,
            ]) { $1 })
        }
        Task { await store.resolveApproval(id: approvalID, decision: decision, trustMinutes: trustMinutes, trustForever: trustForever) }
    }

    /// tool + risk 两个字段在 approval_shown 和 approval_decided 两个事件里都要。
    private func approvalParams(_ a: ApprovalRequest) -> [Telemetry.Key: Any] {
        [
            .tool: a.toolName,
            .risk: riskLevel(for: a).rawValue,
        ]
    }

    func trustSession(sessionID: String, minutes: Int) {
        Task { await store.setAutoAllow(sessionID: sessionID, minutes: minutes) }
    }

    func trustSessionForever(sessionID: String) {
        Task { await store.setAutoAllowForever(sessionID: sessionID) }
    }

    func clearTrust(sessionID: String) {
        Task { await store.clearAutoAllow(sessionID: sessionID) }
    }

    /// Optimistic UI:先本地更新,actor broadcast 回来再 idempotent 覆盖。
    /// Telemetry 在 store 侧唯一上报(HTTP + UI 两条路径都经过 setSessionAlias)。
    func renameSession(sessionID: String, alias: String?) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].alias = alias
        }
        Task { await store.setSessionAliasById(sessionID: sessionID, alias: alias) }
    }

    /// Sidebar / ApprovalCard / MenuBar 共用:alias 优先,否则回落到 sessionId 前 8 位 hex。
    /// 用户自己命名的 alias 才有产品价值,自动生成的昵称已评估为噪音。
    func displayName(forSessionID id: String) -> String {
        if let alias = sessions.first(where: { $0.id == id })?.alias, !alias.isEmpty {
            return alias
        }
        return String(id.prefix(8))
    }

    func allowAll() {
        let ids = approvals.map(\.id)
        Telemetry.track(.allowAllUsed, [.count: ids.count])
        Task {
            for id in ids {
                await store.resolveApproval(id: id, decision: .allow, reason: "batch allow all")
            }
        }
    }

    var activeSessionCount: Int {
        sessions.filter { $0.status != .done }.count
    }

    var hasActiveAutoAllow: Bool {
        let now = Date()
        return sessions.contains { $0.hasActiveTrust(now: now) }
    }

    /// 按 status 优先级 + 启动时间排:waitingApproval > running > idle > done > error,
    /// 同 bucket 内越新的排越前。让需要操作的 session 自动浮到顶上。
    var sortedSessions: [SessionState] {
        sessions.sorted { a, b in
            let pa = statusPriority(a.status), pb = statusPriority(b.status)
            if pa != pb { return pa < pb }
            return a.startedAt > b.startedAt
        }
    }

    private func statusPriority(_ s: SessionStatus) -> Int {
        switch s {
        case .waitingApproval: return 0
        case .running:         return 1
        case .idle:            return 2
        case .done:            return 3
        case .error:           return 4
        }
    }
}
