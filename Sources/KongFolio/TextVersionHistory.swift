import Foundation

struct TextVersionSnapshot: Codable {
    var text: String
    var format: TextDocumentFormat
    var resourceBasePath: String?
}

enum TextVersionHistory {
    static func folder(source: URL, storage: URL) -> URL { storage.appendingPathComponent("TextHistory/" + OCRPageCache.digest(Data(source.standardizedFileURL.path.utf8)), isDirectory: true) }
    private static func entries(_ folder: URL) throws -> [HistoryEntry] {
        let url = folder.appendingPathComponent("index.json")
        return FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: url)) : []
    }
    static func list(source: URL, storage: URL) throws -> [HistoryEntry] { try HistoryRetention.queue.sync { try entries(folder(source: source, storage: storage)).reversed() } }
    static func read(_ entry: HistoryEntry, source: URL, storage: URL) throws -> TextVersionSnapshot {
        try HistoryRetention.queue.sync {
            let directory = folder(source: source, storage: storage)
            guard try entries(directory).contains(where: { $0.id == entry.id }) else { throw FolioError(message: "这个版本已不在历史中") }
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.id.uuidString + ".json"))
            guard OCRPageCache.digest(data) == entry.digest else { throw FolioError(message: "历史版本校验失败，未恢复") }
            return try JSONDecoder().decode(TextVersionSnapshot.self, from: data)
        }
    }
    static func protectExisting(_ source: URL, storage: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let bytes = try Data(contentsOf: source)
        try record(TextVersionSnapshot(text: TextImport.normalized(try TextImport.decode(bytes)), format: TextDocumentFormat.forURL(source), resourceBasePath: source.deletingLastPathComponent().path), source: source, storage: storage, label: "覆盖前的原件", automatic: false)
    }
    static func record(_ snapshot: TextVersionSnapshot, source: URL, storage: URL, label: String, automatic: Bool = false, now: Date = Date()) throws {
        try HistoryRetention.queue.sync {
            let directory = folder(source: source, storage: storage)
            var values = try entries(directory)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot), digest = OCRPageCache.digest(data)
            if let last = values.last, let previous = try? Data(contentsOf: directory.appendingPathComponent(last.id.uuidString + ".json")), OCRPageCache.digest(previous) == last.digest,
               let previous = try? JSONDecoder().decode(TextVersionSnapshot.self, from: previous), previous.text == snapshot.text, previous.format == snapshot.format, previous.resourceBasePath == snapshot.resourceBasePath { return }
            let previous = values
            var entry = HistoryEntry(id: UUID(), created: now, pages: 0, label: label, digest: digest, diskDigest: "", bytes: data.count, automatic: automatic, groupStarted: now)
            if automatic, values.count >= 2, let last = values.last, last.automatic, (0..<60).contains(now.timeIntervalSince(last.groupStarted ?? last.created)) { entry.groupStarted = last.groupStarted ?? last.created; values.removeLast() }
            values.append(entry)
            let policy = HistoryPolicy.load(storage: storage)
            while values.count > policy.maximumEntries || (values.count > 2 && values.reduce(0, { $0 + $1.bytes }) > policy.perFileMB * 1024 * 1024) { values.removeFirst() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = directory.appendingPathComponent(entry.id.uuidString + ".json")
            try data.write(to: payload, options: .atomic)
            do { try encoder.encode(values).write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
            catch { try? FileManager.default.removeItem(at: payload); throw error }
            for old in previous where !values.contains(where: { $0.id == old.id }) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.id.uuidString + ".json")) }
            try HistoryRetention.enforceUnlocked(storage: storage)
        }
    }
}

extension MarkdownNote {
    var versionSnapshot: TextVersionSnapshot { TextVersionSnapshot(text: text, format: format, resourceBasePath: fileURL?.deletingLastPathComponent().path ?? recoveryBaseURL?.path) }
    @discardableResult func restoreTextVersion(_ entry: HistoryEntry) -> Bool {
        guard let source = fileURL else { return false }
        do {
            let archived = try TextVersionHistory.read(entry, source: source, storage: storage)
            // Retain current unsaved work and verify the original before making any change.
            guard let baseline = fileBaseline else { throw FileConflict() }; try baseline.verify(source)
            try TextVersionHistory.protectExisting(source, storage: storage)
            try TextVersionHistory.record(versionSnapshot, source: source, storage: storage, label: "恢复历史前的当前工作")
            let previous = versionSnapshot
            text = archived.text; format = archived.format; recoveryBaseURL = archived.resourceBasePath.map { URL(fileURLWithPath: $0) }
            restoringHistory = true
            defer { restoringHistory = false }
            do { try write(to: source) }
            catch { text = previous.text; format = previous.format; recoveryBaseURL = previous.resourceBasePath.map { URL(fileURLWithPath: $0) }; throw error }
            status = "已恢复历史版本；恢复前的工作已保留"; return true
        } catch { self.error = "无法恢复历史版本：" + error.localizedDescription; return false }
    }
}
