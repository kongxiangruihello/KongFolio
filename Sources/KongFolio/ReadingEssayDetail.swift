import SwiftUI

struct ReadingEssayDetail: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    let id:UUID
    var onExport:(()->Void)? = nil
    private var current:ReadingEssay? { journal.essay(id) }
    var body:some View {
        if let essay = current {
            VStack(alignment:.leading,spacing:10) {
                if journal.draftEssay?.id == essay.id { HStack { Text("空白札记草稿 · 输入内容后才加入记录").font(.caption).foregroundStyle(.secondary); Spacer(); Button("关闭空白草稿") { journal.discardEssayDraft() } } }
                StableTextField("札记标题",text:Binding(get:{current?.title ?? ""},set:{text in journal.editEssay(essay.id) { $0.title = text } }))
                StableTextField("札记标签，以逗号分隔",text:Binding(get:{current?.tags.joined(separator:", ") ?? ""},set:{text in journal.editEssay(essay.id) { $0.tags = ReadingRecordDetail.tags(text) } }))
                HStack {
                    Button("添加段落") { journal.editEssay(essay.id) { $0.blocks.append(ReadingEssay.Block()) } }
                    if let record = journal.record(store.readingRecordID), journal.draftRecord?.id != record.id, record.hasContent { Button("插入当前摘录") { journal.insert(record,in:essay.id) } }
                    Button("导出札记") { journal.selectEssay(essay.id); store.readingExportEssay = true; if let onExport { onExport() } else { store.openReadingDesk(.exports,window:true) } }.disabled(journal.draftEssay?.id == essay.id || !essay.hasContent)
                }
                ScrollView { LazyVStack(alignment:.leading,spacing:14) { ForEach(essay.blocks) { block in blockView(block,essay:essay.id) } } }
            }
        }
    }
    private func blockView(_ block:ReadingEssay.Block,essay:UUID) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(block.record == nil ? "论述段落" : "引用材料与论述").font(.caption)
                Spacer()
                Button("上移") { journal.editEssay(essay) { $0.move(block.id,delta:-1) } }
                Button("下移") { journal.editEssay(essay) { $0.move(block.id,delta:1) } }
                Button("移除段落") { journal.editEssay(essay) { $0.blocks.removeAll{$0.id == block.id} } }
            }
            if let record = block.record {
                if !record.quote.isEmpty { Text(record.quote).textSelection(.enabled) }
                if let name = record.imageAsset { ReadingRecordImage(url:journal.assetURL(name),pending:journal.pendingImage(name)).frame(maxHeight:240) }
                if !record.note.isEmpty { Text("笔记："+record.note).textSelection(.enabled) }
                ForEach(Array(record.citations.enumerated()),id:\.offset) { _,citation in Button(citation.display) { _ = store.reveal(citation.source,beside:false) }.buttonStyle(.link).help(citation.display) }
            }
            StableTextEditor(text:Binding(get:{ current?.blocks.first{$0.id == block.id}?.text ?? "" },set:{ text in journal.editEssay(essay) { value in if let i = value.blocks.firstIndex(where:{$0.id == block.id}) { value.blocks[i].text = text } } }),label:"札记论述正文").frame(minHeight:150).border(.quaternary).accessibilityLabel("札记论述正文")
        }.padding(10).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
    }
}
