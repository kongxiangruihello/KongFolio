import Foundation
import PDFKit

extension Workspace {
    var estimatedResidentBytes: Int {
        let raw = cachedPDF?.count ?? incrementalBase?.count ?? 0
        return raw * 3 + count * 192_000 + history.reduce(0) { $0 + $1.snapshotBytes }
            + ocrOriginals.values.reduce(0) { $0 + $1.count }
    }
}

/// A bounded local heartbeat records stalls without names, paths, document text or automatic uploads.
final class ResponsivenessMonitor: @unchecked Sendable {
    private let lock = NSLock()
    struct Event: Codable { var time: Date; var action: String; var facts: [String: Int] }
    private var events: [Event] = []
    private var pendingBeat = false
    private var lastBeat = Date()
    func record(_ action: String, facts: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        events.append(Event(time: Date(), action: action, facts: facts))
        if events.count > 32 { events.removeFirst(events.count-32) }
    }
    private let timer: DispatchSourceTimer
    init(storage: URL) {
        let target = storage.appendingPathComponent("Diagnostics/stalls.jsonl")
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.kongfolio.heartbeat", qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let elapsed = Date().timeIntervalSince(self.lastBeat); let events = self.events
            let needsBeat = !self.pendingBeat
            if needsBeat { self.pendingBeat = true }
            self.lock.unlock()
            if elapsed >= 3 {
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var bytes = (try? Data(contentsOf: target)) ?? Data()
                if bytes.count > 128_000 { bytes = Data() }
                let encoded = (try? JSONEncoder().encode(events)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
                let record: [String: Any] = ["time": Date().timeIntervalSince1970, "mainThreadDelaySeconds": elapsed, "processUptime": ProcessInfo.processInfo.systemUptime, "recentOperations": encoded]
                if let data = try? JSONSerialization.data(withJSONObject: record) { bytes.append(data); bytes.append(10); try? bytes.write(to: target, options: .atomic) }
            }
            if needsBeat { DispatchQueue.main.async { [weak self] in guard let self else { return }; self.lock.lock(); self.lastBeat = Date(); self.pendingBeat = false; self.lock.unlock() } }
        }
        timer.resume()
    }
    deinit { timer.cancel() }
}

extension WorkspaceStore {
    func recordActivity(_ action: String) {
        let workspaces = tabs.compactMap(\.workspace)
        diagnosticMonitor?.record(action, facts: ["openTabs": tabs.count, "loadedDocuments": workspaces.filter { $0.count > 0 }.count,
            "estimatedMemoryMB": workspaces.reduce(0) { $0 + $1.estimatedResidentBytes } / 1048576,
            "pendingSaves": workspaces.filter { $0.saving || $0.dirty }.count,
            "runningTasks": workspaces.filter(\.busy).count, "cloudImports": workspaces.filter(\.isImporting).count])
    }
}
