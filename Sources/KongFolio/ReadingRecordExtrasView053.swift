import SwiftUI

struct ReadingRecordExtrasView053:View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    var item:ReadingLibraryItem
    @State private var tools=false
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
                DisclosureGroup("引用副本："+quote.title) { VStack(alignment:.leading,spacing:8) { Text(quote.text).textSelection(.enabled);Text(quote.citations.map{ReadingExportOrdering.citation($0)}.joined(separator:"\n")).font(.caption).foregroundStyle(.secondary) } }
            }
            if case .record(let r)=item,r.kind == .image {
                Button(store.multiRegionTarget053==r.id ? "完成这组图片摘录":"继续框选，追加到这组图片摘录") {
                    if store.multiRegionTarget053==r.id { store.multiRegionTarget053=nil }
                    else { store.multiRegionTarget053=r.id;store.commandWorkspace?.tool = .region;store.commandWorkspace?.status="框选后会追加到这组摘录；可以切换页面继续框选" }
                }
            }
        }.font(.system(size:13))
        .sheet(isPresented:$tools) { ReadingTools053(store:store,journal:journal,ids:[item.id]) }
    }
}
