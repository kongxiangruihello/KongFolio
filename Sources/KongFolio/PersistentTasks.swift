import Foundation
import PDFKit

struct PersistentDocumentTask: Codable {
    enum Kind: String, Codable { case merge, flatten, table, word }
    var kind: Kind
    var destination: URL
    var expected: FileBaseline
    var sourceBaseline: FileBaseline? = nil
    var protectedSource: URL? = nil
    var sourceDigest = ""
    var pages: [Int] = []
    var draft: TableDraftRecord? = nil
    var removeHeaders = false
    var languages = ["zh-Hans", "en-US"]
    var suffix = ""
    var word: WordExportOptions? = nil
    var outline: [OutlineEntry] = []
    var regions: [Int: [RecognizedLine]] = [:]
    func run(source: Data, folder: URL, progress: @escaping @Sendable (Double) -> Void) throws -> DocumentTaskResult {
        guard OCRPageCache.digest(source) == sourceDigest else { throw FolioError(message: "任务快照已变化或损坏，已保留记录，请从原文重新开始") }
        if let original = protectedSource ?? sourceBaseline.map({ URL(fileURLWithPath:$0.path) }), DocumentTaskOutput.sameFile(original,destination) { throw FolioError(message:"导出结果请另存到其他位置，不能覆盖原件") }
        if let sourceBaseline { do { try sourceBaseline.verify(URL(fileURLWithPath:sourceBaseline.path)) } catch { throw FolioError(message:"原文件已变化或移走，任务快照和进度保留；请核对原文后重新开始任务") } }
        let document = try PDFDocument(data: source).unwrap("任务文档无法读取")
        guard pages.allSatisfy({ (0..<document.pageCount).contains($0) }), Set(pages).count == pages.count else { throw FolioError(message: "任务页码无效") }
        switch kind {
        case .merge:
            var value = try draft.unwrap("任务缺少表格草稿")
            let result = try TableMerge.extract(data: source, current: value, pages: pages, removeHeaders: removeHeaders, languages: languages, cache: folder, progress: progress)
            value.rows = result.rows; value.sourceRegions = result.regions; value.includeInWord = false; value.modified = Date(); try value.validate()
            try DocumentTaskOutput.write(to: destination, expected: expected) { try JSONEncoder().encode(value).write(to: $0) }
            return DocumentTaskResult(message: "已合并 \(result.regions.count) 页，草稿可继续核对", file: destination)
        case .flatten:
            let output = PDFDocument()
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                let page = try autoreleasepool { () throws -> PDFPage in
                    let cache = folder.appendingPathComponent("flat-\(index).pdf")
                    let bytes: Data
                    if FileManager.default.fileExists(atPath: cache.path) { bytes = try Data(contentsOf: cache) }
                    else {
                        let one = DocumentServices.subset(document, indexes: [index])
                        bytes = try PDFForms.flattened(one).dataRepresentation().unwrap("无法固定表单")
                        try bytes.write(to: cache, options: .atomic)
                    }
                    let part = try PDFDocument(data: bytes).unwrap("固定副本检查点无法读取")
                    guard part.pageCount == 1, let page = part.page(at: 0)?.copy() as? PDFPage else { throw FolioError(message: "固定副本检查点无效") }
                    return page
                }
                output.insert(page, at: output.pageCount); progress(Double(index + 1) / Double(max(document.pageCount,1)))
            }
            try DocumentTaskOutput.write(to: destination, expected: expected) { try output.dataRepresentation().unwrap("无法生成固定副本").write(to: $0) }
            return DocumentTaskResult(message: "固定副本已保存，原件保留", file: destination)
        case .table:
            let draft = try draft.unwrap("没有表格草稿"); try draft.validate()
            try DocumentTaskOutput.write(to: destination, expected: expected) { staging in
                switch suffix {
                case "xlsx": try TableStructure.writeExcel(rows: draft.rows, spans: draft.spans ?? [], to: staging)
                case "docx": try StructuredTableWord.write(draft, to: staging)
                case "md": try ExtractedTable(rows: draft.rows).markdown.write(to: staging, atomically: true, encoding: .utf8)
                case "csv": try ExtractedTable(rows: draft.rows).csv.write(to: staging, atomically: true, encoding: .utf8)
                default: throw FolioError(message: "表格导出格式不支持")
                }
            }
            progress(1); return DocumentTaskResult(message: "表格已导出", file: destination)
        case .word:
            let options = try word.unwrap("缺少 Word 导出选项")
            var summary = ""
            try DocumentTaskOutput.write(to: destination, expected: expected) { staging in
                let report = try WordExport.write(document, pages: pages, outline: outline, options: options, regions: regions, to: staging, sourceDigest: sourceDigest, cache: folder, progress: progress)
                summary = report.summary
            }
            return DocumentTaskResult(message: summary, file: destination)
        }
    }
}
enum StructuredTableWord {
    static func write(_ draft: TableDraftRecord, to url: URL) throws {
        let zip = try ZipWriter(url: url)
        do {
            try zip.add("[Content_Types].xml", Data(WordExport.contentTypes.utf8)); try zip.add("_rels/.rels", Data(WordExport.rootRelationships.utf8)); try zip.add("word/styles.xml", Data(WordExport.styles.utf8))
            let xml = WordExport.header + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + WordTables.xml(draft.rows, spans: draft.spans ?? []) + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/></w:sectPr></w:body></w:document>"
            try zip.add("word/document.xml", Data(xml.utf8)); try zip.add("word/_rels/document.xml.rels", Data((WordExport.header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>").utf8)); try zip.finish()
        } catch { zip.abandon(); try? FileManager.default.removeItem(at: url); throw error }
    }
}
