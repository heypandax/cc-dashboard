import Foundation
@testable import CCDashboard

/// 隔离的 UserDefaults —— 避免测试污染用户 `.standard`。每次调用唯一 suite。
/// 测试本地命令行运行时,旧 suite 文件会留在 `~/Library/Preferences/` 但名字 UUID 化,
/// 不与正常使用冲突;CI 环境用临时 home,自然清理。
func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "cc-dashboard.test.\(UUID().uuidString)")!
}

/// 测试默认的 SessionStore —— 注入隔离的 AliasStore + TrustStore,所有持久化都不落 `.standard`。
/// turn-complete debounce 默认 0:让大部分非 Clock 测试保持立即广播语义。需要测 debounce
/// 行为时用完整初始化器直接构造,传入 TestScheduler 推虚拟时钟。
func makeStore() -> SessionStore {
    SessionStore(
        aliasStore: AliasStore(defaults: isolatedDefaults()),
        trustStore: TrustStore(defaults: isolatedDefaults()),
        turnCompleteDebounceSeconds: 0
    )
}

/// 等待 `SessionStore` 里某个 approval 入队。最多 `timeoutMs` 毫秒(默认 3000)。
/// 返回第一个 approval 的 id;超时返回 nil(调用方用 `XCTUnwrap` 失败测试)。
///
/// 取代 `try await Task.sleep(nanoseconds: 50_000_000)` + `allApprovals()` 的固定 sleep 模式 ——
/// poll 在 CI / 慢机器上更 robust。
func pollForApproval(store: SessionStore, timeoutMs: Int = 3000) async -> String? {
    let start = Date()
    while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
        let approvals = await store.allApprovals()
        if let first = approvals.first { return first.id }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
}
