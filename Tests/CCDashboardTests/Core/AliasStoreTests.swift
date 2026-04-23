import Foundation
import XCTest
@testable import CCDashboard

/// AliasStore 单测:用 UserDefaults(suiteName:) 隔离,确保不污染 `UserDefaults.standard`
/// (其他 test / 本机真机都用得到那个 domain)。
final class AliasStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.alias.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - 基本 roundtrip

    func testSetGetRoundtrip() {
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "/a", alias: "Project Alpha")
        XCTAssertEqual(store.get(cwd: "/a"), "Project Alpha")
    }

    func testGetReturnsNilForUnknownCwd() {
        let store = AliasStore(defaults: defaults)
        XCTAssertNil(store.get(cwd: "/nowhere"))
    }

    // MARK: - 清除语义:nil / 空串 / 纯空白 都清除

    func testNilAliasClearsEntry() {
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "/a", alias: "x")
        store.set(cwd: "/a", alias: nil)
        XCTAssertNil(store.get(cwd: "/a"))
    }

    func testEmptyAliasClearsEntry() {
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "/a", alias: "x")
        store.set(cwd: "/a", alias: "")
        XCTAssertNil(store.get(cwd: "/a"))
    }

    func testWhitespaceOnlyAliasClearsEntry() {
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "/a", alias: "x")
        store.set(cwd: "/a", alias: "   \n\t  ")
        XCTAssertNil(store.get(cwd: "/a"))
    }

    // MARK: - cwd 为空 → no-op

    func testEmptyCwdIgnoredOnSet() {
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "", alias: "x")
        // 不崩,get 空串永远 nil
        XCTAssertNil(store.get(cwd: ""))
    }

    func testEmptyCwdIgnoredOnGet() {
        let store = AliasStore(defaults: defaults)
        XCTAssertNil(store.get(cwd: ""))
    }

    // MARK: - 规范化:trim whitespace/newline,tab 替换为空格

    func testTrimsLeadingAndTrailingWhitespace() {
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "/a", alias: "  my project\n")
        XCTAssertEqual(store.get(cwd: "/a"), "my project")
    }

    func testReplacesInternalNewlinesWithSpaces() {
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "/a", alias: "line1\nline2")
        XCTAssertEqual(store.get(cwd: "/a"), "line1 line2")
    }

    // MARK: - 长度上限

    func testCapsLengthAt64() {
        let long = String(repeating: "x", count: 200)
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "/a", alias: long)
        XCTAssertEqual(store.get(cwd: "/a")?.count, 64)
    }

    // MARK: - 跨实例持久化(同一 UserDefaults suite)

    func testPersistsAcrossInstances() {
        AliasStore(defaults: defaults).set(cwd: "/a", alias: "persisted")
        let another = AliasStore(defaults: defaults)
        XCTAssertEqual(another.get(cwd: "/a"), "persisted")
    }

    // MARK: - load() 整体快照

    func testLoadReturnsFullDict() {
        let store = AliasStore(defaults: defaults)
        store.set(cwd: "/a", alias: "A")
        store.set(cwd: "/b", alias: "B")
        let dict = store.load()
        XCTAssertEqual(dict["/a"], "A")
        XCTAssertEqual(dict["/b"], "B")
    }
}
