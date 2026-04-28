import Foundation
import XCTest
@testable import CCDashboard

final class NotifierTests: XCTestCase {

    // MARK: - foldedPrompt:短 prompt 原样返回

    func testShortPromptUntouched() {
        XCTAssertEqual(Notifier.foldedPrompt("hello"), "hello")
    }

    // MARK: - foldedPrompt:换行折成空格

    func testNewlinesCollapseToSpaces() {
        XCTAssertEqual(
            Notifier.foldedPrompt("first line\nsecond\r\nthird"),
            "first line second third"
        )
    }

    // MARK: - foldedPrompt:超长截断 + …

    func testLongPromptTruncatedWithEllipsis() {
        let long = String(repeating: "a", count: 200)
        let folded = Notifier.foldedPrompt(long, maxLen: 50)
        XCTAssertEqual(folded.count, 50)
        XCTAssertTrue(folded.hasSuffix("…"))
    }

    // MARK: - foldedPrompt:首尾空白 trim

    func testWhitespaceTrimmed() {
        XCTAssertEqual(Notifier.foldedPrompt("  spaced  "), "spaced")
    }
}
