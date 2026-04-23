import SwiftUI

// MARK: - Risk heuristic

enum RiskLevel: String {
    case low, moderate, high

    var edgeColor: Color? {
        switch self {
        case .high:     return CC.red
        case .moderate: return CC.amber
        case .low:      return nil
        }
    }
}

/// Auto-trust 窗口可选时长(分钟),ApprovalRow popover 和菜单栏卡片的 Menu 都用这份。
let trustMinuteOptions: [Int] = [2, 10, 30]

/// 粗启发:基于 toolName + command/file_path 关键词判断写入/破坏性等级。
/// 不求准,只求"一眼看清有没有嫌疑",给 card 左边缘定一个色。
func riskLevel(for approval: ApprovalRequest) -> RiskLevel {
    let cmd = (approval.toolInput["command"]?.display ?? "").lowercased()
    let file = approval.toolInput["file_path"]?.display ?? ""

    if cmd.contains("rm -rf") || cmd.contains("sudo ") ||
       (cmd.contains("curl") && (cmd.contains("| sh") || cmd.contains("| bash"))) {
        return .high
    }
    if file.hasPrefix("/etc/") || file.hasPrefix("/usr/") ||
       file.hasPrefix("/System/") || file.hasPrefix("/var/") {
        return .high
    }
    if approval.toolName == "Bash" {
        let readOnly = ["ls", "pwd", "cat ", "echo ", "git status", "git log", "git diff",
                        "git branch", "head ", "tail ", "grep ", "find ", "which ",
                        "env", "date", "uname", "whoami"]
        if cmd == "ls" || cmd == "pwd" || readOnly.contains(where: { cmd.hasPrefix($0) }) {
            return .low
        }
    }
    if ["Edit", "Write", "MultiEdit"].contains(approval.toolName) {
        return .moderate
    }
    if approval.toolName == "WebFetch" {
        return .moderate
    }
    return .low
}

// MARK: - Relative time

/// 每 10s tick;< 5s 显示 "just now" (本地化);其他委托 RelativeDateTimeFormatter 按系统 locale。
/// TimelineView 用系统共享调度器,多个实例不会各自起一个 Foundation Timer。
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            Text(Self.display(from: date, to: context.date))
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func display(from date: Date, to now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 5 { return String(localized: "just now") }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - Detail toolbar + queue view

struct ApprovalQueueView: View {
    let dashboard: Dashboard

    private var autoAllowCount: Int {
        dashboard.sessions.filter { ($0.autoAllowUntil ?? .distantPast) > Date() }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailToolbar(
                pendingCount: dashboard.approvals.count,
                onAllowAll: { dashboard.allowAll() }
            )
            if dashboard.approvals.isEmpty {
                EmptyApprovalsView(autoAllowCount: autoAllowCount)
            } else {
                // 为什么不是 List:macOS 下 List 会把 row 内第一次 click 当作选中行吞掉,
                // 要点两下 Allow 才响应。ScrollView+LazyVStack 没这个坑,且我们不需要选中语义。
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(dashboard.approvals) { approval in
                            ApprovalRow(approval: approval, dashboard: dashboard)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

struct DetailToolbar: View {
    let pendingCount: Int
    let onAllowAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(pendingCount == 1 ? "Approval" : "Approvals")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            if pendingCount > 0 {
                Text("\(pendingCount) pending")
                    .font(CC.monoTiny.weight(.semibold))
                    .foregroundStyle(CC.amberInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(CC.amber.opacity(0.18)))
            }
            Spacer()
            if pendingCount > 0 {
                Button(action: onAllowAll) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Allow all \(pendingCount)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(CC.mintInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(CC.mint.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(CC.mint.opacity(0.55), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Allow all pending — ⌘↩")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

// MARK: - Empty state

struct EmptyApprovalsView: View {
    let autoAllowCount: Int

    var body: some View {
        VStack(spacing: 18) {
            EmptyMotif()
                .frame(width: 88, height: 88)
                .opacity(0.88)

            VStack(spacing: 4) {
                Text("Nothing to review.")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Sessions will show up here when they need you.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if autoAllowCount > 0 {
                HStack(spacing: 6) {
                    Circle().fill(CC.mint).frame(width: 6, height: 6)
                    Text("\(autoAllowCount)")
                        .font(CC.monoTiny.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(autoAllowCount == 1 ? "auto-allow active" : "auto-allow windows active")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 缩小版 V2 app icon —— indigo squircle + 白卡片 + 3 条线 + mint 勾。
struct EmptyMotif: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(
                    colors: [CC.indigoTop, CC.indigoBot],
                    startPoint: .top, endPoint: .bottom
                ))
            RoundedRectangle(cornerRadius: 5)
                .fill(CC.cardFace)
                .frame(width: 56, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Capsule().fill(CC.indigoBot.opacity(0.85)).frame(width: 22, height: 2)
                    CheckShape()
                        .stroke(CC.mint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 9, height: 7)
                }
                Capsule().fill(CC.indigoBot.opacity(0.5)).frame(width: 26, height: 2)
                Capsule().fill(CC.indigoBot.opacity(0.3)).frame(width: 20, height: 2)
            }
            .frame(width: 44, alignment: .leading)
        }
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        return p
    }
}

// MARK: - Approval card

struct ApprovalRow: View {
    let approval: ApprovalRequest
    let dashboard: Dashboard
    @State private var submenuOpen = false

    private var risk: RiskLevel { riskLevel(for: approval) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(approval.toolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(dashboard.displayName(forSessionID: approval.sessionId))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    RelativeTimeText(date: approval.createdAt)
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            }

            Text(approval.cwd)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.top, 4)

            ToolInputPanel(input: approval.toolInput)
                .padding(.top, 10)

            HStack(spacing: 8) {
                AllowSplitButton(
                    onAllow: { dashboard.decide(approvalID: approval.id, decision: .allow) },
                    onTrust: { mins in
                        dashboard.decide(approvalID: approval.id, decision: .allow, trustMinutes: mins)
                        submenuOpen = false
                    },
                    submenuOpen: $submenuOpen,
                    toolName: approval.toolName
                )

                Button {
                    dashboard.decide(approvalID: approval.id, decision: .deny)
                } label: {
                    Text("Deny")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CC.redInk)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(CC.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(CC.red.opacity(0.35), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                if risk == .high {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                        Text("destructive · review carefully")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(CC.redInk)
                    .padding(.leading, 4)
                }
                Spacer()
            }
            .padding(.top, 14)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            if let edge = risk.edgeColor {
                edge.frame(width: 2.5)
            }
        }
        .shadow(color: Color.black.opacity(0.05), radius: 3, y: 1)
    }
}

struct ToolInputPanel: View {
    @State private var expanded = false
    private let lines: [(key: String, value: String)]

    init(input: [String: AnyCodable]) {
        self.lines = input.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value.display) }
    }

    private var collapsible: Bool { lines.count > 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(collapsible && !expanded ? Array(lines.prefix(3)) : lines, id: \.0) { k, v in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(k):")
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 62, alignment: .leading)
                    Text(v)
                        .foregroundStyle(.primary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if collapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Show less" : "Show \(lines.count - 3) more")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

struct AllowSplitButton: View {
    let onAllow: () -> Void
    let onTrust: (Int) -> Void
    @Binding var submenuOpen: Bool
    let toolName: String

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onAllow) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Allow")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(CC.inkOnMint)
                .padding(.leading, 11)
                .padding(.trailing, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            Rectangle().fill(Color.black.opacity(0.18)).frame(width: 0.5)

            Button { submenuOpen.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CC.inkOnMint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $submenuOpen, arrowEdge: .bottom) {
                TrustSubmenu(toolName: toolName, onSelect: onTrust)
            }
        }
        .background(
            LinearGradient(colors: [CC.mint, CC.mintDeep], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// 共享菜单体:approval card 的 split-button 和 sidebar 行级 trust popover 都用这份。
/// 只有 intro / footer 的行文不同,按钮行 / 键盘快捷键 / 视觉强调(10min 居中高亮)完全一致。
struct TrustPickerMenu: View {
    let introCopy: LocalizedStringKey
    let footerCopy: LocalizedStringKey
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(introCopy)
                .font(.system(size: 10, weight: .bold))
                .kerning(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6).padding(.bottom, 4)

            ForEach(Array(trustMinuteOptions.enumerated()), id: \.element) { index, mins in
                let key = KeyEquivalent(Character("\(index + 1)"))
                Button { onSelect(mins) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text("Allow for").font(.system(size: 13))
                        Text("\(mins) min")
                            .font(.system(size: 13, design: .monospaced))
                            .fontWeight(.semibold)
                        Spacer()
                        Text("⌘\(index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        mins == 10 ? CC.mint.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(key, modifiers: .command)
            }

            Divider().padding(.horizontal, 2).padding(.vertical, 2)

            Text(footerCopy)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 7).padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 230)
        .padding(4)
    }
}

/// 审批卡片里那个版本:intro = "Allow & auto-trust"(含义:允许本次并开窗),footer 提及工具名。
struct TrustSubmenu: View {
    let toolName: String
    let onSelect: (Int) -> Void

    var body: some View {
        TrustPickerMenu(
            introCopy: "Allow & auto-trust",
            footerCopy: "During this window, all \(toolName) tool calls from this session auto-approve.",
            onSelect: onSelect
        )
    }
}
