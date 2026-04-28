import Foundation
import XCTest
@testable import CCDashboard

final class TrustStoreTests: XCTestCase {

    private func makeStore() -> TrustStore {
        TrustStore(defaults: isolatedDefaults())
    }

    // MARK: - 空 store 返回空 dict

    func testEmptyStoreLoadsEmpty() {
        XCTAssertTrue(makeStore().loadAll().isEmpty)
    }

    // MARK: - setForever / loadAll roundtrip

    func testSetForeverPersistsAndLoads() {
        let store = makeStore()
        store.setForever(cwd: "/proj")
        let entry = store.loadAll()["/proj"]
        XCTAssertEqual(entry?.mode, .forever)
    }

    // MARK: - setUntil / loadAll roundtrip 包含 Date

    func testSetUntilPersistsAndLoads() {
        let store = makeStore()
        let until = Date(timeIntervalSinceNow: 1800)
        store.setUntil(cwd: "/proj", until: until)
        let entry = store.loadAll()["/proj"]
        guard case .until(let d) = entry?.mode else {
            return XCTFail("expected .until")
        }
        XCTAssertEqual(d.timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - clear 删除条目

    func testClearRemovesEntry() {
        let store = makeStore()
        store.setForever(cwd: "/proj")
        XCTAssertNotNil(store.loadAll()["/proj"])

        store.clear(cwd: "/proj")
        XCTAssertNil(store.loadAll()["/proj"])
    }

    // MARK: - 后写覆盖前写

    func testSetOverwritesPriorMode() {
        let store = makeStore()
        store.setUntil(cwd: "/proj", until: Date(timeIntervalSinceNow: 600))
        store.setForever(cwd: "/proj")
        XCTAssertEqual(store.loadAll()["/proj"]?.mode, .forever)
    }

    // MARK: - 空 cwd 不写

    func testEmptyCwdIgnored() {
        let store = makeStore()
        store.setForever(cwd: "")
        store.setUntil(cwd: "", until: Date(timeIntervalSinceNow: 100))
        store.clear(cwd: "")
        XCTAssertTrue(store.loadAll().isEmpty)
    }
}
