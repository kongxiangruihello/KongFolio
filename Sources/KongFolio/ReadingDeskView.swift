import SwiftUI

struct ReadingDeskView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @Binding var section:ReadingDeskSection
    var compact = false
    @State private var query = ""
    @State private var tag = ""
    private enum NoteFilter: String, CaseIterable {
        case current = "当前书", independent = "独立笔记", all = "全部"
    }
    @State private var noteFilter = NoteFilter.current
    @State private var excerptsBookOnly = true
    @State private var recent = false
    @State private var removed = false
    @State private var page = 0
    @State private var excerptInList: UUID?
    @State private var excerptScrollTarget: UUID?
    @State private var pendingExcerptReveal: UUID?
    @State private var highlightedExcerpt: UUID?
    @AppStorage("readingRecordsPageSize") private var pageSize = 10
    private var path:String? { store.commandWorkspace?.readingJournalPath }
    @State private var hits:[ReadingDeskHit] = []
    private var sourceFilter: ReadingDeskSourceFilter {
        if section == .notes && noteFilter == .independent { return .independent }
        let currentBookOnly = section == .notes ? noteFilter == .current : excerptsBookOnly
        if currentBookOnly, let path { return .book(path) }
        return .all
    }
    private struct RecordsRequest: Hashable {
        let revision: Int
        let section: ReadingDeskSection
        let source: ReadingDeskSourceFilter
        let query: String
        let tag: String
        let removed: Bool
        let recent: Bool
    }
    private var searchRequest: RecordsRequest {
        RecordsRequest(revision:journal.revisionID,section:section,source:sourceFilter,query:query,tag:tag,removed:removed,recent:recent)
    }
    private var pagination: ReadingPagination { ReadingPagination(total: hits.count, page: page, size: pageSize) }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if section == .excerpts, let feedback = store.readingExcerptFeedback { excerptFeedback(feedback) }
            if !compact && section != .search {
                ReadingDeskHeader(title:"阅读记录",section:$section)
            }
            if section == .exports { ReadingExportPane(store:store,journal:journal) }
            else if section == .search { ReadingLibraryView(store:store,journal:journal,section:$section,compact:compact,showsDeskHeader:!compact) }
            else if section == .essays { ReadingEssayPane(store:store,journal:journal) }
            else { records }
            Divider()
            ReadingSaveRecoveryFooter(journal:journal)
            if let message = journal.pdfCaptureMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            if let backupError = journal.backupError { Text("记录保存不受影响，自动备份尚未完成："+backupError).font(.caption).foregroundStyle(.orange) }
            if journal.unreadable { Button("保留损坏文件并恢复上一份记录") { do { try journal.recoverPrevious() } catch { store.present(error) } } }
        }.padding(compact ? 10 : 18)
        .task(id:searchRequest) {
            let request = searchRequest
            guard request.section == .notes || request.section == .excerpts else { return }
            do { try await Task.sleep(nanoseconds:300_000_000) } catch { return }
            let result = await ReadingSearchWorker.shared.records(journal.state,query:request.query,notes:request.section == .notes,
                                                                  source:request.source,tag:request.tag,removed:request.removed,recent:request.recent)
            if !Task.isCancelled {
                hits = result
                positionCapturedExcerpt(in:result)
            }
        }
        .onChange(of:store.readingExcerptFeedback?.id,initial:true) { _,_ in
            if section == .excerpts, let feedback = store.readingExcerptFeedback { locateCapturedExcerpt(feedback) }
        }
        .task(id:highlightedExcerpt) {
            guard highlightedExcerpt != nil else { return }
            do { try await Task.sleep(nanoseconds:2_000_000_000) } catch { return }
            highlightedExcerpt = nil
        }
        .onChange(of:query) { _,_ in page = 0 }.onChange(of:tag) { _,_ in page = 0 }.onChange(of:path) { _,_ in page = 0 }
        .onChange(of:section) { _,_ in page = 0 }
        .onChange(of:sourceFilter) { _,_ in page = 0 }.onChange(of:recent) { _,_ in page = 0 }.onChange(of:removed) { _,_ in page = 0 }
        .onChange(of:pageSize) { _,_ in page = 0 }.onChange(of:hits.count) { _,_ in page = pagination.index }
        .onChange(of:journal.draftRecord?.id) { _,id in if id != nil { page = 0; query = ""; tag = ""; removed = false; recent = false } }
    }
    private var selectedRecord: ReadingRecord? {
        let ids = [store.readingImageOCRRequest?.recordID,store.pinnedReadingID,store.readingRecordID]
        let selected = ids.compactMap { journal.record($0) }.first { ($0.kind == .note) == (section == .notes) }
        if section == .excerpts, let excerptInList, selected?.id == excerptInList,
           store.readingImageOCRRequest?.recordID != excerptInList { return nil }
        return selected
    }
    private var records: some View {
        ReadingBrowserLayout(hasEditor:selectedRecord != nil,compact:compact,onBack:{
            if section == .notes { store.lastRightPanelNoteID = nil }
            if section == .excerpts { excerptInList = store.readingRecordID }
            if section == .notes || store.pinnedExcerptNote == nil { store.pinnedReadingID = nil }
            store.readingRecordID = nil
        }) {
            recordList
        } editor: {
            if let record = selectedRecord {
                if section == .notes {
                    if journal.draftRecord?.id == record.id {
                        Text("空白草稿 · 输入内容后才加入记录").font(.caption).foregroundStyle(.secondary)
                    }
                    LibraryRecordDetail(store:store,journal:journal,record:record,inReadingSidebar:compact).id(record.id).disabled(journal.unreadable)
                } else {
                    ReadingRecordDetail(store:store,journal:journal,record:record,onNewLinkedNote:{ createNote(linked:$0) })
                        .id(record.id).disabled(journal.unreadable)
                }
            }
        }
    }
    private var recordList: some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("搜索摘录、笔记、书名或页码",text:$query).textFieldStyle(.roundedBorder)
            if section == .notes {
                Picker("笔记范围",selection:Binding(
                    get:{ path == nil && noteFilter == .current ? .all : noteFilter },
                    set:{ noteFilter = $0 }
                )) {
                    ForEach(NoteFilter.allCases.filter { $0 != .current || path != nil },id:\.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }.pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                if section == .excerpts { Toggle("仅当前书",isOn:$excerptsBookOnly).disabled(path == nil) }
                Toggle("最近七天",isOn:$recent)
            }.font(.caption)
            HStack {
                TextField("按标签筛选",text:$tag)
                Toggle("最近移除",isOn:$removed).font(.caption)
            }
            if section == .excerpts {
                HStack {
                    if compact { Menu("摘录操作") { ReadingExcerptActions(store:store) } }
                    if !store.readingRecordSelection.isEmpty {
                        Button("按选中顺序导出…") { store.exportCheckedReadingRecords() }
                    }
                }
            }
            if section == .notes {
                Menu("新建笔记") {
                    Button("当前页笔记") { createNote() }.disabled(store.currentNoteSourceWorkspace == nil)
                    Button("整本书心得") { createNote(source:.wholeBook) }.disabled(store.currentNoteSourceWorkspace == nil)
                    Button("独立笔记") { createNote(source:.independent) }
                    if let current = journal.record(store.readingRecordID), current.kind != .note {
                        Button("关联这条摘录的笔记") { createNote(linked:current) }
                    }
                }.disabled(journal.unreadable)
            }
            ScrollViewReader { proxy in
                List { ForEach(Array(hits.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { hit in
                switch hit {
                case .record(let record): row(record).id(record.id)
                case .essay(let essay):
                    Button { journal.selectEssay(essay.id); section = .essays } label: {
                        VStack(alignment:.leading,spacing:3) {
                            Label(essay.title,systemImage:"doc.text").lineLimit(2).help(essay.title)
                            let source = ReadingLibraryItem.essay(essay).citations053.first?.display ?? "独立笔记"
                            Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(source)
                        }
                    }.buttonStyle(.plain)
                }
            } }
                .frame(minHeight:100,maxHeight:.infinity)
                .overlay { if hits.isEmpty { Text("这里保存你的摘录、标注、评论和笔记").font(.caption).foregroundStyle(.secondary).allowsHitTesting(false) } }
                .task(id:excerptScrollTarget) {
                    guard let id = excerptScrollTarget else { return }
                    await Task.yield()
                    if !Task.isCancelled { proxy.scrollTo(id,anchor:.center) }
                }
            }
            ReadingPageControls(pagination: pagination, page: $page, size: $pageSize)
        }
    }
    private func excerptFeedback(_ feedback: ReadingExcerptFeedback) -> some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(feedback.message).lineLimit(1).help(feedback.message)
                Spacer(minLength:0)
                Button { store.readingExcerptFeedback = nil } label: { Image(systemName:"xmark") }.help("关闭摘录提示")
            }
            HStack(spacing:10) {
                if let excerpt = journal.record(feedback.recordID) {
                    Button("写笔记") { store.startNoteFromExcerpt(excerpt) }.disabled(journal.unreadable)
                    if let note = store.pinnedExcerptNote {
                        Button("加入固定笔记") {
                            let added = journal.appendExcerpt(excerpt.id,toNote:note.id)
                            let message = added > 0 ? "已加入固定笔记" : "固定笔记已包含此摘录"
                            store.readingExcerptFeedback = ReadingExcerptFeedback(recordID:excerpt.id,message:message)
                        }.help(note.displayTitle).disabled(journal.unreadable)
                    }
                }
                Menu("更多") {
                    Button("写摘录备注") { excerptInList = nil; store.readingRecordID = feedback.recordID }
                        .disabled(journal.record(feedback.recordID) == nil)
                    ForEach(ReadingTriage.allCases,id:\.self) { status in
                        Button("标为"+status.rawValue) { journal.updateExtras053([.record(feedback.recordID)]) { $0.triage = status } }
                            .disabled(journal.unreadable || journal.record(feedback.recordID) == nil)
                    }
                    if store.readingExcerptUndo?.saved.id == feedback.recordID,
                       journal.record(feedback.recordID) == store.readingExcerptUndo?.saved {
                        Button("撤销这次摘录") { _ = store.undoCapturedExcerpt(feedback.recordID) }
                    }
                }
            }
        }.font(.caption).buttonStyle(.borderless).padding(6)
            .background(Color.accentColor.opacity(0.10),in:RoundedRectangle(cornerRadius:6))
    }

    private func locateCapturedExcerpt(_ feedback: ReadingExcerptFeedback) {
        guard let record = journal.record(feedback.recordID) else { return }
        excerptInList = record.id
        highlightedExcerpt = record.id
        excerptScrollTarget = nil
        pendingExcerptReveal = record.id
        if !record.matches(query,tag:tag) { query = "";tag = "" }
        if recent && record.modified < Date().addingTimeInterval(-7*86400) { recent = false }
        removed = false
        if excerptsBookOnly, let path, !ReadingLibraryItem.record(record).isFromBook(path) {
            excerptsBookOnly = false
        }
        positionCapturedExcerpt(in:hits)
    }

    private func positionCapturedExcerpt(in results: [ReadingDeskHit]) {
        guard section == .excerpts, let id = pendingExcerptReveal,
              let index = results.firstIndex(where:{ $0.id == "record:"+id.uuidString }) else { return }
        page = index/max(1,pageSize)
        excerptScrollTarget = id
        pendingExcerptReveal = nil
    }

    private func createNote(source:ReadingNoteSource = .currentPage,linked:ReadingRecord? = nil) {
        if compact { store.newReadingNote(source:source,linked:linked) }
        else if store.prepareReadingNote(source:source,linked:linked) != nil { section = .notes }
    }
    private func row(_ record:ReadingRecord) -> some View {
        HStack(alignment:.top) {
            Toggle("选择记录",isOn:Binding(get:{store.readingRecordSelection.contains(record.id)},set:{ if $0 { store.readingRecordSelection.insert(record.id) } else { store.readingRecordSelection.remove(record.id) } })).labelsHidden()
            if section == .excerpts, let index = store.readingRecordSelectionOrder.firstIndex(of:record.id) {
                Text("\(index+1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("第 \(index+1) 个选中")
            }
            Button {
                excerptInList = nil
                if section == .notes || store.pinnedExcerptNote == nil { store.pinnedReadingID = nil }
                store.readingRecordID = record.id
            } label: {
                VStack(alignment:.leading,spacing:3) {
                    Text(record.displayTitle).lineLimit(2).help(record.displayTitle)
                    if record.kind == .note {
                        Text(record.noteSourceSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(record.noteSourceSummary)
                    } else if let source = record.citations.first {
                        Text(source.display).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(source.display)
                    }
                    if let remark = record.excerptRemark, !remark.isEmpty {
                        Text(remark).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !record.tags.isEmpty { Text(record.tags.joined(separator:" · ")).font(.caption).foregroundStyle(.blue) }
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.vertical,3).listRowBackground(highlightedExcerpt == record.id ? Color.accentColor.opacity(0.23) :
                                                       (store.readingRecordID == record.id ? Color.accentColor.opacity(0.10) : .clear))
    }
}
struct ReadingRecordDetail: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    let record:ReadingRecord
    var onNewLinkedNote: ((ReadingRecord) -> Void)?
    @State private var contextSource:ReadingContextRequest?
    @State private var editQuote = false
    @State private var showQuoteCorrection = false
    @State private var showLinkPicker = false
    @StateObject private var imageOCR = ReadingImageOCRController()
    @StateObject private var sourceNavigator = ReadingSourceNavigator()
    @State private var showOCRComparison = false
    private var current:ReadingRecord { journal.record(record.id) ?? record }
    var body:some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                HStack { Button(store.pinnedReadingID == record.id ? "取消固定这条笔记" : "固定这条记录，翻页时继续写") { store.pinnedReadingID = store.pinnedReadingID == record.id ? nil : record.id };if store.pinnedReadingID == record.id { Text("已固定："+current.displayTitle).font(.caption).lineLimit(1) } }
                ReadingRecordMetadataView(record:current)
                if sourceNavigator.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在核对出处…").font(.caption)
                        Button("停止") { sourceNavigator.cancel() }
                    }
                }
                StableTextField("记录标题（可留空）",text:binding(\.title))
                if current.kind == .excerpt || current.kind == .image {
                    ReadingExcerptRemarkField(journal:journal,recordID:record.id)
                }
                if current.excerptSegments != nil {
                    segmentedExcerpt
                } else if current.kind != .note {
                    HStack { Text("摘录原文").font(.caption); Spacer(); Button("原文与校订对照…") { showQuoteCorrection = true }; Button(editQuote ? "完成文字校正" : "校正摘录文字") { editQuote.toggle() } }
                    if editQuote { ReadingWritingEditor(text:binding(\.quote),label:"摘录校订文字",identity:"quote:"+record.id.uuidString).id("quote:"+record.id.uuidString).frame(height:100).border(.quaternary) }
                    else if !current.quote.isEmpty { Text(current.quote).textSelection(.enabled) }
                }
                if current.kind == .note && !current.quote.isEmpty { Text("关联原文").font(.caption); Text(current.quote).textSelection(.enabled) }
                if let image = current.imageAsset, imageOCR.text.isEmpty { ReadingRecordImage(url:journal.assetURL(image),pending:journal.pendingImage(image)).frame(maxHeight:220) }
                if current.kind == .image {
                    imageRecognition.onAppear { imageOCR.restoreSegments(current); startRequestedOCR() }
                }
                if let original = current.originalQuote ?? current.originalOCR { DisclosureGroup("校订前文字（保留）") { Text(original).textSelection(.enabled) } }
                Text("原文引用与我的笔记分别保存；校订只修改摘录副本。").font(.caption).foregroundStyle(.secondary)
                if current.kind == .note { Button("关联更多摘录…") { showLinkPicker = true } }
                Text(current.kind == .note ? "我的笔记" : "我的理解与评论").font(.caption)
                ReadingWritingEditor(text:binding(\.note),label:"阅读笔记正文",identity:"note:"+record.id.uuidString).id("note:"+record.id.uuidString).frame(minHeight:120).border(.quaternary)
                ReadingTagField(journal:journal,label:"标签，以逗号分隔",text:Binding(get:{current.tags.joined(separator:", ")},set:{ text in journal.editRecord(record.id) { $0.tags = Self.tags(text) } }))
                ForEach(Array(current.citations.prefix(20).enumerated()),id:\.offset) { index,citation in
                    VStack(alignment:.leading) {
                        ReadingCitationEditor(journal:journal,record:record.id,index:index)
                        Text(current.wholeBook ? "《"+citation.title+"》 · 整本书" : citation.display).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("原文上下文…") { contextSource = ReadingContextRequest(source:citation.source) }
                            Button("返回原文") { sourceNavigator.open(citation,record:current,store:store) }.disabled(sourceNavigator.busy)
                            Button("核对出处…") { sourceNavigator.open(citation,record:current,store:store,reviewOnly:true) }.disabled(sourceNavigator.busy)
                        }
                    }
                }
                if current.citations.count > 20 { Text("另有来源页，导出时一并保留").font(.caption) }
                HStack {
                    Button("加入笔记") { let id = journal.currentEssayID ?? journal.newEssay(); store.insertReadingRecord(current,in:id); store.openReadingDesk(.essays,window:true) }
                    Button("导出这条记录") { store.exportCheckedReadingRecords(only:record.id) }
                }.disabled(journal.draftRecord?.id == record.id || !current.hasContent)
                if current.kind != .note {
                    Button("针对摘录写笔记") {
                        if let onNewLinkedNote { onNewLinkedNote(current) }
                        else { store.newReadingNote(linked:current) }
                    }
                }
                if journal.draftRecord?.id == record.id { Button("关闭空白草稿") { journal.discardNoteDraft(); store.readingRecordID = nil } }
                else if current.removed != nil { Button("恢复记录") { journal.editRecord(record.id) { $0.removed = nil } } }
                else { Button("移到最近移除") { journal.editRecord(record.id) { $0.removed = Date() }; store.readingRecordID = nil; store.readingRecordSelection.remove(record.id) } }
            }
        }.onChange(of:store.writingSearchRequest) { _,token in
            guard let hit = store.writingSearchHit,hit.identity.hasSuffix(record.id.uuidString) else { return }
            if hit.identity.hasPrefix("quote:") { editQuote = true }
            DispatchQueue.main.async { proxy.scrollTo(hit.identity,anchor:.center) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { if store.writingSearchRequest == token { WritingRegistry.jumpIfCurrent(hit) } }
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
    private var segmentedExcerpt: some View {
        VStack(alignment:.leading,spacing:8) {
            Button(editQuote ? "完成分段校订" : "校订各段") { editQuote.toggle() }
            ReadingExcerptSegmentsView(journal:journal,record:current,editing:editQuote,
                openSource:{ sourceNavigator.open($0,record:current,store:store) },
                showContext:{ contextSource = ReadingContextRequest(source:$0) })
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
struct ReadingRecordImage: View {
    var url:URL
    var pending:Data? = nil
    var region:CGRect? = nil
    @State private var image:NSImage?
    @State private var failed = false
    var body:some View {
        Group {
            if let image {
                Image(nsImage:image).resizable().scaledToFit()
                    .overlay {
                        if let region {
                            GeometryReader { proxy in
                                if let box = ReadingOCRSegments.previewRegion(region,in:proxy.size) {
                                    Rectangle().fill(Color.orange.opacity(0.20))
                                        .overlay { Rectangle().strokeBorder(.orange,lineWidth:2) }
                                        .frame(width:box.width,height:box.height)
                                        .position(x:box.midX,y:box.midY)
                                }
                            }.allowsHitTesting(false)
                        }
                    }
            } else { Text(failed ? "图片暂不可用，可返回原文查看" : "正在载入图片摘录…").font(.caption) }
        }
            .task(id:url.path+(pending == nil ? ":disk" : ":pending")) { let file = url; let data:Data?; if let pending { data = pending } else { data = await Task.detached(priority:.utility) { try? Data(contentsOf:file) }.value }; guard !Task.isCancelled else { return }; image = data.flatMap(NSImage.init(data:)); failed = image == nil }
    }
}

struct ReadingDeskHeader: View {
    let title: String
    @Binding var section: ReadingDeskSection

    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.headline)
            Picker("记录类型",selection:Binding(get:{section == .essays ? .notes : section},set:{section = $0})) {
                ForEach(ReadingDeskSection.allCases.filter{$0 != .essays},id:\.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
        }
    }
}

@MainActor final class ReadingDeskSession:ObservableObject {
    @Published var section:ReadingDeskSection
    init(_ section:ReadingDeskSection) { self.section = section }
}
struct ReadingDeskWindowView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var session:ReadingDeskSession
    var body:some View { ReadingDeskView(store:store,journal:store.journal,section:$session.section).task { await store.importLegacyReadingRecords() } }
}
@MainActor final class ReadingDeskWindowManager {
    static let shared = ReadingDeskWindowManager()
    private var windows:[ObjectIdentifier:ReadingDeskWindowController] = [:]
    func show(_ store:WorkspaceStore) {
        let key = ObjectIdentifier(store)
        if let controller = windows[key] {
            controller.session.section = store.readingDeskWindowSection
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = ReadingDeskWindowController(store:store,section:store.readingDeskWindowSection)
        controller.closed = { [weak self] in self?.windows[key] = nil }; windows[key] = controller
        controller.window?.center(); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}
@MainActor final class ReadingDeskWindowController:NSWindowController,NSWindowDelegate {
    let session:ReadingDeskSession
    var closed:(()->Void)?
    init(store:WorkspaceStore,section:ReadingDeskSection) {
        session = ReadingDeskSession(section)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "阅读资料库 · 摘录、标注、评论与笔记"; window.identifier = NSUserInterfaceItemIdentifier("reading-desk")
        window.minSize = NSSize(width:600,height:460); window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self
        window.contentView = NSHostingView(rootView:ReadingDeskWindowView(store:store,session:session))
    }
    required init?(coder:NSCoder) { fatalError("not used") }
    func windowWillClose(_ notification:Notification) { window?.contentView = nil; closed?() }
}

struct ReadingRecordPicker: View {
    @ObservedObject var journal:ReadingJournal
    var choose:(ReadingRecord)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var page = 0
    @AppStorage("readingRecordsPageSize") private var pageSize = 10
    private var records:[ReadingRecord] { journal.state.records.filter{$0.hasContent && $0.kind != .note && $0.removed == nil && $0.matches(query)}.sorted{$0.modified == $1.modified ? $0.id.uuidString < $1.id.uuidString : $0.modified > $1.modified} }
    private var pagination: ReadingPagination { ReadingPagination(total: records.count, page: page, size: pageSize) }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("选择要关联的摘录").font(.headline); TextField("查找摘录或书名",text:$query)
            List(Array(records.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { record in
                HStack { VStack(alignment:.leading) { Text(record.displayTitle).lineLimit(2); Text(record.citations.map(\.display).joined(separator:" · ")).font(.caption).lineLimit(1) }; Spacer(); Button("关联") { choose(record); dismiss() } }
            }
            ReadingPageControls(pagination: pagination, page: $page, size: $pageSize)
            Button("关闭") { dismiss() }
        }.padding(18).adaptiveSheet(width:700,height:520,minimumWidth:360).onChange(of:query) { _,_ in page = 0 }
        .onChange(of:pageSize) { _,_ in page = 0 }.onChange(of:records.count) { _,_ in page = pagination.index }
    }
}
