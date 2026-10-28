import Foundation

struct HistoryPolicy: Codable, Equatable {
    var maximumEntries = 10
    var perFileMB = 512
    var totalMB = 2048
    var valid: Bool { (2...100).contains(maximumEntries) && (16...4096).contains(perFileMB) && (256...16384).contains(totalMB) }
    static func load(storage: URL) -> Self {
        guard let data = try? Data(contentsOf: storage.appendingPathComponent("HistorySettings.json")), let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return Self() }; return value
    }
    func save(storage: URL) throws {
        guard valid else { throw FolioError(message: "请检查历史版本数量及容量范围") }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: storage.appendingPathComponent("HistorySettings.json"), options: .atomic)
    }
}

enum HistoryRetention {
    static let queue = DispatchQueue(label: "com.kongfolio.history")
    struct Usage { var bytes = 0; var versions = 0; var files = 0 }
    private struct Timeline { var folder: URL; var suffix: String; var rows: [[String: Any]] }
    private static func timelines(storage: URL) throws -> [Timeline] {
        var result: [Timeline] = []
        for (root, suffix) in [("History", ".kongfolio"), ("TextHistory", ".json")] {
            let directory = storage.appendingPathComponent(root)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let index = folder.appendingPathComponent("index.json")
                guard FileManager.default.fileExists(atPath: index.path) else { continue }
                let data = try Data(contentsOf: index)
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.allSatisfy({ row in
                    guard let id = row["id"] as? String, UUID(uuidString: id) != nil, let bytes = row["bytes"] as? Int, bytes >= 0, let created = row["created"] as? Double, created.isFinite else { return false }; return true
                }), Set(rows.compactMap { $0["id"] as? String }).count == rows.count else { throw FolioError(message: "历史索引无法核对，未清理：" + folder.lastPathComponent) }
                result.append(Timeline(folder: folder, suffix: suffix, rows: rows))
            }
        }
        return result
    }
    static func usage(storage: URL) throws -> Usage {
        try queue.sync { let values = try timelines(storage: storage); return Usage(bytes: values.flatMap(\.rows).reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }, versions: values.reduce(0) { $0 + $1.rows.count }, files: values.count) }
    }
    /// Called on the shared history queue. Never deletes crash recovery, conflict copies or user documents.
    static func enforceUnlocked(storage: URL) throws {
        let policy = HistoryPolicy.load(storage: storage)
        var values = try timelines(storage: storage)
        var total = values.flatMap(\.rows).reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }
        let budget = policy.totalMB * 1024 * 1024
        for i in values.indices {
            while values[i].rows.count > 2 && (values[i].rows.count > policy.maximumEntries || values[i].rows.reduce(0, { $0 + ($1["bytes"] as? Int ?? 0) }) > policy.perFileMB * 1024 * 1024) {
                total -= try removeOldest(&values[i])
            }
        }
        while total > budget, let i = values.indices.filter({ values[$0].rows.count > 2 }).min(by: { (values[$0].rows.first?["created"] as? Double ?? 0) < (values[$1].rows.first?["created"] as? Double ?? 0) }) {
            total -= try removeOldest(&values[i])
        }
    }
    private static func removeOldest(_ timeline: inout Timeline) throws -> Int {
        guard let row = timeline.rows.first, let id = row["id"] as? String, UUID(uuidString: id) != nil else { throw FolioError(message: "历史索引无效，未清理") }
        let remaining = Array(timeline.rows.dropFirst())
        try JSONSerialization.data(withJSONObject: remaining, options: [.sortedKeys]).write(to: timeline.folder.appendingPathComponent("index.json"), options: .atomic)
        timeline.rows = remaining
        try? FileManager.default.removeItem(at: timeline.folder.appendingPathComponent(id + timeline.suffix))
        return row["bytes"] as? Int ?? 0
    }
    static func apply(storage: URL) throws { try queue.sync { try enforceUnlocked(storage: storage) } }
}
