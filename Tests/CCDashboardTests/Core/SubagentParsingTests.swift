import Foundation
import XCTest
@testable import CCDashboard

final class SubagentParsingTests: XCTestCase {

    func testParseAssistantLine() throws {
        let line = #"{"type":"assistant","agentId":"a1","timestamp":"2026-06-01T10:00:05.000Z","message":{"model":"claude-haiku-4-5","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":1000}}}"#
        let r = try XCTUnwrap(SubagentParsing.parseLine(line[...]))
        XCTAssertEqual(r.type, "assistant")
        XCTAssertEqual(r.agentId, "a1")
        XCTAssertEqual(r.model, "claude-haiku-4-5")
        XCTAssertEqual(r.stopReason, "end_turn")
        XCTAssertEqual(r.usage?.inputTokens, 100)
        XCTAssertEqual(r.usage?.outputTokens, 50)
        XCTAssertEqual(r.usage?.cacheCreationTokens, 200)
        XCTAssertEqual(r.usage?.cacheReadTokens, 1000)
        XCTAssertNotNil(r.timestamp)
    }

    func testParseUserLineHasNoUsageOrModel() throws {
        let line = #"{"type":"user","agentId":"a1","message":{"role":"user","content":"hi"}}"#
        let r = try XCTUnwrap(SubagentParsing.parseLine(line[...]))
        XCTAssertEqual(r.type, "user")
        XCTAssertNil(r.usage)
        XCTAssertNil(r.model)
    }

    func testBlankAndTruncatedLinesReturnNil() {
        XCTAssertNil(SubagentParsing.parseLine(""[...]))
        XCTAssertNil(SubagentParsing.parseLine("   "[...]))
        // 半行(JSON 未闭合)—— 绝不抛,返回 nil
        XCTAssertNil(SubagentParsing.parseLine(#"{"type":"assistant","message":{"model":"claude-son"#[...]))
    }

    func testParseMetaWithAndWithoutToolUseId() throws {
        let withId = try XCTUnwrap(SubagentParsing.parseMeta(Data(#"{"agentType":"Explore","description":"d","toolUseId":"toolu_x"}"#.utf8)))
        XCTAssertEqual(withId.agentType, "Explore")
        XCTAssertEqual(withId.description, "d")
        XCTAssertEqual(withId.toolUseId, "toolu_x")

        let without = try XCTUnwrap(SubagentParsing.parseMeta(Data(#"{"agentType":"Plan","description":"d2"}"#.utf8)))
        XCTAssertEqual(without.agentType, "Plan")
        XCTAssertNil(without.toolUseId)

        XCTAssertNil(SubagentParsing.parseMeta(Data("not json".utf8)))
        XCTAssertNil(SubagentParsing.parseMeta(Data("{}".utf8)))   // 缺 agentType
    }

    func testAccumulateSumsAssistantUsageAndDetectsTerminal() {
        let chunk = """
        {"type":"user","agentId":"a","message":{"role":"user"}}
        {"type":"assistant","agentId":"a","timestamp":"2026-06-01T10:00:01.000Z","message":{"model":"claude-haiku-4-5","stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":1000}}}
        {"type":"assistant","agentId":"a","timestamp":"2026-06-01T10:00:02.000Z","message":{"model":"claude-haiku-4-5","stop_reason":"end_turn","usage":{"input_tokens":120,"output_tokens":60,"cache_creation_input_tokens":0,"cache_read_input_tokens":1300}}}
        """
        var usage = TokenUsage()
        var model: String?
        var calls: [AgentToolCall] = []
        let result = SubagentParsing.accumulate(into: &usage, model: &model, toolCalls: &calls,
                                                records: SubagentParsing.records(from: chunk))
        XCTAssertEqual(usage.inputTokens, 220)
        XCTAssertEqual(usage.outputTokens, 110)
        XCTAssertEqual(usage.cacheCreationTokens, 200)
        XCTAssertEqual(usage.cacheReadTokens, 2300)
        XCTAssertEqual(usage.totalTokens, 2830)
        XCTAssertEqual(model, "claude-haiku-4-5")
        XCTAssertTrue(result.terminalEndTurn)
        XCTAssertNotNil(result.lastTimestamp)
    }

    func testAccumulateInProgressHasNoTerminal() {
        let chunk = #"{"type":"assistant","agentId":"a","message":{"model":"claude-opus-4-8","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        var usage = TokenUsage()
        var model: String?
        var calls: [AgentToolCall] = []
        let result = SubagentParsing.accumulate(into: &usage, model: &model, toolCalls: &calls,
                                                records: SubagentParsing.records(from: chunk))
        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertEqual(model, "claude-opus-4-8")
        XCTAssertFalse(result.terminalEndTurn)
    }

    func testAgentIdFromFileName() {
        XCTAssertEqual(SubagentParsing.agentId(fromFileName: "agent-a1d860fdf212b3953.jsonl"), "a1d860fdf212b3953")
        XCTAssertEqual(SubagentParsing.agentId(fromFileName: "agent-a1d860fdf212b3953.meta.json"), "a1d860fdf212b3953")
        XCTAssertNil(SubagentParsing.agentId(fromFileName: "notanagent.jsonl"))
        XCTAssertNil(SubagentParsing.agentId(fromFileName: "agent-.jsonl"))
    }

    func testSubagentsDirDerivation() {
        let dir = SubagentParsing.subagentsDir(forTranscriptPath: "/Users/x/.claude/projects/proj/63fe1073.jsonl")
        XCTAssertEqual(dir.path, "/Users/x/.claude/projects/proj/63fe1073/subagents")
    }

    func testParseExtractsToolUseCalls() throws {
        let line = #"{"type":"assistant","agentId":"a","timestamp":"2026-06-01T10:00:01.000Z","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/tmp/x.swift"}}]}}"#
        let r = try XCTUnwrap(SubagentParsing.parseLine(line[...]))
        XCTAssertEqual(r.toolCalls.count, 2)
        XCTAssertEqual(r.toolCalls[0].name, "Bash")
        XCTAssertEqual(r.toolCalls[0].summary, "ls -la")
        XCTAssertEqual(r.toolCalls[1].name, "Read")
        XCTAssertEqual(r.toolCalls[1].summary, "/tmp/x.swift")
    }

    func testStringContentDoesNotBreakRecord() throws {
        // user 消息 content 为 string —— 不报错、不丢记录、无 tool 调用
        let line = #"{"type":"user","agentId":"a","message":{"content":"just a string"}}"#
        let r = try XCTUnwrap(SubagentParsing.parseLine(line[...]))
        XCTAssertEqual(r.type, "user")
        XCTAssertTrue(r.toolCalls.isEmpty)
    }
}
