import Foundation
import UserNotifications

@MainActor
final class Notifier {
    private let center = UNUserNotificationCenter.current()
    private var authorized = false

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

        let request = UNNotificationRequest(
            identifier: "approval-\(approval.id)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func notifySessionDone(_ session: SessionState) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Claude Code · Session done")
        let folder = URL(fileURLWithPath: session.cwd).lastPathComponent
        let name = (session.alias?.isEmpty == false) ? session.alias! : String(session.id.prefix(8))
        content.body = "\(name) — \(folder)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "session-done-\(session.id)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
