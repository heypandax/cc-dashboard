import Foundation
import XCTest
@testable import CCDashboard

/// 扫描器单测:用临时目录里手写的 jsonl + 纯函数 stub resolver,完全不碰真实
/// `~/.claude/projects` 或 git 子进程。
final class SessionArchiveScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// stub:cwd → (commonDir, toplevel)。map 里没有的 cwd 视作非 git 目录(返回 nil)。
    private struct StubResolver: RepoResolving {
        let map: [String: (commonDir: String, toplevel: String)]
        func resolve(cwd: String) -> (commonDir: String, toplevel: String)? { map[cwd] }
    }

    @discardableResult
    private func writeSession(project: String, file: String, lines: [String]) throws -> URL {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func scan(_ map: [String: (commonDir: String, toplevel: String)]) -> [RepoGroup] {
        SessionArchiveScanner(projectsDir: root, resolver: StubResolver(map: map)).scan()
    }

    // MARK: - worktree 聚合到同一仓库

    func testWorktreesAggregateUnderOneRepo() throws {
        try writeSession(project: "p1", file: "s1.jsonl", lines: [
            #"{"type":"user","sessionId":"s1","cwd":"/repo/wt-a","gitBranch":"feat/a","slug":"alpha","message":{"content":"hi a"}}"#
        ])
        try writeSession(project: "p2", file: "s2.jsonl", lines: [
            #"{"type":"user","sessionId":"s2","cwd":"/repo/wt-b","gitBranch":"feat/b","slug":"beta","message":{"content":"hi b"}}"#
        ])

        let groups = scan([
            "/repo/wt-a": (commonDir: "/repo/.git", toplevel: "/repo/wt-a"),
            "/repo/wt-b": (commonDir: "/repo/.git", toplevel: "/repo/wt-b"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].repoRoot, "/repo")
        XCTAssertEqual(groups[0].displayName, "repo")
        XCTAssertEqual(groups[0].worktrees.count, 2)
        XCTAssertEqual(groups[0].sessionCount, 2)
        let branches = Set(groups[0].worktrees.compactMap(\.branch))
        XCTAssertEqual(branches, ["feat/a", "feat/b"])
    }

    // MARK: - 标题优先级:slug > 首条用户输入

    func testTitlePrefersSlugThenFirstPrompt() throws {
        try writeSession(project: "p1", file: "withSlug.jsonl", lines: [
            #"{"type":"user","sessionId":"a","cwd":"/r","slug":"my-slug","message":{"content":"the prompt"}}"#
        ])
        try writeSession(project: "p2", file: "noSlug.jsonl", lines: [
            #"{"type":"user","sessionId":"b","cwd":"/r","message":{"content":"only prompt here"}}"#
        ])

        let groups = scan(["/r": (commonDir: "/r/.git", toplevel: "/r")])
        let sessions = groups.flatMap { $0.worktrees.flatMap(\.sessions) }
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        XCTAssertEqual(byID["a"]?.title, "my-slug")
        XCTAssertEqual(byID["b"]?.title, "only prompt here")
    }

    // MARK: - 首问跳过 sidechain(subagent)行

    func testFirstPromptSkipsSidechain() throws {
        try writeSession(project: "p1", file: "s.jsonl", lines: [
            #"{"type":"user","sessionId":"x","cwd":"/r","isSidechain":true,"message":{"content":"subagent noise"}}"#,
            #"{"type":"user","sessionId":"x","cwd":"/r","message":{"content":"real first prompt"}}"#,
        ])

        let groups = scan(["/r": (commonDir: "/r/.git", toplevel: "/r")])
        let title = groups.first?.worktrees.first?.sessions.first?.title
        XCTAssertEqual(title, "real first prompt")
    }

    // MARK: - content 为富文本数组时取首个 text 块

    func testFirstPromptFromContentArray() throws {
        try writeSession(project: "p1", file: "s.jsonl", lines: [
            #"{"type":"user","sessionId":"x","cwd":"/r","message":{"content":[{"type":"text","text":"hello array"}]}}"#
        ])

        let groups = scan(["/r": (commonDir: "/r/.git", toplevel: "/r")])
        XCTAssertEqual(groups.first?.worktrees.first?.sessions.first?.title, "hello array")
    }

    // MARK: - 非 git 目录 → cwd 自成一组

    func testNonGitCwdBecomesOwnGroup() throws {
        try writeSession(project: "p1", file: "s.jsonl", lines: [
            #"{"type":"user","sessionId":"x","cwd":"/loose/dir","message":{"content":"hi"}}"#
        ])

        let groups = scan([:])   // resolver 对任何 cwd 都返回 nil
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].repoRoot, "/loose/dir")
        XCTAssertEqual(groups[0].worktrees.first?.path, "/loose/dir")
    }

    // MARK: - cwd 缺失的文件被跳过

    func testFileWithoutCwdIsSkipped() throws {
        try writeSession(project: "p1", file: "nocwd.jsonl", lines: [
            #"{"type":"mode","sessionId":"x","mode":"default"}"#,
            #"{"type":"user","sessionId":"x","message":{"content":"no cwd anywhere"}}"#,
        ])

        XCTAssertTrue(scan([:]).isEmpty)
    }

    // MARK: - 空目录 / 不存在目录不崩

    func testEmptyProjectsDirReturnsEmpty() {
        XCTAssertTrue(scan([:]).isEmpty)
    }
}
