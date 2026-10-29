import Foundation

enum AcademicDraftStore {
    struct Draft: Codable { var text: String; var source: String; var digest: String?; var modified: Date }
    static func location(source: String, storage: URL) -> URL { storage.appendingPathComponent("AcademicDrafts").appendingPathComponent(OCRPageCache.digest(Data(source.utf8)) + ".json") }
    static func write(_ draft: Draft, storage: URL) throws {
        let url = location(source: draft.source, storage: storage)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let old = try? Data(contentsOf: url), (try? JSONDecoder().decode(Draft.self, from: old)) == nil {
            try old.write(to: url.deletingPathExtension().appendingPathExtension("damaged-" + UUID().uuidString + ".json"), options: .atomic)
        }
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
    }
    static func read(source: String, storage: URL) throws -> Draft? {
        let url = location(source: source, storage: storage)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
    }
}
