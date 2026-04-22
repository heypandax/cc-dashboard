import Foundation

/// 静默、幂等的 Claude Code hooks 安装器。
///
/// 启动时后台触发 `installIfNeeded()`:
/// - hook 脚本装到固定目录 `~/Library/Application Support/cc-dashboard/hooks/`
///   (不受 app bundle 移动影响 —— settings.json 里的路径是稳定的)
/// - `~/.claude/settings.json` 存在 → merge(保留现有 hooks 和其他字段)
/// - 已装 → 只同步脚本文件,不改 settings.json
/// - settings.json 不存在 / JSON 损坏 / 其他 IO 错误 → log 到 stderr,静默跳过
struct HooksInstaller {
    let installDir: URL
    let settingsPath: String
    /// nil 时从 `Bundle.main.resourceURL/hooks/` 取脚本。测试可注入临时目录。
    let bundledHooksDir: URL?

    static let `default`: HooksInstaller = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cc-dashboard", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let settings = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        return HooksInstaller(installDir: dir, settingsPath: settings, bundledHooksDir: nil)
    }()

    var pretoolPath: String { installDir.appendingPathComponent("pretool.sh").path }
    var lifecyclePath: String { installDir.appendingPathComponent("lifecycle.sh").path }

    /// 启动时后台调用。任何失败都只 log 不抛出。
    static func installIfNeeded() { Self.default.installIfNeeded() }

    func installIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath) else {
            Self.log("settings.json not found at \(settingsPath); skipping (run Claude Code once to create it)")
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
            var root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]

            // 脚本文件每次启动都同步一次(app 版本升级后会带更新的脚本)
            try syncBundledHooks()

            if isAlreadyInstalled(hooks: hooks) {
                return
            }

            let backup = backupPath()
            try fm.copyItem(atPath: settingsPath, toPath: backup)

            stripCCDashboard(&hooks)
            appendCCDashboard(&hooks)

            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }

            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            Self.log("installed; backup at \(backup)")
        } catch {
            Self.log("install failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Detect

    /// 写入 settings.json 时使用的 command 字符串。路径带空格,必须 shell-quote,
    /// 否则 Claude Code 的 `/bin/sh -c <command>` 执行时会按空格 split。
    private var pretoolCommand: String { Self.shellQuote(pretoolPath) }

    private func lifecycleCommand(_ subcommand: String) -> String {
        "\(Self.shellQuote(lifecyclePath)) \(subcommand)"
    }

    private func isAlreadyInstalled(hooks: [String: Any]) -> Bool {
        let pretools = (hooks["PreToolUse"] as? [[String: Any]]) ?? []
        let commands = pretools.flatMap { entry -> [String] in
            let inner = (entry["hooks"] as? [[String: Any]]) ?? []
            return inner.compactMap { $0["command"] as? String }
        }
        // 严格匹配 quoted 形式:unquoted 的会被 isCCDashboardCommand 识别为 legacy 清理并重装
        return commands.contains(pretoolCommand)
    }

    // MARK: - File sync

    private func syncBundledHooks() throws {
        let bundled: URL
        if let injected = bundledHooksDir,
           FileManager.default.fileExists(atPath: injected.path) {
            bundled = injected
        } else if let res = Bundle.main.resourceURL?
                    .appendingPathComponent("hooks", isDirectory: true),
                  FileManager.default.fileExists(atPath: res.path) {
            bundled = res
        } else {
            throw NSError(
                domain: "HooksInstaller", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bundled hooks directory not found in app Resources"]
            )
        }
        let fm = FileManager.default
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)

        for name in ["pretool.sh", "lifecycle.sh"] {
            let src = bundled.appendingPathComponent(name)
            let dst = installDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
    }

    // MARK: - Settings manipulation

    /// 删掉所有指向 cc-dashboard 脚本的 hook entries(包括 legacy 路径)。
    /// 保留用户其他 hook 配置不动。
    private func stripCCDashboard(_ hooks: inout [String: Any]) {
        for event in Array(hooks.keys) {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            for idx in entries.indices {
                guard var inner = entries[idx]["hooks"] as? [[String: Any]] else { continue }
                inner.removeAll { h in
                    guard let cmd = h["command"] as? String else { return false }
                    return isCCDashboardCommand(cmd)
                }
                entries[idx]["hooks"] = inner
            }
            entries.removeAll { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).isEmpty
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
    }

    private func isCCDashboardCommand(_ cmd: String) -> Bool {
        // 当前 Application Support 路径(quoted / unquoted 两种都清掉)
        if cmd == pretoolPath || cmd == pretoolCommand { return true }
        if cmd.hasPrefix(lifecyclePath + " ") { return true }
        if cmd.hasPrefix(Self.shellQuote(lifecyclePath) + " ") { return true }
        // Legacy: 旧版 shell 脚本装到 git clone 目录里的(pretool.sh / pretool.sh')
        if Self.script(from: cmd).hasSuffix("/hooks/pretool.sh") && cmd.contains("cc-dashboard") { return true }
        if Self.script(from: cmd).hasSuffix("/hooks/lifecycle.sh") && cmd.contains("cc-dashboard") { return true }
        return false
    }

    /// 从 "command arg1 arg2" 或 "'quoted path' arg1" 中抽出脚本路径。
    private static func script(from cmd: String) -> String {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("'") {
            let rest = trimmed.dropFirst()
            if let end = rest.firstIndex(of: "'") { return String(rest[..<end]) }
        }
        if trimmed.hasPrefix("\"") {
            let rest = trimmed.dropFirst()
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        if let space = trimmed.firstIndex(of: " ") {
            return String(trimmed[..<space])
        }
        return trimmed
    }

    /// 用单引号把路径包起来。路径里极少出现 `'`,但按 POSIX 规则用 `'\''` 转义以防万一。
    private static func shellQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appendCCDashboard(_ hooks: inout [String: Any]) {
        appendHook(&hooks, event: "PreToolUse",
                   matcher: "Bash|Edit|Write|MultiEdit|WebFetch",
                   command: pretoolCommand, timeout: 605)
        appendHook(&hooks, event: "SessionStart", matcher: nil,
                   command: lifecycleCommand("session-start"), timeout: 10)
        appendHook(&hooks, event: "Stop", matcher: nil,
                   command: lifecycleCommand("stop"), timeout: 10)
        appendHook(&hooks, event: "SessionEnd", matcher: nil,
                   command: lifecycleCommand("session-end"), timeout: 10)
        appendHook(&hooks, event: "Notification", matcher: nil,
                   command: lifecycleCommand("notification"), timeout: 10)
    }

    private func appendHook(
        _ hooks: inout [String: Any],
        event: String, matcher: String?,
        command: String, timeout: Int
    ) {
        let hookDict: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": timeout,
        ]
        var entry: [String: Any] = ["hooks": [hookDict]]
        if let matcher { entry["matcher"] = matcher }

        var list = (hooks[event] as? [[String: Any]]) ?? []
        list.append(entry)
        hooks[event] = list
    }

    // MARK: - Utils

    private func backupPath() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(settingsPath).bak.\(f.string(from: Date()))"
    }

    private static func log(_ msg: String) {
        print("[cc-dashboard hooks] \(msg)")
    }
}
