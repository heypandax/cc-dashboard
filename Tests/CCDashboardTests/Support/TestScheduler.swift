import Foundation

/// 测试用确定性时钟。替换 `SessionStore` 的 `now` / `delay` 闭包,
/// 让 auto-allow 过期和 session purge 的定时逻辑可以通过 `advance(bySeconds:)` 快进,
/// 不用真 sleep 10 秒 / 60 秒。
///
/// 实现上不是 actor —— 因为 `SessionStore` 的 `now: () -> Date` 是同步签名,
/// actor 属性必须 await。改用 class + NSLock 守护 mutable state。
final class TestScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var elapsedNanos: UInt64 = 0
    private var pending: [Pending] = []

    private struct Pending {
        let deadlineNanos: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.start = start
    }

    /// 从 `start + elapsedNanos` 派生 —— 单一 source of truth。
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return start.addingTimeInterval(TimeInterval(elapsedNanos) / 1_000_000_000)
    }

    func sleep(nanos: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            let deadline = elapsedNanos &+ nanos
            if nanos == 0 || deadline <= elapsedNanos {
                lock.unlock()
                continuation.resume()
                return
            }
            pending.append(Pending(deadlineNanos: deadline, continuation: continuation))
            lock.unlock()
        }
    }

    func advance(byNanos nanos: UInt64) {
        lock.lock()
        elapsedNanos &+= nanos
        let due = pending.filter { $0.deadlineNanos <= elapsedNanos }
        pending.removeAll { $0.deadlineNanos <= elapsedNanos }
        lock.unlock()
        for p in due {
            p.continuation.resume()
        }
    }

    func advance(bySeconds seconds: Double) {
        advance(byNanos: UInt64(seconds * 1_000_000_000))
    }
}
