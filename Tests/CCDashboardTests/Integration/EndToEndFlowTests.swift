import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import XCTest
@testable import CCDashboard

/// HTTP 端到端:模拟 hook 脚本沿 session lifecycle 的串行链路。
/// 阻塞的 pre-tool-use + decision 并发流见 `HookFlowTests`。
final class EndToEndFlowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Telemetry.isEnabled = false
    }

    func testFullHookLifecycle() async throws {
        let store = SessionStore()
        let server = DashboardHTTPServer(store: store, port: 0)
        try await server.buildApplication().test(.live) { client in
            // 1) session-start → session 注册
            try await client.execute(
                uri: "/hook/session-start", method: .post,
                body: ByteBuffer(string: #"{"session_id": "e2e", "cwd": "/tmp"}"#)
            ) { r in XCTAssertEqual(r.status, .ok) }

            // 2) UI 端开 trust 窗口(代表用户之前批过一次 allow+trustMinutes=5,或者直接手动点"Trust")
            try await client.execute(
                uri: "/trust/e2e", method: .post,
                body: ByteBuffer(string: #"{"minutes": 5}"#)
            ) { r in XCTAssertEqual(r.status, .ok) }

            // 3) pre-tool-use 同 session → 应命中 auto-allow,立即返回 allow
            let hookBody = ByteBuffer(string: #"""
            {"session_id": "e2e", "cwd": "/tmp", "tool_name": "Bash", "tool_input": {"command": "ls"}}
            """#)
            try await client.execute(uri: "/hook/pre-tool-use", method: .post, body: hookBody) { r in
                XCTAssertEqual(r.status, .ok)
                let obj = try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]
                let decision = ((obj?["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String) ?? ""
                XCTAssertEqual(decision, "allow", "pre-tool-use 应命中 auto-allow 立即 allow")
            }
            let pending = await store.allApprovals()
            XCTAssertTrue(pending.isEmpty, "auto-allow 命中不应入 pending")

            // 4) session-end → status=.done
            try await client.execute(
                uri: "/hook/session-end", method: .post,
                body: ByteBuffer(string: #"{"session_id": "e2e", "cwd": "/tmp"}"#)
            ) { r in XCTAssertEqual(r.status, .ok) }

            let sessions = await store.allSessions()
            let s = sessions.first(where: { $0.id == "e2e" })
            XCTAssertEqual(s?.status, .done)
        }
    }
}
