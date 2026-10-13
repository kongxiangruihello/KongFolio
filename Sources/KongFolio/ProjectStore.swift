import CryptoKit
import Foundation
import PDFKit

struct ImageRecipe: Codable {
    var originalPDF: Data
    var adjustments: ImageAdjustments
}

/// In-memory model of a KongFolio project. Format 4 stores it in a binary container
/// (see `ProjectContainer`); formats 2 and 3 were a single JSON document with Base64 blobs.
struct ProjectArchive: Codable {
    static let currentVersion = 4
    var version = ProjectArchive.currentVersion
    var reading: ReadingState? = nil
    var ocrOriginals: [Int: Data]? = nil
    var ocrRegions: [Int: [RecognizedLine]]? = nil
    var pdf: Data
    var title: String
    var selection: Int
    var selectedPages: Set<Int>
    var mode: WorkspaceMode
    var recipes: [Int: ImageRecipe]
    var drafts: [Int: ImageAdjustments]
    var dirty: Bool
    var projectPath: String?

    func validate() throws {
        guard (2...ProjectArchive.currentVersion).contains(version), let doc = PDFDocument(data: pdf), !doc.isLocked, doc.pageCount > 0 else {
            throw FolioError(message: "项目格式不受支持或数据已损坏。")
        }
        let pages = 0..<doc.pageCount
        let indexSets: [[Int]] = [
            [selection], Array(selectedPages), Array(recipes.keys), Array(drafts.keys),
            Array((ocrOriginals ?? [:]).keys), Array((ocrRegions ?? [:]).keys),
        ]
        guard indexSets.allSatisfy({ $0.allSatisfy(pages.contains) }) else {
            throw FolioError(message: "项目格式不受支持或数据已损坏。")
        }
        for recipe in recipes.values {
            guard PDFDocument(data: recipe.originalPDF)?.pageCount == 1 else { throw FolioError(message: "原始图片数据损坏。") }
        }
    }

    static func read(_ url: URL) throws -> ProjectArchive {
        var isDirectory: ObjCBool = false
        let archive: ProjectArchive
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            archive = try RecoveryStore.read(url)
        } else {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if data.starts(with: ProjectContainer.magic) { archive = try ProjectContainer.decode(data) }
            else { archive = try JSONDecoder().decode(ProjectArchive.self, from: data) }
        }
        try archive.validate()
        return archive
    }

    func write(_ url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectContainer.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Blob separation

    /// Splits the large binary payloads out of the archive so they can be stored raw.
    func separated() -> (manifest: ProjectArchive, blobs: [(key: String, data: Data)]) {
        var manifest = self
        var blobs: [(key: String, data: Data)] = [("pdf", pdf)]
        manifest.pdf = Data()
        for (page, recipe) in recipes.sorted(by: { $0.key < $1.key }) {
            blobs.append(("recipe/\(page)", recipe.originalPDF))
            manifest.recipes[page]?.originalPDF = Data()
        }
        if let originals = ocrOriginals {
            for (page, data) in originals.sorted(by: { $0.key < $1.key }) {
                blobs.append(("ocr/\(page)", data))
                manifest.ocrOriginals?[page] = Data()
            }
        }
        return (manifest, blobs)
    }

    /// Reverses `separated()`.
    func joined(_ blob: (String) throws -> Data) throws -> ProjectArchive {
        var archive = self
        archive.pdf = try blob("pdf")
        for page in recipes.keys { archive.recipes[page]?.originalPDF = try blob("recipe/\(page)") }
        if let originals = ocrOriginals {
            for page in originals.keys { archive.ocrOriginals?[page] = try blob("ocr/\(page)") }
        }
        return archive
    }
}

/// Single-file project container: magic line, 8-byte big-endian manifest length, JSON manifest, raw blobs.
/// Blobs are not Base64 encoded, so a project is roughly the size of its PDFs instead of a third larger.
enum ProjectContainer {
    static let magic = Data("KONGFOLIO-PROJECT\n".utf8)

    struct Manifest: Codable {
        var archive: ProjectArchive
        var blobs: [String: BlobRange]
    }

    struct BlobRange: Codable {
        var offset: Int
        var length: Int
    }

    static func encode(_ archive: ProjectArchive) throws -> Data {
        var stored = archive
        stored.version = ProjectArchive.currentVersion
        let (manifestArchive, blobs) = stored.separated()
        var ranges: [String: BlobRange] = [:]
        var offset = 0
        for blob in blobs {
            ranges[blob.key] = BlobRange(offset: offset, length: blob.data.count)
            offset += blob.data.count
        }
        let manifest = try JSONEncoder().encode(Manifest(archive: manifestArchive, blobs: ranges))
        var output = Data(capacity: magic.count + 8 + manifest.count + offset)
        output.append(magic)
        var length = UInt64(manifest.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(manifest)
        for blob in blobs { output.append(blob.data) }
        return output
    }

    static func decode(_ data: Data) throws -> ProjectArchive {
        let corrupt = FolioError(message: "项目文件已损坏。")
        guard data.count >= magic.count + 8, data.starts(with: magic) else { throw corrupt }
        let lengthStart = data.startIndex + magic.count
        let length = data[lengthStart..<(lengthStart + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let manifestStart = lengthStart + 8
        guard length <= UInt64(data.count - magic.count - 8) else { throw corrupt }
        let manifestEnd = manifestStart + Int(length)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data.subdata(in: manifestStart..<manifestEnd))
        let blobStart = manifestEnd
        return try manifest.archive.joined { key in
            guard let range = manifest.blobs[key], range.offset >= 0, range.length >= 0,
                  blobStart + range.offset + range.length <= data.endIndex else { throw corrupt }
            return data.subdata(in: (blobStart + range.offset)..<(blobStart + range.offset + range.length))
        }
    }
}

/// Recovery copy stored as a directory of content-addressed blobs plus a small manifest.
/// Unchanged originals (image recipes, pre-OCR pages) are written once and reused by later
/// autosaves; only the current PDF and the manifest are rewritten after each edit.
enum RecoveryStore {
    struct Manifest: Codable {
        var archive: ProjectArchive
        var blobs: [String: String]
    }

    static func write(_ archive: ProjectArchive, to directory: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try manager.removeItem(at: directory)
        }
        let blobFolder = directory.appendingPathComponent("blobs", isDirectory: true)
        try manager.createDirectory(at: blobFolder, withIntermediateDirectories: true)
        try archive.validate()
        let (manifestArchive, blobs) = archive.separated()
        var references: [String: String] = [:]
        for blob in blobs {
            let digest = SHA256.hash(data: blob.data).map { String(format: "%02x", $0) }.joined()
            let target = blobFolder.appendingPathComponent(digest)
            if !manager.fileExists(atPath: target.path) { try blob.data.write(to: target, options: .atomic) }
            references[blob.key] = digest
        }
        let manifest = try JSONEncoder().encode(Manifest(archive: manifestArchive, blobs: references))
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        // Only after the manifest points at the new blobs is it safe to drop the old ones.
        let live = Set(references.values)
        for name in (try? manager.contentsOfDirectory(atPath: blobFolder.path)) ?? [] where !live.contains(name) {
            try? manager.removeItem(at: blobFolder.appendingPathComponent(name))
        }
    }

    static func read(_ directory: URL) throws -> ProjectArchive {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let blobFolder = directory.appendingPathComponent("blobs", isDirectory: true)
        return try manifest.archive.joined { key in
            guard let digest = manifest.blobs[key] else { throw FolioError(message: "恢复副本缺少数据：\(key)") }
            return try Data(contentsOf: blobFolder.appendingPathComponent(digest), options: .mappedIfSafe)
        }
    }

    static func blobCount(_ directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path).count) ?? 0
    }
}

// Serial writes prevent an older debounced snapshot from replacing a newer one.
final class RecoveryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kongfolio.recovery", qos: .utility)

    func write(_ archive: ProjectArchive, to url: URL, completion: @escaping (Error?) -> Void) {
        queue.async {
            do { try RecoveryStore.write(archive, to: url); completion(nil) } catch { completion(error) }
        }
    }

    func flush(_ archive: ProjectArchive?, to url: URL) throws {
        try queue.sync {
            if let archive { try RecoveryStore.write(archive, to: url) }
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
