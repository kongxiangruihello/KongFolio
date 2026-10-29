import Foundation

struct ReadingRuler: Codable, Equatable {
    enum Direction: String, Codable, CaseIterable { case horizontal = "横向阅读条", vertical = "竖向跟读列" }
    var enabled = false
    var direction = Direction.vertical
    var position = 0.5
    var thickness = 0.06
    var opacity = 0.22
    var valid: Bool { position.isFinite && thickness.isFinite && opacity.isFinite && (0...1).contains(position) && (0.01...0.3).contains(thickness) && (0.05...0.8).contains(opacity) }
    mutating func move(_ delta: Double) { position = min(1,max(0,position+delta)) }
    static func url(path: String, storage: URL) -> URL { storage.appendingPathComponent("ReadingRulers").appendingPathComponent(OCRPageCache.digest(Data(ReadingProgress.canonicalPath(path).utf8))+".json") }
    static func read(path: String, storage: URL) -> Self { guard let data = try? Data(contentsOf:url(path:path,storage:storage)), let value = try? JSONDecoder().decode(Self.self,from:data), value.valid else { return Self() }; return value }
    func save(path: String, storage: URL) throws {
        guard valid else { throw FolioError(message:"阅读尺设置无效") }
        let file = Self.url(path:path,storage:storage); try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(self).write(to:file,options:.atomic)
    }
}
extension Workspace {
    func loadReadingRulerIfNeeded() {
        guard let path = displayPath, ReadingProgress.canonicalPath(path) != rulerPath else { return }
        rulerTask?.cancel(); rulerPath = ReadingProgress.canonicalPath(path)
        restoringRuler = true; readingRuler = ReadingRuler.read(path:path,storage:storage); restoringRuler = false
    }
    func scheduleReadingRuler() {
        guard !restoringRuler, let path = rulerPath else { return }
        rulerTask?.cancel(); let value = readingRuler, root = storage
        rulerTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:300_000_000); try value.save(path:path,storage:root) }
            catch is CancellationError {} catch { self?.status = "阅读尺尚未保存：" + error.localizedDescription }
        }
    }
}
