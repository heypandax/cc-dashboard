import Foundation

/// 信任授权的持久层条目。`mode` 决定语义,`savedAt` 仅供诊断/历史(不参与失效判断)。
struct PersistedTrust: Codable, Sendable, Equatable {
    enum Mode: Codable, Sendable, Equatable {
        case forever
        case until(Date)
    }
    var mode: Mode
    var savedAt: Date
}

/// cwd → 信任模式 的持久仓库。沿用 AliasStore 的格式(JSON-encoded UserDefaults dict)。
///
/// 为什么键 cwd 不键 sessionId:sessionId 临时,跨重启就没了 —— 持久化必然得绑稳定锚点,
/// 项目目录就是用户脑子里"那个项目"的天然身份。代价同 alias:同一 cwd 下并发 session 共享信任。
///
/// 失效判断不在 store 里做 —— store 只是字典,SessionStore 用注入的 `now()` 闭包过滤,这样测试
/// 能用虚拟时钟跑 GC 行为。
///
/// `@unchecked Sendable`:UserDefaults Apple 文档明确线程安全但 Foundation 没标 Sendable。
/// 这里仅 init 写一次 + 后续只读字面量 key,无其他可变共享,与 AliasStore 同样契约。
struct TrustStore: @unchecked Sendable {
    private static let key = "trustsByCwd"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 全量取条目,不做时间过滤。SessionStore 启动时一次性消化:有效的套到新 session,
    /// 过期的调 `clear` 抹掉。
    func loadAll() -> [String: PersistedTrust] {
        guard let data = defaults.data(forKey: Self.key),
              let dict = try? JSONDecoder().decode([String: PersistedTrust].self, from: data)
        else { return [:] }
        return dict
    }

    func setForever(cwd: String, savedAt: Date = Date()) {
        guard !cwd.isEmpty else { return }
        var dict = loadAll()
        dict[cwd] = PersistedTrust(mode: .forever, savedAt: savedAt)
        save(dict)
    }

    func setUntil(cwd: String, until: Date, savedAt: Date = Date()) {
        guard !cwd.isEmpty else { return }
        var dict = loadAll()
        dict[cwd] = PersistedTrust(mode: .until(until), savedAt: savedAt)
        save(dict)
    }

    func clear(cwd: String) {
        guard !cwd.isEmpty else { return }
        var dict = loadAll()
        if dict.removeValue(forKey: cwd) != nil {
            save(dict)
        }
    }

    private func save(_ dict: [String: PersistedTrust]) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
