import Foundation
import PDFKit

/// Local companion to a plain PDF. It never modifies the original and is accepted only for the saved bytes.
enum ReadingDocumentStore {
    struct Record: Codable {
        var version = 1
        var digest: String
        var reading: ReadingState?
        var signatures: [Int: SignatureEditArchive]?
        var originals: [Int: Data]?
        var regions: [Int: [RecognizedLine]]?
        var word: WordDraftArchive?
        var tables: [TableDraftRecord]?
        init(_ archive: ProjectArchive) {
            digest = OCRPageCache.digest(archive.pdf); reading = archive.reading
            signatures = archive.signatureEdits; originals = archive.ocrOriginals; regions = archive.ocrRegions
            word = archive.wordDraft; tables = archive.tableDrafts
        }
        func archive(pdf: Data, source: URL) throws -> ProjectArchive {
            var value = ProjectArchive(sourcePath: source.path, pdf: pdf, title: source.deletingPathExtension().lastPathComponent,
                selection: 0, selectedPages: [0], mode: .document, recipes: [:], drafts: [:], dirty: false, projectPath: nil)
            value.reading = reading; value.signatureEdits = signatures; value.ocrOriginals = originals
            value.ocrRegions = regions; value.wordDraft = word; value.tableDrafts = tables
            try value.validate()
            let count = PDFDocument(data: pdf)?.pageCount ?? 0
            guard (reading?.bookmarks ?? []).allSatisfy({ (0..<count).contains($0.page) }),
                  (reading?.outline ?? []).allSatisfy({ (0..<count).contains($0.page) }) else { throw FolioError(message: "阅读资料的页码无效，原记录已保留") }
            return value
        }
    }
    static func location(_ source: URL, storage: URL) -> URL {
        storage.appendingPathComponent("ReadingDocuments", isDirectory: true)
            .appendingPathComponent(OCRPageCache.digest(Data(source.resolvingSymlinksInPath().standardizedFileURL.path.utf8)) + ".json")
    }
    static func write(_ archive: ProjectArchive, source: URL, storage: URL) throws {
        let target = location(source, storage: storage)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let next = Record(archive)
        if let oldBytes = try? Data(contentsOf: target) {
            let old = try? JSONDecoder().decode(Record.self, from: oldBytes)
            if old?.digest != next.digest {
                let previous = old == nil
                    ? target.deletingLastPathComponent().appendingPathComponent(target.deletingPathExtension().lastPathComponent + "-损坏记录-" + UUID().uuidString + ".json")
                    : target.deletingPathExtension().appendingPathExtension("previous.json")
                try oldBytes.write(to: previous, options: .atomic)
            }
        }
        try JSONEncoder().encode(next).write(to: target, options: .atomic)
    }
    static func relink(from old: URL, to new: URL, storage: URL) throws {
        guard new.pathExtension.lowercased() == "pdf" else { return }
        let target = location(new, storage: storage), previous = location(old, storage: storage)
        guard target != previous, !FileManager.default.fileExists(atPath: target.path),
              let bytes = try? Data(contentsOf: previous), let value = try? JSONDecoder().decode(Record.self, from: bytes),
              value.digest == OCRPageCache.digest(try Data(contentsOf: new)) else { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)
    }
    /// A changed original must not receive page-specific records belonging to an older version.
    static func read(source: URL, pdf: Data, storage: URL) throws -> ProjectArchive? {
        let target = location(source, storage: storage), digest = OCRPageCache.digest(pdf)
        if FileManager.default.fileExists(atPath: target.path) {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: target))
            guard record.version == 1, record.digest == digest else { throw FolioError(message: "原 PDF 已有变化，旧书签和校对资料已保留，未套用到新页面；可在版本历史中查看。") }
            return try record.archive(pdf: pdf, source: source)
        }
        // Recover metadata saved by 0.37 and earlier, but only when the exact on-disk version matches.
        if let entry = try DocumentHistory.list(source: source, storage: storage).first(where: { $0.diskDigest == digest }) {
            let archive = try DocumentHistory.read(entry, source: source, storage: storage)
            guard archive.pdf == pdf else { return nil }
            try write(archive, source: source, storage: storage)
            return archive
        }
        return nil
    }
}
