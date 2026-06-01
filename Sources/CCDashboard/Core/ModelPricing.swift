import Foundation

/// 单模型计价(美元 / 百万 token)。示意值 —— 以 Anthropic 官方价为准,集中放一处便于改价。
struct ModelRate: Sendable {
    let input: Double
    let output: Double
    let cacheWrite: Double   // cache_creation_input_tokens
    let cacheRead: Double    // cache_read_input_tokens
}

/// 按 message.model 前缀查价,估算单 agent 成本。
/// 成本永远是估算 —— UI 一律标 ≈;未知模型前缀返回 nil(只显 token,不显金额,避免拿错价误导)。
enum ModelPricing {
    /// 前缀匹配,robust 于版本 / 日期后缀(如 claude-haiku-4-5-20251001)。三档不相交。
    static let table: [(prefix: String, family: String, rate: ModelRate)] = [
        ("claude-opus",   "opus",   ModelRate(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("claude-sonnet", "sonnet", ModelRate(input: 3,  output: 15, cacheWrite: 3.75,  cacheRead: 0.3)),
        ("claude-haiku",  "haiku",  ModelRate(input: 1,  output: 5,  cacheWrite: 1.25,  cacheRead: 0.1)),
    ]

    private static func entry(for model: String?) -> (prefix: String, family: String, rate: ModelRate)? {
        guard let model else { return nil }
        return table.first { model.hasPrefix($0.prefix) }
    }

    static func rate(for model: String?) -> ModelRate? { entry(for: model)?.rate }

    /// 模型家族短名(opus/sonnet/haiku)—— UI chip 用,和计价共用同一张表的前缀,不另立一套分类。
    static func family(for model: String?) -> String? { entry(for: model)?.family }

    /// cache_read 通常占 token 总量的绝大头但单价仅 input 的约 1/10 —— 必须分档乘价,
    /// 否则成本夸大一个数量级。
    static func estimatedCostUSD(model: String?, usage: TokenUsage) -> Double? {
        guard let r = rate(for: model) else { return nil }
        return (Double(usage.inputTokens)         * r.input
              + Double(usage.outputTokens)        * r.output
              + Double(usage.cacheCreationTokens) * r.cacheWrite
              + Double(usage.cacheReadTokens)     * r.cacheRead) / 1_000_000.0
    }
}
