import AppKit
import SwiftUI

/// 详情面板 = 选中会话的「Agent 信息中心」(只读)。顶部一条跨会话待审 bar(有 pending 才显),
/// 下面是会话头 + rollup + 子 agent 列表。审批的主动作在左栏会话行,这里专注信息展示。
struct AgentHubView: View {
    let dashboard: Dashboard
    let selectedSessionID: SessionState.ID?

    var body: some View {
        VStack(spacing: 0) {
            CrossSessionPendingBar(dashboard: dashboard)
            if let session = dashboard.session(withID: selectedSessionID) {
                AgentHubContent(dashboard: dashboard, session: session)
            } else {
                NoSelectionView()
            }
        }
    }
}

/// 跨会话待审兜底条 —— 复用审批队列的 DetailToolbar(含「Allow all N」+ ⌘↩),仅 pending 非空时出现。
/// 主审批动作已下沉左栏会话行,这条只保住批量放行与快捷键不丢失。
struct CrossSessionPendingBar: View {
    let dashboard: Dashboard

    var body: some View {
        if !dashboard.approvals.isEmpty {
            DetailToolbar(
                pendingCount: dashboard.approvals.count,
                onAllowAll: { dashboard.allowAll() }
            )
        }
    }
}

private struct AgentHubContent: View {
    let dashboard: Dashboard
    let session: SessionState

    var body: some View {
        let runs = dashboard.agentRuns(forSession: session.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SessionHeaderView(dashboard: dashboard, session: session)
                Divider().opacity(0.6)
                if runs.isEmpty {
                    NoSubagentsView()
                } else {
                    SessionRollupView(dashboard: dashboard, session: session)
                    LazyVStack(spacing: 10) {
                        ForEach(runs) { AgentRunRow(run: $0) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Header

private struct SessionHeaderView: View {
    let dashboard: Dashboard
    let session: SessionState

    private var isHexName: Bool { session.alias?.isEmpty ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(status: session.status)
                Text(dashboard.displayName(forSessionID: session.id))
                    .font(.system(size: 15, weight: .semibold, design: isHexName ? .monospaced : .default))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let mode = session.permissionMode, mode != "default" { InfoChip(text: mode) }
                Spacer(minLength: 8)
                trustBadge
            }
            Text(session.cwd)
                .font(CC.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    @ViewBuilder private var trustBadge: some View {
        if session.autoAllowForever {
            TrustBadge(expiresAt: nil) { dashboard.clearTrust(sessionID: session.id) }
        } else if let until = session.autoAllowUntil, until > Date() {
            TrustBadge(expiresAt: until) { dashboard.clearTrust(sessionID: session.id) }
        }
    }
}

private struct SessionRollupView: View {
    let dashboard: Dashboard
    let session: SessionState

    var body: some View {
        let count = dashboard.agentCount(forSession: session.id)
        let rollup = dashboard.sessionCostRollup(forSession: session.id)
        HStack(spacing: 6) {
            Text("Agents")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            Text(verbatim: "· \(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Text(verbatim: costTokenLine(rollup.costUSD, rollup.tokens))
                .font(CC.monoTiny)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Agent run row

private struct AgentRunRow: View {
    let run: AgentRun
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if expanded { AgentRunDetail(run: run) }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentStatusDot(status: run.status)
            Text(run.agentType)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !run.description.isEmpty {
                Text(run.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let model = run.model { InfoChip(text: ModelPricing.family(for: model) ?? model) }
            Text(verbatim: costTokenLine(run.estCostUSD, run.usage.totalTokens))
                .font(CC.monoTiny)
                .foregroundStyle(.secondary)
            statusLabel
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var statusLabel: some View {
        switch run.status {
        case .running:
            Text("running").font(CC.monoTiny).foregroundStyle(CC.Status.running)
        case .spawning:
            Text("queued").font(CC.monoTiny).foregroundStyle(CC.amberInk)
        case .done:
            if let end = run.endedAt {
                Text(verbatim: formatDuration(end.timeIntervalSince(run.startedAt)))
                    .font(CC.monoTiny.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("done").font(CC.monoTiny).foregroundStyle(.tertiary)
            }
        case .error:
            Text("error").font(CC.monoTiny).foregroundStyle(CC.redInk)
        }
    }
}

/// 展开区。工具调用时间线留待后续;先展示 spawn 时捕获的 prompt 摘要(本机展示,绝不上传)。
private struct AgentRunDetail: View {
    let run: AgentRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !run.toolCalls.isEmpty {
                ForEach(run.toolCalls.suffix(25)) { call in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(call.name)
                            .font(CC.monoTiny.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text(call.summary.isEmpty ? "—" : call.summary)
                            .font(CC.monoTiny)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            } else if let prompt = run.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(CC.monoTiny)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            } else {
                Text("No tool calls recorded")
                    .font(CC.monoTiny)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

/// AgentRunStatus → (颜色, 是否脉冲) 映射,渲染走共享的 PulseDot(StatusDot 同款)。
private struct AgentStatusDot: View {
    let status: AgentRunStatus

    private var color: Color {
        switch status {
        case .running:  return CC.Status.running
        case .spawning: return CC.Status.waiting
        case .done:     return CC.Status.done
        case .error:    return CC.Status.error
        }
    }

    var body: some View {
        PulseDot(color: color, pulsing: status == .running || status == .spawning)
    }
}

/// 中性胶囊小标签(模型 / 模式)。
private struct InfoChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(CC.monoTiny)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - Empty states

private struct NoSubagentsView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No subagents yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Subagents this session spawns will appear here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

private struct NoSelectionView: View {
    var body: some View {
        VStack(spacing: 10) {
            EmptyMotif()
                .frame(width: 72, height: 72)
                .opacity(0.85)
            Text("Select a session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Pick a session on the left to see its agents and cost.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Formatting (presentation-only, verbatim numbers)

/// "≈ $x · Nk tok" —— 成本 + token 一行,rollup 和 agent 行共用。
func costTokenLine(_ cost: Double?, _ tokens: Int) -> String {
    "\(formatCost(cost)) · \(formatTokens(tokens)) tok"
}

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
    return "\(n)"
}

/// 估算成本,一律带 ≈;nil(未知模型)→ —;极小 → <$0.01,避免显成 $0.00 像免费。
func formatCost(_ usd: Double?) -> String {
    guard let usd else { return "—" }
    if usd >= 0.01 { return String(format: "≈ $%.2f", usd) }
    if usd > 0 { return "≈ <$0.01" }
    return "≈ $0.00"
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, seconds)
    if s < 60 { return String(format: "%.1fs", s) }
    return String(format: "%dm%02ds", Int(s) / 60, Int(s) % 60)
}
