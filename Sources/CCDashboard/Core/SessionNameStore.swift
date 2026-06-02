import Foundation

/// sessionId → 用户自定义会话名。会话总览里给"这次会话"起名,用于区分同一 worktree 下的多次会话。
///
/// 为什么键 sessionId 而非 cwd(与 `AliasStore` 相反):AliasStore 是项目级("这个项目叫 X"),
/// 键 cwd;这里是会话级("这次会话叫 Y")。历史会话的 sessionId 固定(= jsonl 文件名),做会话级
/// key 稳定可靠 —— 这点和实时会话不同(那里 sessionId 每次启动都变,故 AliasStore 才避开它)。
struct SessionNameStore: @unchecked Sendable {
    private static let key = "sessionNames"
    private static let maxLength = 64

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

    func get(id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return load()[id]
    }

    /// name 为 nil / 空串 / 纯空白 → 删除该条。非空时 trim + 单行化 + 截断 `maxLength`。
    func set(id: String, name: String?) {
        guard !id.isEmpty else { return }
        var dict = load()
        if let raw = name {
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            let truncated = String(cleaned.prefix(Self.maxLength))
            if truncated.isEmpty { dict.removeValue(forKey: id) }
            else { dict[id] = truncated }
        } else {
            dict.removeValue(forKey: id)
        }
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
