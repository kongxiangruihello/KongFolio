import SwiftUI

struct LibraryRecordDetail: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    let record:ReadingRecord
    var onNewLinkedNote: ((ReadingRecord) -> Void)?
    var topPadding: CGFloat = 8
    @State private var contextSource:ReadingContextRequest?
    @State private var editQuote = false
    @State private var showQuoteCorrection = false
    @State private var showLinkPicker = false
    @State private var noteSourceStatus = ""
    @StateObject private var imageOCR = ReadingImageOCRController()
    @StateObject private var sourceNavigator = ReadingSourceNavigator()
    @State private var showOCRComparison = false
    @State private var showOriginal = false
    @State private var showLinkedQuote = false
    @State private var focusedSegment: String?
    private var current:ReadingRecord { journal.record(record.id) ?? record }
    var body:some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                StableTextField("记录标题（可留空）",text:binding(\.title),fontSize:20)
                if current.kind == .note { noteSourceControls }
                ReadingRecordMetadataView(record:current)
                if sourceNavigator.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在核对出处…").font(.caption)
                        Button("停止") { sourceNavigator.cancel() }
                    }
                }
                ReadingRecordExtrasView053(store:store,journal:journal,item:.record(current))
                HStack {
                    Text(current.kind.rawValue).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
                    Spacer()
                    if let citation = current.citations053.first {
                        Button("返回原文") { sourceNavigator.open(citation,record:current,store:store) }.disabled(sourceNavigator.busy)
                    }
                    Menu("记录操作") {
                        Button(store.pinnedReadingID == record.id ? "取消固定" : "固定记录，翻页时继续写") { store.pinnedReadingID = store.pinnedReadingID == record.id ? nil : record.id }
                        if current.kind == .note { Button("关联更多摘录…") { showLinkPicker = true } }
                        if current.kind != .note {
                            Button("针对摘录写笔记") {
                                if let onNewLinkedNote { onNewLinkedNote(current) }
                                else { store.newReadingNote(linked:current) }
                            }
                        }
                        if journal.draftRecord?.id == record.id { Button("关闭空白草稿") { journal.discardNoteDraft();store.readingRecordID = nil } }
                        else if current.removed != nil { Button("恢复记录") { journal.editRecord(record.id) { $0.removed = nil } } }
                        else { Button("移到最近移除",role:.destructive) { journal.editRecord(record.id) { $0.removed = Date() };store.readingRecordID = nil;store.readingRecordSelection.remove(record.id) } }
                    }.fixedSize()
                }
                if current.kind == .excerpt || current.kind == .image {
                    ReadingExcerptRemarkField(journal:journal,recordID:record.id).id("remark:"+record.id.uuidString)
                }
                if current.excerptSegments != nil {
                    segmentedExcerpt.id("quote:"+record.id.uuidString)
                } else if current.kind != .note && current.pdfOrigin == nil {
                    HStack { Text("摘录原文").font(.caption); Spacer(); Button("原文与校订对照…") { showQuoteCorrection = true }; Button(editQuote ? "完成文字校正" : "校正摘录文字") { editQuote.toggle() } }
                    if editQuote { LibraryWritingEditor(text:binding(\.quote),label:"摘录校订文字",identity:"quote:"+record.id.uuidString).id("quote:"+record.id.uuidString).frame(height:300) }
                    else if current.quote.count>400 { DisclosureGroup("展开原文（\(current.quote.count) 字）") { Text(current.quote).textSelection(.enabled) } }
                    else if !current.quote.isEmpty { Text(current.quote).textSelection(.enabled) }
                }
                if let origin = current.pdfOrigin {
                    if !origin.contents.isEmpty { Text(origin.contents).textSelection(.enabled).id("comment:"+record.id.uuidString) }
                    if !current.quote.isEmpty,current.quote != origin.contents {
                        Text(current.quote).font(.system(size:16)).textSelection(.enabled).id("quote:"+record.id.uuidString)
                    }
                }
                if current.kind == .note && !current.quote.isEmpty {
                    DisclosureGroup("关联原文",isExpanded:$showLinkedQuote) {
                        Text(current.quote).font(.system(size:16)).textSelection(.enabled)
                    }.id("quote:"+record.id.uuidString)
                }
                if let image = current.imageAsset, imageOCR.text.isEmpty { ReadingRecordImage(url:journal.assetURL(image),pending:journal.pendingImage(image)).frame(maxHeight:220) }
                if current.kind == .image {
                    imageRecognition.onAppear { imageOCR.restoreSegments(current); startRequestedOCR() }
                }
                if let original = current.originalQuote ?? current.originalOCR {
                    DisclosureGroup("校订前文字",isExpanded:$showOriginal) { Text(original).textSelection(.enabled) }
                        .id("original:"+record.id.uuidString)
                }
                Text(current.kind == .note || current.pdfOrigin != nil ? "我的笔记" : "我的理解与评论").font(.caption)
                LibraryWritingEditor(text:binding(\.note),label:"阅读笔记正文",identity:"note:"+record.id.uuidString,
                    onEscape:store.quickExcerptNoteID == record.id ? { store.returnFromExcerptNote(record.id) } : nil).id("note:"+record.id.uuidString).frame(height:380)
                if current.kind == .note {
                    ReadingFollowUpButton(journal:journal,item:.record(record.id),identity:"note:"+record.id.uuidString)
                }
                DisclosureGroup("标签与出处（\(current.citations.count)）") {
                    VStack(alignment:.leading,spacing:12) {
                ReadingTagField(journal:journal,label:"标签，以逗号分隔",text:Binding(get:{current.tags.joined(separator:", ")},set:{ text in journal.editRecord(record.id) { $0.tags = Self.tags(text) } }))
                ForEach(Array(current.citations.prefix(20).enumerated()),id:\.offset) { index,citation in
                    VStack(alignment:.leading) {
                        ReadingCitationEditor(journal:journal,record:record.id,index:index).disabled(current.pdfOrigin != nil)
                        Text(current.wholeBook ? "《"+citation.title+"》 · 整本书" : citation.display).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("原文上下文…") { contextSource = ReadingContextRequest(source:citation.source) }
                            Button("返回原文") { sourceNavigator.open(citation,record:current,store:store) }.disabled(sourceNavigator.busy)
                            Button("核对出处…") { sourceNavigator.open(citation,record:current,store:store,reviewOnly:true) }.disabled(sourceNavigator.busy)
                        }
                    }
                }
                if current.citations.count > 20 { Text("另有来源页，导出时一并保留").font(.caption) }
                    }.padding(.vertical,8)
                }.font(.system(size:13))
                HStack {
                    Button("加入笔记") { let id = journal.currentEssayID ?? journal.newEssay(); store.insertReadingRecord(current,in:id); store.openReadingDesk(.essays,window:true) }
                    Button("导出这条记录") { store.exportCheckedReadingRecords(only:record.id) }
                }.disabled(journal.draftRecord?.id == record.id || !current.hasContent)
            }.padding(.horizontal,12).padding(.top,topPadding).padding(.bottom,8)

        }.task(id:store.quickExcerptNoteID) {
            guard store.quickExcerptNoteID == record.id else { return }
            let identity = "note:"+record.id.uuidString
            proxy.scrollTo(identity,anchor:.center)
            for _ in 0..<15 {
                if WritingRegistry.focus(identity) { return }
                do { try await Task.sleep(nanoseconds:40_000_000) } catch { return }
            }
        }.onChange(of:store.writingSearchRequest,initial:true) { _,token in
            guard let hit = store.writingSearchHit else { return }
            let fields = hit.identity.split(separator:":")
            guard fields.count >= 2,fields[1] == record.id.uuidString else { return }
            if hit.identity.hasPrefix("quote:") {
                if current.kind == .note { showLinkedQuote = true }
                else if current.pdfOrigin == nil { editQuote = true }
            }
            if hit.identity.hasPrefix("segment:") { editQuote = true }
            if hit.identity.hasPrefix("original:") { showOriginal = true }
            focusedSegment = hit.identity.hasPrefix("segment-original:") ? hit.identity : nil
            if hit.identity.hasPrefix("quotation:"), fields.count == 3, let id = UUID(uuidString:String(fields[2])) {
                DispatchQueue.main.async { proxy.scrollTo(id,anchor:.center) }
            } else { DispatchQueue.main.async { proxy.scrollTo(hit.identity,anchor:.center) } }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { if store.writingSearchRequest == token { WritingRegistry.jumpIfCurrent(hit) } }
        }.onChange(of:store.readingDetailRequest,initial:true) { _,request in
            guard let request, request.item == .record(record.id) else { return }
            switch request.target {
            case .quotation(let quoteID): DispatchQueue.main.async { proxy.scrollTo(quoteID,anchor:.center) }
            case .linkedQuote:
                showLinkedQuote = true
                DispatchQueue.main.async { proxy.scrollTo("quote:"+record.id.uuidString,anchor:.center) }
            case .block: break
            }
        }
        }.sheet(isPresented:$showQuoteCorrection) { ReadingQuoteCorrectionView(journal:journal,record:current) }.sheet(item:$contextSource) { request in ReadingContextView(store:store,source:request.source) }.onAppear { if journal.draftRecord?.id == record.id && record.kind != .note { editQuote = true } } .onChange(of:store.readingImageOCRRequest) { _,_ in startRequestedOCR() }
        .onDisappear { imageOCR.cancel(); sourceNavigator.cancel() }
        .sheet(item:$sourceNavigator.review,onDismiss:{ sourceNavigator.cancel() }) { request in
            ReadingSourceReviewSheet(request:request,navigator:sourceNavigator,store:store).id(request.id)
        }
        .sheet(isPresented:$showOCRComparison) {
            ReadingImageOCRComparisonSheet(controller:imageOCR,record:current,journal:journal,store:store) { applyOCR() }
        }
        .sheet(isPresented:$showLinkPicker) {
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
    private var noteSourceControls: some View {
        let canSwitch = current.canChangeNoteSource
        let canAdd = store.currentNoteSourceWorkspace != nil && current.removed == nil
        return VStack(alignment:.leading,spacing:4) {
            if canSwitch || canAdd || !current.citations053.isEmpty {
                Menu {
                    if canSwitch {
                        let hasSource = canAdd || !current.citations.isEmpty
                        Button(current.citations.isEmpty ? "关联到当前页" : "关联到出处页") { changeSource(.currentPage) }.disabled(!hasSource)
                        Button("关联到整本书") { changeSource(.wholeBook) }.disabled(!hasSource)
                        Button("设为独立笔记") { changeSource(.independent) }
                        Divider()
                    }
                    if canAdd {
                        Button(current.wholeBook ? "改为页码出处并添加当前页" : "添加当前页为出处") {
                            noteSourceStatus = store.addCurrentPageToNote(record.id) ? "已更新出处" : "当前页已在出处中"
                        }
                    }
                    ForEach(Array(current.citations053.enumerated()),id:\.offset) { _, citation in
                        Button("返回 " + citation.display) { sourceNavigator.open(citation,record:current,store:store) }
                            .disabled(sourceNavigator.busy)
                    }
                } label: { noteSourceLabel }.menuStyle(.borderlessButton)
                    .help("查看或修改笔记出处")
            } else { noteSourceLabel }
            if !noteSourceStatus.isEmpty { Text(noteSourceStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var noteSourceLabel: some View {
        Label(current.noteSourceSummary,systemImage:"link")
            .lineLimit(1).help(current.noteSourceSummary)
    }
    private func changeSource(_ source: ReadingNoteSource) {
        store.changeNoteSource(record.id,to:source)
        noteSourceStatus = ""
    }
    private var segmentedExcerpt: some View {
        VStack(alignment:.leading,spacing:8) {
            Button(editQuote ? "完成分段校订" : "校订各段") { editQuote.toggle() }
            ReadingExcerptSegmentsView(journal:journal,record:current,editing:editQuote,
                openSource:{ sourceNavigator.open($0,record:current,store:store) },
                showContext:{ contextSource = ReadingContextRequest(source:$0) },focusedIdentity:focusedSegment)
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
                HStack {
                    Button("图片与文字对照…") { showOCRComparison = true }
                    Button("采用识别文字") { applyOCR() }
                }
            }
            if !imageOCR.message.isEmpty { Text(imageOCR.message).font(.caption) }
        }
    }
    private func startRequestedOCR() {
        guard let request = store.readingImageOCRRequest, request.recordID == record.id,
              current.kind == .image else { return }
        store.readingImageOCRRequest = nil
        imageOCR.recognize(current,journal:journal,vertical:request.mode != .horizontal,
                           traditional:request.mode == .traditional)
    }

    private func applyOCR() {
        journal.editRecord(record.id) {
            $0.originalQuote = $0.originalQuote ?? ($0.quote.isEmpty ? nil : $0.quote)
            $0.originalOCR = $0.originalOCR ?? imageOCR.originalText
            $0.quote = imageOCR.text
            $0.ocrSegments = imageOCR.segments
        }
        editQuote = true
    }

    private func binding(_ key:WritableKeyPath<ReadingRecord,String>) -> Binding<String> { Binding(get:{current[keyPath:key]},set:{text in journal.editRecord(record.id) { if key == \ReadingRecord.quote, $0.originalQuote == nil, !$0.quote.isEmpty { $0.originalQuote = $0.quote };$0[keyPath:key] = text }}) }
    static func tags(_ text:String) -> [String] { var seen = Set<String>(); return text.replacingOccurrences(of:"，",with:",").split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty && seen.insert($0).inserted} }
}
