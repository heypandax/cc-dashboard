import Foundation
@testable import CCDashboard

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
