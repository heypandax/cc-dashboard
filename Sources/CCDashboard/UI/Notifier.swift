import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var authorized = false

    override init() {
        super.init()
        // 必须设 delegate 才能拦截通知点击 —— 否则走默认行为(激活 cc-dashboard)。
        center.delegate = self
    }

    func requestAuthorization() async {
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            authorized = false
        }
    }

    func notifyApproval(_ approval: ApprovalRequest) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Claude Code · Approval needed")
        content.subtitle = approval.toolName
        content.body = approval.summaryLine
        content.sound = .default
        content.userInfo = ["action": "openDashboard"]   // 审批在 cc-dashboard 里操作

        let request = UNNotificationRequest(
            identifier: "approval-\(approval.id)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// Stop hook 触发的"单回合完成"通知。subtitle 给 session 上下文(alias + folder),body 是
    /// 用户 prompt 截断版 —— 长 prompt 折成 ~140 字符 + …,因为 macOS 横幅可视区就那么多,
    /// 通知中心面板可以滚动看全文。identifier 带 UUID 后缀,后续回合不覆盖前一条(同 session
    /// 跨回合用户能看到历史完成记录)。
    ///
    /// `prompt == nil` 时不弹 —— 没有用户上下文的"完成"提醒纯噪音(Claude 偶尔在
    /// session 启动 / resume 时 fire Stop 而没有 UserPromptSubmit)。
    func notifyTurnComplete(_ session: SessionState, prompt: String?) {
        guard authorized else { return }
        guard let prompt, !prompt.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Claude Code · Reply ready")
        let folder = URL(fileURLWithPath: session.cwd).lastPathComponent
        let name = (session.alias?.isEmpty == false) ? session.alias! : String(session.id.prefix(8))
        content.subtitle = "\(name) — \(folder)"
        content.body = Self.foldedPrompt(prompt)
        content.sound = .default
        // 点击跳到该会话对应的 Ghostty tab(按 cwd 匹配 terminal 的 working directory)。
        content.userInfo = ["action": "focusTab", "cwd": session.cwd]

        let request = UNNotificationRequest(
            identifier: "turn-complete-\(session.id)-\(UUID().uuidString.prefix(8))",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// 多行 prompt 折成单行(NSUserNotification 横幅按字符宽度截,换行不直观);超长尾部加 ….
    nonisolated static func foldedPrompt(_ s: String, maxLen: Int = 140) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxLen { return collapsed }
        return String(collapsed.prefix(maxLen - 1)) + "…"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 通知点击分流:turn-complete → 跳对应 Ghostty tab;其余(审批)→ 打开 cc-dashboard。
    /// 协议方法是 nonisolated,先提取 Sendable 值(action / cwd 字符串)再 hop 到 MainActor。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = info["action"] as? String
        let cwd = info["cwd"] as? String
        Task { @MainActor in
            switch action {
            case "focusTab":
                if let cwd { GhosttyLauncher.focusTab(cwd: cwd) }
            default:
                AppState.shared.statusBar.openMainWindow()
            }
        }
        completionHandler()
    }

    /// app 在前台时也展示横幅 —— 设了 delegate 后不实现这个,前台通知会被系统吞掉。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
