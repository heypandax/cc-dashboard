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
    private let nameStore: SessionNameStore
    private weak var dashboard: Dashboard?

    var groups: [RepoGroup] = []
    var isLoading = false
    var query = ""
    /// 折叠状态外部化、按稳定 id(repoRoot / worktree path)管理 —— 不能用视图局部 @State:
    /// List(.sidebar) 会虚拟化复用 row,@State 在 refresh / 滚动时会串到别的行上(层级展开错乱)。
    /// 存"已折叠"的 id,默认不在集合里即展开,与初始全展开一致。
    /// repo 与 worktree 必须分两个集合:主仓库的 repoRoot 等于其主 worktree 的 path(同一路径),
    /// 合一会让仓库与主 worktree 的折叠态互相串。
    var collapsedRepos: Set<String> = []
    var collapsedWorktrees: Set<String> = []
    /// 短暂底部提示(如剪贴板兜底)。set 后约 3s 自动清空。
    var banner: String?
    private var bannerClearTask: Task<Void, Never>?

    init(
        dashboard: Dashboard?,
        scanner: SessionArchiveScanner = SessionArchiveScanner(),
        aliasStore: AliasStore = AliasStore(),
        nameStore: SessionNameStore = SessionNameStore()
    ) {
        self.dashboard = dashboard
        self.scanner = scanner
        self.aliasStore = aliasStore
        self.nameStore = nameStore
    }

    func refresh() async {
        isLoading = true
        let scanner = self.scanner
        let scanned = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
        groups = overlay(scanned)
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
                let sess = wt.sessions.filter { hit($0.displayTitle) || hit($0.customName) || hit($0.cwd) }
                guard !sess.isEmpty else { return nil }
                var wt = wt; wt.sessions = sess; return wt
            }
            guard !wts.isEmpty else { return nil }
            var repo = repo; repo.worktrees = wts; return repo
        }
    }

    var totalSessionCount: Int { groups.reduce(0) { $0 + $1.sessionCount } }

    // 折叠查询 / 切换 —— 手搓折叠(非 DisclosureGroup)直接读写,按稳定 id。
    func isRepoExpanded(_ id: String) -> Bool { !collapsedRepos.contains(id) }
    func isWorktreeExpanded(_ id: String) -> Bool { !collapsedWorktrees.contains(id) }

    // formSymmetricDifference([id]):有则移除、无则插入 —— 标准 Set toggle 习语。
    func toggleRepo(_ id: String) { collapsedRepos.formSymmetricDifference([id]) }
    func toggleWorktree(_ id: String) { collapsedWorktrees.formSymmetricDifference([id]) }

    /// 给会话命名(空串 → 清除),立即重算 overlay 反映到 UI(不重新扫盘)。
    func rename(_ session: ArchivedSession, name: String?) {
        nameStore.set(id: session.id, name: name)
        groups = overlay(groups)
    }

    /// 叠加实时态(isActive)与用户自定义名(customName)到扫描结果。refresh / rename 后重算。
    private func overlay(_ groups: [RepoGroup]) -> [RepoGroup] {
        let activeIDs = Set((dashboard?.sessions ?? []).filter { $0.status != .done }.map(\.id))
        let names = nameStore.load()
        return groups.map { repo in
            var repo = repo
            repo.worktrees = repo.worktrees.map { wt in
                var wt = wt
                wt.sessions = wt.sessions.map { s in
                    var s = s
                    s.isActive = activeIDs.contains(s.id)
                    s.customName = names[s.id]
                    return s
                }
                return wt
            }
            return repo
        }
    }

    private func track(_ outcome: GhosttyLauncher.Outcome) {
        let fellBack: Int
        switch outcome {
        case .launched: fellBack = 0
        case .notAuthorized, .copiedToClipboard: fellBack = 1
        }
        Telemetry.track(.resumeFromBrowser, [.fallback: fellBack])
    }

    private func report(_ outcome: GhosttyLauncher.Outcome) {
        let message: String
        switch outcome {
        case .launched:
            return
        case .notAuthorized:
            message = String(localized: "Allow Ghostty automation in System Settings › Privacy › Automation, then retry. Command copied to clipboard.")
        case .copiedToClipboard:
            message = String(localized: "Resume command copied to clipboard — paste it into your terminal.")
        }
        banner = message
        bannerClearTask?.cancel()
        bannerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.filteredGroups) { repo in
                        RepoSection(repo: repo, model: model)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

/// 通用折叠头:chevron(随展开旋转) + 自定义 label,整行可点;`indent` 控制层级缩进。
private struct DisclosureRow<Label: View>: View {
    let expanded: Bool
    let indent: CGFloat
    let toggle: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: expanded)
                    .frame(width: 10)
                label()
                Spacer(minLength: 0)
            }
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RepoSection: View {
    let repo: RepoGroup
    let model: SessionBrowserModel

    var body: some View {
        let expanded = model.isRepoExpanded(repo.id)
        VStack(alignment: .leading, spacing: 1) {
            DisclosureRow(expanded: expanded, indent: 0) { model.toggleRepo(repo.id) } label: {
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
            }
            if expanded {
                ForEach(repo.worktrees) { wt in
                    WorktreeSection(worktree: wt, model: model)
                }
            }
        }
    }
}

private struct WorktreeSection: View {
    let worktree: WorktreeGroup
    let model: SessionBrowserModel

    var body: some View {
        let expanded = model.isWorktreeExpanded(worktree.id)
        VStack(alignment: .leading, spacing: 1) {
            DisclosureRow(expanded: expanded, indent: 18) { model.toggleWorktree(worktree.id) } label: {
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
            }
            if expanded {
                ForEach(worktree.sessions) { s in
                    SessionArchiveRow(session: s, model: model)
                }
            }
        }
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

            VStack(alignment: .leading, spacing: 1) {
                if let name = session.customName, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Text(session.displayTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text(session.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1).truncationMode(.tail)
                }
            }

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
        .padding(.leading, 38)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Rename…") {
                if let name = promptSessionName(current: session.customName) {
                    model.rename(session, name: name.isEmpty ? nil : name)
                }
            }
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

/// 会话命名输入框(NSAlert,仿 promptCustomTrustMinutes)。返回 trim 后字符串(空串=清除),
/// nil = 用户取消。
@MainActor
func promptSessionName(current: String?) -> String? {
    let alert = NSAlert()
    alert.messageText = String(localized: "Name this session")
    alert.addButton(withTitle: String(localized: "Save"))
    alert.addButton(withTitle: String(localized: "Cancel"))

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = current ?? ""
    field.placeholderString = String(localized: "Session name")
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
}
