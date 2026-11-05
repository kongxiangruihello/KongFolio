import SwiftUI
struct ReadingRecordMetadataView: View {
    let record:ReadingRecord
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            if let citation = record.citations.first { Text(record.wholeBook ? "《"+citation.title+"》 · 整本书" : citation.display).lineLimit(2).help(ReadingRecordMetadata.lines(record).joined(separator:"\n")) }
            else { Text("独立笔记 · 未关联文献") }
            Text((record.pdfOrigin == nil ? "创建 " : "收录 ")+ReadingRecordMetadata.date(record.created)+" · 修改 "+ReadingRecordMetadata.date(record.modified))
            if let origin = record.pdfOrigin {
                if !origin.contents.isEmpty { Text("PDF 原评论："+origin.contents).font(.system(size:15)).textSelection(.enabled) }
                if origin.missingSince != nil { Text("原 PDF 中已移除，记录与出处继续保留").foregroundStyle(.orange) }
            }
            DisclosureGroup("完整出处与时间") { ForEach(Array(ReadingRecordMetadata.lines(record).enumerated()),id:\.offset) { _,line in Text(line).textSelection(.enabled) } }
        }.font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
    }
}
