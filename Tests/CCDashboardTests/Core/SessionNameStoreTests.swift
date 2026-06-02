import Foundation
import XCTest
@testable import CCDashboard

/// SessionNameStore 单测:用隔离 suite,逻辑镜像 AliasStore 但键 sessionId。
final class SessionNameStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.sessionname.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSetGetRoundtrip() {
        let store = SessionNameStore(defaults: defaults)
        store.set(id: "sess-1", name: "Refactor auth")
        XCTAssertEqual(store.get(id: "sess-1"), "Refactor auth")
    }

    func testNilAndEmptyClear() {
        let store = SessionNameStore(defaults: defaults)
        store.set(id: "s", name: "x")
        store.set(id: "s", name: nil)
        XCTAssertNil(store.get(id: "s"))
        store.set(id: "s", name: "y")
        store.set(id: "s", name: "   \n ")
        XCTAssertNil(store.get(id: "s"))
    }

    func testEmptyIdIgnored() {
        let store = SessionNameStore(defaults: defaults)
        store.set(id: "", name: "x")
        XCTAssertNil(store.get(id: ""))
    }

    func testTrimAndCap() {
        let store = SessionNameStore(defaults: defaults)
        store.set(id: "a", name: "  hi\nthere  ")
        XCTAssertEqual(store.get(id: "a"), "hi there")
        store.set(id: "b", name: String(repeating: "x", count: 200))
        XCTAssertEqual(store.get(id: "b")?.count, 64)
    }

    func testKeysAreIndependent() {
        let store = SessionNameStore(defaults: defaults)
        store.set(id: "a", name: "A")
        store.set(id: "b", name: "B")
        XCTAssertEqual(store.get(id: "a"), "A")
        XCTAssertEqual(store.get(id: "b"), "B")
    }
}
