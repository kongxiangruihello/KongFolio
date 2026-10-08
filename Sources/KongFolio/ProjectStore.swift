import Foundation
import PDFKit

struct ImageRecipe: Codable {
    var originalPDF: Data
    var adjustments: ImageAdjustments
}
struct ProjectArchive: Codable {
    var version = 3
    var reading: ReadingState? = nil
    var ocrOriginals: [Int: Data]? = nil
    var ocrRegions: [Int: [RecognizedLine]]? = nil
    var pdf: Data
    var title: String
    var selection: Int
    var selectedPages: Set<Int>
    var mode: String
    var recipes: [Int: ImageRecipe]
    var drafts: [Int: ImageAdjustments]
    var dirty: Bool
    var projectPath: String?
    func validate() throws {
        guard (2...3).contains(version), let doc = PDFDocument(data: pdf), !doc.isLocked, doc.pageCount > 0,
              selection >= 0, selection < doc.pageCount,
              selectedPages.allSatisfy({ $0 >= 0 && $0 < doc.pageCount }),
              recipes.keys.allSatisfy({ $0 >= 0 && $0 < doc.pageCount }) else {
            throw FolioError(message: "项目格式不受支持或数据已损坏。")
        }
        for recipe in recipes.values {
            guard PDFDocument(data: recipe.originalPDF)?.pageCount == 1 else { throw FolioError(message: "原始图片数据损坏。") }
        }
    }
    static func read(_ url: URL) throws -> ProjectArchive {
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: url))
        try archive.validate(); return archive
    }
    func write(_ url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
// Serial writes prevent an older debounced snapshot from replacing a newer one.
final class RecoveryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kongfolio.recovery", qos: .utility)
    func write(_ archive: ProjectArchive, to url: URL, completion: @escaping (Error?) -> Void) {
        queue.async { do { try archive.write(url); completion(nil) } catch { completion(error) } }
    }
    func flush(_ archive: ProjectArchive?, to url: URL) throws {
        try queue.sync {
            if let archive { try archive.write(url) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
enum PageRange {
    static func parse(_ text: String, count: Int) throws -> [Int] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolioError(message: "请输入页码，例如 1–3, 5。") }
        var result = Set<Int>()
        let normalized = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        for raw in normalized.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(parts.count), let start = Int(parts[0]), start >= 1, start <= count else { throw FolioError(message: "页码必须在 1…\(count) 之间。") }
            let end = parts.count == 2 ? Int(parts[1]) : start
            guard let end, end >= start, end <= count else { throw FolioError(message: "页码范围无效：\(raw)") }
            result.formUnion((start...end).map { $0 - 1 })
        }
        return result.sorted()
    }
}
struct SignatureTemplate: Codable, Identifiable {
    var id = UUID()
    var name: String
    var pdf: Data
}
