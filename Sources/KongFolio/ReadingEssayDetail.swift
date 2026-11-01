import SwiftUI
import UniformTypeIdentifiers

struct ReadingEssayHeading:Identifiable { var id:String { block.uuidString+":"+String(range.location) };var block:UUID;var title:String;var level:Int;var range:NSRange }
struct ReadingEssayDetail: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    let id:UUID
    var onExport:(()->Void)? = nil
    @State private var headings:[ReadingEssayHeading] = []
    private var current:ReadingEssay? { journal.essay(id) }
    var body:some View {
        if let essay = current {
            VStack(alignment:.leading,spacing:10) {
                if journal.draftEssay?.id == essay.id { HStack { Text("空白札记草稿 · 输入内容后才加入记录").font(.caption).foregroundStyle(.secondary);Spacer();Button("关闭空白草稿") { journal.discardEssayDraft() } } }
                StableTextField("札记标题",text:Binding(get:{current?.title ?? ""},set:{text in journal.editEssay(id) { $0.title = text } }))
                StableTextField("札记标签，以逗号分隔",text:Binding(get:{current?.tags.joined(separator:", ") ?? ""},set:{text in journal.editEssay(id) { $0.tags = ReadingRecordDetail.tags(text) } }))
                ScrollViewReader { proxy in
                    VStack(alignment:.leading,spacing:8) {
                        controls(essay)
                        HStack {
                            Menu("札记大纲") { ForEach(headings) { h in Button(String(repeating:"　",count:max(0,h.level-1))+h.title) {
                                store.readingEssayBlockID = h.block;proxy.scrollTo(h.block,anchor:.top)
                                DispatchQueue.main.async { WritingRegistry.jump("essay:"+id.uuidString+":"+h.block.uuidString,range:h.range) }
                            } } }
                            Button("上移当前段落") { move(-1) }.keyboardShortcut(.upArrow,modifiers:[.command,.shift,.option])
                            Button("下移当前段落") { move(1) }.keyboardShortcut(.downArrow,modifiers:[.command,.shift,.option])
                            if let block = store.readingEssayBlockID,let index = essay.blocks.firstIndex(where:{$0.id == block}) { Text("插入位置：第 \(index+1) 段光标处").font(.caption) }
                        }.font(.caption)
                        ScrollView { LazyVStack(alignment:.leading,spacing:14) { ForEach(essay.blocks) { block in
                            ReadingEssayBlockView(store:store,journal:journal,essayID:id,block:block).id(block.id)
                        } } }
                    }
                }
            }.task(id:essay.modified) {
                do { try await Task.sleep(nanoseconds:400_000_000) } catch { return }
                var values:[ReadingEssayHeading] = []
                for block in essay.blocks { let result = await WritingAnalysisWorker.shared.analyze(block.text);values += result.headings.map{ReadingEssayHeading(block:block.id,title:$0.title,level:$0.level,range:$0.range)} }
                if !Task.isCancelled { headings = values }
            }
        }
    }
    private func move(_ delta:Int) { if let block = store.readingEssayBlockID { journal.editEssay(id) { $0.move(block,delta:delta) } } }
    private func controls(_ essay:ReadingEssay) -> some View {
        HStack {
            Button("添加段落") { let block = ReadingEssay.Block();journal.editEssay(id) { $0.blocks.append(block) };store.readingEssayBlockID = block.id }
            if let record = journal.record(store.readingRecordID),journal.draftRecord?.id != record.id,record.hasContent { Button("插入当前摘录") { store.insertReadingRecord(record,in:id) } }
            Button("导出札记") { journal.selectEssay(id);store.readingExportEssay = true;if let onExport { onExport() } else { store.openReadingDesk(.exports,window:true) } }.disabled(journal.draftEssay?.id == essay.id || !essay.hasContent)
        }
    }
}
struct ReadingEssayBlockView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    let essayID:UUID
    let block:ReadingEssay.Block
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(block.record == nil ? "我的论述" : "原文引用与我的论述").font(.caption)
                    .onDrag { NSItemProvider(object:block.id.uuidString as NSString) }
                Spacer()
                Button("上移") { journal.editEssay(essayID) { $0.move(block.id,delta:-1) } }
                Button("下移") { journal.editEssay(essayID) { $0.move(block.id,delta:1) } }
                Button("移除段落") { journal.editEssay(essayID) { $0.blocks.removeAll{$0.id == block.id} } }
            }
            if let record = block.record {
                VStack(alignment:.leading,spacing:6) {
                    Text("原文引用（插入时的副本）").font(.caption).foregroundStyle(.secondary)
                    if !record.quote.isEmpty { Text(record.quote).textSelection(.enabled) }
                    if let name = record.imageAsset { ReadingRecordImage(url:journal.assetURL(name),pending:journal.pendingImage(name)).frame(maxHeight:240) }
                    if !record.note.isEmpty { Text("原笔记："+record.note).textSelection(.enabled) }
                    ForEach(Array(record.citations.enumerated()),id:\.offset) { _,citation in Button(citation.display) { _ = store.reveal(citation.source,beside:false) }.buttonStyle(.link).help(citation.display) }
                }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:6))
            }
            ReadingWritingEditor(text:Binding(get:{journal.essay(essayID)?.blocks.first{$0.id == block.id}?.text ?? ""},set:{text in journal.editEssay(essayID) { value in if let i = value.blocks.firstIndex(where:{$0.id == block.id}) { value.blocks[i].text = text } } }),label:"札记论述正文",identity:"essay:"+essayID.uuidString+":"+block.id.uuidString,onFocus:{store.readingEssayBlockID = block.id}).frame(minHeight:150).border(.quaternary)
        }.padding(10).background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
        .onDrop(of:[UTType.plainText],isTargeted:nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass:NSString.self) { value,_ in
                guard let value = value as? String,let source = UUID(uuidString:value) else { return }
                Task { @MainActor in journal.editEssay(essayID) { $0.move(source,before:block.id) } }
            };return true
        }
    }
}