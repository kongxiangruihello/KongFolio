import SwiftUI

struct ReadingEssayPane: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @State private var query = ""
    @State private var page = 0
    @AppStorage("readingRecordsPageSize") private var pageSize = 10
    private var current:ReadingEssay? { journal.essay(journal.currentEssayID) }
    private var essays:[ReadingEssay] { journal.state.essays.filter{$0.hasContent && $0.removed == nil && $0.matches(query)}.sorted{$0.modified == $1.modified ? $0.id.uuidString < $1.id.uuidString : $0.modified > $1.modified} }
    private var pagination: ReadingPagination { ReadingPagination(total: essays.count, page: page, size: pageSize) }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { TextField("查找札记文字、书名或标签",text:$query); Button("新建札记") { page = 0; query = ""; _ = journal.newEssay() }.disabled(journal.unreadable) }
            List(Array(essays.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { essay in
                Button { journal.selectEssay(essay.id) } label: { Text(essay.title).lineLimit(2).help(essay.title).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                    .listRowBackground(journal.currentEssayID == essay.id ? Color.accentColor.opacity(0.12) : .clear)
            }.frame(minHeight:80,maxHeight:current == nil ? 260 : 140).accessibilityLabel("札记列表")
            ReadingPageControls(pagination:pagination,page:$page,size:$pageSize)
            if let essay = current {
                if journal.draftEssay?.id == essay.id { HStack { Text("空白札记草稿 · 输入内容后才加入记录").font(.caption).foregroundStyle(.secondary); Spacer(); Button("关闭空白草稿") { journal.discardEssayDraft() } } }
                TextField("札记标题",text:Binding(get:{current?.title ?? ""},set:{text in journal.editEssay(essay.id) { $0.title = text } }))
                TextField("札记标签，以逗号分隔",text:Binding(get:{current?.tags.joined(separator:", ") ?? ""},set:{text in journal.editEssay(essay.id) { $0.tags = ReadingRecordDetail.tags(text) } }))
                HStack {
                    Button("添加段落") { journal.editEssay(essay.id) { $0.blocks.append(ReadingEssay.Block()) } }
                    if let record = journal.record(store.readingRecordID), journal.draftRecord?.id != record.id, record.hasContent { Button("插入当前摘录") { journal.insert(record,in:essay.id) } }
                    Button("导出札记") { store.readingExportEssay = true; store.openReadingDesk(.exports,window:true) }.disabled(journal.draftEssay?.id == essay.id || !essay.hasContent)
                }
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) { ForEach(essay.blocks) { block in blockView(block,essay:essay.id) } }
                }
                Text("文字直接输入；从摘录或笔记点击“加入札记”插入出处，可跨书引用。").font(.caption).foregroundStyle(.secondary)
            } else { Spacer(); Text("把摘录与自己的思考写成一篇札记").foregroundStyle(.secondary); Spacer() }
        }.onChange(of:query) { _,_ in page = 0 }.onChange(of:pageSize) { _,_ in page = 0 }
        .onChange(of:essays.count) { _,_ in page = pagination.index }
        .onChange(of:journal.draftEssay?.id) { _,id in if id != nil { page = 0; query = "" } }
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
            TextEditor(text:Binding(get:{ current?.blocks.first{$0.id == block.id}?.text ?? "" },set:{ text in journal.editEssay(essay) { value in if let i = value.blocks.firstIndex(where:{$0.id == block.id}) { value.blocks[i].text = text } } })).frame(minHeight:150).border(.quaternary).accessibilityLabel("札记论述正文")
        }.padding(10).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
    }
}
