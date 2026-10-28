import SwiftUI
struct WordMixedEditor: View {
    var blocks: [WordPreparedBlock]
    var change: (Int, Int?, Int?, String) -> Void
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks.indices, id: \.self) { i in
                    switch blocks[i] {
                    case .paragraph(let p):
                        TextField("正文段落", text: Binding(get: { p.text }, set: { change(i,nil,nil,$0) }), axis: .vertical).textFieldStyle(.roundedBorder).frame(width: 500)
                    case .table(let rows): cells(rows, spans: [], index: i)
                    case .spanningTable(let rows, let spans): cells(rows, spans: spans, index: i)
                    }
                }
            }.padding(6)
        }
    }
    private func cells(_ rows: [[String]], spans: [TableCellSpan], index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(rows.indices, id: \.self) { r in
                ForEach(rows[r].indices, id: \.self) { c in
                    if !TableStructure.covered(r,c,spans:spans) {
                        let span = spans.first { $0.row == r && $0.column == c }
                        TextField("第 \(r+1) 行第 \(c+1) 列", text: Binding(get: { rows[r][c] }, set: { change(index,r,c,$0) }), axis: .vertical).textFieldStyle(.roundedBorder)
                            .frame(width: CGFloat(span?.columns ?? 1) * 150 - 4, height: CGFloat(span?.rows ?? 1) * 44 - 4)
                            .offset(x: CGFloat(c) * 150, y: CGFloat(r) * 44)
                    }
                }
            }
        }.frame(width: CGFloat(rows.first?.count ?? 1) * 150, height: CGFloat(rows.count) * 44)
    }
}
