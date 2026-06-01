import Foundation

/// subagent 转录(`<sid>/subagents/agent-<id>.jsonl`)与边车(`.meta.json`)的纯解析层。
/// 从 watcher 拆出来 —— 零 IO、零 timer、可 fixture 单测。所有函数对坏数据返回 nil / 跳过,绝不抛。
///
/// Swift 6 并发安全:不持有 static 的 JSONDecoder / DateFormatter(非 Sendable),
/// 每次按需在函数内构造(批量入口 `records(from:)` 一个 chunk 只造一份)。
enum SubagentParsing {

    /// 一条我们关心的 JSONL 记录。不关心的字段不解。
    struct Record: Sendable, Equatable {
        let type: String            // "user" | "assistant"
        let agentId: String?
        let model: String?          // assistant only
        let usage: TokenUsage?      // assistant only(4 个扁平字段)
        let stopReason: String?     // assistant only
        let timestamp: Date?
        let toolCalls: [AgentToolCall]
    }

    /// agent-<id>.meta.json。`toolUseId` 双形态 —— 实测仅约 1/3 文件带,可为 nil。
    struct Meta: Sendable, Equatable {
        let agentType: String
        let description: String
        let toolUseId: String?
    }

    // MARK: Path / filename helpers

    /// `.../<session_id>.jsonl` → `.../<session_id>/subagents`
    static func subagentsDir(forTranscriptPath path: String) -> URL {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathComponent("subagents")
    }

    /// 从 tool_use 的 input 里取一行摘要 —— 优先 command / 路径 / url 等,取不到返空串。
    static func toolSummary(_ input: [String: AnyCodable]?) -> String {
        guard let input else { return "" }
        for k in ["command", "file_path", "path", "pattern", "url", "subagent_type", "query", "description", "prompt"] {
            if let v = input[k]?.value as? String, !v.isEmpty { return v }
        }
        return ""
    }

    /// `agent-<id>.jsonl` / `agent-<id>.meta.json` → `<id>`(非该形态返 nil)
    static func agentId(fromFileName name: String) -> String? {
        guard name.hasPrefix("agent-") else { return nil }
        var rest = name.dropFirst("agent-".count)
        if rest.hasSuffix(".meta.json") {
            rest = rest.dropLast(".meta.json".count)
        } else if rest.hasSuffix(".jsonl") {
            rest = rest.dropLast(".jsonl".count)
        } else {
            return nil
        }
        return rest.isEmpty ? nil : String(rest)
    }

    // MARK: Decoding

    /// 批量解析一个 chunk(保证由完整行组成 —— watcher 只读到最后一个换行)。一个 chunk 共用一份 decoder。
    static func records(from chunk: String) -> [Record] {
        let ctx = DecodeContext()
        return chunk
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { ctx.parse($0) }
    }

    /// 单行入口 —— 主要给单测用。空行 / 半行 / 不关心的行 → nil。
    static func parseLine(_ line: Substring) -> Record? {
        DecodeContext().parse(line)
    }

    /// meta.json → Meta。malformed 或缺 agentType → nil。
    static func parseMeta(_ data: Data) -> Meta? {
        guard let raw = try? JSONDecoder().decode(RawMeta.self, from: data),
              let agentType = raw.agentType else { return nil }
        return Meta(agentType: agentType, description: raw.description ?? "", toolUseId: raw.toolUseId)
    }

    // MARK: Accumulation

    /// 把一批新记录折叠进累加器。usage 只累加 assistant 记录;model 取最近一条 assistant 的
    /// (subagent 可能中途切模型);见到任一 assistant 的 stop_reason==end_turn 即判终态
    /// (一个 agent 转录只会在最后一条出现 end_turn,中间 tool_use 步是 "tool_use")。
    /// 终态 end_turn 记录本身带最终 usage,所以必须把它一起累加。
    static func accumulate(
        into usage: inout TokenUsage,
        model: inout String?,
        toolCalls: inout [AgentToolCall],
        records: [Record]
    ) -> (terminalEndTurn: Bool, lastTimestamp: Date?) {
        var terminal = false
        var lastTs: Date?
        for r in records {
            if let ts = r.timestamp { lastTs = ts }
            guard r.type == "assistant" else { continue }
            if let u = r.usage { usage = usage + u }
            if let m = r.model { model = m }
            if r.stopReason == "end_turn" { terminal = true }
            toolCalls.append(contentsOf: r.toolCalls)
        }
        // 只留最近 60 条 —— 大 agent 可能上千次调用,详情面板只看近况。
        if toolCalls.count > 60 { toolCalls.removeFirst(toolCalls.count - 60) }
        return (terminal, lastTs)
    }

    // MARK: - Private

    /// 一份 decoder + 两个 ISO8601 formatter 的复用容器。非 Sendable,只在单个 records(from:)
    /// 调用内同步使用,不跨线程逃逸。
    private final class DecodeContext {
        let decoder = JSONDecoder()
        let isoFractional: ISO8601DateFormatter
        let isoPlain: ISO8601DateFormatter

        init() {
            isoFractional = ISO8601DateFormatter()
            isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
        }

        func parse(_ line: Substring) -> Record? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let raw = try? decoder.decode(RawRecord.self, from: data),
                  let type = raw.type else { return nil }

            let usage: TokenUsage? = raw.message?.usage.map {
                TokenUsage(
                    inputTokens: $0.input_tokens ?? 0,
                    outputTokens: $0.output_tokens ?? 0,
                    cacheCreationTokens: $0.cache_creation_input_tokens ?? 0,
                    cacheReadTokens: $0.cache_read_input_tokens ?? 0
                )
            }
            let ts = raw.timestamp.flatMap { isoFractional.date(from: $0) ?? isoPlain.date(from: $0) }
            let calls: [AgentToolCall] = (raw.message?.content ?? []).compactMap { block in
                guard block.type == "tool_use", let id = block.id else { return nil }
                return AgentToolCall(id: id, name: block.name ?? "tool",
                                     summary: SubagentParsing.toolSummary(block.input), at: ts)
            }
            return Record(
                type: type,
                agentId: raw.agentId,
                model: raw.message?.model,
                usage: usage,
                stopReason: raw.message?.stop_reason,
                timestamp: ts,
                toolCalls: calls
            )
        }
    }

    // snake_case 直映;只声明关心的字段,其余(content / uuid / cache_creation 嵌套等)忽略。
    private struct RawRecord: Decodable {
        let type: String?
        let agentId: String?
        let timestamp: String?
        let message: RawMessage?

        struct RawMessage: Decodable {
            let model: String?
            let stop_reason: String?
            let usage: RawUsage?
            let content: [RawContentBlock]?

            enum CodingKeys: String, CodingKey { case model, stop_reason, usage, content }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                model = try? c.decode(String.self, forKey: .model)
                stop_reason = try? c.decode(String.self, forKey: .stop_reason)
                usage = try? c.decode(RawUsage.self, forKey: .usage)
                // content 在 user 消息里可能是 string(非数组)—— try? 容错取不到当 nil,不丢整条记录的 usage。
                content = try? c.decode([RawContentBlock].self, forKey: .content)
            }
        }
        struct RawContentBlock: Decodable {
            let type: String?
            let id: String?
            let name: String?
            let input: [String: AnyCodable]?
        }
        struct RawUsage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
    }

    private struct RawMeta: Decodable {
        let agentType: String?
        let description: String?
        let toolUseId: String?
    }
}
