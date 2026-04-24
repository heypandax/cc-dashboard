import SwiftUI

struct MenuBarView: View {
    let dashboard: Dashboard
    @Bindable var controller: StatusBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if dashboard.approvals.isEmpty {
                Text("No pending approvals")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 8)
            } else {
                pendingBar
                ForEach(dashboard.approvals) { approval in
                    MenuApprovalCard(approval: approval, dashboard: dashboard)
                }
            }

            Divider()

            HStack {
                Button { controller.openMainWindow() } label: {
                    Text("Open Dashboard").fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .tint(CC.indigoBot)
                .controlSize(.small)
                Spacer()
                Button("Check for Updates…") { controller.checkForUpdates() }
                    .controlSize(.small)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
            .font(.callout)
        }
        .padding(12)
        .frame(minWidth: 340, maxWidth: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            MenuHeaderIcon()
                .frame(width: 22, height: 22)
            Text("CC Dashboard")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(dashboard.activeSessionCount) active")
                .font(CC.monoTiny.monospacedDigit())
                .foregroundStyle(.tertiary)
            pinButton
        }
    }

    // Pin 开关:pin 时 panel 不会在失焦/点击外部时关闭,相当于把菜单栏弹窗钉成常驻窗口。
    private var pinButton: some View {
        Button {
            controller.isPinned.toggle()
        } label: {
            Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(45))
                .foregroundStyle(controller.isPinned ? CC.amber : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(controller.isPinned ? "Unpin (auto-hide on click outside)" : "Pin (keep panel open)")
    }

    private var pendingBar: some View {
        HStack {
            Text("\(dashboard.approvals.count) pending")
                .font(CC.monoTiny.weight(.semibold))
                .foregroundStyle(CC.amberInk)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Capsule().fill(CC.amber.opacity(0.18)))
            Spacer()
            Button { dashboard.allowAll() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("Allow all")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(CC.mintInk)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(CC.mint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(CC.mint.opacity(0.55), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }
}

/// 菜单栏 popover header 的小 icon:22pt 简化版,不复用 EmptyMotif
/// (它的几何是给 88pt 画布调的,缩到 22pt subview 不跟着缩会溢出)。
private struct MenuHeaderIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(
                    colors: [CC.indigoTop, CC.indigoBot],
                    startPoint: .top, endPoint: .bottom
                ))
            VStack(alignment: .leading, spacing: 2) {
                Capsule().fill(Color.white.opacity(0.85)).frame(width: 10, height: 1.5)
                Capsule().fill(Color.white.opacity(0.55)).frame(width: 8,  height: 1.5)
                Capsule().fill(Color.white.opacity(0.35)).frame(width: 6,  height: 1.5)
            }
        }
    }
}

struct MenuApprovalCard: View {
    let approval: ApprovalRequest
    let dashboard: Dashboard

    private var risk: RiskLevel { riskLevel(for: approval) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(approval.toolName)
                    .font(.system(size: 13, weight: .semibold))
                Text(dashboard.displayName(forSessionID: approval.sessionId))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                RelativeTimeText(date: approval.createdAt)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(approval.summaryLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                Button {
                    dashboard.decide(approvalID: approval.id, decision: .allow)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Allow")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(CC.inkOnMint)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        LinearGradient(colors: [CC.mint, CC.mintDeep], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(trustMinuteOptions, id: \.self) { mins in
                        Button("Allow for \(mins) min") {
                            dashboard.decide(approvalID: approval.id, decision: .allow, trustMinutes: mins)
                        }
                    }
                    Divider()
                    Button("Custom duration…") {
                        if let mins = promptCustomTrustMinutes() {
                            dashboard.decide(approvalID: approval.id, decision: .allow,
                                             trustMinutes: mins, customTrust: true)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CC.mintInk)
                        .frame(minWidth: 16, minHeight: 16)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(CC.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CC.mint.opacity(0.4), lineWidth: 0.5))

                Button {
                    dashboard.decide(approvalID: approval.id, decision: .deny)
                } label: {
                    Text("Deny")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CC.redInk)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(CC.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CC.red.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            if let edge = risk.edgeColor {
                edge.frame(width: 2.5)
            }
        }
    }
}
