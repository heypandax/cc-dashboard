import AppKit
import SwiftUI

/// 纯 Circle 状态点,running/waitingApproval 有外扩 pulse 环。
/// `onChange(of: pulsing)` 保证状态切换(idle → running)时动画能重启/停止。
struct StatusDot: View {
    let status: SessionStatus
    @State private var pulse = false

    private var pulsing: Bool {
        status == .running || status == .waitingApproval
    }

    private var color: Color {
        switch status {
        case .running:         return CC.Status.running
        case .waitingApproval: return CC.Status.waiting
        case .idle:            return CC.Status.idle
        case .done:            return CC.Status.done
        case .error:           return CC.Status.error
        }
    }

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.5)
            }
            Circle().fill(color)
        }
        .frame(width: 8, height: 8)
        .onAppear(perform: restart)
        .onChange(of: pulsing) { _, _ in restart() }
    }

    private func restart() {
        pulse = false
        guard pulsing else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

/// Mint 胶囊 + 时钟 icon + mono countdown + × 取消 trust。
struct TrustBadge: View {
    let expiresAt: Date
    let onCancel: () -> Void
    @State private var now = Date()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .semibold))
            Text("auto \(remaining)")
                .font(CC.monoTiny.weight(.semibold).monospacedDigit())
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
            .buttonStyle(.plain)
            .help("Cancel auto-allow")
        }
        .foregroundStyle(CC.mintInk)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(CC.mint.opacity(0.18)))
        .overlay(Capsule().strokeBorder(CC.mint.opacity(0.45), lineWidth: 0.5))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
        }
    }

    private var remaining: String {
        let secs = max(0, Int(expiresAt.timeIntervalSince(now)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

/// 行标题:未编辑态 Text(alias 或 FriendlyName),双击进入编辑态 TextField。
/// editing 由 parent (SessionRow) 持有并以 Binding 下传 —— context menu "Rename…" 才能触发。
struct SessionNameField: View {
    let session: SessionState
    let dashboard: Dashboard
    @Binding var editing: Bool

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var displayName: String {
        if let alias = session.alias, !alias.isEmpty { return alias }
        return String(session.id.prefix(8))
    }

    /// 未 alias 时用 monospace 显示 hex id,和老版视觉一致;alias 后改成常规字体更像人话。
    private var font: Font {
        let hasAlias = (session.alias?.isEmpty == false)
        return hasAlias
            ? .system(size: 12, weight: .semibold)
            : .system(size: 12, weight: .semibold, design: .monospaced)
    }

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft, prompt: Text("Name this session"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }   // Esc
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused && editing {
                            // 失焦也提交。commit 本身幂等,和 onSubmit 的二次触发无副作用。
                            commit()
                        }
                    }
                    .onAppear {
                        draft = session.alias ?? ""
                        focused = true
                    }
            } else {
                Text(displayName)
                    .font(font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { editing = true }
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dashboard.renameSession(
            sessionID: session.id,
            alias: trimmed.isEmpty ? nil : trimmed
        )
        editing = false
    }

    private func cancel() { editing = false }
}

/// Row hover 时出现的小时钟按钮,点击弹 TrustPickerMenu —— 非审批路径直接给 session 开窗。
/// intro / footer 跟 approval 卡片里那一版不同:不是"允许这次 + 开窗",而是纯"开窗"。
struct RowTrustMenu: View {
    let onSelect: (Int) -> Void

    var body: some View {
        TrustPickerMenu(
            introCopy: "Start trust window",
            footerCopy: "During this window, all tool calls from this session auto-approve.",
            onSelect: onSelect
        )
    }
}

struct SessionRow: View {
    let session: SessionState
    let dashboard: Dashboard
    @State private var editing = false
    @State private var hovered = false
    @State private var trustPopoverOpen = false

    private var pendingCount: Int {
        dashboard.approvals.filter { $0.sessionId == session.id }.count
    }

    private var hasActiveTrust: Bool {
        (session.autoAllowUntil ?? .distantPast) > Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                StatusDot(status: session.status)
                SessionNameField(session: session, dashboard: dashboard, editing: $editing)
                if let until = session.autoAllowUntil, until > Date() {
                    TrustBadge(expiresAt: until) {
                        dashboard.clearTrust(sessionID: session.id)
                    }
                } else if hovered {
                    Button { trustPopoverOpen = true } label: {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CC.mintInk)
                    }
                    .buttonStyle(.plain)
                    .help("Start auto-trust window")
                    .popover(isPresented: $trustPopoverOpen, arrowEdge: .bottom) {
                        RowTrustMenu { mins in
                            dashboard.trustSession(sessionID: session.id, minutes: mins)
                            Telemetry.track(.trustFromRow, [.minutes: mins])
                            trustPopoverOpen = false
                        }
                    }
                }
                Spacer(minLength: 4)
                RelativeTimeText(date: session.lastActivityAt)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(session.cwd)
                .font(CC.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            HStack(spacing: 4) {
                Text("tool:")
                    .font(CC.monoTiny)
                    .foregroundStyle(.tertiary)
                Text(session.lastTool ?? "—")
                    .font(CC.monoTiny.weight(.medium))
                    .foregroundStyle(session.status == .waitingApproval ? CC.amberInk : Color.secondary)
                Spacer()
                if pendingCount > 0 {
                    Text("\(pendingCount) pending")
                        .font(CC.monoTiny.weight(.semibold))
                        .foregroundStyle(CC.amberInk)
                }
            }
        }
        .padding(.vertical, 3)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Rename…") { editing = true }
            Menu("Start trust window") {
                ForEach(trustMinuteOptions, id: \.self) { mins in
                    Button("Allow for \(mins) min") {
                        dashboard.trustSession(sessionID: session.id, minutes: mins)
                        Telemetry.track(.trustFromRow, [.minutes: mins])
                    }
                }
            }
            if hasActiveTrust {
                Button("Cancel auto-allow") {
                    dashboard.clearTrust(sessionID: session.id)
                }
            }
            Divider()
            Button("Copy session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
    }
}

struct SessionListView: View {
    let dashboard: Dashboard
    @Binding var selection: SessionState.ID?

    var body: some View {
        let sorted = dashboard.sortedSessions
        return VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    if sorted.isEmpty {
                        Text("No active sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sorted) { session in
                            SessionRow(session: session, dashboard: dashboard)
                                .tag(session.id)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Sessions")
                            .textCase(.uppercase)
                            .font(.system(size: 11, weight: .bold))
                            .kerning(0.8)
                            .foregroundStyle(.secondary)
                        Text("· \(dashboard.activeSessionCount)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
            }
            .listStyle(.sidebar)
            SidebarFooter(error: dashboard.serverError)
        }
    }
}

struct SidebarFooter: View {
    let error: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(error == nil ? CC.mint : CC.red)
                .frame(width: 6, height: 6)
            Text(error == nil ? "connected" : "error")
                .font(CC.monoTiny)
                .foregroundStyle(.tertiary)
            Spacer()
            if let version = Bundle.main.appVersion {
                Text("v\(version)")
                    .font(CC.monoTiny.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}
