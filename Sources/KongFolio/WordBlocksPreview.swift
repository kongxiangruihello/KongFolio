import SwiftUI

struct WordBlocksPreview: View {
    var blocks: [WordPreparedBlock]
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let paragraph): Text(paragraph.text).font(paragraph.heading > 0 ? .headline : .body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    case .spanningTable(let rows, let spans):
                        SpanningTablePreview(rows: rows, spans: spans)
                    case .table(let rows):
                        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(rows.indices, id: \.self) { r in
                                GridRow { ForEach(rows[r].indices, id: \.self) { c in Text(rows[r][c]).font(r == 0 ? .headline : .body).padding(5).frame(minWidth: 80, maxWidth: 180, alignment: .leading).border(.secondary.opacity(0.4)).textSelection(.enabled) } }
                            }
                        }
                    }
                }
            }.padding(8).frame(minWidth: 320, alignment: .leading)
        }
    }
}

struct SpanningTablePreview: View {
    var rows: [[String]]
    var spans: [TableCellSpan]
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(rows.indices, id: \.self) { r in
                ForEach(rows[r].indices, id: \.self) { c in
                    if !TableStructure.covered(r,c,spans:spans) {
                        let span = spans.first { $0.row == r && $0.column == c }
                        Text(rows[r][c]).padding(5).frame(width: CGFloat(span?.columns ?? 1) * 120, height: CGFloat(span?.rows ?? 1) * 44, alignment: .topLeading).border(.secondary.opacity(0.4)).offset(x: CGFloat(c) * 120, y: CGFloat(r) * 44).textSelection(.enabled)
                    }
                }
            }
        }.frame(width: CGFloat(rows.first?.count ?? 1) * 120, height: CGFloat(rows.count) * 44)
    }
}
