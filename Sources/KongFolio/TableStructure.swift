import Foundation

struct TableCellSpan: Codable, Equatable {
    var row: Int
    var column: Int
    var rows: Int
    var columns: Int
    func contains(_ r: Int, _ c: Int) -> Bool { (row..<row + rows).contains(r) && (column..<column + columns).contains(c) }
    func intersects(_ other: TableCellSpan) -> Bool { row < other.row + other.rows && other.row < row + rows && column < other.column + other.columns && other.column < column + columns }
    var anchor: String { "\(row):\(column)" }
}
enum TableStructure {
    static func validate(rows: [[String]], spans: [TableCellSpan]) throws {
        var seen: [TableCellSpan] = []
        for span in spans {
            guard span.row >= 0, span.column >= 0, span.rows > 0, span.columns > 0,
                  span.rows <= rows.count, span.columns <= (rows.first?.count ?? 0),
                  span.row <= rows.count - span.rows, span.column <= (rows.first?.count ?? 0) - span.columns,
                  span.rows > 1 || span.columns > 1, !seen.contains(where: { $0.intersects(span) }) else { throw FolioError(message: "合并单元格范围无效或重叠") }
            seen.append(span)
        }
    }
    static func covered(_ r: Int, _ c: Int, spans: [TableCellSpan]) -> Bool { spans.contains { $0.contains(r,c) && ($0.row != r || $0.column != c) } }
    static func merge(_ region: TableCellSpan, draft: inout TableDraftRecord) throws {
        try validate(rows: draft.rows, spans: [region])
        let old = draft.spans ?? []
        guard old.filter({ $0.intersects(region) }).allSatisfy({ region.contains($0.row, $0.column) && region.contains($0.row + $0.rows - 1, $0.column + $0.columns - 1) }) else { throw FolioError(message: "选区只覆盖了部分合并单元格，请先拆分或扩大选区") }
        var text: [String] = []
        for r in region.row..<region.row + region.rows { for c in region.column..<region.column + region.columns { if !draft.rows[r][c].isEmpty { text.append(draft.rows[r][c]) }; draft.rows[r][c] = "" } }
        draft.rows[region.row][region.column] = text.joined(separator: "\n")
        draft.spans = old.filter { !$0.intersects(region) } + [region]
    }
    static func split(row: Int, column: Int, draft: inout TableDraftRecord) { draft.spans?.removeAll { $0.contains(row,column) } }
    static func structure(_ action: TableCellEdit, draft: inout TableDraftRecord) throws {
        let original = draft.rows
        var spans = draft.spans ?? []
        draft.rows = try action.applying(to: draft.rows)
        for i in spans.indices {
            switch action {
            case .insertRow(let r): if r <= spans[i].row { spans[i].row += 1 } else if r < spans[i].row + spans[i].rows { spans[i].rows += 1 }
            case .insertColumn(let c): if c <= spans[i].column { spans[i].column += 1 } else if c < spans[i].column + spans[i].columns { spans[i].columns += 1 }
            case .deleteRow(let r):
                if r < spans[i].row { spans[i].row -= 1 }
                else if r < spans[i].row + spans[i].rows { if r == spans[i].row, spans[i].rows > 1 { draft.rows[r][spans[i].column] = original[r][spans[i].column] }; spans[i].rows -= 1 }
            case .deleteColumn(let c):
                if c < spans[i].column { spans[i].column -= 1 }
                else if c < spans[i].column + spans[i].columns { if c == spans[i].column, spans[i].columns > 1 { draft.rows[spans[i].row][c] = original[spans[i].row][c] }; spans[i].columns -= 1 }
            }
        }
        draft.spans = spans.filter { $0.rows > 0 && $0.columns > 0 && ($0.rows > 1 || $0.columns > 1) }
        try validate(rows: draft.rows, spans: draft.spans ?? [])
    }
    static func parseTSV(_ text: String) throws -> [[String]] {
        guard text.utf8.count <= 4_000_000 else { throw FolioError(message: "粘贴内容过大") }
        let input = Array(TextImport.normalized(text)); var result: [[String]] = [], row: [String] = [], cell = "", quoted = false, i = 0
        while i < input.count {
            let ch = input[i]
            if ch == "\"" {
                if quoted, i + 1 < input.count, input[i + 1] == "\"" { cell.append("\""); i += 1 }
                else if quoted || cell.isEmpty { quoted.toggle() } else { cell.append(ch) }
            } else if ch == "\t", !quoted { row.append(cell); cell = "" }
            else if ch == "\n", !quoted { row.append(cell); result.append(row); row = []; cell = "" }
            else { cell.append(ch) }
            i += 1
        }
        guard !quoted else { throw FolioError(message: "粘贴内容的引号未闭合") }
        if !cell.isEmpty || !row.isEmpty || result.isEmpty { row.append(cell); result.append(row) }
        let width = result.map(\.count).max() ?? 0
        guard width > 0, width <= 100, result.count * width <= 2000 else { throw FolioError(message: "粘贴内容超过 2000 个单元格或 100 列") }
        return result.map { $0 + Array(repeating: "", count: width - $0.count) }
    }
    static func paste(_ text: String, row: Int, column: Int, draft: inout TableDraftRecord) throws {
        let values = try parseTSV(text), height = max(draft.rows.count, row + values.count), width = max(draft.columns, column + values[0].count)
        guard row >= 0, column >= 0, width <= 100, height * width <= 2000 else { throw FolioError(message: "粘贴后超过表格大小限制") }
        let target = TableCellSpan(row: row, column: column, rows: values.count, columns: values[0].count)
        guard !(draft.spans ?? []).contains(where: { $0.intersects(target) }) else { throw FolioError(message: "粘贴范围含合并单元格，请先拆分") }
        draft.rows = draft.rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        draft.rows += Array(repeating: Array(repeating: "", count: width), count: height - draft.rows.count)
        for r in values.indices { for c in values[r].indices { draft.rows[row+r][column+c] = values[r][c] } }
    }
    static func columnName(_ index: Int) -> String { var n = index + 1, result = ""; while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }; return result }
    static func reference(_ row: Int, _ column: Int) -> String { columnName(column) + String(row + 1) }
    static func writeExcel(rows: [[String]], spans: [TableCellSpan], to url: URL) throws {
        guard let first = rows.first, !first.isEmpty, first.count <= 100, rows.count * first.count <= 2000, rows.allSatisfy({ $0.count == first.count }) else { throw FolioError(message: "表格为空或行列不一致") }
        try validate(rows: rows, spans: spans)
        for r in rows.indices { for c in rows[r].indices where rows[r][c].utf16.count > 32767 { throw FolioError(message: "Excel 单元格 \(reference(r,c)) 超过 32767 字符，请拆分内容后导出") } }
        let zip = try ZipWriter(url: url)
        do {
            let header = WordExport.header
            try zip.add("[Content_Types].xml", Data((header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>").utf8))
            try zip.add("_rels/.rels", Data((header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>").utf8))
            try zip.add("xl/workbook.xml", Data((header + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"表格\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>").utf8))
            try zip.add("xl/_rels/workbook.xml.rels", Data((header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>").utf8))
            let styles = header + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left style=\"thin\"/><right style=\"thin\"/><top style=\"thin\"/><bottom style=\"thin\"/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
            try zip.add("xl/styles.xml", Data(styles.utf8))
            var sheet = header + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><cols><col min=\"1\" max=\"\(first.count)\" width=\"22\" customWidth=\"1\"/></cols><sheetData>"
            for r in rows.indices { try Task.checkCancellation(); sheet += "<row r=\"\(r+1)\" ht=\"\(min(100,max(30,(rows[r].map { $0.components(separatedBy: "\n").count }.max() ?? 1) * 15)))\" customHeight=\"1\">"; for c in rows[r].indices where !covered(r,c,spans:spans) { let text = TextImport.normalized(rows[r][c]).components(separatedBy: "\n").map(WordExport.escape).joined(separator: "&#10;"); sheet += "<c r=\"\(reference(r,c))\" t=\"inlineStr\" s=\"\(r == 0 ? 1 : 0)\"><is><t xml:space=\"preserve\">\(text)</t></is></c>" }; sheet += "</row>" }
            sheet += "</sheetData>"
            if !spans.isEmpty { sheet += "<mergeCells count=\"\(spans.count)\">" + spans.map { "<mergeCell ref=\"\(reference($0.row,$0.column)):\(reference($0.row+$0.rows-1,$0.column+$0.columns-1))\"/>" }.joined() + "</mergeCells>" }
            sheet += "</worksheet>"; try zip.add("xl/worksheets/sheet1.xml", Data(sheet.utf8)); try zip.finish()
        } catch { zip.abandon(); try? FileManager.default.removeItem(at: url); throw error }
    }
}
