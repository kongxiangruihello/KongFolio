import SwiftUI

struct ReadingRecordExtrasView053:View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    var item:ReadingLibraryItem
    @State private var tools=false
    @State private var versionPair: ReadingExcerptVersionPair?
    @State private var showFollowUps = false
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(item.extras053.review?.rawValue ?? "待核对").font(.caption).foregroundStyle(.secondary)
                if let meaning=item.extras053.colorMeaning,!meaning.isEmpty { Text(meaning).font(.caption) }
                Spacer()
                Button("核对、历史与整理…") { tools=true }
            }
            if let visual=item.extras053.visualAsset { DisclosureGroup("来源与标注快照（原标注移除后仍保留）") { ReadingRecordImage(url:journal.assetURL(visual),pending:journal.pendingImage(visual)).frame(maxHeight:220) } }
            ForEach(item.extras053.regions ?? []) { region in
                DisclosureGroup(region.citation.display) { ReadingRecordImage(url:journal.assetURL(region.asset),pending:journal.pendingImage(region.asset)).frame(maxHeight:320);Button("返回此区域原页") { _=store.reveal(region.citation.source,beside:false) } }
            }
            ForEach(item.extras053.quotations ?? []) { quote in
                ReadingQuotationCard(store:store,journal:journal,item:item.id,quote:quote).id(quote.id)
            }
            if case .record(let record) = item, record.isExcerpt {
                let variants = (record.extras?.versionExcerpts ?? []).compactMap { journal.record($0) }.filter { $0.removed == nil }
                HStack {
                    Menu(record.extras?.triage?.rawValue ?? "待整理标记") {
                        ForEach(ReadingTriage.allCases,id:\.self) { value in
                            Button(value.rawValue) { journal.updateExtras053([item.id]) { $0.triage = value } }
                        }
                        Button("清除标记") { journal.updateExtras053([item.id]) { $0.triage = nil } }
                    }.disabled(journal.unreadable || record.removed != nil)
                    if !variants.isEmpty {
                        Menu("版本对照") {
                            ForEach(variants) { variant in
                                Button(variant.displayTitle) { versionPair = ReadingExcerptVersionPair(left:record.id,right:variant.id) }
                            }
                        }
                    }
                }
            }
            let questions = (item.extras053.followUps ?? []).filter { $0.resolved == nil }
            if item.extras053.followUps?.isEmpty == false {
                Button("待查问题（\(questions.count)）") { showFollowUps = true }
            }
            if case .record(let r)=item,r.kind == .image {
                Button(store.multiRegionTarget053==r.id ? "完成这组图片摘录":"继续框选，追加到这组图片摘录") {
                    if store.multiRegionTarget053==r.id { store.multiRegionTarget053=nil }
                    else { store.multiRegionTarget053=r.id;store.commandWorkspace?.tool = .region;store.commandWorkspace?.status="框选后会追加到这组摘录；可以切换页面继续框选" }
                }
            }
        }.font(.system(size:13))
        .sheet(item:$versionPair) { ReadingExcerptVersionsSheet(journal:journal,pair:$0) }
        .sheet(isPresented:$showFollowUps) {
            ReadingFollowUpsView(journal:journal,only:item.id) { selected,question in
                _ = store.openFollowUp(selected,question:question)
            }
        }
        .sheet(isPresented:$tools) { ReadingTools053(store:store,journal:journal,ids:[item.id]) }
    }
}


private struct ReadingQuotationCard: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var journal: ReadingJournal
    let item: ReadingLibraryID
    let quote: ReadingQuotation053
    @State private var expanded = false
    @State private var showReview = false
    @State private var reviewed: ReadingQuotation053?
    @State private var message = ""

    private var current: ReadingQuotation053? { journal.currentQuotation(quote) }
    private var changed: Bool {
        guard let current else { return false }
        return quote.text != current.text || quote.citations != current.citations || quote.assets != current.assets
    }

    var body: some View {
        DisclosureGroup("引用副本："+quote.title,isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                Text(quote.text).textSelection(.enabled)
                ForEach(Array(quote.citations.enumerated()),id:\.offset) { _,citation in
                    HStack {
                        Text(ReadingExportOrdering.citation(citation)).textSelection(.enabled)
                        Button("返回原文") { store.reveal(citation.source,beside:false) }
                            .disabled(citation.source.path.isEmpty || citation.source.invalidPage053 == true)
                    }.font(.caption)
                }
                Text("摘录时间 "+ReadingRecordMetadata.date(quote.originalCreated ?? quote.captured))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array((quote.assets ?? []).prefix(8).enumerated()),id:\.offset) { _,asset in
                    ReadingRecordImage(url:journal.assetURL(asset),pending:journal.pendingImage(asset)).frame(maxHeight:150)
                }
                if changed {
                    Button("核对原摘录的更新…") { reviewed = current; showReview = true }.disabled(journal.unreadable)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
        .onChange(of:store.readingDetailRequest,initial:true) { _,request in
            if request?.item == item, request?.target == .quotation(quote.id) { expanded = true }
        }
        .onChange(of:store.writingSearchRequest,initial:true) { _,_ in
            if store.writingSearchHit?.identity == "quotation:"+item.uuid053.uuidString+":"+quote.id.uuidString { expanded = true }
        }
        .sheet(isPresented:$showReview) {
            if let reviewed {
                VStack(alignment:.leading,spacing:12) {
                    Text("核对引用副本").font(.headline)
                    HSplitView {
                        comparison("笔记中的副本",quote)
                        comparison("当前摘录",reviewed)
                    }
                    HStack {
                        Button("保留现有副本") { showReview = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("更新此处引用") {
                            do {
                                try journal.refreshQuotation053(item,quotation:quote.id,expected:quote,reviewed:reviewed)
                                message = "已更新此处引用"; showReview = false
                            } catch { message = error.localizedDescription; showReview = false }
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding(20).adaptiveSheet(width:720,height:430,minimumWidth:460)
            } else {
                VStack {
                    ContentUnavailableView("原摘录暂不可用",systemImage:"doc.text")
                    Button("关闭") { showReview = false }
                }.padding(20)
            }
        }
    }

    private func comparison(_ title:String,_ value:ReadingQuotation053) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:8) {
                Text(title).font(.headline)
                Text(value.text).textSelection(.enabled)
                Text(value.citations.map(ReadingExportOrdering.citation).joined(separator:"\n"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
        }.frame(minWidth:200)
    }
}
