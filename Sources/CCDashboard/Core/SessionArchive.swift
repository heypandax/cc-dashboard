import Foundation

// MARK: - Models

/// 一次历史会话(一个 jsonl 文件)的轻量投影。只保留总览与 resume 需要的字段 ——
/// 完整对话内容不解析,扫描器只读文件头部,见 `SessionArchiveScanner`。
struct ArchivedSession: Identifiable, Sendable {
    let id: String            // sessionId,等于 jsonl 文件名去扩展名
    let cwd: String           // 会话运行目录(worktree 路径)
    let gitBranch: String?
    let title: String?        // slug 优先,回落到首条用户输入;两者皆无为 nil
    let startedAt: Date?
    let lastActivityAt: Date  // 文件 mtime,近似"最后活动"
    let jsonlPath: String
    /// 是否有同 id 的实时活跃会话。扫描阶段恒为 false,由 UI 层用 `Dashboard.sessions` 叠加。
    var isActive: Bool = false

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return String(id.prefix(8))
    }
}

/// 一个 worktree(或主 working tree)下的会话集合。`path` = git toplevel。
struct WorktreeGroup: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let branch: String?
    /// 目录当前是否仍存在 —— 已删除的 worktree 仍留有历史会话,灰显但不隐藏。
    let exists: Bool
    var sessions: [ArchivedSession]

    var displayName: String { (path as NSString).lastPathComponent }
    var lastActivityAt: Date { sessions.map(\.lastActivityAt).max() ?? .distantPast }
}

/// 一个 git 仓库(含其全部 worktree)的会话聚合。`repoRoot` = git common-dir 去掉末尾 `/.git`。
struct RepoGroup: Identifiable, Sendable {
    var id: String { repoRoot }
    let repoRoot: String
    var worktrees: [WorktreeGroup]

    var displayName: String { (repoRoot as NSString).lastPathComponent }
    var sessionCount: Int { worktrees.reduce(0) { $0 + $1.sessions.count } }
    var lastActivityAt: Date { worktrees.map(\.lastActivityAt).max() ?? .distantPast }
}

// MARK: - Git repo resolution

/// cwd → (git common-dir, worktree toplevel)。抽成协议是注入点 —— 测试用纯函数 stub
/// 替换真实 git 子进程调用。
protocol RepoResolving: Sendable {
    func resolve(cwd: String) -> (commonDir: String, toplevel: String)?
}

/// 调 `git rev-parse` 把任意 worktree 的 cwd 归一到它所属仓库。worktree 与主仓库共享
/// 同一个 `--git-common-dir`(即 `<repo>/.git`),这是把散落 worktree 收拢的天然聚合键。
/// 非 git 目录 / git 不可用 → nil,调用方让该 cwd 自成一组。
struct GitRepoResolver: RepoResolving {
    func resolve(cwd: String) -> (commonDir: String, toplevel: String)? {
        guard FileManager.default.fileExists(atPath: cwd) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // 输出严格按参数顺序:第 1 行 common-dir,第 2 行 toplevel(已实测)。
        p.arguments = ["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // 先读后等,避免管道缓冲满时死锁(此处输出虽小,仍守惯例)。
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let str = String(data: data, encoding: .utf8) else { return nil }
        let lines = str.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        return (commonDir: lines[0], toplevel: lines[1])
    }
}

// MARK: - Scanner

/// 扫描 `~/.claude/projects` 下所有会话 jsonl,聚合成 仓库 → worktree → 会话 三层。
/// 性能策略:每个 jsonl 只读头部若干字节拿元数据,`lastActivityAt` 取文件 mtime,不读全文 ——
/// 单仓库可达上百会话、单文件数十 MB,全量读会卡。
struct SessionArchiveScanner: Sendable {
    let projectsDir: URL
    let headByteLimit: Int
    let resolver: RepoResolving

    init(
        projectsDir: URL = SessionArchiveScanner.defaultProjectsDir,
        headByteLimit: Int = 64 * 1024,
        resolver: RepoResolving = GitRepoResolver()
    ) {
        self.projectsDir = projectsDir
        self.headByteLimit = headByteLimit
        self.resolver = resolver
    }

    static var defaultProjectsDir: URL {
        URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath)
    }

    /// 同步阻塞(文件 IO + git 子进程)。调用方放后台 Task,不要在 MainActor 直接调。
    func scan() -> [RepoGroup] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var sessions: [ArchivedSession] = []
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let s = parse(file: file) { sessions.append(s) }
            }
        }
        return group(sessions)
    }

    // MARK: Parse one file

    private func parse(file: URL) -> ArchivedSession? {
        guard let head = readHead(of: file) else { return nil }

        var cwd: String?
        var branch: String?
        var slug: String?
        var firstPrompt: String?
        var startedAt: Date?
        var sessionId: String?

        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let row = try? Self.decoder.decode(ArchiveLine.self, from: data) else { continue }
            if cwd == nil, let c = row.cwd, !c.isEmpty { cwd = c }
            if branch == nil, let b = row.gitBranch, !b.isEmpty { branch = b }
            if slug == nil, let s = row.slug, !s.isEmpty { slug = s }
            if sessionId == nil, let sid = row.sessionId, !sid.isEmpty { sessionId = sid }
            if startedAt == nil, let ts = row.timestamp { startedAt = Self.parseTimestamp(ts) }
            // 首条真实用户输入:跳过 subagent(sidechain)与工具结果行。
            if firstPrompt == nil, row.type == "user", row.isSidechain != true,
               let text = row.message?.content?.firstUserText {
                firstPrompt = text
            }
        }

        // cwd 缺失则无法归类,放弃该文件。sessionId 缺失回落到文件名。
        guard let cwd else { return nil }
        let id = sessionId ?? file.deletingPathExtension().lastPathComponent

        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        return ArchivedSession(
            id: id,
            cwd: cwd,
            gitBranch: branch,
            title: slug ?? firstPrompt.map(Self.tidy),
            startedAt: startedAt,
            lastActivityAt: mtime,
            jsonlPath: file.path
        )
    }

    /// 只读头部 `headByteLimit` 字节。会话首部即含 cwd / gitBranch / slug / 首问,
    /// 无需读完整文件。末行可能被截断,解析时 decode 失败自然跳过。
    private func readHead(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: headByteLimit)) ?? Data()
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Group

    private func group(_ sessions: [ArchivedSession]) -> [RepoGroup] {
        // cwd → 解析结果,去重避免对同一目录重复 fork git。
        var cache: [String: (commonDir: String, toplevel: String)?] = [:]
        func resolved(_ cwd: String) -> (commonDir: String, toplevel: String)? {
            if let hit = cache[cwd] { return hit }
            let r = resolver.resolve(cwd: cwd)
            cache[cwd] = r
            return r
        }

        var repos: [String: [String: [ArchivedSession]]] = [:]   // repoRoot → toplevel → sessions
        var branchByToplevel: [String: String] = [:]

        for s in sessions {
            let r = resolved(s.cwd)
            let repoRoot = r.map { Self.repoRoot(fromCommonDir: $0.commonDir) } ?? s.cwd
            let toplevel = r?.toplevel ?? s.cwd
            repos[repoRoot, default: [:]][toplevel, default: []].append(s)
            if let b = s.gitBranch { branchByToplevel[toplevel] = b }
        }

        let fm = FileManager.default
        return repos.map { repoRoot, byTop in
            let worktrees = byTop.map { top, sess in
                WorktreeGroup(
                    path: top,
                    branch: branchByToplevel[top],
                    exists: fm.fileExists(atPath: top),
                    sessions: sess.sorted { $0.lastActivityAt > $1.lastActivityAt }
                )
            }.sorted { $0.lastActivityAt > $1.lastActivityAt }
            return RepoGroup(repoRoot: repoRoot, worktrees: worktrees)
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// common-dir(`<repo>/.git`)→ 展示用仓库根。裸库等少见情况直接用 common-dir。
    private static func repoRoot(fromCommonDir commonDir: String) -> String {
        let ns = commonDir as NSString
        return ns.lastPathComponent == ".git" ? ns.deletingLastPathComponent : commonDir
    }

    // MARK: Helpers

    // 无配置、decode 只读,跨线程复用安全;避免在逐行解析里反复新建(每文件头部可达数十行)。
    nonisolated(unsafe) private static let decoder = JSONDecoder()

    // ISO8601DateFormatter 文档保证线程安全,但未标 Sendable;只在解析时只读,故 unsafe 接管。
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    private static func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// 首问作列表副标题:压平换行、截断,避免一行塞满。
    private static func tidy(_ s: String) -> String {
        let oneLine = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return String(oneLine.prefix(80))
    }
}

// MARK: - JSONL line decoding

/// 只声明扫描需要的字段,其余忽略。`content` 可能是字符串或富文本数组,见 `Content`。
private struct ArchiveLine: Decodable {
    let type: String?
    let cwd: String?
    let gitBranch: String?
    let slug: String?
    let sessionId: String?
    let isSidechain: Bool?
    let timestamp: String?
    let message: Message?

    struct Message: Decodable {
        let content: Content?
    }

    enum Content: Decodable {
        case text(String)
        case parts([Part])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) }
            else if let p = try? c.decode([Part].self) { self = .parts(p) }
            else { self = .text("") }
        }

        /// 真实用户键入文本。数组形态只认 `type == "text"` 的块,排除 tool_result 等。
        var firstUserText: String? {
            switch self {
            case .text(let s):
                return s.isEmpty ? nil : s
            case .parts(let ps):
                return ps.first { $0.type == "text" && $0.text?.isEmpty == false }?.text
            }
        }
    }

    struct Part: Decodable {
        let type: String?
        let text: String?
    }
}
