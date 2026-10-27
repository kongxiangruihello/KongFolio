import Foundation
import PDFKit

struct WordTableInsertion: Codable, Equatable, Identifiable {
    var id: UUID
    var sourceDigest: String
    var page: Int
    var regions: [TableSourceRegion]
    var rows: [[String]]
}
enum WordPreparedBlock: Equatable {
    case paragraph(WordPreparedParagraph)
    case table([[String]])
}
enum WordTables {
    static func validate(_ tables: [WordTableInsertion], document: PDFDocument, pages: [Int], options: WordExportOptions, sourceDigest: String?) throws {
        let selected = Set(pages)
        var occupied: [TableSourceRegion] = []
        for table in tables where table.regions.contains(where: { selected.contains($0.page) }) {
            guard sourceDigest == table.sourceDigest else { throw FolioError(message: "表格草稿对应的 PDF 已变化，请回到表格工具核对，或关闭“正文插入表格草稿”") }
            guard !table.rows.isEmpty, let first = table.rows.first, !first.isEmpty, first.count <= 100, table.rows.count * first.count <= 2000,
                  table.rows.allSatisfy({ $0.count == first.count }), !table.regions.isEmpty,
                  table.regions.contains(where: { $0.page == table.page }), table.regions.allSatisfy({ (0..<document.pageCount).contains($0.page) && TableGrid.validRect($0.rect) }) else { throw FolioError(message: "表格草稿范围无效") }
            guard table.regions.allSatisfy({ selected.contains($0.page) }) else { throw FolioError(message: "导出范围只包含跨页表格的一部分，请选择全部来源页，或关闭表格插入") }
            guard table.regions.allSatisfy({ options.editedText?[$0.page] == nil }) else { throw FolioError(message: "表格来源页已有手动 Word 正文，请先拷贝并清除这些页的正文修改，或关闭表格插入") }
            for region in table.regions {
                guard !occupied.contains(where: { $0.page == region.page && $0.rect.intersects(region.rect) }) else { throw FolioError(message: "已加入的表格范围重叠，请取消其中一份再导出") }
                occupied.append(region)
            }
        }
    }
    static func blocks(page: PDFPage, index: Int, tables: [WordTableInsertion], options: WordExportOptions, margins: Set<String>) throws -> [WordPreparedBlock]? {
        let covered = tables.flatMap(\.regions).filter { $0.page == index }
        guard !covered.isEmpty else { return nil }
        let text = TableExtraction.pieces(page).filter { piece in !covered.contains { $0.rect.contains(CGPoint(x: piece.box.midX, y: piece.box.midY)) } }
        let anchors = tables.filter { $0.page == index }.sorted { ($0.regions.first(where: { $0.page == index })?.rect.minY ?? 0) < ($1.regions.first(where: { $0.page == index })?.rect.minY ?? 0) }
        var result: [WordPreparedBlock] = [], lower = 0.0
        func append(_ pieces: [TablePiece]) throws {
            guard !pieces.isEmpty else { return }
            let raw = try TableExtraction.extract(pieces, x: [0,1], y: [0,1]).rows[0][0]
            let prepared = WordCleanup.prepare(index: index, label: nil, text: raw, regions: nil, options: options, margins: margins)
            result += prepared.paragraphs.map(WordPreparedBlock.paragraph)
        }
        for table in anchors {
            try Task.checkCancellation()
            let y = Double(table.regions.first(where: { $0.page == index })!.rect.minY)
            try append(text.filter { $0.box.midY >= lower && $0.box.midY < y })
            result.append(.table(table.rows)); lower = y
        }
        try append(text.filter { $0.box.midY >= lower })
        return result
    }
    static func xml(_ rows: [[String]]) -> String {
        let columns = max(1, rows.first?.count ?? 1), width = 8880 / columns
        var result = "<w:tbl><w:tblPr><w:tblW w:w=\"8880\" w:type=\"dxa\"/><w:tblBorders>" + ["top","left","bottom","right","insideH","insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"A6A6A6\"/>" }.joined() + "</w:tblBorders></w:tblPr><w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
        for (i, row) in rows.enumerated() {
            result += "<w:tr>" + (i == 0 ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for value in row {
                result += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>" + TextImport.normalized(value).components(separatedBy: "\n").map { WordExport.textParagraph($0, bold: i == 0) }.joined() + "</w:tc>"
            }
            result += "</w:tr>"
        }
        return result + "</w:tbl><w:p/>"
    }
}
extension Workspace {
    func wordOptionsWithTables() throws -> WordExportOptions {
        var result = wordOptions
        let included = tableDrafts.filter(\.includeInWord)
        if result.includeTables != false && result.content != .imagesOnly {
            guard !included.contains(where: \.needsRegeneration) else { throw FolioError(message: "表格分隔线已修改，请重新生成并核对表格") }
            result.tables = included.map { WordTableInsertion(id: $0.id, sourceDigest: $0.sourceDigest, page: $0.page, regions: $0.regions, rows: $0.rows) }
        } else { result.tables = nil }
        return result
    }
}
