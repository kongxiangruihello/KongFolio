import SwiftUI
struct ReadingCitationEditor: View {
    @ObservedObject var journal:ReadingJournal
    let record:UUID
    let index:Int
    private var current:ReadingCitation? { guard let list = journal.record(record)?.citations,list.indices.contains(index) else { return nil };return list[index] }
    var body:some View {
        if let current { DisclosureGroup("整理这条出处") {
            StableTextField("作者",text:binding(\.author))
            StableTextField("书名",text:binding(\.title))
            StableTextField("版本／卷次",text:Binding(get:{self.current?.edition ?? ""},set:{text in update { $0.edition = text.isEmpty ? nil : text } }))
            HStack { Stepper("PDF 第 \(current.source.page+1) 页",value:Binding(get:{(self.current?.source.page ?? 0)+1},set:{page in update { $0.source.page = max(0,page-1) } }),in:1...100000);StableTextField("书上印刷页码",text:Binding(get:{self.current?.source.pageLabel ?? ""},set:{text in update { $0.source.pageLabel = text.isEmpty ? nil : text } })) }
            Text("修改这条记录的出处；已经插入笔记的引用副本保持原样。").font(.caption)
        } }
    }
    private func update(_ edit:(inout ReadingCitation)->Void) { journal.editRecord(record) { value in guard value.citations.indices.contains(index) else { return };edit(&value.citations[index]) } }
    private func binding(_ key:WritableKeyPath<ReadingCitation,String>) -> Binding<String> { Binding(get:{current?[keyPath:key] ?? ""},set:{text in update { $0[keyPath:key] = text }}) }
}
