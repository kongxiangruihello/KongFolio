import SwiftUI

struct WordBlocksPreview: View {
    var blocks: [WordPreparedBlock]
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let paragraph): Text(paragraph.text).font(paragraph.heading > 0 ? .headline : .body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
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
