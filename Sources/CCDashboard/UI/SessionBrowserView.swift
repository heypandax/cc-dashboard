import AppKit
import SwiftUI

// MARK: - ViewModel

/// 会话总览的 ViewModel。与实时审批的 `Dashboard` 平行 —— 数据来自扫盘(历史 jsonl),
/// 只向 `Dashboard.sessions` 单向读取以叠加"正在跑"高亮。扫盘 + git 子进程放后台 Task,
/// 不阻塞主线程。
@MainActor
@Observable
final class SessionBrowserModel {
    private let scanner: SessionArchiveScanner
    private let aliasStore: AliasStore
    private weak var dashboard: Dashboard?

    var groups: [RepoGroup] = []
    var isLoading = false
    var query = ""
    /// 短暂底部提示(如剪贴板兜底)。set 后约 3s 自动清空。
    var banner: String?
    private var bannerClearTask: Task<Void, Never>?

    init(
        dashboard: Dashboard?,
        scanner: SessionArchiveScanner = SessionArchiveScanner(),
        aliasStore: AliasStore = AliasStore()
    ) {
        self.dashboard = dashboard
        self.scanner = scanner
        self.aliasStore = aliasStore
    }

    func refresh() async {
        isLoading = true
        let scanner = self.scanner
        let scanned = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
        groups = overlayActive(scanned)
        isLoading = false
    }

    func resume(_ s: ArchivedSession) {
        // 历史会话本身无 alias,按 cwd 查 AliasStore 复用用户给"这个项目"起的名。
        let name = aliasStore.get(cwd: s.cwd)
        let outcome = GhosttyLauncher.resume(sessionID: s.id, cwd: s.cwd, name: name)
        track(outcome)
        report(outcome)
    }

    func openDirectory(_ s: ArchivedSession) {
        report(GhosttyLauncher.openDirectory(s.cwd))
    }

    /// 过滤:命中仓库名整组放行;否则下钻匹配 worktree(名/分支/路径)与会话(标题/路径)。
    var filteredGroups: [RepoGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        func hit(_ s: String?) -> Bool { s?.lowercased().contains(q) ?? false }
        return groups.compactMap { repo in
            if hit(repo.displayName) { return repo }
            let wts = repo.worktrees.compactMap { wt -> WorktreeGroup? in
                if hit(wt.displayName) || hit(wt.branch) || hit(wt.path) { return wt }
                let sess = wt.sessions.filter { hit($0.displayTitle) || hit($0.cwd) }
                guard !sess.isEmpty else { return nil }
                var wt = wt; wt.sessions = sess; return wt
            }
            guard !wts.isEmpty else { return nil }
            var repo = repo; repo.worktrees = wts; return repo
        }
    }

    var totalSessionCount: Int { groups.reduce(0) { $0 + $1.sessionCount } }

    /// 用实时活跃会话(非 done)按 sessionId 叠加 `isActive`。
    private func overlayActive(_ groups: [RepoGroup]) -> [RepoGroup] {
        let activeIDs = Set((dashboard?.sessions ?? []).filter { $0.status != .done }.map(\.id))
        guard !activeIDs.isEmpty else { return groups }
        return groups.map { repo in
            var repo = repo
            repo.worktrees = repo.worktrees.map { wt in
                var wt = wt
                wt.sessions = wt.sessions.map { s in
                    var s = s; s.isActive = activeIDs.contains(s.id); return s
                }
                return wt
            }
            return repo
        }
    }

    private func track(_ outcome: GhosttyLauncher.Outcome) {
        var fellBack = 0
        if case .copiedToClipboard = outcome { fellBack = 1 }
        Telemetry.track(.resumeFromBrowser, [.fallback: fellBack])
    }

    private func report(_ outcome: GhosttyLauncher.Outcome) {
        guard case .copiedToClipboard = outcome else { return }
        banner = String(localized: "Ghostty not available — command copied to clipboard")
        bannerClearTask?.cancel()
        bannerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}

// MARK: - View

struct SessionBrowserView: View {
    @Bindable var model: SessionBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 580, minHeight: 440)
        .overlay(alignment: .bottom) { bannerView }
        .animation(.spring(duration: 0.3), value: model.banner)
        .task { await model.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary).font(.system(size: 12))
            TextField("Search sessions", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(model.totalSessionCount) sessions")
                .font(CC.monoTiny.monospacedDigit()).foregroundStyle(.tertiary)
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading)
            .help("Refresh")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.groups.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
        } else if model.filteredGroups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "No sessions found" : "No matches")
                    .foregroundStyle(.secondary)
            }
        } else {
            List {
                ForEach(model.filteredGroups) { repo in
                    RepoSection(repo: repo, model: model)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = model.banner {
            Text(banner)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.thinMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Repo / Worktree / Session rows

private struct RepoSection: View {
    let repo: RepoGroup
    let model: SessionBrowserModel
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(repo.worktrees) { wt in
                WorktreeSection(worktree: wt, model: model)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(CC.indigoBot).font(.system(size: 12))
                Text(repo.displayName).font(.system(size: 13, weight: .semibold))
                Text("\(repo.sessionCount)")
                    .font(CC.monoTiny.monospacedDigit()).foregroundStyle(.tertiary)
                if repo.worktrees.count > 1 {
                    Text("\(repo.worktrees.count) worktrees")
                        .font(CC.monoTiny).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
            }
        }
    }
}

private struct WorktreeSection: View {
    let worktree: WorktreeGroup
    let model: SessionBrowserModel
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(worktree.sessions) { s in
                SessionArchiveRow(session: s, model: model)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(worktree.branch ?? worktree.displayName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(worktree.exists ? .primary : .secondary)
                    .lineLimit(1)
                if !worktree.exists {
                    Text("deleted")
                        .font(CC.monoTiny).foregroundStyle(CC.amberInk)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(CC.amber.opacity(0.15)))
                }
                Spacer()
            }
        }
        .padding(.leading, 6)
    }
}

private struct SessionArchiveRow: View {
    let session: ArchivedSession
    let model: SessionBrowserModel
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            if session.isActive {
                StatusDot(status: .running)
            } else {
                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            }

            Text(session.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if hovered {
                Button("Resume") { model.resume(session) }
                    .controlSize(.small)
                Button { model.openDirectory(session) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open directory")
            } else {
                RelativeTimeText(date: session.lastActivityAt)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Resume") { model.resume(session) }
            Button("Open directory") { model.openDirectory(session) }
            Divider()
            Button("Copy session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
    }
}
