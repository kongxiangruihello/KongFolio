import Foundation

/// Synchronous page recognition runs on workers; waits are bounded and check task cancellation.
final class OCRResourceGate: @unchecked Sendable {
    static let shared = OCRResourceGate()
    private let condition = NSCondition()
    private var limit = 2
    private var active = 0
    init(maximum:Int = 2) { limit = max(1,maximum) }
    func setMaximum(_ value:Int) { condition.lock(); limit = max(1,min(2,value)); condition.broadcast(); condition.unlock() }
    func acquire() throws {
        condition.lock(); defer { condition.unlock() }
        while active >= limit { try Task.checkCancellation(); _ = condition.wait(until:Date().addingTimeInterval(0.03)) }
        try Task.checkCancellation(); active += 1
    }
    func release() { condition.lock(); active = max(0,active-1); condition.broadcast(); condition.unlock() }
    var running: Int { condition.lock(); defer { condition.unlock() }; return active }
}
