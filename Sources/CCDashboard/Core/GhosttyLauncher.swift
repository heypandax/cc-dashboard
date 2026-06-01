import AppKit
import Foundation

/// 把一次会话 resume / 一个目录,投送到 Ghostty。走 Ghostty 官方 AppleScript 接口
/// (见 `Ghostty.sdef`: `new tab` + `surface configuration` 的 initial working directory /
/// initial input),在用户当前窗口新开 tab、cd 到目标目录、自动执行命令 —— 契合"用 tab
/// 管理多会话"的工作流,且比模拟键盘稳定。Ghostty 未装或脚本失败 → 命令落剪贴板兜底,
/// 绝不静默失败。
enum GhosttyLauncher {
    static let bundleID = "com.mitchellh.ghostty"

    enum Outcome: Sendable {
        case launched
        case copiedToClipboard   // 兜底:命令已复制,需用户手动粘贴
    }

    @MainActor
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// 新 tab 内 resume 指定会话。`name` 透传给 `claude --name`,使终端标题 / picker 显示友好名。
    @MainActor
    @discardableResult
    static func resume(sessionID: String, cwd: String, name: String?) -> Outcome {
        var cmd = "claude --resume \(shellQuote(sessionID))"
        if let name, !name.isEmpty { cmd += " --name \(shellQuote(name))" }
        return run(inDirectory: cwd, command: cmd)
    }

    /// 新 tab 内只 cd 到目录,不跑 claude。
    @MainActor
    @discardableResult
    static func openDirectory(_ cwd: String) -> Outcome {
        run(inDirectory: cwd, command: nil)
    }

    @MainActor
    private static func run(inDirectory cwd: String, command: String?) -> Outcome {
        if isInstalled, let script = NSAppleScript(source: appleScript(cwd: cwd, command: command)) {
            var err: NSDictionary?
            script.executeAndReturnError(&err)
            if err == nil { return .launched }
            Log.lifecycle.error("ghostty applescript failed: \(String(describing: err), privacy: .public)")
        }
        return copyFallback(cwd: cwd, command: command)
    }

    /// surface configuration 的 initial input 末尾换行 = 回车执行;用 input 而非 command,
    /// 让 tab 保持常驻 shell(claude 退出后仍可继续用)。无窗口时兜底开新窗口。
    private static func appleScript(cwd: String, command: String?) -> String {
        let inputLine = command.map {
            "set initial input of cfg to \(quote($0 + "\n"))"
        } ?? ""
        return """
        tell application id "\(bundleID)"
            activate
            set cfg to new surface configuration
            set initial working directory of cfg to \(quote(cwd))
            \(inputLine)
            if (count of windows) > 0 then
                new tab in front window with configuration cfg
            else
                new window with configuration cfg
            end if
        end tell
        """
    }

    private static func copyFallback(cwd: String, command: String?) -> Outcome {
        let full = command.map { "cd \(shellQuote(cwd)) && \($0)" } ?? "cd \(shellQuote(cwd))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full, forType: .string)
        return .copiedToClipboard
    }

    // MARK: Quoting

    /// 包成 AppleScript 字符串字面量。先转义反斜杠再转义其余,换行 / 制表符转成 AppleScript
    /// 能解释的 `\n` / `\t` 文本(不能在源码里出现真实换行,会破坏字符串字面量)。
    private static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// 单引号包裹防 shell 注入 —— `name` 来自用户 alias,可能含空格 / 特殊字符。
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
