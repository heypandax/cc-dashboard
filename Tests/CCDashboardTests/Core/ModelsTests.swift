import Foundation
import XCTest
@testable import CCDashboard

final class ModelsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Telemetry.isEnabled = false
    }

    // MARK: - HookInput snake_case 解码 (fixture-driven)

    func testHookInputDecodesClaudeCodePayload() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "hook_input_pretool",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            "Fixtures/hook_input_pretool.json not found in test bundle"
        )
        let data = try Data(contentsOf: url)
        let input = try JSONDecoder().decode(HookInput.self, from: data)

        XCTAssertEqual(input.sessionID, "test-session-123")
        XCTAssertEqual(input.cwd, "/Users/test/project")
        XCTAssertEqual(input.hookEventName, "PreToolUse")
        XCTAssertEqual(input.transcriptPath, "/tmp/transcript.jsonl")
        XCTAssertEqual(input.permissionMode, "default")
        XCTAssertEqual(input.toolName, "Bash")
        XCTAssertEqual(input.toolInput?["command"]?.display, "ls -la")
    }

    // MARK: - AnyCodable roundtrip

    func testAnyCodableScalarRoundtrip() throws {
        let json = #"{"n": null, "b": true, "i": 42, "d": 3.14, "s": "hello"}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: json)

        XCTAssertTrue(decoded["n"]?.value is NSNull)
        XCTAssertEqual(decoded["b"]?.value as? Bool, true)
        XCTAssertEqual(decoded["i"]?.value as? Int, 42)
        XCTAssertEqual(decoded["d"]?.value as? Double, 3.14)
        XCTAssertEqual(decoded["s"]?.value as? String, "hello")

        // 二次 encode/decode:确保 roundtrip 稳定
        let reEncoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode([String: AnyCodable].self, from: reEncoded)
        XCTAssertTrue(redecoded["n"]?.value is NSNull)
        XCTAssertEqual(redecoded["b"]?.value as? Bool, true)
        XCTAssertEqual(redecoded["i"]?.value as? Int, 42)
        XCTAssertEqual(redecoded["d"]?.value as? Double, 3.14)
        XCTAssertEqual(redecoded["s"]?.value as? String, "hello")
    }

    func testAnyCodableNestedObject() throws {
        let json = #"{"nested": {"command": "rm -rf /tmp/foo"}}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: json)

        let nested = try XCTUnwrap(decoded["nested"]?.value as? [String: AnyCodable])
        XCTAssertEqual(nested["command"]?.value as? String, "rm -rf /tmp/foo")
        // display 走 command 分支(优先级最高)
        XCTAssertEqual(decoded["nested"]?.display, "rm -rf /tmp/foo")
    }

    // MARK: - ApprovalRequest.summaryLine 优先级 (command > file_path > fallback)

    func testApprovalSummaryPriority() {
        let cmdReq = ApprovalRequest(
            id: "1", sessionId: "s", toolName: "Bash",
            toolInput: [
                "command": AnyCodable("echo hi"),
                "file_path": AnyCodable("/tmp/x")
            ],
            cwd: "/", createdAt: Date()
        )
        XCTAssertEqual(cmdReq.summaryLine, "echo hi")

        let fileReq = ApprovalRequest(
            id: "2", sessionId: "s", toolName: "Edit",
            toolInput: ["file_path": AnyCodable("/tmp/x.swift")],
            cwd: "/", createdAt: Date()
        )
        XCTAssertEqual(fileReq.summaryLine, "/tmp/x.swift")

        let fallback = ApprovalRequest(
            id: "3", sessionId: "s", toolName: "WebFetch",
            toolInput: [:],
            cwd: "/", createdAt: Date()
        )
        XCTAssertEqual(fallback.summaryLine, "Tool: WebFetch")
    }

    // MARK: - DashboardEvent JSON 契约 (锁死前端 JS 依赖的 wire 格式)

    func testDashboardEventWireFormatTypeTags() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SessionState(
            id: "s1", cwd: "/tmp", status: .running,
            startedAt: fixedDate, lastActivityAt: fixedDate,
            transcriptPath: nil, lastTool: nil, lastNotification: nil,
            autoAllowUntil: nil, alias: nil
        )
        let approval = ApprovalRequest(
            id: "a1", sessionId: "s1", toolName: "Bash",
            toolInput: [:], cwd: "/tmp", createdAt: fixedDate
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let cases: [(DashboardEvent, String)] = [
            (.sessionUpsert(session),                                       "session_upsert"),
            (.sessionRemove("s1"),                                          "session_remove"),
            (.sessionFinished(session),                                     "session_finished"),
            (.turnComplete(session: session, prompt: "hi"),                 "turn_complete"),
            (.turnComplete(session: session, prompt: nil),                  "turn_complete"),
            (.approvalAdd(approval),                                        "approval_add"),
            (.approvalResolve("a1"),                                        "approval_resolve"),
            (.autoAllowSet(sessionId: "s1", until: fixedDate),              "auto_allow_set"),
            (.autoAllowForeverSet(sessionId: "s1"),                         "auto_allow_forever_set"),
            (.autoAllowCleared(sessionId: "s1"),                            "auto_allow_cleared"),
            (.sessionAliasChanged(sessionId: "s1", alias: "hello"),         "session_alias_changed"),
            (.sessionAliasChanged(sessionId: "s1", alias: nil),             "session_alias_changed"),
            (.snapshot(sessions: [session], approvals: [approval]),         "snapshot")
        ]

        for (event, expectedType) in cases {
            let data = try encoder.encode(event)
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(
                obj["type"] as? String,
                expectedType,
                "wire format broke: event should encode with type=\(expectedType)"
            )
        }
    }

    func testDashboardEventAutoAllowSetShape() throws {
        let until = Date(timeIntervalSince1970: 1_700_000_000)
        let event = DashboardEvent.autoAllowSet(sessionId: "s1", until: until)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["type"] as? String, "auto_allow_set")
        XCTAssertEqual(obj["sessionId"] as? String, "s1")
        XCTAssertEqual(obj["until"] as? String, "2023-11-14T22:13:20Z")
    }

    func testDashboardEventAutoAllowForeverSetShape() throws {
        let event = DashboardEvent.autoAllowForeverSet(sessionId: "s1")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["type"] as? String, "auto_allow_forever_set")
        XCTAssertEqual(obj["sessionId"] as? String, "s1")
        XCTAssertNil(obj["until"], "forever 事件不应携带 until")
    }

    // MARK: - turnComplete:prompt 非 nil 带字段,nil 省字段

    func testDashboardEventTurnCompleteShape() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SessionState(
            id: "s1", cwd: "/tmp", status: .idle,
            startedAt: date, lastActivityAt: date,
            transcriptPath: nil, lastTool: nil, lastNotification: nil,
            autoAllowUntil: nil, alias: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let withPrompt = DashboardEvent.turnComplete(session: session, prompt: "fix the build")
        let d1 = try encoder.encode(withPrompt)
        let obj1 = try XCTUnwrap(try JSONSerialization.jsonObject(with: d1) as? [String: Any])
        XCTAssertEqual(obj1["type"] as? String, "turn_complete")
        XCTAssertEqual(obj1["prompt"] as? String, "fix the build")
        XCTAssertNotNil(obj1["session"])

        let noPrompt = DashboardEvent.turnComplete(session: session, prompt: nil)
        let d2 = try encoder.encode(noPrompt)
        let obj2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: d2) as? [String: Any])
        XCTAssertEqual(obj2["type"] as? String, "turn_complete")
        XCTAssertNil(obj2["prompt"], "prompt=nil 走 encodeIfPresent")
    }

    // MARK: - HookInput:UserPromptSubmit 顶层 prompt 字段解码

    func testHookInputDecodesUserPromptSubmit() throws {
        let json = #"{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"refactor it"}"#
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        XCTAssertEqual(input.prompt, "refactor it")
        XCTAssertEqual(input.sessionID, "s1")
    }

    // MARK: - sessionAliasChanged:alias 非 nil 带字段,nil 省字段

    func testDashboardEventSessionAliasChangedShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let withAlias = DashboardEvent.sessionAliasChanged(sessionId: "s1", alias: "my project")
        let d1 = try encoder.encode(withAlias)
        let obj1 = try XCTUnwrap(try JSONSerialization.jsonObject(with: d1) as? [String: Any])
        XCTAssertEqual(obj1["type"] as? String, "session_alias_changed")
        XCTAssertEqual(obj1["sessionId"] as? String, "s1")
        XCTAssertEqual(obj1["alias"] as? String, "my project")

        let cleared = DashboardEvent.sessionAliasChanged(sessionId: "s1", alias: nil)
        let d2 = try encoder.encode(cleared)
        let obj2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: d2) as? [String: Any])
        XCTAssertEqual(obj2["type"] as? String, "session_alias_changed")
        XCTAssertEqual(obj2["sessionId"] as? String, "s1")
        XCTAssertNil(obj2["alias"], "alias=nil 应通过 encodeIfPresent 省略字段,不编成 null")
    }

    // MARK: - ApprovalRequest 完整 roundtrip

    func testApprovalRequestRoundtrip() throws {
        let original = ApprovalRequest(
            id: "req-1", sessionId: "sess-1", toolName: "Bash",
            toolInput: [
                "command": AnyCodable("ls"),
                "timeout": AnyCodable(5000)
            ],
            cwd: "/tmp",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ApprovalRequest.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.sessionId, original.sessionId)
        XCTAssertEqual(decoded.toolName, original.toolName)
        XCTAssertEqual(decoded.toolInput["command"]?.display, "ls")
        XCTAssertEqual(decoded.toolInput["timeout"]?.value as? Int, 5000)
    }
}
