import Foundation
import XCTest
@testable import CCDashboard

final class HooksInstallerTests: XCTestCase {

    private var tempRoot: URL!
    private var installDir: URL!
    private var settingsPath: String!
    private var bundledHooks: URL!

    override func setUpWithError() throws {
        Telemetry.isEnabled = false

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-dashboard-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        installDir = tempRoot.appendingPathComponent("install", isDirectory: true)
        settingsPath = tempRoot.appendingPathComponent("settings.json").path
        bundledHooks = tempRoot.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledHooks, withIntermediateDirectories: true)

        // 模拟 bundle 里的脚本
        try "#!/bin/sh\necho pretool\n".write(
            to: bundledHooks.appendingPathComponent("pretool.sh"),
            atomically: true, encoding: .utf8
        )
        try "#!/bin/sh\necho lifecycle $1\n".write(
            to: bundledHooks.appendingPathComponent("lifecycle.sh"),
            atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeInstaller() -> HooksInstaller {
        HooksInstaller(
            installDir: installDir,
            settingsPath: settingsPath,
            bundledHooksDir: bundledHooks
        )
    }

    // MARK: - settings.json 不存在 → 静默退出

    func testInstallerSkipsWhenSettingsMissing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath))

        makeInstaller().installIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installDir.path))
    }

    // MARK: - 已有其他 hooks → 保留 + 追加 cc-dashboard

    func testInstallerPreservesOtherHooksAndAppendsCCDashboard() throws {
        let original: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "hooks": [
                            ["type": "command", "command": "/custom/other-tool.sh", "timeout": 5]
                        ]
                    ]
                ]
            ],
            "theme": "dark"
        ]
        let data = try JSONSerialization.data(withJSONObject: original, options: [])
        try data.write(to: URL(fileURLWithPath: settingsPath))

        makeInstaller().installIfNeeded()

        // 脚本已拷贝
        let pretool = installDir.appendingPathComponent("pretool.sh").path
        let lifecycle = installDir.appendingPathComponent("lifecycle.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: pretool))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lifecycle))

        // settings.json 保留其他字段
        let newData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let newRoot = try JSONSerialization.jsonObject(with: newData) as? [String: Any]
        XCTAssertEqual(newRoot?["theme"] as? String, "dark")

        let hooks = try XCTUnwrap(newRoot?["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["UserPromptSubmit"], "原有 hook 未动")
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["SessionEnd"])
        XCTAssertNotNil(hooks["Notification"])

        // 备份文件存在
        let dir = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backups = contents.filter { $0.contains(".bak.") }
        XCTAssertEqual(backups.count, 1, "should produce exactly one backup")
    }

    // MARK: - 二次 install 幂等

    func testInstallerIsIdempotent() throws {
        let initial: [String: Any] = [:]
        let data = try JSONSerialization.data(withJSONObject: initial, options: [])
        try data.write(to: URL(fileURLWithPath: settingsPath))

        let installer = makeInstaller()
        installer.installIfNeeded()

        let dir = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
        let afterFirst = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backupsAfterFirst = afterFirst.filter { $0.contains(".bak.") }
        XCTAssertEqual(backupsAfterFirst.count, 1)

        let settingsAfterFirst = try Data(contentsOf: URL(fileURLWithPath: settingsPath))

        // 二次 install
        installer.installIfNeeded()

        let afterSecond = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backupsAfterSecond = afterSecond.filter { $0.contains(".bak.") }
        XCTAssertEqual(backupsAfterSecond.count, 1, "幂等 install 不应产生新备份")

        let settingsAfterSecond = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        XCTAssertEqual(settingsAfterFirst, settingsAfterSecond, "settings 应字节相同")
    }
}
