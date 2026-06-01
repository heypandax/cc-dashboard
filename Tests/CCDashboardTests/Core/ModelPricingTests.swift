import Foundation
import XCTest
@testable import CCDashboard

final class ModelPricingTests: XCTestCase {

    func testHaikuCacheReadDominantDoesNotBlowUp() throws {
        // cache_read 主导(116 万)但单价低 —— 分档乘价后不应被夸大成一个数量级。
        let usage = TokenUsage(inputTokens: 20_000, outputTokens: 5_000,
                               cacheCreationTokens: 200_000, cacheReadTokens: 1_160_000)
        let cost = try XCTUnwrap(ModelPricing.estimatedCostUSD(model: "claude-haiku-4-5-20251001", usage: usage))
        // (20000*1 + 5000*5 + 200000*1.25 + 1160000*0.1)/1e6 = 411000/1e6
        XCTAssertEqual(cost, 0.411, accuracy: 1e-9)
    }

    func testOpusAndSonnetInputRates() throws {
        let oneM = TokenUsage(inputTokens: 1_000_000, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        XCTAssertEqual(try XCTUnwrap(ModelPricing.estimatedCostUSD(model: "claude-opus-4-8", usage: oneM)), 15.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ModelPricing.estimatedCostUSD(model: "claude-sonnet-4-6", usage: oneM)), 3.0, accuracy: 1e-9)
    }

    func testUnknownModelReturnsNilCost() {
        let u = TokenUsage(inputTokens: 100, outputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 0)
        XCTAssertNil(ModelPricing.estimatedCostUSD(model: "gpt-4o", usage: u))
        XCTAssertNil(ModelPricing.estimatedCostUSD(model: nil, usage: u))
    }
}
