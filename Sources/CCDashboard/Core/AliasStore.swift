import Foundation

/// cwd → alias 的小型持久仓库。SessionStore 通过注入持有一个 instance,测试用
/// `UserDefaults(suiteName:)` 隔离。
///
/// 为什么键 cwd 不键 sessionId:sessionId 每次 claude 启动都变,但 cwd 在同一 repo 内稳定,
/// 用户的意图是"这个项目叫 X",不是"这个 pid 叫 X"。代价:同一目录下多个并发 session
/// 会共享 alias(见 CLAUDE.md / plan 中的 Risks 条目)。
/// @unchecked Sendable:UserDefaults 在 Apple 文档里明确是线程安全的,但 Foundation 没给它加
/// Sendable 标注。我们只在 init 里存一次、后续只读字面量 key,没有其他共享可变状态,所以
/// 把这层"未声明"的契约接过来是安全的。
struct AliasStore: @unchecked Sendable {
    private static let key = "sessionAliases"
    private static let maxAliasLength = 64

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: String] {
        guard let data = defaults.data(forKey: Self.key),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    /// 空 cwd 总是返回 nil —— 避免空串把一堆 zombie session 绑到同一 alias。
    func get(cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        return load()[cwd]
    }

    /// alias 为 nil / 空串 → 删除该 cwd entry。非空时 trim whitespace+newlines 并截 `maxAliasLength`。
    /// cwd 为空直接忽略。持久化失败(磁盘满)静默吞异常,下次 load() 还能读到上次成功的值。
    func set(cwd: String, alias: String?) {
        guard !cwd.isEmpty else { return }
        var dict = load()
        if let raw = alias {
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            let truncated = String(cleaned.prefix(Self.maxAliasLength))
            if truncated.isEmpty {
                dict.removeValue(forKey: cwd)
            } else {
                dict[cwd] = truncated
            }
        } else {
            dict.removeValue(forKey: cwd)
        }
        save(dict)
    }

    private func save(_ dict: [String: String]) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
