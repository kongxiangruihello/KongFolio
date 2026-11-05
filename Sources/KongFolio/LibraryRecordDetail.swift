import SwiftUI

struct LibraryRecordDetail: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    let record:ReadingRecord
    @State private var contextSource:ReadingContextRequest?
    @State private var editQuote = false
    @State private var showQuoteCorrection = false
    @State private var showLinkPicker = false
    @StateObject private var imageOCR = ReadingImageOCRController()
    private var current:ReadingRecord { journal.record(record.id) ?? record }
    var body:some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                StableTextField("记录标题（可留空）",text:binding(\.title),fontSize:20)
                ReadingRecordMetadataView(record:current)
                HStack {
                    Text(current.kind.rawValue).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
                    Spacer()
                    if let source = current.citations.first?.source { Button("返回原文") { _ = store.reveal(source,beside:false) }.disabled(source.path.isEmpty) }
                    Menu("记录操作") {
                        Button(store.pinnedReadingID == record.id ? "取消固定" : "固定记录，翻页时继续写") { store.pinnedReadingID = store.pinnedReadingID == record.id ? nil : record.id }
                        if current.kind == .note { Button("关联更多摘录…") { showLinkPicker = true } }
                        if current.kind != .note { Button("针对摘录写笔记") { store.newReadingNote(linked:current) } }
                        if journal.draftRecord?.id == record.id { Button("关闭空白草稿") { journal.discardNoteDraft();store.readingRecordID = nil } }
                        else if current.removed != nil { Button("恢复记录") { journal.editRecord(record.id) { $0.removed = nil } } }
                        else { Button("移到最近移除",role:.destructive) { journal.editRecord(record.id) { $0.removed = Date() };store.readingRecordID = nil;store.readingRecordSelection.remove(record.id) } }
                    }.fixedSize()
                }
                if current.kind != .note && current.pdfOrigin == nil {
                    HStack { Text("摘录原文").font(.caption); Spacer(); Button("原文与校订对照…") { showQuoteCorrection = true }; Button(editQuote ? "完成文字校正" : "校正摘录文字") { editQuote.toggle() } }
                    if editQuote { LibraryWritingEditor(text:binding(\.quote),label:"摘录校订文字",identity:"quote:"+record.id.uuidString).id("quote:"+record.id.uuidString).frame(height:300) }
                    else if !current.quote.isEmpty { Text(current.quote).textSelection(.enabled) }
                }
                if current.pdfOrigin != nil && !current.quote.isEmpty { Text(current.quote).font(.system(size:16)).textSelection(.enabled) }
                if current.kind == .note && !current.quote.isEmpty { DisclosureGroup("关联原文（展开查看）") { Text(current.quote).font(.system(size:16)).textSelection(.enabled) } }
                if let image = current.imageAsset, imageOCR.text.isEmpty { ReadingRecordImage(url:journal.assetURL(image),pending:journal.pendingImage(image)).frame(maxHeight:220) }
                if current.kind == .image { imageRecognition.onAppear { imageOCR.restoreSegments(current) } }
                if let original = current.originalQuote ?? current.originalOCR { DisclosureGroup("校订前文字（保留）") { Text(original).textSelection(.enabled) } }
                Text(current.kind == .note || current.pdfOrigin != nil ? "我的笔记" : "我的理解与评论").font(.caption)
                LibraryWritingEditor(text:binding(\.note),label:"阅读笔记正文",identity:"note:"+record.id.uuidString).id("note:"+record.id.uuidString).frame(height:380)
                DisclosureGroup("标签与出处（\(current.citations.count)）") {
                    VStack(alignment:.leading,spacing:12) {
                ReadingTagField(journal:journal,label:"标签，以逗号分隔",text:Binding(get:{current.tags.joined(separator:", ")},set:{ text in journal.editRecord(record.id) { $0.tags = Self.tags(text) } }))
                ForEach(Array(current.citations.prefix(20).enumerated()),id:\.offset) { index,citation in
                    VStack(alignment:.leading) {
                        ReadingCitationEditor(journal:journal,record:record.id,index:index).disabled(current.pdfOrigin != nil)
                        Text(current.wholeBook ? "《"+citation.title+"》 · 整本书" : citation.display).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("快看原页") { contextSource = ReadingContextRequest(source:citation.source) }
                            Button("返回原文") { _ = store.reveal(citation.source,beside:false) }.disabled(citation.source.path.isEmpty)
                            Button("重新关联…") { relink(citation) }
                        }
                    }
                }
                if current.citations.count > 20 { Text("另有来源页，导出时一并保留").font(.caption) }
                    }.padding(.vertical,8)
                }.font(.system(size:13))
                HStack {
                    Button("加入笔记") { let id = journal.currentEssayID ?? journal.newEssay(); store.insertReadingRecord(current,in:id); store.openReadingDesk(.essays,window:true) }
                    Button("导出这条记录") { store.readingRecordSelection = [record.id]; store.readingExportEssay = false; store.openReadingDesk(.exports,window:true) }
                }.disabled(journal.draftRecord?.id == record.id || !current.hasContent)
            }.padding(.horizontal,12).padding(.vertical,8)

        }.onChange(of:store.writingSearchRequest) { _,token in
            guard let hit = store.writingSearchHit,hit.identity.hasSuffix(record.id.uuidString) else { return }
            if hit.identity.hasPrefix("quote:") { editQuote = true }
            DispatchQueue.main.async { proxy.scrollTo(hit.identity,anchor:.center) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { if store.writingSearchRequest == token { WritingRegistry.jumpIfCurrent(hit) } }
        }
        }.sheet(isPresented:$showQuoteCorrection) { ReadingQuoteCorrectionView(journal:journal,record:current) }.sheet(item:$contextSource) { request in ReadingContextView(store:store,source:request.source) }.onAppear { if journal.draftRecord?.id == record.id && record.kind != .note { editQuote = true } }.onDisappear { imageOCR.cancel() }.sheet(isPresented:$showLinkPicker) {
            ReadingRecordPicker(journal:journal) { other in
                journal.editRecord(record.id) { value in
                    guard !value.linkedRecords.contains(other.id) else { return }
                    value.linkedRecords.append(other.id)
                    if !other.quote.isEmpty { value.quote += (value.quote.isEmpty ? "" : "\n\n")+other.quote }
                    for citation in other.citations where !value.citations.contains(citation) { value.citations.append(citation) }
                }
            }
        }
    }
    private var imageRecognition:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Menu("识别摘录图片文字") {
                    Button("横排文字") { imageOCR.recognize(current,journal:journal,vertical:false) }
                    Button("竖排文字") { imageOCR.recognize(current,journal:journal,vertical:true) }
                    Button("竖排古籍（优先繁体）") { imageOCR.recognize(current,journal:journal,vertical:true,traditional:true) }
                }.disabled(imageOCR.busy)
                if imageOCR.busy { ProgressView().controlSize(.small); Button("取消识别") { imageOCR.cancel() } }
            }
            if !imageOCR.text.isEmpty {
                HSplitView {
                    if let image = current.imageAsset { ReadingRecordImage(url:journal.assetURL(image),pending:journal.pendingImage(image)).frame(minWidth:100,minHeight:180) }
                    LibraryWritingEditor(text:$imageOCR.text,label:"对照校订识别文字",identity:"ocr:"+record.id.uuidString).frame(minWidth:180,minHeight:180)
                }
                ReadingOCRSegmentEditor(controller:imageOCR)
                Button("采用识别文字") { journal.editRecord(record.id) { $0.originalQuote = $0.originalQuote ?? ($0.quote.isEmpty ? nil : $0.quote);$0.originalOCR = $0.originalOCR ?? imageOCR.originalText;$0.quote = imageOCR.text;$0.ocrSegments = imageOCR.segments }; editQuote = true }
            }
            if !imageOCR.message.isEmpty { Text(imageOCR.message).font(.caption) }
        }
    }
    private func binding(_ key:WritableKeyPath<ReadingRecord,String>) -> Binding<String> { Binding(get:{current[keyPath:key]},set:{text in journal.editRecord(record.id) { if key == \ReadingRecord.quote, $0.originalQuote == nil, !$0.quote.isEmpty { $0.originalQuote = $0.quote };$0[keyPath:key] = text }}) }
    static func tags(_ text:String) -> [String] { var seen = Set<String>(); return text.replacingOccurrences(of:"，",with:",").split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty && seen.insert($0).inserted} }
    private func relink(_ citation:ReadingCitation) {
        let panel = NSOpenPanel(); panel.message = "选择这条记录的原书；记录文字和原页码保留，请核对来源。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if citation.source.path.isEmpty { journal.relink(old:"",to:url,recordID:record.id) }
            else { try store.library.relink(path:citation.source.path,to:url,defaults:store.readingDefaults) }
        } catch { store.present(error) }
    }
}
