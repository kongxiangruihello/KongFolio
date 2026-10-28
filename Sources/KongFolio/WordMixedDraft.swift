import Foundation

enum WordMixedDraft {
    static func digest(_ blocks: [WordPreparedBlock]) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return OCRPageCache.digest(try encoder.encode(blocks)) }
    static func text(_ blocks: [WordPreparedBlock]) -> String {
        blocks.map { block in switch block { case .paragraph(let p): return p.text; case .table(let rows), .spanningTable(let rows, _): return ExtractedTable(rows: rows).markdown } }.joined(separator: "\n\n")
    }
    static func validate(_ edited: [WordPreparedBlock], against base: [WordPreparedBlock]) throws {
        guard edited.count == base.count, edited.count <= 10000 else { throw FolioError(message: "Word 正文和表格结构已变化，请先核对草稿") }
        for (old,new) in zip(base,edited) {
            switch (old,new) {
            case (.paragraph, .paragraph): break
            case (.table(let a), .table(let b)):
                guard a.count == b.count, a.map(\.count) == b.map(\.count) else { throw FolioError(message: "Word 表格行列已变化，请先核对草稿") }
            case (.spanningTable(let a, let sa), .spanningTable(let b, let sb)):
                guard a.count == b.count, a.map(\.count) == b.map(\.count), sa == sb else { throw FolioError(message: "Word 合并单元格结构已变化，请先核对草稿") }
                try TableStructure.validate(rows: b, spans: sb)
            default: throw FolioError(message: "Word 正文和表格顺序已变化，请先核对草稿")
            }
        }
        guard text(edited).utf8.count <= 8_000_000 else { throw FolioError(message: "Word 修改草稿过大") }
    }
    static func replacing(_ blocks: [WordPreparedBlock], block: Int, row: Int?, column: Int?, text: String) throws -> [WordPreparedBlock] {
        guard blocks.indices.contains(block) else { throw FolioError(message: "预览内容已变化") }
        var result = blocks
        switch blocks[block] {
        case .paragraph(let p): result[block] = .paragraph(WordPreparedParagraph(text: text, heading: p.heading))
        case .table(var rows):
            guard let row, let column, rows.indices.contains(row), rows[row].indices.contains(column) else { throw FolioError(message: "单元格位置无效") }
            rows[row][column] = text; result[block] = .table(rows)
        case .spanningTable(var rows, let spans):
            guard let row, let column, rows.indices.contains(row), rows[row].indices.contains(column), !TableStructure.covered(row,column,spans:spans) else { throw FolioError(message: "请编辑合并单元格的左上角") }
            rows[row][column] = text; result[block] = .spanningTable(rows: rows, spans: spans)
        }
        return result
    }
}
extension WordExportOptions {
    var hasDraft: Bool { !(editedText ?? [:]).isEmpty || !(editedBlocks ?? [:]).isEmpty }
    var draftPages: Set<Int> { Set((editedText ?? [:]).keys).union((editedBlocks ?? [:]).keys) }
    var draftText: String { draftPages.sorted().map { index in "—— 第 \(index + 1) 页 ——\n" + (editedBlocks?[index].map(WordMixedDraft.text) ?? editedText?[index] ?? "") }.joined(separator: "\n\n") }
}
extension Workspace {
    func setWordBlocks(_ blocks: [WordPreparedBlock], base: [WordPreparedBlock], page: Int) throws {
        try validateWordDraft(); guard (0..<count).contains(page) else { throw FolioError(message: "预览页面已不存在") }
        try WordMixedDraft.validate(blocks, against: base)
        if !wordOptions.hasDraft { wordDraftDigest = OCRPageCache.digest(try pdfData()) }
        var options = wordOptions
        options.editedFromRevision = revision; options.editedSourceDigest = wordDraftDigest
        if options.editedBlocks == nil { options.editedBlocks = [:] }; if options.blockBaselines == nil { options.blockBaselines = [:] }
        if options.blockBaselines?[page] == nil { options.blockBaselines?[page] = try WordMixedDraft.digest(base) }
        options.editedBlocks?[page] = blocks; options.editedText?[page] = nil
        wordOptions = options; try persistWordDraft(); scheduleRecovery()
    }
}
