import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import XCTest
@testable import CCDashboard

final class HTTPRoutesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Telemetry.isEnabled = false
    }

    // MARK: - /health

    func testHealthEndpoint() async throws {
        let server = DashboardHTTPServer(store: SessionStore(), port: 0)
        try await server.buildApplication().test(.live) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "ok")
            }
        }
    }

    // MARK: - POST /hook/session-start → GET /sessions

    func testSessionStartThenListSessions() async throws {
        let store = SessionStore()
        let server = DashboardHTTPServer(store: store, port: 0)
        try await server.buildApplication().test(.live) { client in
            let body = ByteBuffer(string: #"""
            {"session_id": "s-1", "cwd": "/tmp/test", "hook_event_name": "SessionStart"}
            """#)
            try await client.execute(uri: "/hook/session-start", method: .post, body: body) { r in
                XCTAssertEqual(r.status, .ok)
            }

            try await client.execute(uri: "/sessions", method: .get) { r in
                XCTAssertEqual(r.status, .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let sessions = try decoder.decode([SessionState].self, from: Data(buffer: r.body))
                XCTAssertEqual(sessions.count, 1)
                XCTAssertEqual(sessions.first?.id, "s-1")
                XCTAssertEqual(sessions.first?.cwd, "/tmp/test")
            }
        }
    }

    // MARK: - POST /trust/:sid → autoAllowUntil 非空

    func testTrustEndpointSetsAutoAllow() async throws {
        let store = SessionStore()
        let server = DashboardHTTPServer(store: store, port: 0)
        try await server.buildApplication().test(.live) { client in
            _ = try await client.execute(
                uri: "/hook/session-start", method: .post,
                body: ByteBuffer(string: #"{"session_id": "s-trust", "cwd": "/"}"#)
            )

            try await client.execute(
                uri: "/trust/s-trust", method: .post,
                body: ByteBuffer(string: #"{"minutes": 10}"#)
            ) { r in XCTAssertEqual(r.status, .ok) }

            try await client.execute(uri: "/sessions", method: .get) { r in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let sessions = try decoder.decode([SessionState].self, from: Data(buffer: r.body))
                XCTAssertNotNil(sessions.first?.autoAllowUntil)
            }
        }
    }

    // MARK: - DELETE /trust/:sid → autoAllowUntil 清空

    func testTrustEndpointClearsAutoAllow() async throws {
        let store = SessionStore()
        let server = DashboardHTTPServer(store: store, port: 0)
        try await server.buildApplication().test(.live) { client in
            _ = try await client.execute(
                uri: "/hook/session-start", method: .post,
                body: ByteBuffer(string: #"{"session_id": "s-del", "cwd": "/"}"#)
            )
            _ = try await client.execute(
                uri: "/trust/s-del", method: .post,
                body: ByteBuffer(string: #"{"minutes": 10}"#)
            )

            try await client.execute(uri: "/trust/s-del", method: .delete) { r in
                XCTAssertEqual(r.status, .ok)
            }

            try await client.execute(uri: "/sessions", method: .get) { r in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let sessions = try decoder.decode([SessionState].self, from: Data(buffer: r.body))
                XCTAssertNil(sessions.first?.autoAllowUntil)
            }
        }
    }

    // MARK: - PUT /sessions/:id/alias 设置 alias,GET /sessions 反映

    func testPutAliasSetsAndReflectsInSessionList() async throws {
        let defaults = UserDefaults(suiteName: "test.http.\(UUID().uuidString)")!
        let store = SessionStore(aliasStore: AliasStore(defaults: defaults))
        let server = DashboardHTTPServer(store: store, port: 0)
        try await server.buildApplication().test(.live) { client in
            _ = try await client.execute(
                uri: "/hook/session-start", method: .post,
                body: ByteBuffer(string: #"{"session_id": "s-a", "cwd": "/proj"}"#)
            )
            try await client.execute(
                uri: "/sessions/s-a/alias", method: .put,
                body: ByteBuffer(string: #"{"alias": "hello"}"#)
            ) { r in XCTAssertEqual(r.status, .ok) }

            try await client.execute(uri: "/sessions", method: .get) { r in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let ss = try decoder.decode([SessionState].self, from: Data(buffer: r.body))
                XCTAssertEqual(ss.first?.alias, "hello")
            }
        }
    }

    // MARK: - DELETE /sessions/:id/alias 清空

    func testDeleteAliasClears() async throws {
        let defaults = UserDefaults(suiteName: "test.http.\(UUID().uuidString)")!
        let store = SessionStore(aliasStore: AliasStore(defaults: defaults))
        let server = DashboardHTTPServer(store: store, port: 0)
        try await server.buildApplication().test(.live) { client in
            _ = try await client.execute(
                uri: "/hook/session-start", method: .post,
                body: ByteBuffer(string: #"{"session_id": "s-b", "cwd": "/proj"}"#)
            )
            _ = try await client.execute(
                uri: "/sessions/s-b/alias", method: .put,
                body: ByteBuffer(string: #"{"alias": "x"}"#)
            )

            try await client.execute(uri: "/sessions/s-b/alias", method: .delete) { r in
                XCTAssertEqual(r.status, .ok)
            }

            try await client.execute(uri: "/sessions", method: .get) { r in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let ss = try decoder.decode([SessionState].self, from: Data(buffer: r.body))
                XCTAssertNil(ss.first?.alias)
            }
        }
    }

    // MARK: - PUT body {"alias": null} 也应清空

    func testPutAliasNullClears() async throws {
        let defaults = UserDefaults(suiteName: "test.http.\(UUID().uuidString)")!
        let store = SessionStore(aliasStore: AliasStore(defaults: defaults))
        let server = DashboardHTTPServer(store: store, port: 0)
        try await server.buildApplication().test(.live) { client in
            _ = try await client.execute(
                uri: "/hook/session-start", method: .post,
                body: ByteBuffer(string: #"{"session_id": "s-c", "cwd": "/proj"}"#)
            )
            _ = try await client.execute(
                uri: "/sessions/s-c/alias", method: .put,
                body: ByteBuffer(string: #"{"alias": "x"}"#)
            )

            try await client.execute(
                uri: "/sessions/s-c/alias", method: .put,
                body: ByteBuffer(string: #"{"alias": null}"#)
            ) { r in XCTAssertEqual(r.status, .ok) }

            try await client.execute(uri: "/sessions", method: .get) { r in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let ss = try decoder.decode([SessionState].self, from: Data(buffer: r.body))
                XCTAssertNil(ss.first?.alias)
            }
        }
    }

    // MARK: - GET /approvals shape 合约

    func testApprovalsEndpointShape() async throws {
        let store = SessionStore()
        await store.upsertSession(id: "s1", cwd: "/", transcriptPath: nil)

        let pendingTask = Task { [store] in
            let req = ApprovalRequest(
                id: "req-1", sessionId: "s1", toolName: "Bash",
                toolInput: ["command": AnyCodable("ls")],
                cwd: "/", createdAt: Date()
            )
            _ = await store.requestApproval(req)
        }
        _ = await pollForApproval(store: store)

        let server = DashboardHTTPServer(store: store, port: 0)
        try await server.buildApplication().test(.live) { client in
            try await client.execute(uri: "/approvals", method: .get) { r in
                XCTAssertEqual(r.status, .ok)
                let obj = try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [[String: Any]]
                XCTAssertEqual(obj?.count, 1)
                let first = obj?.first
                XCTAssertEqual(first?["id"] as? String, "req-1")
                XCTAssertEqual(first?["sessionId"] as? String, "s1")
                XCTAssertEqual(first?["toolName"] as? String, "Bash")
                XCTAssertEqual(first?["cwd"] as? String, "/")
                let toolInput = first?["toolInput"] as? [String: Any]
                XCTAssertEqual(toolInput?["command"] as? String, "ls")
            }
        }

        // cleanup:resolve 让 Task 正常退出
        await store.resolveApproval(id: "req-1", decision: .deny, reason: nil, trustMinutes: nil)
        _ = await pendingTask.value
    }
}
