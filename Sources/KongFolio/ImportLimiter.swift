import Foundation

actor ImportLimiter {
    static let shared = ImportLimiter()
    private var active = 0
    private(set) var maximum: Int
    init(maximum: Int = 2) { self.maximum = max(1,maximum) }
    func acquire() async throws {
        while active >= maximum { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 30_000_000) }
        try Task.checkCancellation(); active += 1
    }
    func setMaximum(_ value: Int) { maximum = max(1,min(2,value)) }
    func release() { active = max(0,active-1) }
    var running: Int { active }
}
